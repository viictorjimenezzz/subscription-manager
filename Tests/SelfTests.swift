import Foundation

@main
struct SubscriptionManagerSelfTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("codex: selects weekly and session windows", selectsWeeklyAndSessionWindows),
            ("codex: prefers codex bucket", prefersCodexNamedBucket),
            ("codex: ignores auxiliary buckets", handlesAdditionalLimitBuckets),
            ("codex: parses ChatGPT account", parsesChatGPTAccount),
            ("codex: parses banked resets", parsesResetCredits),
            ("codex: maps reset outcomes", mapsResetOutcomes),
            ("claude: parses /usage output", parsesClaudeUsage),
            ("claude: parses time-only and next-year resets", parsesClaudeResetVariants),
            ("claude: ignores unrelated output", ignoresLoggedOutUsage),
            ("claude: keychain service name", claudeKeychainServiceName),
            ("claude: extracts authorization URL", extractsAuthorizationURL),
            ("quota: expired windows count as full", expiredWindowsCountAsFull),
            ("vault: slugs", generatesSlugs),
            ("vault: manifest round trip", manifestRoundTrip),
            ("vault: decodes 1.x records", decodesLegacyRecords),
            ("vault: migrates Codex Quota profiles", migratesLegacyProfiles),
            ("vault: links shared config once", linksSharedConfigOnce),
            ("cli: resolves references", resolvesReferences),
            ("cli: environment snippets", environmentSnippets)
        ]
        for (name, test) in tests {
            do {
                try test()
            } catch {
                print("FAIL \(name): \(error.localizedDescription)")
                exit(1)
            }
        }
        print("\(tests.count) self-tests passed")
    }

    // MARK: Codex

    private static func selectsWeeklyAndSessionWindows() throws {
        let payload = try decode("""
        {
          "rateLimits": {
            "primary": {"usedPercent": 23, "windowDurationMins": 300, "resetsAt": 1700000000},
            "secondary": {"usedPercent": 67, "windowDurationMins": 10080, "resetsAt": 1800000000}
          }
        }
        """)
        guard let quota = CodexPayloadParser.quota(from: payload), let weekly = quota.weekly else { throw Failure("Missing weekly quota") }
        try expect(weekly.usedPercent == 67, "Expected weekly percent")
        try expect(weekly.remainingPercent == 33, "Expected inverted remaining percent")
        try expect(weekly.windowDurationMinutes == 10_080, "Expected weekly duration")
        try expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_800_000_000), "Expected reset date")
        try expect(quota.session?.usedPercent == 23, "Expected session window")
        try expect(quota.session?.label == "5h", "Expected 5h label")
    }

    private static func prefersCodexNamedBucket() throws {
        let payload = try decode("""
        {
          "rateLimits": {"secondary": {"usedPercent": 1, "windowDurationMins": 10080}},
          "rateLimitsByLimitId": {
            "other": {"secondary": {"usedPercent": 5, "windowDurationMins": 10080}},
            "codex": {"secondary": {"usedPercent": 91, "windowDurationMins": 10080}}
          }
        }
        """)
        try expect(CodexPayloadParser.quota(from: payload)?.weekly?.usedPercent == 91, "Expected codex bucket")
    }

    private static func handlesAdditionalLimitBuckets() throws {
        let payload = try decode("""
        {
          "rateLimits": {
            "limitId": "codex",
            "primary": {"usedPercent": 100, "windowDurationMins": 10080}
          },
          "rateLimitsByLimitId": {
            "base_model_inference": {
              "primary": {"usedPercent": 13, "windowDurationMins": 10080}
            },
            "codex": {
              "primary": {"usedPercent": 100, "windowDurationMins": 10080}
            }
          }
        }
        """)
        try expect(CodexPayloadParser.quota(from: payload)?.weekly?.usedPercent == 100, "Expected codex bucket over auxiliary bucket")
    }

    private static func parsesChatGPTAccount() throws {
        let payload = try decode("""
        {"requiresOpenaiAuth": true, "account": {"type": "chatgpt", "email": "me@example.com", "planType": "plus"}}
        """)
        guard let account = CodexPayloadParser.account(from: payload) else { throw Failure("Missing account") }
        try expect(account.email == "me@example.com", "Expected email")
        try expect(account.plan == "plus", "Expected plan")
    }

    private static func parsesResetCredits() throws {
        let payload = try decode("""
        {
          "rateLimitsByLimitId": {"codex": {"primary": {"usedPercent": 100, "windowDurationMins": 10080}}},
          "rateLimitResetCredits": {
            "availableCount": 2,
            "credits": [
              {"id": "a", "status": "available", "resetType": "codexRateLimits", "grantedAt": 1793478676, "expiresAt": 1796165951},
              {"id": "b", "status": "available", "resetType": "codexRateLimits", "grantedAt": 1793573951, "expiresAt": 1796070676},
              {"id": "c", "status": "redeemed", "resetType": "codexRateLimits", "grantedAt": 1790000000, "expiresAt": 1700000000}
            ]
          }
        }
        """)
        let credits = CodexPayloadParser.quota(from: payload)?.resetCredits
        let balance = CodexPayloadParser.quota(from: try decode("""
        {"rateLimitsByLimitId": {"codex": {"primary": {"usedPercent": 100, "windowDurationMins": 10080},
         "credits": {"balance": "9452.9336150000", "hasCredits": true, "unlimited": false}}}}
        """))?.credits
        try expect(balance == CreditBalance(balance: 9452.933615, unlimited: false), "Expected credit balance, got \(String(describing: balance))")
        try expect(credits?.available == 2, "Expected two banked resets")
        try expect(credits?.nextExpiry == Date(timeIntervalSince1970: 1_796_070_676), "Expected soonest expiry of available credits")

        let none = try decode(#"{"rateLimits": {"primary": {"usedPercent": 5, "windowDurationMins": 10080}}}"#)
        try expect(CodexPayloadParser.quota(from: none)?.resetCredits == nil, "Expected no reset info")
    }

    private static func mapsResetOutcomes() throws {
        try expect(ResetOutcome("reset") == .reset && ResetOutcome("noCredit") == .noCredit, "Expected known outcomes")
        try expect(ResetOutcome("nothingToReset") == .nothingToReset && ResetOutcome("alreadyRedeemed") == .alreadyRedeemed, "Expected known outcomes")
        try expect(ResetOutcome("future") == .other("future"), "Expected unknown outcome to be kept")
    }

    // MARK: Claude

    private static let zurich = TimeZone(identifier: "Europe/Zurich")!

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ timeZone: TimeZone = zurich) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func parsesClaudeUsage() throws {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 1% used · resets Nov 3 at 2:30pm (Europe/Zurich)
        Current week (all models): 9% used · resets Nov 8 at 9am (Europe/Zurich)
        Current week (Fable): 0% used · resets Nov 8 at 9am (Europe/Zurich)

        What's contributing to your limits usage?
        Last 7d · 4757 requests · 19 sessions
          96% of your usage came from subagent-heavy sessions
        """
        guard let quota = ClaudeUsageParser.quota(from: text, now: date(2026, 11, 3, 10, 0)) else { throw Failure("Missing quota") }
        try expect(quota.windows.count == 3, "Expected three windows, got \(quota.windows.count)")
        try expect(quota.session?.usedPercent == 1, "Expected session percent")
        try expect(quota.session?.resetsAt == date(2026, 11, 3, 14, 30), "Expected session reset")
        try expect(quota.weekly?.usedPercent == 9, "Expected weekly percent")
        try expect(quota.weekly?.remainingPercent == 91, "Expected weekly remaining")
        try expect(quota.weekly?.resetsAt == date(2026, 11, 8, 9, 0), "Expected weekly reset")
        try expect(quota.modelWindows.map(\.label) == ["Fable"], "Expected Fable model window")
        try expect(quota.availablePercent(at: date(2026, 11, 3, 10, 0)) == 91, "Expected tightest general limit")
    }

    private static func parsesClaudeResetVariants() throws {
        let now = date(2026, 12, 30, 20, 0)
        try expect(ClaudeUsageParser.resetDate(from: "Jan 2 at 9am (Europe/Zurich)", now: now) == date(2027, 1, 2, 9, 0), "Expected next-year rollover")
        try expect(ClaudeUsageParser.resetDate(from: "7:15pm (Europe/Zurich)", now: now) == date(2026, 12, 31, 19, 15), "Expected time-only reset tomorrow")
        try expect(ClaudeUsageParser.resetDate(from: "Dec 31, 2026 at 12am (UTC)", now: now) == date(2026, 12, 31, 0, 0, TimeZone(identifier: "UTC")!), "Expected explicit year and midnight")
        let line = ClaudeUsageParser.window(from: "Current week (Sonnet only): 100% used", now: now)
        try expect(line?.kind == .weeklyModel && line?.remainingPercent == 0 && line?.resetsAt == nil, "Expected model window without reset")
    }

    private static func ignoresLoggedOutUsage() throws {
        let text = "Total cost:            $0.0000\nTotal duration (API):  0s\nUsage:                 0 input, 0 output"
        try expect(ClaudeUsageParser.quota(from: text) == nil, "Expected no quota")
    }

    private static func claudeKeychainServiceName() throws {
        let name = ClaudeKeychain.serviceName(configDirectory: "/Users/test/.subscription-manager/claude/work")
        try expect(name == "Claude Code-credentials-d3de09b1", "Unexpected service name \(name)")
    }

    private static func extractsAuthorizationURL() throws {
        let output = "Opening browser to sign in…\nIf the browser didn't open, visit: \u{1B}]8;;https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz\u{07}https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz\u{1B}]8;;\u{07}\nPaste code here if prompted > "
        let url = ClaudeCLIClient.authorizationURL(in: Data(output.utf8))
        try expect(url?.absoluteString == "https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz", "Unexpected URL \(String(describing: url))")
    }

    private static func expiredWindowsCountAsFull() throws {
        let past = Date(timeIntervalSinceNow: -60)
        let quota = QuotaSnapshot(windows: [
            QuotaWindow(kind: .session, label: "Session", usedPercent: 100, resetsAt: past, windowDurationMinutes: 300),
            QuotaWindow(kind: .weekly, label: "Week", usedPercent: 40, resetsAt: Date(timeIntervalSinceNow: 3_600), windowDurationMinutes: 10_080)
        ])
        try expect(quota.availablePercent(at: Date()) == 60, "Expected session reset to count as full")
    }

    // MARK: Vault

    private static func generatesSlugs() throws {
        try expect(Vault.slug(fromEmail: "Victor.J@uthereal.ai") == "victor-j-uthereal", "Unexpected email slug")
        try expect(Vault.sanitize("  Work  Account!! ") == "work-account", "Unexpected sanitized slug")
        try expect(Vault.isValidSlug("work-2") && !Vault.isValidSlug("Work") && !Vault.isValidSlug("a/b"), "Unexpected slug validation")
        let vault = Vault(root: try temporaryDirectory())
        try expect(vault.uniqueSlug("work", provider: .claude, taken: ["work", "work-2"]) == "work-3", "Expected collision suffix")
    }

    private static func manifestRoundTrip() throws {
        let root = try temporaryDirectory()
        let vault = Vault(root: root)
        let quota = QuotaSnapshot(windows: [QuotaWindow(kind: .weekly, label: "Week", usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 1_800_000_000), windowDurationMinutes: 10_080)])
        let account = AccountRecord(provider: .claude, slug: "work", email: "me@example.com", plan: "max", quota: quota, lastUpdated: Date(timeIntervalSince1970: 1_700_000_000))
        try vault.save([account])
        try expect(try vault.loadAccounts() == [account], "Expected identical records")

        let json = try decode(String(contentsOf: vault.manifestURL, encoding: .utf8))
        let entry = json["accounts"]?.arrayValue?.first
        try expect(entry?["reference"]?.stringValue == "claude/work", "Expected reference in manifest")
        try expect(entry?["home"]?.stringValue == root.path + "/claude/work", "Expected exact home path")
        try expect(entry?["env"]?["CLAUDE_CONFIG_DIR"]?.stringValue == root.path + "/claude/work", "Expected env in manifest")
        let attributes = try FileManager.default.attributesOfItem(atPath: vault.manifestURL.path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Expected private manifest")
    }

    private static func decodesLegacyRecords() throws {
        let data = Data("""
        {"id": "0A07E658-1BDE-4EE0-B802-AE0AEA9B0B7F", "name": "victor", "email": "v@example.com",
         "quota": {"usedPercent": 40, "windowDurationMinutes": 10080}}
        """.utf8)
        let record = try JSONDecoder().decode(AccountRecord.self, from: data)
        try expect(record.provider == .codex && record.slug.isEmpty, "Expected codex default")
        try expect(record.quota == nil, "Expected old quota to be dropped")
    }

    private static func migratesLegacyProfiles() throws {
        let legacy = try temporaryDirectory()
        let root = try temporaryDirectory().appendingPathComponent("vault")
        let first = UUID(), second = UUID(), missing = UUID()
        for id in [first, second] {
            let profile = legacy.appendingPathComponent("Profiles/\(id.uuidString)")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: profile.appendingPathComponent("auth.json"))
        }
        let records = """
        [{"id": "\(first.uuidString)", "name": "a", "email": "victor@uthereal.ai"},
         {"id": "\(second.uuidString)", "name": "victor", "email": "victor@uthereal.ai"},
         {"id": "\(missing.uuidString)", "name": "gone"}]
        """
        try Data(records.utf8).write(to: legacy.appendingPathComponent("accounts.json"))

        let vault = Vault(root: root)
        guard let migrated = try vault.migrateLegacy(from: legacy) else { throw Failure("Expected migration") }
        try expect(migrated.map(\.slug) == ["victor-uthereal", "victor-uthereal-2"], "Unexpected slugs \(migrated.map(\.slug))")
        try expect(migrated.map(\.id) == [first, second], "Expected ids to be preserved")
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("codex/victor-uthereal-2/auth.json").path), "Expected moved profile")
        try expect(!FileManager.default.fileExists(atPath: legacy.path), "Expected empty legacy folder to be removed")
        try expect(try vault.loadAccounts().count == 2, "Expected saved manifest")
        try expect(try vault.migrateLegacy(from: legacy) == nil, "Expected migration to run once")
    }

    private static func linksSharedConfigOnce() throws {
        let source = try temporaryDirectory()
        let home = try temporaryDirectory()
        try Data("{}".utf8).write(to: source.appendingPathComponent("settings.json"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try Data("own".utf8).write(to: home.appendingPathComponent("CLAUDE.md"))
        try Data("shared".utf8).write(to: source.appendingPathComponent("CLAUDE.md"))

        SharedConfig.link(provider: .claude, into: home, source: source)
        let fileManager = FileManager.default
        try expect((try? fileManager.destinationOfSymbolicLink(atPath: home.appendingPathComponent("settings.json").path)) == source.appendingPathComponent("settings.json").path, "Expected settings link")
        try expect((try? fileManager.destinationOfSymbolicLink(atPath: home.appendingPathComponent("skills").path)) != nil, "Expected skills link")
        try expect(try String(contentsOf: home.appendingPathComponent("CLAUDE.md"), encoding: .utf8) == "own", "Expected existing file to be kept")
        try expect(!fileManager.fileExists(atPath: home.appendingPathComponent("plugins").path), "Expected missing source to be skipped")

        try fileManager.removeItem(at: home.appendingPathComponent("settings.json"))
        SharedConfig.link(provider: .claude, into: home, source: source)
        try expect((try? fileManager.destinationOfSymbolicLink(atPath: home.appendingPathComponent("settings.json").path)) == nil, "Expected removed link to stay removed")
    }

    // MARK: CLI

    private static func resolvesReferences() throws {
        let accounts = [
            AccountRecord(provider: .codex, slug: "work", email: "a@example.com"),
            AccountRecord(provider: .claude, slug: "work", email: "b@example.com"),
            AccountRecord(provider: .claude, slug: "personal", email: "c@example.com")
        ]
        try expect(try CommandLineTool.resolve("claude/work", in: accounts).email == "b@example.com", "Expected exact reference")
        try expect(try CommandLineTool.resolve("personal", in: accounts).provider == .claude, "Expected unique slug")
        try expect(try CommandLineTool.resolve("A@example.com", in: accounts).provider == .codex, "Expected email lookup")
        try expect((try? CommandLineTool.resolve("work", in: accounts)) == nil, "Expected ambiguous slug to fail")
    }

    private static func environmentSnippets() throws {
        let posix = EnvironmentSnippet.lines(provider: .claude, home: "/Users/x/.subscription-manager/claude/work", shell: .posix)
        try expect(posix == ["export CLAUDE_CONFIG_DIR='/Users/x/.subscription-manager/claude/work'", "unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN"], "Unexpected POSIX snippet \(posix)")
        let fish = EnvironmentSnippet.lines(provider: .codex, home: "/tmp/it's", shell: .fish)
        try expect(fish == ["set -gx CODEX_HOME '/tmp/it'\\''s'"], "Unexpected fish snippet \(fish)")
    }

    // MARK: Helpers

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("subscription-manager-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message) }
    }

    private static func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
