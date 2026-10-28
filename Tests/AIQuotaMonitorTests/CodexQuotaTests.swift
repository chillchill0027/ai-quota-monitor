import Foundation

// Standalone runner: works with Command Line Tools without the XCTest framework.
func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
    precondition(actual == expected, "Expected \(expected), got \(actual)")
}
func XCTAssertNil<T>(_ actual: T?) { precondition(actual == nil, "Expected nil") }

final class CodexQuotaTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(_ json: String) throws -> QuotaWindowSnapshot {
        try JSONDecoder().decode(CodexQuotaService.Response.self, from: Data(json.utf8)).snapshot(now: now)
    }

    func testWindowsAreMatchedByDurationInsteadOfOrder() throws {
        let result = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1700600000},"secondary":{"usedPercent":95,"windowDurationMins":300,"resetsAt":1700010000}}}"#)
        XCTAssertEqual(result.fiveHourRemainingPercent, 5)
        XCTAssertEqual(result.weeklyRemainingPercent, 80)
        XCTAssertEqual(result.fiveHourResetsAt?.timeIntervalSince1970, 1_700_010_000)
        XCTAssertEqual(result.weeklyResetsAt?.timeIntervalSince1970, 1_700_600_000)
    }

    func testMultiBucketViewOverridesLegacyAndIgnoresOtherModels() throws {
        let result = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":2,"windowDurationMins":300}},"other_model":{"secondary":{"usedPercent":90,"windowDurationMins":10080}}}}"#)
        XCTAssertEqual(result.fiveHourRemainingPercent, 98)
        XCTAssertNil(result.weeklyRemainingPercent)
        let missing = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300}},"rateLimitsByLimitId":{}}"#)
        XCTAssertNil(missing.fiveHourRemainingPercent)
        XCTAssertEqual(missing.status, .unavailable)
    }

    func testMissingOrUnexpectedWindowsAreNotZeroOrInferred() throws {
        for json in [#"{}"#, #"{"rateLimits":{"primary":null,"secondary":null}}"#,
                     #"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":180}}}"#,
                     #"{"rateLimits":{"primary":{"windowDurationMins":300}}}"#] {
            let result = try snapshot(json)
            XCTAssertNil(result.fiveHourRemainingPercent)
            XCTAssertNil(result.weeklyRemainingPercent)
            XCTAssertEqual(result.status, .unavailable)
        }
    }

    func testZeroAndClamping() throws {
        let result = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300},"secondary":{"usedPercent":-5,"windowDurationMins":10080}}}"#)
        XCTAssertEqual(result.fiveHourRemainingPercent, 0)
        XCTAssertEqual(result.weeklyRemainingPercent, 100)
        let over = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":120,"windowDurationMins":300}}}"#)
        XCTAssertEqual(over.fiveHourRemainingPercent, 0)
    }

    func testResetNeverInventsARefill() throws {
        let result = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1700000000},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1700600000}}}"#)
        XCTAssertNil(result.codexRemaining(weekly: false, now: now))
        XCTAssertEqual(result.codexRemaining(weekly: true, now: now), 80)
        XCTAssertEqual(result.fiveHourRemainingPercent, 0)
    }

    func testLegacyCacheDecodesButHasNoCounterOrResetAuthority() throws {
        let data = Data(#"{"fiveHourRemainingPercent":100,"windowMessagesCount":0,"windowMessagesLimit":80,"windowResetAt":0,"planLabel":"ChatGPT Plus","updatedAt":0,"status":"已同步"}"#.utf8)
        let result = try JSONDecoder().decode(QuotaWindowSnapshot.self, from: data)
        XCTAssertNil(result.fiveHourResetsAt)
        XCTAssertNil(result.weeklyResetsAt)
        XCTAssertNil(QuotaWindowSnapshot.restoredCodex(result, version: nil).fiveHourRemainingPercent)
        XCTAssertEqual(QuotaWindowSnapshot.restoredCodex(result, version: 2).status, .cached)
    }
}

@main
struct TestRunner {
    @MainActor
    static func main() async throws {
        let tests = CodexQuotaTests()
        try tests.testWindowsAreMatchedByDurationInsteadOfOrder()
        try tests.testMultiBucketViewOverridesLegacyAndIgnoresOtherModels()
        try tests.testMissingOrUnexpectedWindowsAreNotZeroOrInferred()
        try tests.testZeroAndClamping()
        try tests.testResetNeverInventsARefill()
        try tests.testLegacyCacheDecodesButHasNoCounterOrResetAuthority()
        print("PASS: 6 Codex quota regression tests")
        StatusBarPanelTests.run()
        try await ProviderVisibilityTests.run()
        try WebQuotaParserTests.run()
        try await DeepSeekServiceTests.run()
        try await AccessPolicyTests.run()
        try await WebNavigationTests.run()
        try await CodexProcessTests.run()
        try await WebPageRefreshTests.run()
        try await AntigravityServiceTests.run()
    }
}
