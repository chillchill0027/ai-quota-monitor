import Foundation

@MainActor
enum WebPageRefreshTests {
    private final class Driver: WebPageRefreshDriver {
        let provider: ProviderID
        var currentURL: URL?
        var failureMessage: String?
        var loading = false
        var initialLoadingPolls = 0
        var bodies: [String?]
        var startCount = 0
        var stopCount = 0
        var readCount = 0
        var changeURLOnStart: URL?
        var urlWhenLoadingFinishes: URL?
        var failureOnStart: String?
        var isLoading: Bool {
            if initialLoadingPolls > 0 { initialLoadingPolls -= 1; return true }
            if !loading, let urlWhenLoadingFinishes { currentURL = urlWhenLoadingFinishes }
            return loading
        }
        init(_ provider: ProviderID, bodies: [String?]) {
            self.provider = provider
            self.currentURL = provider.consoleURL
            self.bodies = bodies
        }
        func startQuotaReload() {
            startCount += 1
            if let changeURLOnStart { currentURL = changeURLOnStart }
            if let failureOnStart { failureMessage = failureOnStart }
        }
        func readBodyText() async -> String? {
            precondition(startCount == 1, "Every DOM read must follow the single fresh navigation")
            readCount += 1
            if bodies.isEmpty { return nil }
            if bodies.count == 1 { return bodies[0] }
            return bodies.removeFirst()
        }
        func stopRefresh() { stopCount += 1; loading = false }
    }

    static func run() async throws {
        let money = Driver(.mimo, bodies: ["Cash Balance: ¥ 678.90"])
        let success = await refresh(.mimo, money)
        if case .mimo(let value) = success { XCTAssertEqual(value.amount, 678.90) }
        else { preconditionFailure("Expected fresh MiMo value") }
        XCTAssertEqual(money.startCount, 1)
        XCTAssertEqual(money.readCount, 1)
        XCTAssertEqual(money.stopCount, 1)

        let delayed = Driver(.gemini, bodies: [nil, "Loading", "5-hour limit\n80% remaining\nWeekly limit\n90% remaining"])
        delayed.initialLoadingPolls = 2
        let delayedResult = await refresh(.gemini, delayed)
        if case .gemini(let value) = delayedResult {
            XCTAssertEqual(value.fiveHour?.remainingPercent, 80)
            XCTAssertEqual(value.weekly?.remainingPercent, 90)
        } else { preconditionFailure("Expected delayed SPA value") }
        XCTAssertEqual(delayed.startCount, 1)
        XCTAssertEqual(delayed.readCount, 3)
        XCTAssertEqual(delayed.stopCount, 1)

        let unknown = Driver(.mimo, bodies: ["Top up ¥50.00"])
        let unknownResult = await refresh(.mimo, unknown, reads: 3)
        XCTAssertEqual(unknownResult.succeeded, false)
        XCTAssertEqual(unknown.startCount, 1)
        XCTAssertEqual(unknown.readCount, 3)
        XCTAssertEqual(unknown.stopCount, 1)

        let auth = Driver(.gemini, bodies: ["5-hour limit\n100% remaining"])
        auth.changeURLOnStart = URL(string: "https://accounts.google.com/signin")
        let authResult = await refresh(.gemini, auth)
        XCTAssertEqual(authResult.failureMessage?.contains("登录"), true)
        XCTAssertEqual(auth.readCount, 0)
        XCTAssertEqual(auth.stopCount, 1)

        // A reload can still expose the previous login URL until the new navigation commits.
        let recovering = Driver(.mimo, bodies: ["Cash Balance: ¥ 11.25"])
        recovering.changeURLOnStart = URL(string: "https://id.mi.com/login")
        recovering.initialLoadingPolls = 2
        recovering.urlWhenLoadingFinishes = ProviderID.mimo.consoleURL
        let recovered = await refresh(.mimo, recovering)
        XCTAssertEqual(recovered.succeeded, true)
        XCTAssertEqual(recovering.startCount, 1)
        XCTAssertEqual(recovering.readCount, 1)

        let challenge = Driver(.mimo, bodies: ["Cash Balance: ¥ 678.90\nVerify you are human"])
        let challengeResult = await refresh(.mimo, challenge)
        XCTAssertEqual(challengeResult.failureMessage?.contains("验证"), true)
        XCTAssertEqual(challenge.readCount, 1)
        XCTAssertEqual(challenge.stopCount, 1)

        let denied = Driver(.gemini, bodies: ["Weekly\n100% remaining"])
        let deniedResult = await WebPageRefresh.refresh(provider: .gemini, driver: denied,
            accessCheck: { "Retry-After still active" }, timeoutSeconds: 0.05, pollIntervalNanoseconds: 1_000_000)
        XCTAssertEqual(deniedResult.failureMessage, "Retry-After still active")
        XCTAssertEqual(denied.startCount, 0)
        XCTAssertEqual(denied.stopCount, 0)

        let failed = Driver(.mimo, bodies: ["Cash Balance: ¥ 10.00"])
        failed.failureOnStart = "HTTP 403"
        let failedResult = await refresh(.mimo, failed)
        XCTAssertEqual(failedResult.failureMessage, "HTTP 403")
        XCTAssertEqual(failed.readCount, 0)
        XCTAssertEqual(failed.stopCount, 1)

        let stalled = Driver(.gemini, bodies: [])
        stalled.loading = true
        let stalledResult = await refresh(.gemini, stalled, timeout: 0.03)
        XCTAssertEqual(stalledResult.failureMessage?.contains("超时"), true)
        XCTAssertEqual(stalled.startCount, 1)
        XCTAssertEqual(stalled.readCount, 0)
        XCTAssertEqual(stalled.stopCount, 1)

        let cancelled = Driver(.mimo, bodies: [])
        cancelled.loading = true
        let task = Task { await refresh(.mimo, cancelled) }
        while cancelled.startCount == 0 { await Task.yield() }
        task.cancel()
        let cancelledResult = await task.value
        XCTAssertEqual(cancelledResult.failureMessage?.contains("取消"), true)
        XCTAssertEqual(cancelled.stopCount, 1)

        // Two provider sessions are independent; neither window visibility nor active tab exists in this workflow.
        let first = Driver(.mimo, bodies: ["Cash Balance: ¥ 1.25"])
        let second = Driver(.gemini, bodies: ["Weekly\n88% remaining"])
        async let firstValue = refresh(.mimo, first)
        async let secondValue = refresh(.gemini, second)
        let results = await (firstValue, secondValue)
        XCTAssertEqual(results.0.succeeded, true)
        XCTAssertEqual(results.1.succeeded, true)
        XCTAssertEqual(first.startCount, 1)
        XCTAssertEqual(second.startCount, 1)

        XCTAssertEqual(WebPageRefresh.isQuotaURL(URL(string: "https://gemini.google.com.evil.test/usage"), provider: .gemini), false)
        XCTAssertEqual(WebPageRefresh.isAuthenticationURL(URL(string: "https://accounts.google.com.evil.test/signin")), false)
        print("PASS: fresh webpage reload, SPA wait, independent providers, login/challenge, timeout and cancellation tests")
    }

    private static func refresh(_ provider: ProviderID, _ driver: Driver, reads: Int = 8,
                                timeout: TimeInterval = 0.2) async -> WebPageRefreshOutcome {
        await WebPageRefresh.refresh(provider: provider, driver: driver, accessCheck: { nil },
            timeoutSeconds: timeout, maxDOMReads: reads, pollIntervalNanoseconds: 1_000_000)
    }
}
