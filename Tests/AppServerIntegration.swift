import Foundation

@main
struct AppServerIntegrationTest {
    static func main() async throws {
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-manager-integration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }

        let client = CodexAppServerClient(profileURL: profile)
        try await client.start()

        let account = try await client.account(refreshToken: false)
        guard CodexPayloadParser.account(from: account) == nil else {
            throw Failure("Fresh isolated profile unexpectedly contained an account")
        }

        let login = try await client.beginLogin()
        guard login.authURL.scheme == "https", login.loginID.isEmpty == false else {
            throw Failure("Codex did not return valid browser login instructions")
        }
        await client.cancelLogin(id: login.loginID)
        await client.stop()
        print("Codex app-server isolation and login test passed")
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
