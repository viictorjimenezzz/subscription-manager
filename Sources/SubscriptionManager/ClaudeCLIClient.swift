import CryptoKit
import Foundation

enum ClaudeClientError: LocalizedError {
    case executableNotFound
    case commandFailed(String)
    case timedOut
    case notLoggedIn
    case notSubscription(String)
    case noUsage
    case loginFailed(String)
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Claude Code was not found. Install it (brew install --cask claude-code), then reopen Subscription Manager."
        case .commandFailed(let detail): return "Claude Code failed: \(detail)"
        case .timedOut: return "Claude Code did not respond in time."
        case .notLoggedIn: return "This account needs to be connected again."
        case .notSubscription(let method): return "This account signs in with \(method), not a Claude subscription."
        case .noUsage: return "Claude Code returned no subscription usage for this account."
        case .loginFailed(let detail): return "Claude sign-in did not start: \(detail)"
        case .keychain(let detail): return "Could not move the Claude login in the Keychain: \(detail)"
        }
    }
}

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var output: String { String(data: stdout, encoding: .utf8) ?? "" }
    var errorOutput: String { String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}

enum ProcessRunner {
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        input: Data? = nil,
        timeout: TimeInterval = 60
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                let stdin = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                if let environment { process.environment = environment }
                if let directory { process.currentDirectoryURL = directory }
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = input == nil ? FileHandle.nullDevice : stdin

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ClaudeClientError.commandFailed(error.localizedDescription))
                    return
                }
                if let input {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                }

                var timedOut = false
                let timer = DispatchWorkItem {
                    timedOut = true
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                var errorData = Data()
                let errorReader = DispatchGroup()
                errorReader.enter()
                DispatchQueue.global().async {
                    errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    errorReader.leave()
                }
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                errorReader.wait()
                process.waitUntilExit()
                timer.cancel()

                if timedOut {
                    continuation.resume(throwing: ClaudeClientError.timedOut)
                } else {
                    continuation.resume(returning: ProcessResult(status: process.terminationStatus, stdout: outputData, stderr: errorData))
                }
            }
        }
    }
}

enum ClaudeLocator {
    static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ExecutableLocator.find("claude", extraCandidates: ["\(home)/.claude/local/claude"])
    }
}

/// Talks to Claude Code through its CLI with `CLAUDE_CONFIG_DIR` pointed at
/// one account folder. The CLI owns token storage and refresh; this client
/// never reads credentials itself.
actor ClaudeCLIClient: QuotaBackend {
    private let homeURL: URL
    private var loginProcess: Process?
    private var loginInput: FileHandle?
    private var loginOutput = Data()
    private var loginID: String?
    private var loginWaiter: CheckedContinuation<Bool, Never>?
    private var loginFinished: Bool?
    private var urlWaiter: CheckedContinuation<URL, Error>?

    init(homeURL: URL) {
        self.homeURL = homeURL
    }

    static func environment(for home: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for name in Provider.claude.conflictingEnvironmentVariables { environment.removeValue(forKey: name) }
        environment["CLAUDE_CONFIG_DIR"] = home.path
        return environment
    }

    private func executable() throws -> URL {
        guard let url = ClaudeLocator.executableURL() else { throw ClaudeClientError.executableNotFound }
        return url
    }

    private func runClaude(_ arguments: [String], timeout: TimeInterval = 60) async throws -> ProcessResult {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try await ProcessRunner.run(
            try executable(),
            arguments,
            environment: Self.environment(for: homeURL),
            directory: homeURL,
            timeout: timeout
        )
    }

    // MARK: Status

    func status(refreshingToken: Bool) async throws -> AccountStatus {
        let auth = try await authStatus()
        guard auth["loggedIn"]?.boolValue == true else { throw ClaudeClientError.notLoggedIn }
        let method = auth["authMethod"]?.stringValue ?? ""
        if method != "claude.ai", auth["subscriptionType"]?.stringValue == nil {
            throw ClaudeClientError.notSubscription(method.isEmpty ? "an API key" : method)
        }

        // `/usage` is a local command: it makes no model request and costs nothing.
        let usage = try await runClaude([
            "-p", "/usage",
            "--output-format", "json",
            "--no-session-persistence",
            "--setting-sources", "project"
        ], timeout: 90)
        guard let payload = try? JSONDecoder().decode(JSONValue.self, from: usage.stdout),
              let text = payload["result"]?.stringValue else {
            throw ClaudeClientError.commandFailed(usage.errorOutput.isEmpty ? "unreadable /usage output" : usage.errorOutput)
        }
        if payload["is_error"]?.boolValue == true { throw ClaudeClientError.commandFailed(text) }
        guard let quota = ClaudeUsageParser.quota(from: text) else { throw ClaudeClientError.noUsage }

        return AccountStatus(
            email: auth["email"]?.stringValue,
            plan: auth["subscriptionType"]?.stringValue,
            quota: quota
        )
    }

    func authStatus() async throws -> JSONValue {
        let result = try await runClaude(["auth", "status", "--json"], timeout: 30)
        guard let payload = try? JSONDecoder().decode(JSONValue.self, from: result.stdout) else {
            throw ClaudeClientError.commandFailed(result.errorOutput.isEmpty ? "unreadable auth status" : result.errorOutput)
        }
        return payload
    }

    // MARK: Login

    func beginLogin() async throws -> LoginInstructions {
        if loginProcess != nil, let loginID { await cancelLogin(id: loginID) }
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = try executable()
        process.arguments = ["auth", "login", "--claudeai"]
        process.environment = Self.environment(for: homeURL)
        process.currentDirectoryURL = homeURL
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input

        let id = UUID().uuidString
        loginID = id
        loginOutput = Data()
        loginFinished = nil

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeLoginOutput(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.loginTerminated(id: id, status: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            throw ClaudeClientError.loginFailed(error.localizedDescription)
        }
        loginProcess = process
        loginInput = input.fileHandleForWriting

        let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            if let url = Self.authorizationURL(in: loginOutput) {
                continuation.resume(returning: url)
                return
            }
            urlWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                await self?.failURLWait(ClaudeClientError.timedOut)
            }
        }
        return LoginInstructions(loginID: id, authURL: url, browserOpened: true, acceptsCode: true)
    }

    func waitForLogin(id: String) async -> Bool {
        guard id == loginID else { return false }
        if let finished = loginFinished { return finished }
        return await withCheckedContinuation { continuation in
            loginWaiter = continuation
        }
    }

    func submitLoginCode(_ code: String, loginID: String) async throws {
        guard loginID == self.loginID, let loginInput else { throw ClaudeClientError.loginFailed("No sign-in is in progress.") }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        try loginInput.write(contentsOf: Data((trimmed + "\n").utf8))
    }

    func cancelLogin(id: String) async {
        guard id == loginID else { return }
        loginProcess?.terminate()
        finishLogin(success: false)
    }

    func logout() async {
        _ = try? await runClaude(["auth", "logout"], timeout: 30)
    }

    func stop() async {
        if let loginID { await cancelLogin(id: loginID) }
    }

    private func consumeLoginOutput(_ data: Data) {
        loginOutput.append(data)
        if let url = Self.authorizationURL(in: loginOutput), let waiter = urlWaiter {
            urlWaiter = nil
            waiter.resume(returning: url)
        }
    }

    private func failURLWait(_ error: Error) {
        guard let waiter = urlWaiter else { return }
        urlWaiter = nil
        let detail = String(data: loginOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        waiter.resume(throwing: detail.isEmpty ? error : ClaudeClientError.loginFailed(detail))
        loginProcess?.terminate()
    }

    private func loginTerminated(id: String, status: Int32) {
        guard id == loginID else { return }
        if urlWaiter != nil { failURLWait(ClaudeClientError.loginFailed("exit status \(status)")) }
        finishLogin(success: status == 0)
    }

    private func finishLogin(success: Bool) {
        loginProcess?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        loginProcess = nil
        try? loginInput?.close()
        loginInput = nil
        loginFinished = success
        loginWaiter?.resume(returning: success)
        loginWaiter = nil
    }

    static func authorizationURL(in data: Data) -> URL? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Drop OSC 8 hyperlink and other escape sequences if a TTY was assumed.
        let cleaned = text.replacingOccurrences(of: #"\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        guard let range = cleaned.range(of: #"https://\S+oauth/authorize\?\S+"#, options: .regularExpression) else { return nil }
        return URL(string: String(cleaned[range]))
    }
}

/// Claude Code stores each `CLAUDE_CONFIG_DIR`'s login in the login Keychain
/// under `Claude Code-credentials-<first 8 hex of sha256(dir)>`. Renaming an
/// account folder therefore has to move that item too.
enum ClaudeKeychain {
    static func serviceName(configDirectory: String) -> String {
        let normalized = configDirectory.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(digest.prefix(8))"
    }

    static var accountName: String {
        let name = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !name.isEmpty && name.unicodeScalars.allSatisfy(allowed.contains) ? name : "claude-code-user"
    }

    private static let security = URL(fileURLWithPath: "/usr/bin/security")

    static func read(configDirectory: String) async throws -> Data? {
        let result = try await ProcessRunner.run(security, ["find-generic-password", "-a", accountName, "-s", serviceName(configDirectory: configDirectory), "-w"], timeout: 20)
        guard result.status == 0 else { return nil }
        var data = result.stdout
        if data.last == 0x0A { data.removeLast() }
        // `security -w` prints the value as hex when it holds non-ASCII bytes.
        // The stored value is JSON, so plain output is never pure hex.
        return decodeHex(data) ?? data
    }

    private static func decodeHex(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count % 2 == 0,
              let text = String(data: data, encoding: .ascii),
              text.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = Data(capacity: data.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Writes through `security -i` so the secret never appears in a process
    /// argument list.
    static func write(_ secret: Data, configDirectory: String) async throws {
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(accountName)\" -s \"\(serviceName(configDirectory: configDirectory))\" -X \"\(hex)\"\n"
        let result = try await ProcessRunner.run(security, ["-i"], input: Data(command.utf8), timeout: 20)
        guard result.status == 0 else {
            throw ClaudeClientError.keychain(result.errorOutput.isEmpty ? "security exited with \(result.status)" : result.errorOutput)
        }
    }

    static func delete(configDirectory: String) async {
        _ = try? await ProcessRunner.run(security, ["delete-generic-password", "-a", accountName, "-s", serviceName(configDirectory: configDirectory)], timeout: 20)
    }
}
