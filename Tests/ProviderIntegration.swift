import Foundation

@main
struct ProviderIntegrationTest {
    static func main() async throws {
        try await codexIsolationAndLogin()
        try await claudeIsolation()
        try await claudeLiveUsageFormat()
    }

    /// A fresh CODEX_HOME starts logged out and can begin a browser login.
    private static func codexIsolationAndLogin() async throws {
        let profile = try temporaryDirectory("codex")
        defer { try? FileManager.default.removeItem(at: profile) }

        let client = CodexAppServerClient(profileURL: profile)
        try await client.start()

        let account = try await client.account(refreshToken: false)
        guard CodexPayloadParser.account(from: account) == nil else {
            throw Failure("Fresh isolated Codex profile unexpectedly contained an account")
        }

        let login = try await client.beginLogin()
        guard login.authURL.scheme == "https", login.loginID.isEmpty == false else {
            throw Failure("Codex did not return valid browser login instructions")
        }
        await client.cancelLogin(id: login.loginID)
        await client.stop()
        print("Codex app-server isolation and login test passed")
    }

    /// A fresh CLAUDE_CONFIG_DIR does not see the default Claude login.
    private static func claudeIsolation() async throws {
        guard ClaudeLocator.executableURL() != nil else {
            print("Claude Code not installed; skipping Claude isolation test")
            return
        }
        let home = try temporaryDirectory("claude")
        defer { try? FileManager.default.removeItem(at: home) }

        let client = ClaudeCLIClient(homeURL: home)
        let status = try await client.authStatus()
        guard status["loggedIn"]?.boolValue == false else {
            throw Failure("Fresh CLAUDE_CONFIG_DIR unexpectedly reported a login")
        }
        guard status["configDirectory"]?.stringValue == home.path else {
            throw Failure("Claude Code ignored CLAUDE_CONFIG_DIR")
        }
        do {
            _ = try await client.status(refreshingToken: false)
            throw Failure("Expected a logged-out status error")
        } catch ClaudeClientError.notLoggedIn {}
        print("Claude Code config isolation test passed")
    }

    /// When the default Claude account is a subscription, its live `/usage`
    /// output must still match the parser.
    private static func claudeLiveUsageFormat() async throws {
        guard let claude = ClaudeLocator.executableURL() else { return }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        let auth = try await ProcessRunner.run(claude, ["auth", "status", "--json"], environment: environment, timeout: 30)
        let payload = try? JSONDecoder().decode(JSONValue.self, from: auth.stdout)
        guard payload?["loggedIn"]?.boolValue == true, payload?["subscriptionType"]?.stringValue != nil else {
            print("No default Claude subscription login; skipping live /usage format test")
            return
        }
        let scratch = try temporaryDirectory("claude-usage")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let usage = try await ProcessRunner.run(
            claude,
            ["-p", "/usage", "--output-format", "json", "--no-session-persistence", "--setting-sources", "project"],
            environment: environment,
            directory: scratch,
            timeout: 90
        )
        guard let text = (try? JSONDecoder().decode(JSONValue.self, from: usage.stdout))?["result"]?.stringValue,
              let quota = ClaudeUsageParser.quota(from: text),
              quota.weekly != nil, quota.session != nil else {
            throw Failure("Live /usage output no longer matches the parser:\n\(usage.output)")
        }
        print("Claude Code live /usage format test passed (\(quota.windows.count) windows)")
    }

    private static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subscription-manager-integration-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
