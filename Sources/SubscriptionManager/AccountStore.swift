import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AccountStore: ObservableObject {
    static let maximumAccountsPerProvider = 6

    @Published private(set) var accounts: [AccountRecord] = []
    @Published private(set) var states: [UUID: AccountRuntimeState] = [:]
    @Published var activeLogin: (accountID: UUID, instructions: LoginInstructions)?
    @Published var globalError: String?
    @Published private(set) var isRefreshingAll = false

    private(set) var vault: Vault
    private var backends: [UUID: any QuotaBackend] = [:]
    private var refreshTask: Task<Void, Never>?

    init(vault: Vault = Vault(), startAutomaticRefresh: Bool = true) {
        self.vault = vault
        if usesDefaultVault, Vault.needsPreviousRootMigration(to: vault) {
            Task {
                await adoptPreviousVault()
                load()
                if startAutomaticRefresh { scheduleRefresh() }
            }
        } else {
            load()
            if startAutomaticRefresh { scheduleRefresh() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.shutdown() }
        }
    }

    /// Only the real vault adopts older data; a vault chosen with
    /// SUBSCRIPTION_MANAGER_HOME (tests, experiments) never does.
    private var usesDefaultVault: Bool {
        vault.root == Vault.defaultRoot.standardizedFileURL
            && ProcessInfo.processInfo.environment["SUBSCRIPTION_MANAGER_HOME"] == nil
    }

    private func scheduleRefresh() {
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled else { break }
                await self?.refreshAll()
            }
        }
    }

    deinit { refreshTask?.cancel() }

    func accounts(for provider: Provider) -> [AccountRecord] {
        accounts.filter { $0.provider == provider }
    }

    func canAddAccount(_ provider: Provider) -> Bool {
        accounts(for: provider).count < Self.maximumAccountsPerProvider
    }

    func homePath(for account: AccountRecord) -> String { vault.homePath(for: account) }

    // MARK: Login

    func addAccount(_ provider: Provider) async {
        guard canAddAccount(provider), activeLogin == nil else { return }
        globalError = nil
        let record = AccountRecord(provider: provider, slug: Vault.provisionalSlug())
        do {
            try vault.prepareHome(for: record)
        } catch {
            globalError = "Could not create the account folder: \(error.localizedDescription)"
            return
        }
        accounts.append(record)
        persist()
        await signIn(record.id)
    }

    /// Signs in again inside the existing folder, so the account keeps its
    /// name, settings and history and agents keep working.
    func reconnect(_ id: UUID) async {
        guard activeLogin == nil, accounts.contains(where: { $0.id == id }) else { return }
        globalError = nil
        await signIn(id)
    }

    private func signIn(_ id: UUID) async {
        guard let record = accounts.first(where: { $0.id == id }) else { return }
        let expectedEmail = record.isProvisional ? nil : record.email
        states[id] = .connecting
        do {
            let backend = backend(for: record)
            let instructions = try await backend.beginLogin()
            activeLogin = (id, instructions)
            states[id] = .awaitingLogin
            if !instructions.browserOpened { NSWorkspace.shared.open(instructions.authURL) }

            let success = await backend.waitForLogin(id: instructions.loginID)
            guard accounts.contains(where: { $0.id == id }) else { return }
            if activeLogin?.accountID == id { activeLogin = nil }
            if success {
                states[id] = .idle
                await refresh(id, refreshingToken: true)
                if let expectedEmail,
                   let account = accounts.first(where: { $0.id == id }),
                   let email = account.email, email.lowercased() != expectedEmail.lowercased() {
                    globalError = "\(account.reference) was \(expectedEmail) but is now signed in as \(email). Sign in again with \(expectedEmail), or rename the folder."
                }
            } else if states[id] == .awaitingLogin {
                states[id] = .failed("Login was not completed.")
            }
        } catch {
            if activeLogin?.accountID == id { activeLogin = nil }
            states[id] = .failed(error.localizedDescription)
        }
    }

    func submitLoginCode(_ code: String) async {
        guard let login = activeLogin, let backend = backends[login.accountID] else { return }
        do {
            try await backend.submitLoginCode(code, loginID: login.instructions.loginID)
        } catch {
            globalError = error.localizedDescription
        }
    }

    func cancelActiveLogin() async {
        guard let login = activeLogin, let backend = backends[login.accountID] else { return }
        activeLogin = nil
        states[login.accountID] = .failed("Login cancelled.")
        await backend.cancelLogin(id: login.instructions.loginID)
    }

    // MARK: Refresh

    func refreshAll() async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        globalError = nil
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { [weak self] in
                    await self?.refresh(account.id)
                }
            }
        }
        isRefreshingAll = false
    }

    func refresh(_ id: UUID, refreshingToken: Bool = false) async {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        switch states[id] {
        case .connecting, .awaitingLogin, .refreshing: return
        default: break
        }
        states[id] = .refreshing
        do {
            let status = try await backend(for: account).status(refreshingToken: refreshingToken)
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[index].email = status.email ?? accounts[index].email
            accounts[index].plan = status.plan
            accounts[index].quota = status.quota
            accounts[index].lastUpdated = Date()
            states[id] = .ready
            persist()

            if accounts[index].isProvisional, let email = status.email {
                let slug = vault.uniqueSlug(Vault.slug(fromEmail: email), provider: account.provider, taken: takenSlugs(account.provider, excluding: id))
                do {
                    try await rename(id, to: slug)
                } catch {
                    globalError = "Connected, but could not name the folder “\(slug)”: \(error.localizedDescription)"
                }
            }
        } catch {
            states[id] = .failed(error.localizedDescription)
        }
    }

    // MARK: Folder management

    /// Renames an account folder. Agents address accounts by this name, so
    /// the folder is moved in place; for Claude the Keychain item keyed on the
    /// folder path moves with it.
    func rename(_ id: UUID, to newSlug: String) async throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let account = accounts[index]
        guard newSlug != account.slug else { return }
        guard Vault.isValidSlug(newSlug) else { throw VaultError.invalidSlug(newSlug) }
        guard !takenSlugs(account.provider, excluding: id).contains(newSlug) else { throw VaultError.slugTaken(newSlug) }

        let previousState = states[id]
        states[id] = .refreshing
        defer { if states[id] == .refreshing { states[id] = previousState ?? .idle } }

        if let backend = backends.removeValue(forKey: id) { await backend.stop() }

        var renamed = account
        renamed.slug = newSlug
        let oldPath = vault.homePath(for: account)
        let newPath = vault.homePath(for: renamed)

        var movedSecret = false
        if account.provider == .claude, let secret = try await ClaudeKeychain.read(configDirectory: oldPath) {
            try await ClaudeKeychain.write(secret, configDirectory: newPath)
            movedSecret = true
        }

        do {
            try vault.moveHome(of: account, toSlug: newSlug)
        } catch {
            if movedSecret { await ClaudeKeychain.delete(configDirectory: newPath) }
            throw error
        }

        if movedSecret {
            let check = ClaudeCLIClient(homeURL: vault.home(for: renamed))
            let loggedIn = (try? await check.authStatus())?["loggedIn"]?.boolValue == true
            guard loggedIn else {
                try? vault.moveHome(of: renamed, toSlug: account.slug)
                await ClaudeKeychain.delete(configDirectory: newPath)
                throw ClaudeClientError.keychain("Claude Code did not accept the moved login.")
            }
            await ClaudeKeychain.delete(configDirectory: oldPath)
        }

        accounts[index] = renamed
        persist()
    }

    func remove(_ id: UUID) async {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        if activeLogin?.accountID == id { await cancelActiveLogin() }
        let backend = backends.removeValue(forKey: id) ?? makeBackend(for: account)
        await backend.logout()
        await backend.stop()
        accounts.removeAll { $0.id == id }
        states.removeValue(forKey: id)
        vault.removeHome(of: account)
        persist()
    }

    func shutdown() async {
        refreshTask?.cancel()
        let active = backends.values
        backends.removeAll()
        for backend in active { await backend.stop() }
    }

    // MARK: Private

    private func takenSlugs(_ provider: Provider, excluding id: UUID) -> Set<String> {
        Set(accounts.filter { $0.provider == provider && $0.id != id }.map(\.slug))
    }

    private func backend(for account: AccountRecord) -> any QuotaBackend {
        if let existing = backends[account.id] { return existing }
        let new = makeBackend(for: account)
        backends[account.id] = new
        return new
    }

    private func makeBackend(for account: AccountRecord) -> any QuotaBackend {
        let home = vault.home(for: account)
        switch account.provider {
        case .codex: return CodexAppServerClient(profileURL: home)
        case .claude: return ClaudeCLIClient(homeURL: home)
        }
    }

    private func load() {
        do {
            try vault.ensureRoot()
            if usesDefaultVault, let migrated = try vault.migrateLegacy() {
                accounts = migrated
            } else {
                accounts = (try? vault.loadAccounts()) ?? []
            }
        } catch {
            accounts = (try? vault.loadAccounts()) ?? []
            globalError = "Could not prepare \(vault.root.path): \(error.localizedDescription)"
        }
        // Folders left by a login that never finished.
        let abandoned = accounts.filter { $0.isProvisional && $0.email == nil }
        for account in abandoned {
            if account.provider == .claude {
                let path = vault.homePath(for: account)
                Task.detached { await ClaudeKeychain.delete(configDirectory: path) }
            }
            vault.removeHome(of: account)
        }
        accounts.removeAll { account in abandoned.contains(where: { $0.id == account.id }) }

        for account in accounts {
            SharedConfig.link(provider: account.provider, into: vault.home(for: account))
        }
        states = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.quota == nil ? .idle : .ready) })
        vault.writeAgentGuide()
        persist()
    }

    /// Moves the Quota Manager folder (`~/.quota-manager`) to the current
    /// vault. Claude Code keys each login on its folder path, so every Claude
    /// Keychain item is copied to the new path first, verified after the move,
    /// and only then removed from the old path. Any failure puts everything back.
    private func adoptPreviousVault() async {
        let previous = Vault(root: Vault.previousRoot)
        guard let previousAccounts = try? previous.loadAccounts() else { return }
        var moved: [(old: String, new: String)] = []

        func rollBack(_ reason: String, folderMoved: Bool) async {
            if folderMoved { try? FileManager.default.moveItem(at: vault.root, to: previous.root) }
            for item in moved { await ClaudeKeychain.delete(configDirectory: item.new) }
            vault = previous
            globalError = "Still using \(previous.root.path): \(reason)"
        }

        do {
            for account in previousAccounts where account.provider == .claude {
                let oldPath = previous.homePath(for: account)
                let newPath = vault.homePath(for: account)
                if let secret = try await ClaudeKeychain.read(configDirectory: oldPath) {
                    try await ClaudeKeychain.write(secret, configDirectory: newPath)
                    moved.append((oldPath, newPath))
                }
            }
            try FileManager.default.moveItem(at: previous.root, to: vault.root)
        } catch {
            await rollBack("could not move it (\(error.localizedDescription)).", folderMoved: false)
            return
        }

        for item in moved {
            let status = try? await ClaudeCLIClient(homeURL: URL(fileURLWithPath: item.new)).authStatus()
            guard status?["loggedIn"]?.boolValue == true else {
                await rollBack("Claude Code did not accept the moved login for \(item.new).", folderMoved: true)
                return
            }
        }
        for item in moved { await ClaudeKeychain.delete(configDirectory: item.old) }
    }

    private func persist() {
        do {
            try vault.save(accounts)
        } catch {
            globalError = "Could not save account settings: \(error.localizedDescription)"
        }
    }
}

@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
