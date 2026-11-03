import Foundation

/// Runs async work from the synchronous command-line entry point.
enum AsyncRunner {
    private final class Box<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    static func run<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = Box<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }
}

/// `subscription-manager add`, `add-code` and `reset`: the agent-driven
/// replacement for adding accounts in the app. Every step mirrors what the
/// app does: sign in inside the account folder, check who signed in, name
/// the folder after the email, and register the account in the manifest.
enum AccountOnboarding {
    typealias CLIError = CommandLineTool.CLIError

    // MARK: add

    static func add(_ arguments: [String], vault: Vault) throws -> Int32 {
        guard let name = arguments.first, let provider = Provider(rawValue: name) else {
            throw CLIError(message: "add needs a provider: codex or claude", code: 2)
        }
        let expectedEmail = option("--email", in: arguments)?.lowercased()
        let requestedSlug = option("--slug", in: arguments)
        let fromDefault = arguments.contains("--from-default")

        try vault.ensureRoot()
        let existing = (try? vault.loadAccounts()) ?? []
        if let expectedEmail, let duplicate = existing.first(where: { $0.provider == provider && $0.email?.lowercased() == expectedEmail }) {
            throw CLIError(message: "\(expectedEmail) is already added as \(duplicate.reference)")
        }

        let taken = Set(existing.filter { $0.provider == provider }.map(\.slug))
        let slug: String
        if let requestedSlug {
            guard Vault.isValidSlug(requestedSlug) else { throw CLIError(message: VaultError.invalidSlug(requestedSlug).localizedDescription, code: 2) }
            guard !taken.contains(requestedSlug), !FileManager.default.fileExists(atPath: vault.home(provider: provider, slug: requestedSlug).path) else {
                throw CLIError(message: VaultError.slugTaken(requestedSlug).localizedDescription, code: 2)
            }
            slug = requestedSlug
        } else if let expectedEmail {
            slug = vault.uniqueSlug(Vault.slug(fromEmail: expectedEmail), provider: provider, taken: taken)
        } else {
            slug = Vault.provisionalSlug()
        }

        var record = AccountRecord(provider: provider, slug: slug)
        try vault.prepareHome(for: record)

        // Undo everything this command created; with --from-default, hand the
        // login back to the default location instead of deleting it.
        var undoAdoption: (() -> Void)?
        func discard() {
            if let undoAdoption {
                undoAdoption()
            } else if provider == .claude {
                let path = vault.homePath(for: record)
                try? AsyncRunner.run { await ClaudeKeychain.delete(configDirectory: path) }
            }
            vault.removeHome(of: record)
        }

        do {
            if fromDefault {
                undoAdoption = try adoptDefaultLogin(provider: provider, home: vault.home(for: record))
            } else {
                try runLogin(provider: provider, home: vault.home(for: record), email: expectedEmail, vault: vault, slug: slug)
            }
        } catch {
            discard()
            throw error
        }

        let status: AccountStatus
        do {
            status = try readStatus(provider: provider, home: vault.home(for: record))
        } catch {
            discard()
            throw CLIError(message: "signed in, but the account could not be read (\(error.localizedDescription)); nothing was saved")
        }
        let email = status.email?.lowercased()
        if let expectedEmail, email != expectedEmail {
            discard()
            throw CLIError(message: "signed in as \(email ?? "an unknown account"), not \(expectedEmail); nothing was saved. Switch the browser to \(expectedEmail) (or use a private window) and run add again.")
        }
        if let email, let duplicate = existing.first(where: { $0.provider == provider && $0.email?.lowercased() == email }) {
            discard()
            throw CLIError(message: "\(email) is already added as \(duplicate.reference); nothing was saved")
        }

        if record.isProvisional, let email {
            let finalSlug = vault.uniqueSlug(Vault.slug(fromEmail: email), provider: provider, taken: taken)
            do {
                try rename(record, to: finalSlug, vault: vault)
                record.slug = finalSlug
            } catch {
                FileHandle.standardError.write(Data("subscription-manager: kept folder name \(record.slug): \(error.localizedDescription)\n".utf8))
            }
        }

        record.email = status.email
        record.plan = status.plan
        record.quota = status.quota
        record.lastUpdated = Date()
        try register(record, vault: vault)

        if fromDefault, provider == .claude {
            // Only now that the copy is verified and registered does the
            // default location stop holding the login.
            try? AsyncRunner.run { await ClaudeKeychain.delete(service: ClaudeKeychain.defaultServiceName) }
        }

        let weekly = status.quota.weekly.map { "\($0.remainingPercent)% of the week left" } ?? "quota unknown"
        print("Added \(record.reference) (\(status.email ?? "unknown email"), \(status.plan ?? "unknown plan")): \(weekly).")
        print("Use it with: subscription-manager exec \(record.reference) -- \(provider == .codex ? "codex" : "claude") …")
        return 0
    }

    /// Runs the provider's own sign-in inside `home`. The sign-in URL is
    /// printed by the provider CLI; a pasted code can be delivered with
    /// `subscription-manager add-code`.
    private static func runLogin(provider: Provider, home: URL, email: String?, vault: Vault, slug: String) throws {
        let executable: URL
        var arguments: [String]
        switch provider {
        case .codex:
            guard let codex = CodexLocator.executableURL() else { throw CodexClientError.executableNotFound }
            executable = codex
            arguments = ["login"]
        case .claude:
            guard let claude = ClaudeLocator.executableURL() else { throw ClaudeClientError.executableNotFound }
            executable = claude
            arguments = ["auth", "login", "--claudeai"]
            if let email { arguments += ["--email", email] }
        }

        try FileManager.default.createDirectory(at: vault.pendingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fifo = vault.pendingDirectory.appendingPathComponent("\(provider.rawValue)-\(slug).code")
        try? FileManager.default.removeItem(at: fifo)
        guard mkfifo(fifo.path, 0o600) == 0 else { throw CLIError(message: "could not create \(fifo.path)") }
        defer { try? FileManager.default.removeItem(at: fifo) }

        var environment = ProcessInfo.processInfo.environment
        for name in provider.conflictingEnvironmentVariables { environment.removeValue(forKey: name) }
        environment[provider.homeEnvironmentVariable] = home.path

        let process = Process()
        let input = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = input
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        // Forward codes written to the FIFO (and typed on a terminal) to the
        // provider CLI. Opening the FIFO read-write keeps it from hitting EOF.
        let writer = input.fileHandleForWriting
        let fifoDescriptor = Darwin.open(fifo.path, O_RDWR)
        if fifoDescriptor >= 0 {
            let reader = FileHandle(fileDescriptor: fifoDescriptor, closeOnDealloc: true)
            Thread.detachNewThread {
                while true {
                    let data = reader.availableData
                    if data.isEmpty { break }
                    try? writer.write(contentsOf: data)
                }
            }
        }
        if isatty(STDIN_FILENO) != 0 {
            Thread.detachNewThread {
                while true {
                    let data = FileHandle.standardInput.availableData
                    if data.isEmpty { break }
                    try? writer.write(contentsOf: data)
                }
            }
        }

        FileHandle.standardError.write(Data("""
        Signing in to \(provider.displayName) inside \(home.path).
        Open the sign-in URL below in a browser logged into the right account.
        If the page shows a code, run: subscription-manager add-code '<code>'

        """.utf8))
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError(message: "\(provider.displayName) sign-in did not complete (exit \(process.terminationStatus)); nothing was saved")
        }
    }

    /// Moves the login the provider CLI uses by default into `home`, so it
    /// is held in one place only. Returns a closure that moves it back.
    private static func adoptDefaultLogin(provider: Provider, home: URL) throws -> () -> Void {
        switch provider {
        case .codex:
            let source = SharedConfig.sourceDirectory(for: .codex).appendingPathComponent("auth.json")
            let destination = home.appendingPathComponent("auth.json")
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: source.path)) == nil,
                  FileManager.default.fileExists(atPath: source.path) else {
                throw CLIError(message: "~/.codex has no login to bring in")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: source, to: destination)
            return { try? FileManager.default.moveItem(at: destination, to: source) }
        case .claude:
            let path = home.path
            guard let secret = try AsyncRunner.run({ try await ClaudeKeychain.read(service: ClaudeKeychain.defaultServiceName) }) else {
                throw CLIError(message: "the default Claude Code login has no Keychain entry to bring in")
            }
            try AsyncRunner.run { try await ClaudeKeychain.write(secret, configDirectory: path) }
            // The default entry is deleted only after the account is registered.
            return { try? AsyncRunner.run { await ClaudeKeychain.delete(configDirectory: path) } }
        }
    }

    private static func readStatus(provider: Provider, home: URL) throws -> AccountStatus {
        try AsyncRunner.run {
            switch provider {
            case .codex:
                return try await withCodexClient(home) { try await $0.status(refreshingToken: false) }
            case .claude:
                return try await ClaudeCLIClient(homeURL: home).status(refreshingToken: false)
            }
        }
    }

    private static func rename(_ record: AccountRecord, to slug: String, vault: Vault) throws {
        var renamed = record
        renamed.slug = slug
        let oldPath = vault.homePath(for: record)
        let newPath = vault.homePath(for: renamed)
        guard record.provider == .claude else {
            try vault.moveHome(of: record, toSlug: slug)
            return
        }
        try AsyncRunner.run {
            guard let secret = try await ClaudeKeychain.read(configDirectory: oldPath) else { return }
            try await ClaudeKeychain.write(secret, configDirectory: newPath)
        }
        do {
            try vault.moveHome(of: record, toSlug: slug)
        } catch {
            try? AsyncRunner.run { await ClaudeKeychain.delete(configDirectory: newPath) }
            throw error
        }
        let home = vault.home(for: renamed)
        let loggedIn = (try? AsyncRunner.run { try await ClaudeCLIClient(homeURL: home).authStatus() })?["loggedIn"]?.boolValue == true
        guard loggedIn else {
            try? vault.moveHome(of: renamed, toSlug: record.slug)
            try? AsyncRunner.run { await ClaudeKeychain.delete(configDirectory: newPath) }
            throw ClaudeClientError.keychain("Claude Code did not accept the moved login.")
        }
        try? AsyncRunner.run { await ClaudeKeychain.delete(configDirectory: oldPath) }
    }

    /// Appends the account to the manifest. The app may rewrite the manifest
    /// at the same moment, so the write is checked and repeated if lost.
    private static func register(_ record: AccountRecord, vault: Vault) throws {
        for attempt in 0..<4 {
            var accounts = (try? vault.loadAccounts()) ?? []
            if !accounts.contains(where: { $0.id == record.id }) {
                accounts.append(record)
                try vault.save(accounts)
            }
            Thread.sleep(forTimeInterval: attempt == 0 ? 1.5 : 1)
            if (try? vault.loadAccounts())?.contains(where: { $0.id == record.id }) == true { return }
        }
        throw CLIError(message: "could not register \(record.reference) in \(vault.manifestURL.path)")
    }

    // MARK: add-code

    static func addCode(_ arguments: [String], vault: Vault) throws -> Int32 {
        guard let code = arguments.first(where: { !$0.hasPrefix("-") }) else {
            throw CLIError(message: "add-code needs the code shown after signing in", code: 2)
        }
        let pending = ((try? FileManager.default.contentsOfDirectory(atPath: vault.pendingDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".code") }
        let target: String
        if let slug = option("--slug", in: arguments) {
            guard let match = pending.first(where: { $0.hasSuffix("-\(slug).code") }) else {
                throw CLIError(message: "no sign-in in progress for \(slug)")
            }
            target = match
        } else if pending.count == 1 {
            target = pending[0]
        } else {
            throw CLIError(message: pending.isEmpty ? "no sign-in is in progress; run subscription-manager add first" : "several sign-ins are in progress; pass --slug")
        }
        let path = vault.pendingDirectory.appendingPathComponent(target).path
        let descriptor = Darwin.open(path, O_WRONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw CLIError(message: "the sign-in for \(target) is no longer waiting") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data((code.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8))
        print("Code sent. The add command finishes on its own.")
        return 0
    }

    // MARK: reset

    static func reset(_ arguments: [String], vault: Vault, accounts: [AccountRecord]) throws -> Int32 {
        guard let reference = arguments.first(where: { !$0.hasPrefix("-") }) else {
            throw CLIError(message: "reset needs an account", code: 2)
        }
        let account = try CommandLineTool.resolve(reference, in: accounts)
        guard account.provider == .codex else { throw CLIError(message: "only Codex accounts have banked resets", code: 2) }
        let home = vault.home(for: account)

        let before = try AsyncRunner.run {
            try await withCodexClient(home) { try await $0.status(refreshingToken: false) }
        }
        let banked = before.quota.resetCredits?.available ?? 0
        let weekly = before.quota.weekly.map { "\($0.remainingPercent)%" } ?? "unknown"
        guard arguments.contains("--yes") else {
            print("\(account.reference): \(banked) banked \(banked == 1 ? "reset" : "resets"), \(weekly) of the week left.")
            if banked > 0 { print("Applying one spends a credit. Re-run with --yes once the user has agreed.") }
            return 0
        }
        guard banked > 0 else { throw CLIError(message: "\(account.reference) has no banked resets") }

        let key = UUID().uuidString
        let outcome = try AsyncRunner.run {
            try await withCodexClient(home) { client in
                do {
                    return try await client.consumeResetCredit(idempotencyKey: key)
                } catch {
                    // Same key: a retry can never spend a second credit.
                    return try await client.consumeResetCredit(idempotencyKey: key)
                }
            }
        }
        print("\(account.reference): \(outcome.message)")
        return outcome == .reset || outcome == .alreadyRedeemed ? 0 : 1
    }

    // MARK: Helpers

    /// Runs `body` against a Codex app-server for `home` and always stops it.
    private static func withCodexClient<T>(_ home: URL, _ body: (CodexAppServerClient) async throws -> T) async throws -> T {
        let client = CodexAppServerClient(profileURL: home)
        do {
            let value = try await body(client)
            await client.stop()
            return value
        } catch {
            await client.stop()
            throw error
        }
    }

    static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
