import Foundation

/// The on-disk credentials folder shared with agents:
///
///     ~/.quota-manager/
///       accounts.json        manifest (accounts, quota, home folders, env vars)
///       README.md            instructions for agents
///       codex/<slug>/        a CODEX_HOME
///       claude/<slug>/       a CLAUDE_CONFIG_DIR
///
/// Account folders are used in place. Credentials are never copied, because
/// both providers rotate refresh tokens and a copy goes stale on first use.
struct Vault: Sendable {
    static let provisionalSlugPrefix = "new-"
    static let manifestVersion = 2

    let root: URL

    init(root: URL = Vault.defaultRoot) {
        self.root = root.standardizedFileURL
    }

    static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["QUOTA_MANAGER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".quota-manager", isDirectory: true)
    }

    static var legacyRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexQuota", isDirectory: true)
    }

    var manifestURL: URL { root.appendingPathComponent("accounts.json") }
    var guideURL: URL { root.appendingPathComponent("README.md") }

    func providerDirectory(_ provider: Provider) -> URL {
        root.appendingPathComponent(provider.rawValue, isDirectory: true)
    }

    func home(provider: Provider, slug: String) -> URL {
        providerDirectory(provider).appendingPathComponent(slug, isDirectory: true)
    }

    func home(for account: AccountRecord) -> URL {
        home(provider: account.provider, slug: account.slug)
    }

    /// The exact path string agents must use. Claude Code keys its Keychain
    /// entry on this string, so it must never gain a trailing slash or `~`.
    func homePath(for account: AccountRecord) -> String {
        home(for: account).path
    }

    // MARK: Manifest

    private struct Manifest: Codable {
        var version: Int
        var root: String?
        var accounts: [Entry]
    }

    /// An account plus the derived fields agents need. Decoding ignores the
    /// derived fields and reads the record itself.
    private struct Entry: Codable {
        let record: AccountRecord
        let home: String?
        let env: [String: String]?

        init(record: AccountRecord, home: String, env: [String: String]) {
            self.record = record
            self.home = home
            self.env = env
        }

        private enum ExtraKeys: String, CodingKey { case reference, home, env }

        init(from decoder: Decoder) throws {
            record = try AccountRecord(from: decoder)
            home = nil
            env = nil
        }

        func encode(to encoder: Encoder) throws {
            try record.encode(to: encoder)
            var container = encoder.container(keyedBy: ExtraKeys.self)
            try container.encode(record.reference, forKey: .reference)
            try container.encodeIfPresent(home, forKey: .home)
            try container.encodeIfPresent(env, forKey: .env)
        }
    }

    func loadAccounts() throws -> [AccountRecord] {
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: data).accounts.map(\.record)
    }

    func save(_ accounts: [AccountRecord]) throws {
        try ensureRoot()
        let manifest = Manifest(
            version: Self.manifestVersion,
            root: root.path,
            accounts: accounts.map { account in
                Entry(record: account, home: homePath(for: account), env: [account.provider.homeEnvironmentVariable: homePath(for: account)])
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    func ensureRoot() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        for provider in Provider.allCases {
            try fileManager.createDirectory(at: providerDirectory(provider), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    // MARK: Slugs

    /// `victor@uthereal.ai` becomes `victor-uthereal`.
    static func slug(fromEmail email: String) -> String {
        let parts = email.lowercased().split(separator: "@", maxSplits: 1)
        var base = String(parts.first ?? "")
        if parts.count == 2, let domain = parts[1].split(separator: ".").first {
            base += "-" + domain
        }
        return sanitize(base)
    }

    static func sanitize(_ text: String) -> String {
        var result = ""
        var lastWasDash = true
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return String(result.prefix(48))
    }

    static func isValidSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.count <= 48 && sanitize(slug) == slug
    }

    /// Appends `-2`, `-3`, … until the slug is free for the provider.
    func uniqueSlug(_ base: String, provider: Provider, taken: Set<String>) -> String {
        let base = base.isEmpty ? "account" : base
        var candidate = base
        var counter = 2
        while taken.contains(candidate) || FileManager.default.fileExists(atPath: home(provider: provider, slug: candidate).path) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    static func provisionalSlug() -> String {
        provisionalSlugPrefix + UUID().uuidString.prefix(6).lowercased()
    }

    // MARK: Account folders

    func prepareHome(for account: AccountRecord) throws {
        try ensureRoot()
        let home = home(for: account)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        SharedConfig.link(provider: account.provider, into: home)
    }

    func moveHome(of account: AccountRecord, toSlug slug: String) throws {
        let source = home(for: account)
        let destination = home(provider: account.provider, slug: slug)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw VaultError.slugTaken(slug)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func removeHome(of account: AccountRecord) {
        try? FileManager.default.removeItem(at: home(for: account))
    }

    // MARK: Migration from Codex Quota 1.x

    private struct LegacyAccount: Decodable {
        let id: UUID
        let name: String?
        let email: String?
        let plan: String?
    }

    /// Moves Codex Quota profiles into the vault. Returns the migrated records,
    /// or nil when there is nothing to migrate.
    func migrateLegacy(from legacyRoot: URL = Vault.legacyRoot) throws -> [AccountRecord]? {
        let fileManager = FileManager.default
        let legacyRecords = legacyRoot.appendingPathComponent("accounts.json")
        guard !fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: legacyRecords) else { return nil }

        let legacy = try JSONDecoder().decode([LegacyAccount].self, from: data)
        try ensureRoot()
        var migrated: [AccountRecord] = []
        var taken = Set<String>()
        for account in legacy {
            let profile = legacyRoot
                .appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(account.id.uuidString, isDirectory: true)
            guard fileManager.fileExists(atPath: profile.path) else { continue }
            let base = account.email.map(Self.slug(fromEmail:)) ?? Self.sanitize(account.name ?? "")
            let slug = uniqueSlug(base, provider: .codex, taken: taken)
            taken.insert(slug)
            try fileManager.moveItem(at: profile, to: home(provider: .codex, slug: slug))
            migrated.append(AccountRecord(id: account.id, provider: .codex, slug: slug, email: account.email, plan: account.plan))
        }
        try save(migrated)

        try? fileManager.removeItem(at: legacyRecords)
        for directory in [legacyRoot.appendingPathComponent("Profiles"), legacyRoot] {
            if let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
               contents.allSatisfy({ $0 == ".DS_Store" }) {
                try? fileManager.removeItem(at: directory)
            }
        }
        return migrated
    }

    // MARK: Agent guide

    func writeAgentGuide() {
        let root = root.path
        let guide = """
        # Quota Manager credentials

        This folder is managed by the Quota Manager menu bar app. Each subfolder is a
        logged-in Codex or Claude Code subscription account that agents can switch to
        without logging in again.

        ## Choose an account

        `accounts.json` lists every account with its `reference` (`<provider>/<slug>`),
        email, plan, remaining quota (`quota.windows`, refreshed every 15 minutes) and the
        exact environment to use (`env`).

        The `quota-manager` command reads the same file:

        ```sh
        quota-manager list                        # accounts and remaining quota
        quota-manager pick claude                 # the Claude account with the most quota left
        quota-manager env claude/<slug>           # shell lines that select an account
        quota-manager exec codex/<slug> -- codex exec "…"
        ```

        ## Use an account directly

        ```sh
        CODEX_HOME=\(root)/codex/<slug> codex …
        CLAUDE_CONFIG_DIR=\(root)/claude/<slug> claude …
        ```

        Rules:

        - Use the path exactly as written in `accounts.json`: absolute, no `~`, no trailing
          slash, no symlinked alias. Claude Code stores the login in the macOS Keychain under
          a key derived from this exact string; any other spelling looks logged out.
        - Unset `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` when
          selecting a Claude account; they override the folder's login.
        - Never copy `auth.json` or the folder elsewhere. Refresh tokens rotate on use, so a
          copy stops working and can sign the original out.
        - Do not log out from inside these folders. Remove accounts from the app instead.
        - Settings, skills, plugins and agent instructions from `~/.claude` and `~/.codex` are
          symlinked into each folder, so changes there apply to every account.
        """
        try? guide.write(to: guideURL, atomically: true, encoding: .utf8)
    }
}

enum VaultError: LocalizedError {
    case slugTaken(String)
    case invalidSlug(String)

    var errorDescription: String? {
        switch self {
        case .slugTaken(let slug): return "An account folder named “\(slug)” already exists."
        case .invalidSlug(let slug): return "“\(slug)” is not a valid name. Use lowercase letters, numbers and dashes."
        }
    }
}

/// Shares the user's normal settings, skills and plugins with every account
/// folder by symlinking them from `~/.claude` and `~/.codex`. Credentials and
/// per-account state are never linked.
enum SharedConfig {
    static func sharedItems(for provider: Provider) -> [String] {
        switch provider {
        case .claude:
            return ["settings.json", "CLAUDE.md", "agents", "commands", "hooks", "output-styles", "plugins", "skills", "keybindings.json"]
        case .codex:
            return ["AGENTS.md", "prompts", "rules", "skills", "hooks.json"]
        }
    }

    static func sourceDirectory(for provider: Provider) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch provider {
        case .claude: return home.appendingPathComponent(".claude", isDirectory: true)
        case .codex: return home.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    private static let ledgerName = ".quota-manager-links"

    /// Links each shared item once. Items listed in the ledger are not
    /// recreated, so deleting a link opts that account out permanently.
    static func link(provider: Provider, into home: URL, source: URL? = nil) {
        let fileManager = FileManager.default
        let source = source ?? sourceDirectory(for: provider)
        let ledger = home.appendingPathComponent(ledgerName)
        var handled = Set((try? String(contentsOf: ledger, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [])
        let before = handled.count

        for item in sharedItems(for: provider) where !handled.contains(item) {
            let target = source.appendingPathComponent(item)
            let link = home.appendingPathComponent(item)
            guard fileManager.fileExists(atPath: target.path) else { continue }
            if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) == nil,
               fileManager.fileExists(atPath: link.path) {
                // The account already has its own copy; leave it alone.
                handled.insert(item)
                continue
            }
            if (try? fileManager.createSymbolicLink(at: link, withDestinationURL: target)) != nil
                || (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                handled.insert(item)
            }
        }

        if handled.count != before {
            try? handled.sorted().joined(separator: "\n").write(to: ledger, atomically: true, encoding: .utf8)
        }
    }
}
