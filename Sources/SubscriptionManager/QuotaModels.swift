import Foundation

enum Provider: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }

    /// Environment variable that points the provider's CLI at an account folder.
    var homeEnvironmentVariable: String {
        switch self {
        case .codex: return "CODEX_HOME"
        case .claude: return "CLAUDE_CONFIG_DIR"
        }
    }

    /// Variables that would override the account folder's subscription login
    /// and must be cleared when switching to a stored account.
    var conflictingEnvironmentVariables: [String] {
        switch self {
        case .codex: return []
        case .claude: return ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
        }
    }

    var logoAsset: String {
        switch self {
        case .codex: return "openai-white.png"
        case .claude: return "claude-color.png"
        }
    }

    /// Monochrome logos follow the text color instead of keeping their own.
    var logoIsTemplate: Bool { self == .codex }
}

struct AccountRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var provider: Provider
    /// Folder name inside `~/.subscription-manager/<provider>/`. Agents select an
    /// account with `<provider>/<slug>`.
    var slug: String
    var email: String?
    var plan: String?
    var quota: QuotaSnapshot?
    var lastUpdated: Date?

    var reference: String { "\(provider.rawValue)/\(slug)" }
    var isProvisional: Bool { slug.hasPrefix(Vault.provisionalSlugPrefix) }

    init(id: UUID = UUID(), provider: Provider, slug: String, email: String? = nil, plan: String? = nil, quota: QuotaSnapshot? = nil, lastUpdated: Date? = nil) {
        self.id = id
        self.provider = provider
        self.slug = slug
        self.email = email
        self.plan = plan
        self.quota = quota
        self.lastUpdated = lastUpdated
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, slug, email, plan, quota, lastUpdated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        // Records written by Codex Quota 1.x have no provider or slug.
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? .codex
        slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        // Older single-window snapshots are dropped and re-read on refresh.
        quota = try? container.decodeIfPresent(QuotaSnapshot.self, forKey: .quota)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
    }
}

struct QuotaWindow: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// Short rolling window (5 hours for both providers today).
        case session
        /// The weekly limit that applies to all usage.
        case weekly
        /// A weekly limit that only applies to one model family.
        case weeklyModel
    }

    let kind: Kind
    let label: String
    let usedPercent: Int
    let resetsAt: Date?
    let windowDurationMinutes: Int?

    var id: String { "\(kind.rawValue)-\(label)" }
    var clampedPercent: Int { min(max(usedPercent, 0), 100) }
    var remainingPercent: Int { 100 - clampedPercent }

    /// Remaining percent, treating a window whose reset time has passed as full.
    func remainingPercent(at date: Date) -> Int {
        if let resetsAt, resetsAt <= date { return 100 }
        return remainingPercent
    }
}

struct QuotaSnapshot: Codable, Sendable, Equatable {
    let windows: [QuotaWindow]

    /// The headline weekly window, falling back to the longest window reported.
    var weekly: QuotaWindow? {
        windows.first(where: { $0.kind == .weekly })
            ?? windows.max(by: { ($0.windowDurationMinutes ?? 0) < ($1.windowDurationMinutes ?? 0) })
    }

    var session: QuotaWindow? { windows.first(where: { $0.kind == .session && $0 != weekly }) }
    var modelWindows: [QuotaWindow] { windows.filter { $0.kind == .weeklyModel } }

    /// The tightest general-purpose limit, used to choose an account for new work.
    func availablePercent(at date: Date) -> Int? {
        let general = windows.filter { $0.kind != .weeklyModel }
        return general.map { $0.remainingPercent(at: date) }.min()
    }
}

struct AccountStatus: Sendable, Equatable {
    let email: String?
    let plan: String?
    let quota: QuotaSnapshot
}

struct LoginInstructions: Sendable, Equatable {
    let loginID: String
    let authURL: URL
    /// The helper already opened the browser itself.
    let browserOpened: Bool
    /// The helper accepts a pasted authorization code as a fallback.
    let acceptsCode: Bool
}

enum AccountRuntimeState: Equatable {
    case idle
    case connecting
    case awaitingLogin
    case refreshing
    case ready
    case failed(String)

    var isBusy: Bool {
        self == .connecting || self == .awaitingLogin || self == .refreshing
    }
}

enum CodexPayloadParser {
    static func account(from value: JSONValue) -> (email: String?, plan: String?)? {
        guard let account = value["account"], account != .null,
              account["type"]?.stringValue == "chatgpt" else { return nil }
        let email = account["email"]?.stringValue
        let plan = account["planType"]?.stringValue
        return (email, plan)
    }

    static func quota(from value: JSONValue) -> QuotaSnapshot? {
        let rootSnapshot: JSONValue
        if let buckets = value["rateLimitsByLimitId"]?.objectValue,
           let codex = buckets["codex"] ?? buckets.values.first {
            rootSnapshot = codex
        } else if let legacy = value["rateLimits"] {
            rootSnapshot = legacy
        } else {
            return nil
        }

        let windows = [rootSnapshot["primary"], rootSnapshot["secondary"]]
            .compactMap { $0 }
            .filter { $0 != .null }
            .compactMap(window(from:))
        return windows.isEmpty ? nil : QuotaSnapshot(windows: windows)
    }

    private static func window(from value: JSONValue) -> QuotaWindow? {
        guard let used = value["usedPercent"]?.intValue else { return nil }
        let duration = value["windowDurationMins"]?.intValue
        let isWeekly = (duration ?? 0) >= 6 * 24 * 60
        return QuotaWindow(
            kind: isWeekly ? .weekly : .session,
            label: isWeekly ? "Week" : sessionLabel(minutes: duration),
            usedPercent: used,
            resetsAt: value["resetsAt"]?.intValue.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            windowDurationMinutes: duration
        )
    }

    private static func sessionLabel(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Session" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
    }
}
