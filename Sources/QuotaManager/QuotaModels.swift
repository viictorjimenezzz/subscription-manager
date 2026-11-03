import Foundation

struct AccountRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var email: String?
    var plan: String?
    var quota: QuotaSnapshot?
    var lastUpdated: Date?

    init(id: UUID = UUID(), name: String, email: String? = nil, plan: String? = nil, quota: QuotaSnapshot? = nil, lastUpdated: Date? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.plan = plan
        self.quota = quota
        self.lastUpdated = lastUpdated
    }
}

struct QuotaSnapshot: Codable, Sendable, Equatable {
    let usedPercent: Int
    let resetsAt: Date?
    let windowDurationMinutes: Int?

    var clampedPercent: Int { min(max(usedPercent, 0), 100) }
    var remainingPercent: Int { 100 - clampedPercent }
}

struct LoginInstructions: Sendable, Equatable {
    let loginID: String
    let authURL: URL
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

    static func weeklyQuota(from value: JSONValue) -> QuotaSnapshot? {
        let rootSnapshot: JSONValue
        if let buckets = value["rateLimitsByLimitId"]?.objectValue,
           let codex = buckets["codex"] ?? buckets.values.first {
            rootSnapshot = codex
        } else if let legacy = value["rateLimits"] {
            rootSnapshot = legacy
        } else {
            return nil
        }

        let candidates = [rootSnapshot["primary"], rootSnapshot["secondary"]]
            .compactMap { $0 }
            .filter { $0 != .null && $0["usedPercent"]?.intValue != nil }

        guard let selected = candidates.max(by: {
            ($0["windowDurationMins"]?.intValue ?? 0) < ($1["windowDurationMins"]?.intValue ?? 0)
        }), let used = selected["usedPercent"]?.intValue else { return nil }

        let resetDate = selected["resetsAt"]?.intValue.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return QuotaSnapshot(
            usedPercent: used,
            resetsAt: resetDate,
            windowDurationMinutes: selected["windowDurationMins"]?.intValue
        )
    }
}
