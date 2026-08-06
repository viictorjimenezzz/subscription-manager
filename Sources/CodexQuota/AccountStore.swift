import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AccountStore: ObservableObject {
    static let maximumAccounts = 4

    @Published private(set) var accounts: [AccountRecord] = []
    @Published private(set) var states: [UUID: AccountRuntimeState] = [:]
    @Published var activeLogin: (accountID: UUID, instructions: LoginInstructions)?
    @Published var globalError: String?
    @Published private(set) var isRefreshingAll = false

    private var clients: [UUID: CodexAppServerClient] = [:]
    private var refreshTask: Task<Void, Never>?
    private let rootURL: URL
    private let recordsURL: URL

    init(baseURL: URL? = nil, startAutomaticRefresh: Bool = true) {
        let support = baseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexQuota", isDirectory: true)
        rootURL = support
        recordsURL = support.appendingPathComponent("accounts.json")
        load()
        if startAutomaticRefresh {
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
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.shutdown() }
        }
    }

    deinit { refreshTask?.cancel() }

    var canAddAccount: Bool { accounts.count < Self.maximumAccounts }

    func addAccount() async {
        guard canAddAccount, activeLogin == nil else { return }
        globalError = nil
        let record = AccountRecord(name: "Account \(accounts.count + 1)")
        accounts.append(record)
        states[record.id] = .connecting
        persist()

        do {
            let client = client(for: record.id)
            let instructions = try await client.beginLogin()
            activeLogin = (record.id, instructions)
            states[record.id] = .awaitingLogin
            NSWorkspace.shared.open(instructions.authURL)

            let success = await client.waitForLogin(id: instructions.loginID)
            guard accounts.contains(where: { $0.id == record.id }) else { return }
            activeLogin = nil
            if success {
                states[record.id] = .idle
                await refresh(record.id, refreshingToken: true)
            } else {
                states[record.id] = .failed("Login was not completed.")
            }
        } catch {
            activeLogin = nil
            states[record.id] = .failed(error.localizedDescription)
        }
    }

    func cancelActiveLogin() async {
        guard let login = activeLogin, let client = clients[login.accountID] else { return }
        await client.cancelLogin(id: login.instructions.loginID)
        activeLogin = nil
        states[login.accountID] = .failed("Login cancelled.")
    }

    func refreshAll() async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        globalError = nil
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { [weak self] in
                    await self?.refresh(account.id, refreshingToken: true)
                }
            }
        }
        isRefreshingAll = false
    }

    func refresh(_ id: UUID, refreshingToken: Bool = true) async {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        switch states[id] {
        case .connecting, .awaitingLogin, .refreshing: return
        default: break
        }
        states[id] = .refreshing
        do {
            let client = client(for: id)
            let accountPayload = try await client.account(refreshToken: refreshingToken)
            guard let identity = CodexPayloadParser.account(from: accountPayload) else {
                throw CodexClientError.notLoggedIn
            }
            let limitsPayload = try await client.rateLimits()
            guard let quota = CodexPayloadParser.weeklyQuota(from: limitsPayload) else {
                throw CodexClientError.noWeeklyQuota
            }

            accounts[index].email = identity.email
            accounts[index].plan = identity.plan
            accounts[index].quota = quota
            accounts[index].lastUpdated = Date()
            if let email = identity.email, accounts[index].name.hasPrefix("Account ") {
                accounts[index].name = email.components(separatedBy: "@").first ?? accounts[index].name
            }
            states[id] = .ready
            persist()
        } catch {
            states[id] = .failed(error.localizedDescription)
        }
    }

    func remove(_ id: UUID) async {
        if activeLogin?.accountID == id { await cancelActiveLogin() }
        if let client = clients.removeValue(forKey: id) {
            await client.logout()
            await client.stop()
        }
        accounts.removeAll { $0.id == id }
        states.removeValue(forKey: id)
        let profile = profileURL(for: id)
        try? FileManager.default.removeItem(at: profile)
        persist()
    }

    func retryLogin(_ id: UUID) async {
        await remove(id)
        await addAccount()
    }

    func shutdown() async {
        refreshTask?.cancel()
        let activeClients = clients.values
        clients.removeAll()
        for client in activeClients { await client.stop() }
    }

    private func client(for id: UUID) -> CodexAppServerClient {
        if let existing = clients[id] { return existing }
        let new = CodexAppServerClient(profileURL: profileURL(for: id))
        clients[id] = new
        return new
    }

    private func profileURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try Data(contentsOf: recordsURL)
            accounts = try JSONDecoder().decode([AccountRecord].self, from: data)
            states = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.quota == nil ? .idle : .ready) })
        } catch {
            accounts = []
            states = [:]
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(accounts).write(to: recordsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordsURL.path)
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
