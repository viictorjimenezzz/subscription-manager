import Foundation

enum ShellKind {
    case posix
    case fish

    static var current: ShellKind {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return (shell as NSString).lastPathComponent == "fish" ? .fish : .posix
    }
}

enum EnvironmentSnippet {
    static func lines(provider: Provider, home: String, shell: ShellKind) -> [String] {
        let quoted = "'" + home.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var lines: [String]
        switch shell {
        case .posix: lines = ["export \(provider.homeEnvironmentVariable)=\(quoted)"]
        case .fish: lines = ["set -gx \(provider.homeEnvironmentVariable) \(quoted)"]
        }
        let conflicts = provider.conflictingEnvironmentVariables
        if !conflicts.isEmpty {
            switch shell {
            case .posix: lines.append("unset \(conflicts.joined(separator: " "))")
            case .fish: lines.append("set -e \(conflicts.joined(separator: " "))")
            }
        }
        return lines
    }
}

/// `quota-manager <command>`: lets agents list, choose and switch to accounts
/// stored in the credentials folder. It only reads the manifest the app keeps
/// up to date, so it is fast and never touches credentials.
enum CommandLineTool {
    static let commands: Set<String> = ["list", "ls", "env", "path", "exec", "pick", "help", "--help", "-h", "version", "--version"]

    static func shouldHandle(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return commands.contains(first)
    }

    static func run(_ arguments: [String]) -> Int32 {
        var arguments = arguments
        let command = arguments.removeFirst()
        let vault = Vault()
        do {
            switch command {
            case "list", "ls": return try list(arguments, vault: vault)
            case "env": return try env(arguments, vault: vault)
            case "path": return try path(arguments, vault: vault)
            case "exec": return try exec(arguments, vault: vault)
            case "pick": return try pick(arguments, vault: vault)
            case "version", "--version":
                print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                return 0
            default:
                print(usage)
                return 0
            }
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("quota-manager: \(error.message)\n".utf8))
            return error.code
        } catch {
            FileHandle.standardError.write(Data("quota-manager: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static let usage = """
    Usage: quota-manager <command>

    Accounts live in \(Vault().root.path)/<provider>/<slug> and are
    addressed as <provider>/<slug>, for example claude/victor-uthereal.

    Commands:
      list [codex|claude] [--json]   Show accounts and remaining quota
      pick <codex|claude> [--min N]  Print the account with the most quota left
      env <account> [--fish|--sh]    Print shell lines that select an account
      path <account>                 Print the account folder
      exec <account> -- <command…>   Run a command as that account
      help                           Show this help

    <account> may be <provider>/<slug>, a unique slug, or an email address.
    Quota figures come from the menu bar app and refresh every 15 minutes.

    Examples:
      eval "$(quota-manager env claude/work)"
      quota-manager exec "$(quota-manager pick codex)" -- codex exec "fix the tests"
    """

    struct CLIError: Error {
        let message: String
        var code: Int32 = 1
    }

    // MARK: Commands

    private static func list(_ arguments: [String], vault: Vault) throws -> Int32 {
        var accounts = try load(vault)
        if let provider = arguments.first(where: { !$0.hasPrefix("-") }) {
            guard let parsed = Provider(rawValue: provider) else { throw CLIError(message: "unknown provider “\(provider)”") }
            accounts = accounts.filter { $0.provider == parsed }
        }

        if arguments.contains("--json") {
            let entries = accounts.map { account -> JSONValue in
                let home = vault.homePath(for: account)
                var object: [String: JSONValue] = [
                    "reference": .string(account.reference),
                    "provider": .string(account.provider.rawValue),
                    "slug": .string(account.slug),
                    "home": .string(home),
                    "env": .object([account.provider.homeEnvironmentVariable: .string(home)])
                ]
                if let email = account.email { object["email"] = .string(email) }
                if let plan = account.plan { object["plan"] = .string(plan) }
                if let available = account.quota?.availablePercent(at: Date()) { object["availablePercent"] = .number(Double(available)) }
                if let weekly = account.quota?.weekly { object["weeklyRemainingPercent"] = .number(Double(weekly.remainingPercent(at: Date()))) }
                if let updated = account.lastUpdated { object["lastUpdated"] = .string(ISO8601DateFormatter().string(from: updated)) }
                return .object(object)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(data: try encoder.encode(JSONValue.array(entries)), encoding: .utf8) ?? "[]")
            return 0
        }

        guard !accounts.isEmpty else {
            print("No accounts yet. Add one from the Quota Manager menu bar app.")
            return 0
        }
        let now = Date()
        let rows = accounts.map { account -> [String] in
            let weekly = account.quota?.weekly.map { "\($0.remainingPercent(at: now))%" } ?? "–"
            let session = account.quota?.session.map { "\($0.remainingPercent(at: now))%" } ?? "–"
            let updated = account.lastUpdated.map { relative($0, now: now) } ?? "never"
            return [account.reference, account.email ?? "–", account.plan ?? "–", weekly, session, updated]
        }
        printTable(header: ["ACCOUNT", "EMAIL", "PLAN", "WEEK LEFT", "SESSION LEFT", "UPDATED"], rows: rows)
        return 0
    }

    private static func env(_ arguments: [String], vault: Vault) throws -> Int32 {
        guard let reference = arguments.first(where: { !$0.hasPrefix("-") }) else { throw CLIError(message: "env needs an account", code: 2) }
        let account = try resolve(reference, in: try load(vault))
        let shell: ShellKind = arguments.contains("--fish") ? .fish : arguments.contains("--sh") ? .posix : .current
        EnvironmentSnippet.lines(provider: account.provider, home: vault.homePath(for: account), shell: shell).forEach { print($0) }
        return 0
    }

    private static func path(_ arguments: [String], vault: Vault) throws -> Int32 {
        guard let reference = arguments.first else { throw CLIError(message: "path needs an account", code: 2) }
        print(vault.homePath(for: try resolve(reference, in: try load(vault))))
        return 0
    }

    private static func pick(_ arguments: [String], vault: Vault) throws -> Int32 {
        guard let name = arguments.first, let provider = Provider(rawValue: name) else {
            throw CLIError(message: "pick needs a provider: codex or claude", code: 2)
        }
        var minimum = 1
        if let index = arguments.firstIndex(of: "--min"), arguments.indices.contains(index + 1), let value = Int(arguments[index + 1]) {
            minimum = value
        }
        let now = Date()
        let candidates = try load(vault)
            .filter { $0.provider == provider && !$0.isProvisional }
            .compactMap { account -> (AccountRecord, Int, Int)? in
                guard let quota = account.quota, let available = quota.availablePercent(at: now) else { return nil }
                return (account, available, quota.weekly?.remainingPercent(at: now) ?? available)
            }
            .filter { $0.1 >= minimum }
            .sorted { ($0.1, $0.2) > ($1.1, $1.2) }
        guard let best = candidates.first else {
            throw CLIError(message: "no \(provider.displayName) account has at least \(minimum)% quota left", code: 3)
        }
        print(best.0.reference)
        return 0
    }

    private static func exec(_ arguments: [String], vault: Vault) throws -> Int32 {
        guard let reference = arguments.first else { throw CLIError(message: "exec needs an account", code: 2) }
        var command = Array(arguments.dropFirst())
        if command.first == "--" { command.removeFirst() }
        guard !command.isEmpty else { throw CLIError(message: "exec needs a command after the account", code: 2) }

        let account = try resolve(reference, in: try load(vault))
        for name in account.provider.conflictingEnvironmentVariables { unsetenv(name) }
        setenv(account.provider.homeEnvironmentVariable, vault.homePath(for: account), 1)

        let argv = command.map { strdup($0) } + [nil]
        execvp(command[0], argv)
        throw CLIError(message: "could not run \(command[0]): \(String(cString: strerror(errno)))", code: 127)
    }

    // MARK: Helpers

    private static func load(_ vault: Vault) throws -> [AccountRecord] {
        guard FileManager.default.fileExists(atPath: vault.manifestURL.path) else {
            throw CLIError(message: "no accounts found at \(vault.manifestURL.path). Open the Quota Manager app and add one.")
        }
        return try vault.loadAccounts()
    }

    static func resolve(_ reference: String, in accounts: [AccountRecord]) throws -> AccountRecord {
        let needle = reference.lowercased()
        if let exact = accounts.first(where: { $0.reference == needle }) { return exact }
        let matches = accounts.filter { $0.slug == needle || $0.email?.lowercased() == needle }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw CLIError(message: "“\(reference)” matches \(matches.map(\.reference).joined(separator: ", ")); use <provider>/<slug>", code: 2)
        }
        let known = accounts.map(\.reference).joined(separator: ", ")
        throw CLIError(message: "no account “\(reference)”. Known accounts: \(known.isEmpty ? "none" : known)", code: 2)
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3_600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    private static func printTable(header: [String], rows: [[String]]) {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        for row in all {
            let line = row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            print(line)
        }
    }
}
