import Foundation

/// The on-disk credentials folder shared with agents:
///
///     ~/.subscription-manager/
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
        if let override = ProcessInfo.processInfo.environment["SUBSCRIPTION_MANAGER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".subscription-manager", isDirectory: true)
    }

    /// Where Quota Manager 2.x kept the vault.
    static var previousRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".quota-manager", isDirectory: true)
    }

    static func needsPreviousRootMigration(to vault: Vault) -> Bool {
        let fileManager = FileManager.default
        return !fileManager.fileExists(atPath: vault.root.path)
            && fileManager.fileExists(atPath: Vault(root: previousRoot).manifestURL.path)
    }

    static var legacyRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexQuota", isDirectory: true)
    }

    var manifestURL: URL { root.appendingPathComponent("accounts.json") }
    var guideURL: URL { root.appendingPathComponent("README.md") }
    var addGuideURL: URL { root.appendingPathComponent("ADD.md") }
    var pendingDirectory: URL { root.appendingPathComponent(".pending", isDirectory: true) }

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
        # Subscription Manager credentials

        This folder is managed by the Subscription Manager menu bar app. Each subfolder is a
        logged-in Codex or Claude Code subscription account that agents can switch to
        without logging in again.

        ## Choose an account

        `accounts.json` lists every account with its `reference` (`<provider>/<slug>`),
        email, plan, remaining quota (`quota.windows`, refreshed every 15 minutes) and the
        exact environment to use (`env`).

        The `subscription-manager` command reads the same file:

        ```sh
        subscription-manager list                        # accounts and remaining quota
        subscription-manager pick claude                 # the Claude account with the most quota left
        subscription-manager env claude/<slug>           # shell lines that select an account
        subscription-manager exec codex/<slug> -- codex exec "…"
        ```

        To add a new account, follow `ADD.md` in this folder.

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
        try? Self.addGuide.write(to: addGuideURL, atomically: true, encoding: .utf8)
    }

    /// Instructions for agents that add a subscription on the user's behalf.
    static let addGuide = """
    # Adding a subscription to Subscription Manager

    New accounts are added by an agent, not from the menu bar app. Follow these
    steps exactly; the app picks the account up within seconds of step 4.

    ## 1. Ask the user

    - Which provider: `codex` (ChatGPT / Codex) or `claude` (Claude Code subscription)?
    - Which email address? Always pass it with `--email`: the command then refuses to
      save a login for any other account.
    - Check it is not already there: `subscription-manager list`.

    ## 2. Start the sign-in (in the background)

    ```sh
    subscription-manager add codex  --email someone@example.com
    subscription-manager add claude --email someone@example.com
    ```

    Run it as a background command: it keeps running until the user finishes signing in.
    It prints a sign-in URL. Give the URL to the user and tell them:

    - The browser must be logged into **that** email. If it is logged into another
      account, they should open the URL in a private window instead.
    - Click **Authorize** / **Continue** (not Decline).

    ## 3. If the page shows a code (Claude only)

    When the user opens the URL in a private window, Claude shows a code instead of
    finishing automatically. Ask the user to paste it to you, then run:

    ```sh
    subscription-manager add-code '<the code exactly as given>'
    ```

    ## 4. Wait for the add command to finish

    - Success prints `Added <provider>/<slug> (<email>, <plan>) …`. The folder is
      named after the email, e.g. `claude/someone-example`.
    - `signed in as X, not Y; nothing was saved`: the browser used the wrong account.
      Nothing was kept. Ask the user to switch accounts (or use a private window) and
      repeat from step 2.
    - If the user declined or closed the page, the command fails and nothing is kept;
      just run it again.

    Confirm with `subscription-manager list`.

    ## Bringing in a login that already exists on this Mac

    Only when the user explicitly asks to move their current default login (the one
    plain `codex` or `claude` uses) into Subscription Manager instead of signing in again:

    ```sh
    subscription-manager add codex  --email someone@example.com --from-default
    subscription-manager add claude --email someone@example.com --from-default
    ```

    This **moves** the login: afterwards plain `codex` / `claude` (without
    `CODEX_HOME` / `CLAUDE_CONFIG_DIR`) is logged out. Before running it for Codex,
    the user should quit the ChatGPT app and stop the Codex background service
    (`pkill -f "app-server --listen unix://"`), because those processes keep the old
    session in memory and would otherwise write a second copy back. For Claude, any
    Claude Code session running on the default login (possibly your own) is logged
    out, so do it last and warn the user first.

    ## Never

    - Never copy `auth.json` files or Keychain entries; refresh tokens rotate and
      copies sign each other out.
    - Never edit `accounts.json` by hand to add accounts.
    - Never create, rename or move account folders yourself: Claude Code logins are
      keyed on the exact folder path.
    """
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

    private static let ledgerName = ".subscription-manager-links"

    /// Links each shared item once. Items listed in the ledger are not
    /// recreated, so deleting a link opts that account out permanently.
    static func link(provider: Provider, into home: URL, source: URL? = nil) {
        let fileManager = FileManager.default
        let source = source ?? sourceDirectory(for: provider)
        let ledger = home.appendingPathComponent(ledgerName)
        let previousLedger = home.appendingPathComponent(".quota-manager-links")
        var handled = Set([ledger, previousLedger].flatMap {
            (try? String(contentsOf: $0, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        })
        var before = handled.count
        if FileManager.default.fileExists(atPath: previousLedger.path) {
            try? FileManager.default.removeItem(at: previousLedger)
            before = -1
        }

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
