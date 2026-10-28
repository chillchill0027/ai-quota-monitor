import Foundation

@MainActor
enum AccessPolicyTests {
    static func run() async throws {
        try testAccessPolicyModes()
        testNavigationBudget()
        try await testFiveProviderFiveMinuteCycle()
        try await testManualButtonReloadsAndReadsBothPages()
        try await testManualAllRefreshFailuresAreIndependent()
        try await testManagerRequestsAndCache()
        try await testManagerFailureAndSingleFlight()
        try await testOrdinaryFailureAllowsManualRetry()
        try await testWebRefreshSingleFlight()
        try await testCredentialChangeWhileQuerying()
        try await testSaveEmptyKeyDoesNotQuery()
        try testInstanceLease()
        testQuotaURLs()
        print("PASS: five-provider manual refresh, five-minute reopen cycle, server limits, cache, credential and single-flight regressions")
    }

    private static func testAccessPolicyModes() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var policy = AccessPolicy()
        XCTAssertNil(policy.begin(.deepseekAPI, now: now))
        XCTAssertEqual(policy.begin(.deepseekAPI, now: now) != nil, true)
        XCTAssertNil(policy.begin(.deepseekAPI, isManual: true, now: now.addingTimeInterval(1)))
        XCTAssertNil(policy.begin(.deepseekAPI, isManual: true, now: now.addingTimeInterval(2)))
        XCTAssertEqual(policy.begin(.deepseekAPI, now: now.addingTimeInterval(3)) != nil, true)
        XCTAssertNil(policy.begin(.codexAPI, now: now)) // independent provider budgets
        var restored = try JSONDecoder().decode(AccessPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(restored.begin(.deepseekAPI, now: now.addingTimeInterval(299)) != nil, true)
        XCTAssertNil(restored.begin(.deepseekAPI, isManual: true, now: now.addingTimeInterval(299)))

        var serverLimited = AccessPolicy()
        serverLimited.failed(.deepseekAPI, now: now, retryAfter: 3600)
        XCTAssertEqual(serverLimited.entries[AccessAction.deepseekAPI.rawValue]?.serverRetryUntil, now.addingTimeInterval(3600))
        for manual in [false, true] {
            XCTAssertEqual(serverLimited.begin(.deepseekAPI, isManual: manual, now: now.addingTimeInterval(1)) != nil, true)
        }
        serverLimited.clearSuspension(.deepseekAPI)
        XCTAssertEqual(serverLimited.begin(.deepseekAPI, isManual: true, now: now.addingTimeInterval(3599)) != nil, true)
        var restarted = try JSONDecoder().decode(AccessPolicy.self, from: JSONEncoder().encode(serverLimited))
        XCTAssertEqual(restarted.begin(.deepseekAPI, isManual: true, now: now.addingTimeInterval(3599)) != nil, true)
        XCTAssertNil(restarted.begin(.deepseekAPI, isManual: true, now: now.addingTimeInterval(3600)))
        // The hard server deadline can expire before the app's ordinary failure backoff.
        var shortServerWait = AccessPolicy()
        shortServerWait.failed(.deepseekAPI, now: now, retryAfter: 60)
        XCTAssertEqual(shortServerWait.begin(.deepseekAPI, now: now.addingTimeInterval(60)) != nil, true)
        XCTAssertNil(shortServerWait.begin(.deepseekAPI, isManual: true, now: now.addingTimeInterval(60)))
        var excessiveServerWait = AccessPolicy()
        excessiveServerWait.failed(.deepseekAPI, now: now, retryAfter: 1e30)
        XCTAssertEqual(excessiveServerWait.begin(.deepseekAPI, isManual: true, now: now) != nil, true)

        var authentication = AccessPolicy()
        authentication.failed(.deepseekAPI, now: now, suspendReason: "authentication")
        for manual in [false, true] {
            XCTAssertEqual(authentication.begin(.deepseekAPI, isManual: manual, now: now.addingTimeInterval(100_000))?.contains("authentication"), true)
        }
        authentication.failed(.deepseekAPI, now: now.addingTimeInterval(1))
        authentication.succeeded(.deepseekAPI) // a late success must not silently remove a pause
        XCTAssertEqual(authentication.begin(.deepseekAPI, isManual: true, now: now.addingTimeInterval(2))?.contains("authentication"), true)
        authentication.clearSuspension(.deepseekAPI)
        XCTAssertEqual(authentication.begin(.deepseekAPI, now: now.addingTimeInterval(2)) != nil, true)
        XCTAssertNil(authentication.begin(.deepseekAPI, isManual: true, now: now.addingTimeInterval(2)))

        var combined = AccessPolicy()
        combined.failed(.mimoPage, now: now, retryAfter: 1200, suspendReason: "verification")
        combined.clearSuspension(.mimoPage)
        XCTAssertEqual(combined.begin(.mimoPage, isManual: true, now: now.addingTimeInterval(1)) != nil, true)
        XCTAssertEqual(combined.serverWait(.mimoPage, now: now.addingTimeInterval(1)) != nil, true)
        XCTAssertNil(combined.serverWait(.mimoPage, now: now.addingTimeInterval(1200)))
        // Normal-browser recovery is independent from an embedded-page verification pause.
        XCTAssertNil(combined.begin(.mimoBrowser, isManual: true, now: now))
        XCTAssertNil(combined.begin(.mimoBrowser, isManual: true, now: now))

        var networkFailure = AccessPolicy()
        networkFailure.failed(.codexAPI, now: now)
        XCTAssertEqual(networkFailure.begin(.codexAPI, now: now.addingTimeInterval(1)) != nil, true)
        XCTAssertNil(networkFailure.begin(.codexAPI, isManual: true, now: now.addingTimeInterval(1)))
    }

    private static func testNavigationBudget() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var navigation = NavigationBudget()
        XCTAssertEqual(navigation.consume(now: now), false)
        navigation.grant(now: now)
        for _ in 0..<8 { XCTAssertEqual(navigation.consume(now: now), true) }
        XCTAssertEqual(navigation.consume(now: now), false)
        navigation.grant(now: now)
        XCTAssertEqual(navigation.consume(now: now.addingTimeInterval(31)), false)
        navigation.grant(now: now)
        navigation.clear()
        XCTAssertEqual(navigation.consume(now: now), false)
    }

    private final class Counts {
        var ds = 0
        var codex = 0
        var mimo = 0
        var gemini = 0
        var agy = 0
        var localPageReads = 0
        var webModes: [Bool] = []
        var webBatches: [[ProviderID]] = []
        var all: [Int] { [ds, mimo, gemini, codex, agy] }
    }
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
    }
    private static func refreshWeb(_ providers: [ProviderID], manual: Bool, counts: Counts) -> [ProviderID: String] {
        counts.webModes.append(manual)
        counts.webBatches.append(providers)
        var results: [ProviderID: String] = [:]
        for provider in providers {
            if provider == .mimo { counts.mimo += 1 }
            if provider == .gemini { counts.gemini += 1 }
            results[provider] = "\(provider.displayName) 已刷新（离线模拟）"
        }
        return results
    }
    private static func defaults() -> (UserDefaults, String) {
        let suite = "AIQuotaMonitor.offline-tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
    private static func success(_ amount: Double = 678.90) -> DeepSeekService.FetchResult {
        var value = DeepSeekBalanceSnapshot.placeholder
        value.status = .ready; value.currency = "USD"; value.totalBalance = amount
        value.updatedAt = Date(); value.isAvailable = true
        return DeepSeekService.FetchResult(snapshot: value, retryAfter: nil, requiresUserAction: false)
    }

    private static func testFiveProviderFiveMinuteCycle() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock()
        let start = clock.date
        let counts = Counts()
        func manager() -> QuotaManager {
            QuotaManager(defaults: defaults, access: AccessPolicyStore(defaults: defaults, now: { clock.date }),
                key: "sk-test-only", bindWeb: false,
                visibleQuotaReader: { counts.localPageReads += 1 },
                webQuotaRefresher: { refreshWeb($0, manual: $1, counts: counts) },
                deepSeekReader: { _ in counts.ds += 1; return success() },
                codexReader: {
                    counts.codex += 1
                    var value = QuotaWindowSnapshot.defaultChatGPT()
                    value.status = .ready; value.fiveHourRemainingPercent = 80; value.updatedAt = clock.date
                    return value
                },
                antigravityReader: {
                    counts.agy += 1
                    var value = AntigravityQuotaSnapshot.placeholder
                    value.status = .ready; value.fiveHourRemainingPercent = 90; value.updatedAt = clock.date
                    return value
                }, now: { clock.date })
        }
        let first = manager()
        first.onUserInteractionReopenDashboard()
        first.saveState()
        XCTAssertEqual(counts.all, [0, 0, 0, 0, 0])
        await first.onUserInteractionOpenPopover().value
        XCTAssertEqual(counts.all, [1, 1, 1, 1, 1]) // first open actually requests every provider
        XCTAssertEqual(counts.webBatches, [[.mimo, .gemini]])
        XCTAssertEqual(counts.webModes, [false])
        for _ in 0..<30 { await first.onUserInteractionOpenPopover().value }
        XCTAssertEqual(counts.all, [1, 1, 1, 1, 1])
        clock.date = start.addingTimeInterval(299)
        await first.onUserInteractionOpenPopover().value
        XCTAssertEqual(counts.all, [1, 1, 1, 1, 1])
        let reopened = manager()
        await reopened.onUserInteractionOpenPopover().value
        XCTAssertEqual(counts.all, [1, 1, 1, 1, 1]) // restarting must not reset the five-minute gate
        clock.date = start.addingTimeInterval(300)
        await reopened.onUserInteractionOpenPopover().value
        XCTAssertEqual(counts.all, [2, 2, 2, 2, 2]) // at exactly five minutes all five are refreshed again
        XCTAssertEqual(counts.webModes, [false, false])

        await reopened.manualRefreshNow().value
        await reopened.manualRefreshNow().value
        XCTAssertEqual(counts.all, [4, 4, 4, 4, 4]) // manual all-refresh has no ordinary time restriction
        XCTAssertEqual(counts.webModes, [false, false, true, true])
        XCTAssertEqual(counts.localPageReads, 0) // no stale visible-page-only shortcut remains

        await reopened.performManualRefresh(provider: .deepseek)
        XCTAssertEqual(counts.all, [5, 4, 4, 4, 4])
        await reopened.performManualRefresh(provider: .mimo)
        XCTAssertEqual(counts.all, [5, 5, 4, 4, 4])
        XCTAssertEqual(counts.webBatches.last, [.mimo])
        await reopened.performManualRefresh(provider: .gemini)
        XCTAssertEqual(counts.all, [5, 5, 5, 4, 4])
        XCTAssertEqual(counts.webBatches.last, [.gemini])
        await reopened.performManualRefresh(provider: .chatgpt)
        XCTAssertEqual(counts.all, [5, 5, 5, 5, 4])
        await reopened.performManualRefresh(provider: .antigravity)
        XCTAssertEqual(counts.all, [5, 5, 5, 5, 5]) // card refresh is isolated from other providers

        clock.date = start.addingTimeInterval(599)
        let restarted = manager()
        await restarted.onUserInteractionOpenPopover().value
        XCTAssertEqual(counts.all, [5, 5, 5, 5, 5])
        clock.date = start.addingTimeInterval(600)
        await restarted.onUserInteractionOpenPopover().value
        XCTAssertEqual(counts.all, [6, 6, 6, 6, 6])
        XCTAssertEqual(counts.webModes.last, false)
    }

    /// Exercise the same public entry point as the top button and the real bounded reload/read engine.
    /// These drivers have no visible window, WebKit session, account or network access.
    private final class ManualPageDriver: WebPageRefreshDriver {
        let provider: ProviderID
        var currentURL: URL? { provider.consoleURL }
        var isLoading: Bool { false }
        var failureMessage: String? { nil }
        var reloads = 0
        var reads = 0
        var stops = 0
        init(_ provider: ProviderID) { self.provider = provider }
        func startQuotaReload() { reloads += 1 }
        func readBodyText() async -> String? {
            precondition(reloads > reads, "A fresh reload must precede each page read")
            reads += 1
            return provider == .mimo ? "Cash Balance: ¥ 678.90" : "5-hour limit\n80% remaining\nWeekly limit\n90% remaining"
        }
        func stopRefresh() { stops += 1 }
    }

    private static func testManualButtonReloadsAndReadsBothPages() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock()
        let access = AccessPolicyStore(defaults: defaults, now: { clock.date })
        let counts = Counts()
        let mimo = ManualPageDriver(.mimo)
        let gemini = ManualPageDriver(.gemini)
        // Every provider is already in ordinary cooldown before the first manual click.
        for action in [AccessAction.deepseekAPI, .codexAPI, .antigravityAPI, .mimoPage, .geminiPage] {
            XCTAssertNil(access.begin(action))
        }
        let manager = QuotaManager(defaults: defaults, access: access, key: "sk-test-only", bindWeb: false,
            visibleQuotaReader: { counts.localPageReads += 1 },
            webQuotaRefresher: { providers, isManual in
                counts.webModes.append(isManual)
                counts.webBatches.append(providers)
                var messages: [ProviderID: String] = [:]
                for provider in providers {
                    let driver = provider == .mimo ? mimo : gemini
                    let outcome = await WebPageRefresh.refresh(provider: provider, driver: driver,
                        accessCheck: { access.begin(provider.pageAccessAction, isManual: isManual) },
                        timeoutSeconds: 0.2, pollIntervalNanoseconds: 1_000_000)
                    XCTAssertEqual(outcome.succeeded, true)
                    messages[provider] = "\(provider.displayName) 已刷新"
                }
                return messages
            }, deepSeekReader: { _ in counts.ds += 1; return success() },
            codexReader: {
                counts.codex += 1
                var value = QuotaWindowSnapshot.defaultChatGPT()
                value.status = .ready
                return value
            }, antigravityReader: {
                counts.agy += 1
                var value = AntigravityQuotaSnapshot.placeholder
                value.status = .ready
                return value
            }, now: { clock.date })
        await manager.manualRefreshNow().value
        await manager.manualRefreshNow().value
        XCTAssertEqual([counts.ds, mimo.reloads, gemini.reloads, counts.codex, counts.agy], [2, 2, 2, 2, 2])
        XCTAssertEqual([mimo.reads, gemini.reads, mimo.stops, gemini.stops], [2, 2, 2, 2])
        XCTAssertEqual(counts.webModes, [true, true])
        XCTAssertEqual(counts.webBatches, [[.mimo, .gemini], [.mimo, .gemini]])
        XCTAssertEqual(counts.localPageReads, 0)
        XCTAssertEqual(manager.isRefreshing, false)
    }

    private static func testManualAllRefreshFailuresAreIndependent() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let counts = Counts()
        let manager = QuotaManager(defaults: defaults, access: AccessPolicyStore(defaults: defaults),
            key: "sk-test-only", bindWeb: false,
            webQuotaRefresher: { providers, isManual in
                var messages = refreshWeb(providers, manual: isManual, counts: counts)
                messages[.mimo] = "小米 MiMo：需要登录"
                return messages
            }, deepSeekReader: { _ in counts.ds += 1; return success() },
            codexReader: {
                counts.codex += 1
                throw URLError(.notConnectedToInternet)
            }, antigravityReader: {
                counts.agy += 1
                var value = AntigravityQuotaSnapshot.placeholder
                value.status = .ready
                return value
            })
        await manager.manualRefreshNow().value
        XCTAssertEqual(counts.all, [1, 1, 1, 1, 1])
        XCTAssertEqual(manager.deepseek.status, .ready)
        XCTAssertEqual(manager.chatgpt.status, .error)
        XCTAssertEqual(manager.antigravity.status, .ready)
        XCTAssertEqual(manager.statusBannerText.contains("需要登录"), true)
        XCTAssertEqual(manager.statusBannerText.contains("\(ProviderID.gemini.displayName) 已刷新"), true)
        XCTAssertEqual(manager.statusBannerText.contains("Codex 查询失败"), true)
        XCTAssertEqual(manager.statusBannerText.contains("反重力已刷新"), true)
        XCTAssertEqual(manager.isRefreshing, false)
        // Codex's ordinary error backoff must not prevent the next manual all-refresh.
        await manager.manualRefreshNow().value
        XCTAssertEqual(counts.all, [2, 2, 2, 2, 2])
    }

    private static func testManagerRequestsAndCache() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let counts = Counts()
        func manager() -> QuotaManager {
            QuotaManager(defaults: defaults, access: AccessPolicyStore(defaults: defaults), key: "sk-test-only", bindWeb: false,
                visibleQuotaReader: { counts.localPageReads += 1 },
                webQuotaRefresher: { refreshWeb($0, manual: $1, counts: counts) },
                deepSeekReader: { _ in counts.ds += 1; return success() },
                codexReader: {
                    counts.codex += 1
                    var value = QuotaWindowSnapshot.defaultChatGPT()
                    value.status = .ready; value.fiveHourRemainingPercent = 80; value.updatedAt = Date()
                    return value
                },
                antigravityReader: {
                    counts.agy += 1
                    return AntigravityQuotaSnapshot.placeholder
                })
        }
        let first = manager()
        for _ in 0..<30 { first.onUserInteractionReopenDashboard() }
        first.saveState()
        XCTAssertEqual(counts.ds + counts.codex, 0)
        XCTAssertEqual(counts.localPageReads, 0)
        await first.onUserInteractionOpenPopover().value
        XCTAssertEqual(counts.ds, 1)
        XCTAssertEqual(counts.codex, 1)
        XCTAssertEqual(counts.localPageReads, 0)
        XCTAssertEqual(counts.mimo, 1)
        XCTAssertEqual(counts.gemini, 1)
        for _ in 0..<30 { await first.onUserInteractionOpenPopover().value }
        XCTAssertEqual(counts.ds + counts.codex, 2)
        await first.performManualRefresh()
        XCTAssertEqual(counts.ds, 2)
        XCTAssertEqual(counts.codex, 2) // manual refresh ignores ordinary app cooldown
        await first.performManualRefresh(provider: .deepseek)
        XCTAssertEqual(counts.ds, 3)
        XCTAssertEqual(counts.codex, 2)
        await first.performManualRefresh(provider: .chatgpt, includeVisibleWeb: true)
        XCTAssertEqual(counts.codex, 3)
        XCTAssertEqual(counts.mimo, 2)
        XCTAssertEqual(counts.gemini, 2)
        XCTAssertEqual(counts.localPageReads, 0)
        let reopened = manager()
        XCTAssertEqual(reopened.deepseek.status, .cached)
        XCTAssertEqual(reopened.chatgpt.status, .cached)
        for _ in 0..<30 { reopened.onUserInteractionReopenDashboard() }
        for _ in 0..<30 { await reopened.onUserInteractionOpenPopover().value }
        await reopened.performRefresh(isManual: false)
        XCTAssertEqual(counts.ds + counts.codex, 6) // restart does not erase automatic cooldowns
        XCTAssertEqual(reopened.statusBarCompactTitle.contains("$678.9"), true)

        reopened.gemini.weeklyRemainingPercent = 99
        reopened.acceptGemini(WebQuotaParser.parseGemini("5-hour limit\n20% used"))
        XCTAssertEqual(reopened.gemini.fiveHourRemainingPercent, 80)
        XCTAssertNil(reopened.gemini.weeklyRemainingPercent)
        XCTAssertEqual(reopened.gemini.source, .webpage)
        XCTAssertEqual(reopened.updateGeminiPercentages(fiveHour: 101, weekly: nil), false)
        XCTAssertEqual(reopened.updateGeminiPercentages(fiveHour: .nan, weekly: nil), false)
        XCTAssertEqual(reopened.updateGeminiPercentages(fiveHour: 0, weekly: nil), true)
        XCTAssertEqual(reopened.gemini.status, .manualCalibrated)
        XCTAssertEqual(reopened.gemini.source, .manual)
        XCTAssertNil(reopened.gemini.fiveHourResetText)
        reopened.mimoCurrencyInput = "USD"
        XCTAssertEqual(reopened.updateMiMoManualBalance(-1.2), true)
        XCTAssertEqual(reopened.mimo.currencySymbol, "$")
        XCTAssertEqual(reopened.mimo.status, .manualCalibrated)
        XCTAssertEqual(reopened.updateMiMoManualBalance(.infinity), false)
        XCTAssertEqual(counts.ds + counts.codex, 6)

        // A failed observation must not become a fresh successful reading after restart.
        let failedAt = Date(timeIntervalSince1970: 1_700_000_123)
        reopened.mimo.status = .error
        reopened.mimo.updatedAt = failedAt
        reopened.mimo.note = "页面要求安全验证，读取失败"
        reopened.saveState()
        let failedReload = manager()
        XCTAssertEqual(failedReload.mimo.status == .error || failedReload.mimo.status == .cached, true)
        XCTAssertEqual(failedReload.mimo.updatedAt, failedAt)
        XCTAssertEqual(counts.ds + counts.codex, 6)

        let legacy = QuotaManager.PersistedState(deepseek: first.deepseek, mimo: reopened.mimo,
            gemini: reopened.gemini, chatgpt: first.chatgpt, menuBarStyle: .compactBalances,
            lastInteractiveRefreshAt: nil, codexQuotaVersion: 2, webQuotaVersion: nil)
        defaults.set(try JSONEncoder().encode(legacy), forKey: "com.chill.AIQuotaMonitor.persistedState.v1")
        let upgraded = manager()
        XCTAssertNil(upgraded.gemini.fiveHourRemainingPercent)
        XCTAssertEqual(upgraded.mimo.updatedAt, .distantPast)
        XCTAssertEqual(counts.ds + counts.codex, 6)
    }

    private static func testManagerFailureAndSingleFlight() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        var codexCalls = 0
        var completion: CheckedContinuation<Void, Never>?
        let manager = QuotaManager(defaults: defaults, access: AccessPolicyStore(defaults: defaults), key: "sk-test-only", bindWeb: false,
            deepSeekReader: { _ in
                calls += 1
                if calls == 1 { await withCheckedContinuation { completion = $0 } }
                let response = HTTPURLResponse(url: DeepSeekService.balanceEndpoint, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return DeepSeekService.parseResponse(data: Data(), response: response)
            }, codexReader: {
                codexCalls += 1
                throw URLError(.notConnectedToInternet)
            }, antigravityReader: {
                AntigravityQuotaSnapshot.placeholder
            })
        manager.deepseek.totalBalance = 123.45
        manager.deepseek.updatedAt = Date(timeIntervalSince1970: 1000)
        manager.deepseek.source = .officialAPI
        let query = manager.onUserInteractionOpenPopover()
        while completion == nil { await Task.yield() }
        let concurrentOpens = (0..<20).map { _ in manager.onUserInteractionOpenPopover() }
        for task in concurrentOpens { await task.value }
        await manager.performManualRefresh(provider: .deepseek)
        XCTAssertEqual(calls, 1)
        completion?.resume()
        await query.value
        XCTAssertEqual(manager.deepseek.totalBalance, 123.45)
        XCTAssertEqual(manager.deepseek.updatedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(manager.deepseek.status, .error)
        XCTAssertEqual(manager.chatgpt.status, .error)
        for _ in 0..<30 { await manager.onUserInteractionOpenPopover().value }
        await manager.performManualRefresh(provider: .deepseek)
        XCTAssertEqual(calls, 1) // even a manual click cannot clear an authentication pause
        XCTAssertEqual(codexCalls, 1)
        let store = AccessPolicyStore(defaults: defaults)
        XCTAssertEqual(store.begin(.deepseekAPI)?.contains("暂停"), true)
        manager.resumeDeepSeekAfterUserAction()
        await manager.performManualRefresh(provider: .deepseek)
        XCTAssertEqual(calls, 2) // deliberate recovery permits manual refresh despite ordinary cooldown
    }

    private static func testOrdinaryFailureAllowsManualRetry() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let manager = QuotaManager(defaults: defaults, access: AccessPolicyStore(defaults: defaults), key: "sk-test-only", bindWeb: false,
            deepSeekReader: { _ in
                calls += 1
                if calls > 1 { return success() }
                var value = DeepSeekBalanceSnapshot.placeholder
                value.status = .error; value.errorMessage = "网络错误"
                return DeepSeekService.FetchResult(snapshot: value, retryAfter: nil, requiresUserAction: false)
            }, antigravityReader: {
                AntigravityQuotaSnapshot.placeholder
            })
        await manager.performRefresh(provider: .deepseek, isManual: false)
        await manager.performRefresh(provider: .deepseek, isManual: false)
        XCTAssertEqual(calls, 1)
        await manager.performManualRefresh(provider: .deepseek)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(manager.deepseek.status, .ready)
    }

    private static func testWebRefreshSingleFlight() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let counts = Counts()
        var webCompletion: CheckedContinuation<Void, Never>?
        let manager = QuotaManager(defaults: defaults, access: AccessPolicyStore(defaults: defaults), key: "sk-test-only", bindWeb: false,
            visibleQuotaReader: { counts.localPageReads += 1 },
            webQuotaRefresher: { providers, manual in
                let result = refreshWeb(providers, manual: manual, counts: counts)
                await withCheckedContinuation { webCompletion = $0 }
                return result
            }, deepSeekReader: { _ in counts.ds += 1; return success() },
            codexReader: {
                counts.codex += 1
                return QuotaWindowSnapshot.defaultChatGPT()
            }, antigravityReader: {
                counts.agy += 1
                return AntigravityQuotaSnapshot.placeholder
            })
        let firstOpen = manager.onUserInteractionOpenPopover()
        while webCompletion == nil { await Task.yield() }
        let concurrentOpens = (0..<20).map { _ in manager.onUserInteractionOpenPopover() }
        for task in concurrentOpens { await task.value }
        await manager.manualRefreshNow().value
        XCTAssertEqual(counts.mimo, 1)
        XCTAssertEqual(counts.gemini, 1)
        XCTAssertEqual(counts.webModes, [false])
        XCTAssertEqual(counts.localPageReads, 0)
        XCTAssertEqual(manager.isRefreshing, true)
        webCompletion?.resume()
        await firstOpen.value
        await Task.yield()
        XCTAssertEqual(manager.isRefreshing, false)
        XCTAssertEqual(counts.all, [1, 1, 1, 1, 1]) // no duplicate or deferred all-refresh while any provider is active
        XCTAssertEqual(counts.webBatches, [[.mimo, .gemini]])
    }

    private static func testCredentialChangeWhileQuerying() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var completion: CheckedContinuation<Void, Never>?
        var queriedKeys: [String] = []
        let manager = QuotaManager(defaults: defaults, access: AccessPolicyStore(defaults: defaults), key: "sk-test-old", bindWeb: false,
            keyWriter: { _ in true }, deepSeekReader: { key in
                queriedKeys.append(key)
                if key == "sk-test-old" {
                    await withCheckedContinuation { completion = $0 }
                    let response = HTTPURLResponse(url: DeepSeekService.balanceEndpoint, statusCode: 403, httpVersion: nil, headerFields: nil)!
                    return DeepSeekService.parseResponse(data: Data(), response: response)
                }
                return success()
            }, antigravityReader: {
                AntigravityQuotaSnapshot.placeholder
            })
        let query = Task { await manager.performManualRefresh(provider: .deepseek) }
        while completion == nil { await Task.yield() }
        manager.apiKeyInput = "sk-test-new"
        manager.saveDeepSeekKey()
        XCTAssertEqual(manager.saveConfirmation.contains("手动"), true)
        XCTAssertEqual(manager.saveConfirmation.contains("结束"), true)
        completion?.resume()
        await query.value
        // Give any accidentally queued task a chance to execute; no task should have been queued.
        await Task.yield()
        XCTAssertEqual(queriedKeys, ["sk-test-old"])
        XCTAssertEqual(manager.deepseek.status, .needsSetup)
        XCTAssertEqual(manager.deepseek.updatedAt, .distantPast)
        XCTAssertEqual(manager.saveConfirmation.contains("手动"), true)
        let denial = AccessPolicyStore(defaults: defaults).begin(.deepseekAPI)
        XCTAssertEqual(denial?.contains("冷却"), true)
        XCTAssertEqual(denial?.contains("暂停"), false)
        await manager.performManualRefresh(provider: .deepseek)
        XCTAssertEqual(queriedKeys, ["sk-test-old", "sk-test-new"])
        XCTAssertEqual(manager.deepseek.status, .ready)
    }

    private static func testSaveEmptyKeyDoesNotQuery() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var queried = 0
        let manager = QuotaManager(defaults: defaults, access: AccessPolicyStore(defaults: defaults), key: "sk-test-old", bindWeb: false,
            keyWriter: { _ in true }, deepSeekReader: { _ in queried += 1; return success() },
            antigravityReader: { AntigravityQuotaSnapshot.placeholder })
        manager.apiKeyInput = ""
        manager.saveDeepSeekKey()
        await Task.yield()
        XCTAssertEqual(manager.hasDeepSeekKey, false)
        XCTAssertEqual(queried, 0)
        XCTAssertEqual(manager.saveConfirmation.contains("正在"), false)
    }

    private static func testInstanceLease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quota-lock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        var first: InstanceLease? = try InstanceLease(url: url)
        XCTAssertEqual(first != nil, true)
        do {
            _ = try InstanceLease(url: url)
            preconditionFailure("A second instance must not obtain the lease")
        } catch InstanceLease.LeaseError.occupied { }
        first = nil
        let reopened = try InstanceLease(url: url)
        withExtendedLifetime(reopened) { }
    }

    private static func testQuotaURLs() {
        XCTAssertEqual(SafeWebExtractor.isQuotaURL(URL(string: "https://gemini.google.com/usage"), provider: .gemini), true)
        XCTAssertEqual(SafeWebExtractor.isQuotaURL(URL(string: "https://gemini.google.com/chat"), provider: .gemini), false)
        XCTAssertEqual(SafeWebExtractor.isQuotaURL(URL(string: "https://gemini.google.com.evil.test/usage"), provider: .gemini), false)
        XCTAssertEqual(SafeWebExtractor.isQuotaURL(URL(string: "http://gemini.google.com/usage"), provider: .gemini), false)
        XCTAssertEqual(SafeWebExtractor.isQuotaURL(URL(string: "https://platform.xiaomimimo.com/#/console/balance"), provider: .mimo), true)
        XCTAssertEqual(SafeWebExtractor.isQuotaURL(URL(string: "https://id.mi.com/"), provider: .mimo), false)
    }
}
