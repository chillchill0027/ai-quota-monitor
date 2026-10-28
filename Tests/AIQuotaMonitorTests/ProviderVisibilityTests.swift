import Foundation

@MainActor
enum ProviderVisibilityTests {
    private static let stateKey = "com.chill.AIQuotaMonitor.persistedState.v1"

    static func run() async throws {
        testDefaultVisibilityAndStableOrder()
        testEveryProviderCanBeTheRequiredLastSelection()
        testSelectionAndStatusBarModeSurviveRestart()
        try testOlderAndUnknownSelectionsPreserveQuotaCache()
        testVisibilityChangesStayLocal()
        await testHiddenCardsKeepFiveProviderRefreshAndCooldown()
        print("PASS: 6 provider-visibility selection, migration, persistence and refresh-policy regressions")
    }

    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private final class Counts {
        var deepseek = 0
        var mimo = 0
        var gemini = 0
        var codex = 0
        var antigravity = 0
        var keyWrites = 0
        var webModes: [Bool] = []
        var webBatches: [[ProviderID]] = []
        var readers: [Int] { [deepseek, mimo, gemini, codex, antigravity] }
    }

    @MainActor
    private final class Fixture {
        let suite = "AIQuotaMonitor.visibility-tests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let clock = Clock()
        let counts = Counts()

        init() { defaults = UserDefaults(suiteName: suite)! }
        func cleanUp() { defaults.removePersistentDomain(forName: suite) }

        func manager() -> QuotaManager {
            let counts = counts
            let clock = clock
            return QuotaManager(
                defaults: defaults,
                access: AccessPolicyStore(defaults: defaults, now: { clock.date }),
                key: "sk-offline-visibility-test", bindWeb: false,
                keyWriter: { _ in counts.keyWrites += 1; return true },
                webQuotaRefresher: { providers, manual in
                    counts.webModes.append(manual)
                    counts.webBatches.append(providers)
                    var results: [ProviderID: String] = [:]
                    for provider in providers {
                        if provider == .mimo { counts.mimo += 1 }
                        if provider == .gemini { counts.gemini += 1 }
                        results[provider] = "离线模拟已刷新"
                    }
                    return results
                },
                deepSeekReader: { _ in
                    counts.deepseek += 1
                    var snapshot = DeepSeekBalanceSnapshot.placeholder
                    snapshot.status = .ready
                    snapshot.totalBalance = 12.34
                    snapshot.updatedAt = clock.date
                    return DeepSeekService.FetchResult(snapshot: snapshot, retryAfter: nil, requiresUserAction: false)
                },
                codexReader: {
                    counts.codex += 1
                    var snapshot = QuotaWindowSnapshot.defaultChatGPT()
                    snapshot.status = .ready
                    snapshot.fiveHourRemainingPercent = 72
                    snapshot.updatedAt = clock.date
                    return snapshot
                },
                antigravityReader: {
                    counts.antigravity += 1
                    var snapshot = AntigravityQuotaSnapshot.placeholder
                    snapshot.status = .ready
                    snapshot.fiveHourRemainingPercent = 81
                    snapshot.updatedAt = clock.date
                    return snapshot
                },
                now: { clock.date }
            )
        }
    }

    private static func testDefaultVisibilityAndStableOrder() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager()
        XCTAssertEqual(manager.visibleProviders, Set(ProviderID.allCases))
        XCTAssertEqual(ProviderID.dashboardOrder, [.deepseek, .mimo, .chatgpt, .gemini, .antigravity])
        for provider in ProviderID.allCases {
            XCTAssertEqual(manager.isProviderVisible(provider), true)
            XCTAssertEqual(manager.canToggleProvider(provider), true)
        }
        XCTAssertEqual(fixture.counts.readers, [0, 0, 0, 0, 0])
    }

    private static func testEveryProviderCanBeTheRequiredLastSelection() {
        for lastProvider in ProviderID.allCases {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            let manager = fixture.manager()
            for provider in ProviderID.allCases where provider != lastProvider {
                XCTAssertEqual(manager.toggleProviderVisibility(provider), true)
            }
            XCTAssertEqual(manager.visibleProviders, [lastProvider])
            XCTAssertEqual(manager.canToggleProvider(lastProvider), false)
            for _ in 0..<3 {
                XCTAssertEqual(manager.toggleProviderVisibility(lastProvider), false)
                XCTAssertEqual(manager.visibleProviders, [lastProvider])
            }
            let restoredProvider = ProviderID.allCases.first { $0 != lastProvider }!
            XCTAssertEqual(manager.canToggleProvider(restoredProvider), true)
            XCTAssertEqual(manager.toggleProviderVisibility(restoredProvider), true)
            XCTAssertEqual(manager.canToggleProvider(lastProvider), true)
            XCTAssertEqual(manager.toggleProviderVisibility(lastProvider), true)
            XCTAssertEqual(manager.visibleProviders, [restoredProvider])
        }
    }

    private static func testSelectionAndStatusBarModeSurviveRestart() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager()
        manager.menuBarStyle = .allFive
        let statusBarTitle = manager.statusBarCompactTitle
        for style in MenuBarDisplayStyle.allCases {
            let preview = manager.statusBarTitle(for: style)
            XCTAssertEqual(manager.menuBarStyle, .allFive)
            if style == .allFive { XCTAssertEqual(preview, statusBarTitle) }
        }
        manager.toggleProviderVisibility(.deepseek)
        manager.toggleProviderVisibility(.chatgpt)
        let expected: Set<ProviderID> = [.mimo, .gemini, .antigravity]
        XCTAssertEqual(manager.visibleProviders, expected)
        // The settings expose card visibility and the status-bar format separately.
        XCTAssertEqual(manager.statusBarCompactTitle, statusBarTitle)
        for _ in 0..<2 {
            let restarted = fixture.manager()
            XCTAssertEqual(restarted.visibleProviders, expected)
            XCTAssertEqual(restarted.menuBarStyle, .allFive)
            XCTAssertEqual(restarted.statusBarCompactTitle, statusBarTitle)
        }
    }

    private static func testOlderAndUnknownSelectionsPreserveQuotaCache() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager()
        manager.deepseek.totalBalance = 43.21
        manager.deepseek.status = .ready
        manager.deepseek.updatedAt = fixture.clock.date
        manager.chatgpt.fiveHourRemainingPercent = 64
        manager.chatgpt.status = .ready
        manager.chatgpt.updatedAt = fixture.clock.date
        manager.menuBarStyle = .iconOnly
        manager.saveState()
        let saved = try JSONSerialization.jsonObject(with: fixture.defaults.data(forKey: stateKey)!) as! [String: Any]
        let cases: [([String]?, Set<ProviderID>)] = [
            (nil, Set(ProviderID.allCases)),
            ([], Set(ProviderID.allCases)),
            (["future-service"], Set(ProviderID.allCases)),
            (["mimo", "future-service", "mimo"], [.mimo])
        ]
        for (selection, expected) in cases {
            var payload = saved
            if let selection { payload["visibleProviders"] = selection }
            else { payload.removeValue(forKey: "visibleProviders") }
            fixture.defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: stateKey)
            let restarted = fixture.manager()
            XCTAssertEqual(restarted.visibleProviders, expected)
            XCTAssertEqual(restarted.deepseek.totalBalance, 43.21)
            XCTAssertEqual(restarted.deepseek.status, .cached)
            XCTAssertEqual(restarted.chatgpt.fiveHourRemainingPercent, 64)
            XCTAssertEqual(restarted.menuBarStyle, .iconOnly)
        }
    }

    private static func testVisibilityChangesStayLocal() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager()
        for provider in ProviderID.dashboardOrder.dropLast() { manager.toggleProviderVisibility(provider) }
        for provider in ProviderID.dashboardOrder.dropLast() { manager.toggleProviderVisibility(provider) }
        XCTAssertEqual(manager.visibleProviders, Set(ProviderID.allCases))
        XCTAssertEqual(fixture.counts.readers, [0, 0, 0, 0, 0])
        XCTAssertEqual(fixture.counts.keyWrites, 0)
        XCTAssertNil(manager.lastInteractiveRefreshAt)
        XCTAssertEqual(manager.isRefreshing, false)
    }

    private static func testHiddenCardsKeepFiveProviderRefreshAndCooldown() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager()
        let start = fixture.clock.date
        for provider in ProviderID.allCases where provider != .gemini {
            manager.toggleProviderVisibility(provider)
        }
        XCTAssertEqual(manager.visibleProviders, [.gemini])
        await manager.onUserInteractionOpenPopover().value
        XCTAssertEqual(fixture.counts.readers, [1, 1, 1, 1, 1])
        fixture.clock.date = start.addingTimeInterval(299)
        await manager.onUserInteractionOpenPopover().value
        XCTAssertEqual(fixture.counts.readers, [1, 1, 1, 1, 1])

        manager.toggleProviderVisibility(.deepseek)
        manager.toggleProviderVisibility(.gemini)
        await manager.onUserInteractionOpenPopover().value
        XCTAssertEqual(fixture.counts.readers, [1, 1, 1, 1, 1])
        fixture.clock.date = start.addingTimeInterval(300)
        await manager.onUserInteractionOpenPopover().value
        XCTAssertEqual(fixture.counts.readers, [2, 2, 2, 2, 2])
        await manager.manualRefreshNow().value
        await manager.manualRefreshNow().value
        XCTAssertEqual(fixture.counts.readers, [4, 4, 4, 4, 4])
        fixture.clock.date = start.addingTimeInterval(599)
        await manager.onUserInteractionOpenPopover().value
        XCTAssertEqual(fixture.counts.readers, [4, 4, 4, 4, 4])
        fixture.clock.date = start.addingTimeInterval(600)
        let restarted = fixture.manager()
        XCTAssertEqual(restarted.visibleProviders, [.deepseek])
        await restarted.onUserInteractionOpenPopover().value
        XCTAssertEqual(fixture.counts.readers, [5, 5, 5, 5, 5])
        XCTAssertEqual(fixture.counts.webModes, [false, false, true, true, false])
        XCTAssertEqual(fixture.counts.webBatches.allSatisfy { $0 == [.mimo, .gemini] }, true)
        XCTAssertEqual(fixture.counts.keyWrites, 0)
    }
}
