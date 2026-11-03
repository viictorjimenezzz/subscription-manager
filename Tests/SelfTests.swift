import Foundation

@main
struct QuotaParserSelfTests {
    static func main() throws {
        try selectsLongestWindowAsWeeklyQuota()
        try prefersCodexNamedBucket()
        try handlesAdditionalLimitBuckets()
        try parsesChatGPTAccount()
        print("4 parser tests passed")
    }

    private static func selectsLongestWindowAsWeeklyQuota() throws {
        let payload = try decode("""
        {
          "rateLimits": {
            "primary": {"usedPercent": 23, "windowDurationMins": 300, "resetsAt": 1700000000},
            "secondary": {"usedPercent": 67, "windowDurationMins": 10080, "resetsAt": 1800000000}
          }
        }
        """)
        guard let quota = CodexPayloadParser.weeklyQuota(from: payload) else { throw Failure("Missing weekly quota") }
        try expect(quota.usedPercent == 67, "Expected weekly percent")
        try expect(quota.remainingPercent == 33, "Expected inverted remaining percent")
        try expect(quota.windowDurationMinutes == 10_080, "Expected weekly duration")
        try expect(quota.resetsAt == Date(timeIntervalSince1970: 1_800_000_000), "Expected reset date")
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
        try expect(CodexPayloadParser.weeklyQuota(from: payload)?.usedPercent == 91, "Expected codex bucket")
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
        try expect(CodexPayloadParser.weeklyQuota(from: payload)?.usedPercent == 100, "Expected codex bucket over auxiliary bucket")
    }

    private static func parsesChatGPTAccount() throws {
        let payload = try decode("""
        {"requiresOpenaiAuth": true, "account": {"type": "chatgpt", "email": "me@example.com", "planType": "plus"}}
        """)
        guard let account = CodexPayloadParser.account(from: payload) else { throw Failure("Missing account") }
        try expect(account.email == "me@example.com", "Expected email")
        try expect(account.plan == "plus", "Expected plan")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
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
