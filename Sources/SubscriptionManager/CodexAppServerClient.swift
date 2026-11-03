import Foundation

enum CodexClientError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case serverStopped(String)
    case malformedResponse
    case rpc(Int, String)
    case notLoggedIn
    case noWeeklyQuota

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex CLI was not found. Install it (brew install --cask codex), then reopen Subscription Manager."
        case .launchFailed(let detail): return "Could not start Codex: \(detail)"
        case .serverStopped(let detail): return "Codex stopped unexpectedly: \(detail)"
        case .malformedResponse: return "Codex returned an unreadable response."
        case .rpc(_, let message): return message
        case .notLoggedIn: return "This account needs to be connected again."
        case .noWeeklyQuota: return "No weekly Codex quota was returned for this account."
        }
    }
}

enum CodexLocator {
    static func executableURL() -> URL? {
        ExecutableLocator.find("codex")
    }
}

actor CodexAppServerClient {
    private let profileURL: URL
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var stderrBuffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var loginWaiters: [String: CheckedContinuation<Bool, Never>] = [:]
    private var initialized = false

    init(profileURL: URL) {
        self.profileURL = profileURL
    }

    func start() async throws {
        if initialized, process?.isRunning == true { return }
        guard let executable = CodexLocator.executableURL() else { throw CodexClientError.executableNotFound }

        try FileManager.default.createDirectory(
            at: profileURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try writeIsolatedConfigIfNeeded()

        let task = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        let stderr = Pipe()
        task.executableURL = executable
        task.arguments = ["app-server", "--stdio"]
        task.currentDirectoryURL = profileURL
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = profileURL.path
        task.environment = environment
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeOutput(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeError(data) }
        }
        task.terminationHandler = { [weak self] process in
            Task { await self?.processTerminated(status: process.terminationStatus) }
        }

        do {
            try task.run()
        } catch {
            throw CodexClientError.launchFailed(error.localizedDescription)
        }
        process = task
        input = stdin.fileHandleForWriting

        _ = try await requestRaw(method: "initialize", params: .object([
            "clientInfo": .object([
                "name": .string("subscription-manager"),
                "title": .string("Subscription Manager"),
                "version": .string("3.0.0")
            ]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ]))
        try sendNotification(method: "initialized", params: .object([:]))
        initialized = true
    }

    func account(refreshToken: Bool) async throws -> JSONValue {
        try await request(method: "account/read", params: .object(["refreshToken": .bool(refreshToken)]))
    }

    func rateLimits() async throws -> JSONValue {
        try await request(method: "account/rateLimits/read", params: .object([:]))
    }

    func beginLogin() async throws -> LoginInstructions {
        let result = try await request(method: "account/login/start", params: .object([
            "type": .string("chatgpt"),
            "appBrand": .string("codex"),
            "useHostedLoginSuccessPage": .bool(true),
            "codexStreamlinedLogin": .bool(true)
        ]))
        guard let id = result["loginId"]?.stringValue,
              let rawURL = result["authUrl"]?.stringValue,
              let url = URL(string: rawURL) else { throw CodexClientError.malformedResponse }
        return LoginInstructions(loginID: id, authURL: url, browserOpened: false, acceptsCode: false)
    }

    func waitForLogin(id: String) async -> Bool {
        await withCheckedContinuation { continuation in
            loginWaiters[id] = continuation
        }
    }

    func cancelLogin(id: String) async {
        _ = try? await request(method: "account/login/cancel", params: .object(["loginId": .string(id)]))
        loginWaiters.removeValue(forKey: id)?.resume(returning: false)
    }

    func logout() async {
        _ = try? await request(method: "account/logout", params: .object([:]))
    }

    func stop() {
        outputBuffer.removeAll()
        initialized = false
        input?.closeFile()
        input = nil
        process?.terminate()
        process = nil
        failPending(with: CodexClientError.serverStopped("The local helper was closed."))
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        try await start()
        return try await requestRaw(method: method, params: params)
    }

    private func requestRaw(method: String, params: JSONValue) async throws -> JSONValue {
        guard process?.isRunning == true, let input else {
            throw CodexClientError.serverStopped("The local helper is not running.")
        }
        let id = nextID
        nextID += 1
        let payload: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params
        ])
        let encoded = try JSONEncoder().encode(payload) + Data([0x0A])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input.write(contentsOf: encoded)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: CodexClientError.serverStopped(error.localizedDescription))
            }
        }
    }

    private func sendNotification(method: String, params: JSONValue) throws {
        guard let input else { throw CodexClientError.serverStopped("The local helper is not running.") }
        let payload: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params
        ])
        try input.write(contentsOf: JSONEncoder().encode(payload) + Data([0x0A]))
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: Data(line)) else { continue }
            handle(envelope)
        }
    }

    private func handle(_ envelope: RPCEnvelope) {
        if let id = envelope.id, let continuation = pending.removeValue(forKey: id) {
            if let error = envelope.error {
                continuation.resume(throwing: CodexClientError.rpc(error.code, error.message))
            } else if let result = envelope.result {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: CodexClientError.malformedResponse)
            }
            return
        }

        guard envelope.method == "account/login/completed",
              let loginID = envelope.params?["loginId"]?.stringValue else { return }
        let success = envelope.params?["success"]?.boolValue ?? false
        loginWaiters.removeValue(forKey: loginID)?.resume(returning: success)
    }

    private func consumeError(_ data: Data) {
        stderrBuffer.append(data)
        if stderrBuffer.count > 8_192 {
            stderrBuffer.removeFirst(stderrBuffer.count - 8_192)
        }
    }

    private func processTerminated(status: Int32) {
        guard process != nil else { return }
        let detail = String(data: stderrBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        process = nil
        input = nil
        initialized = false
        failPending(with: CodexClientError.serverStopped(detail?.isEmpty == false ? detail! : "exit status \(status)"))
        let waiters = loginWaiters.values
        loginWaiters.removeAll()
        waiters.forEach { $0.resume(returning: false) }
    }

    private func failPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func writeIsolatedConfigIfNeeded() throws {
        let config = profileURL.appendingPathComponent("config.toml")
        guard !FileManager.default.fileExists(atPath: config.path) else { return }
        let contents = """
        cli_auth_credentials_store = "file"

        [analytics]
        enabled = false
        """
        try contents.write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    }
}
