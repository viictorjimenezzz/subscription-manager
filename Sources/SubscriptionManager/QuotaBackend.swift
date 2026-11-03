import Foundation

/// One provider session bound to a single account folder.
protocol QuotaBackend: Actor {
    func beginLogin() async throws -> LoginInstructions
    func waitForLogin(id: String) async -> Bool
    func submitLoginCode(_ code: String, loginID: String) async throws
    func cancelLogin(id: String) async
    func status(refreshingToken: Bool) async throws -> AccountStatus
    func applyResetCredit(idempotencyKey: String) async throws -> ResetOutcome
    func logout() async
    func stop() async
}

enum ExecutableLocator {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var shellCache: [String: URL?] = [:]

    /// Looks for `name` in the bundle, the usual install locations, and
    /// finally the user's login shell PATH (apps launched from Finder do not
    /// inherit it).
    static func find(_ name: String, extraCandidates: [String] = []) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name).path {
            candidates.append(bundled)
        }
        candidates += extraCandidates
        candidates += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }
        return loginShellLookup(name)
    }

    private static func loginShellLookup(_ name: String) -> URL? {
        cacheLock.lock()
        if let cached = shellCache[name] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v \(name)"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var result: URL?
        if (try? process.run()) != nil {
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).last ?? ""
            if text.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: text) {
                result = URL(fileURLWithPath: text)
            }
        }
        cacheLock.lock()
        shellCache[name] = result
        cacheLock.unlock()
        return result
    }
}

extension CodexAppServerClient: QuotaBackend {
    func submitLoginCode(_ code: String, loginID: String) async throws {
        throw CodexClientError.rpc(0, "Codex sign-in finishes in the browser.")
    }

    func applyResetCredit(idempotencyKey: String) async throws -> ResetOutcome {
        try await consumeResetCredit(idempotencyKey: idempotencyKey)
    }

    func status(refreshingToken: Bool) async throws -> AccountStatus {
        let accountPayload = try await account(refreshToken: refreshingToken)
        // A forced token refresh can succeed while the current app-server
        // response omits the account object. Read the account normally
        // before treating the session as disconnected.
        let identityPayload: JSONValue
        if CodexPayloadParser.account(from: accountPayload) != nil || !refreshingToken {
            identityPayload = accountPayload
        } else {
            identityPayload = try await account(refreshToken: false)
        }
        guard let identity = CodexPayloadParser.account(from: identityPayload) else {
            throw CodexClientError.notLoggedIn
        }
        guard let quota = CodexPayloadParser.quota(from: try await rateLimits()) else {
            throw CodexClientError.noWeeklyQuota
        }
        return AccountStatus(email: identity.email, plan: identity.plan, quota: quota)
    }
}
