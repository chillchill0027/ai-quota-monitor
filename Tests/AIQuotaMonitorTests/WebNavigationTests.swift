import Foundation

/// Pure state-machine tests. They never initialize WebKit or load an account page.
enum WebNavigationTests {
    static func run() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var gate = WebNavigationGate()
        var automaticReservations = 0
        let limited: () -> String? = {
            automaticReservations += 1
            return "automatic cooldown"
        }

        // An actual native button can grant another chain immediately, with no ordinary wait.
        gate.nativeActionApproved(now: now)
        for _ in 0..<8 {
            XCTAssertNil(gate.authorizeMainFrame(suspendedReason: nil, now: now, reserveAutomatic: limited))
        }
        XCTAssertEqual(automaticReservations, 0)
        XCTAssertEqual(gate.authorizeMainFrame(suspendedReason: nil, now: now, reserveAutomatic: limited), "automatic cooldown")
        XCTAssertEqual(automaticReservations, 1)
        gate.nativeActionApproved(now: now)
        XCTAssertNil(gate.authorizeMainFrame(suspendedReason: nil, now: now, reserveAutomatic: limited))
        XCTAssertEqual(automaticReservations, 1)

        // A finished document may still perform a client-side hop within the same
        // explicit refresh. Finishing it keeps only the original bounded permit.
        var refreshGate = WebNavigationGate()
        var refreshAutomaticReservations = 0
        let refreshLimited: () -> String? = {
            refreshAutomaticReservations += 1
            return "automatic cooldown"
        }
        refreshGate.nativeActionApproved(now: now)
        for _ in 0..<3 {
            XCTAssertNil(refreshGate.authorizeMainFrame(suspendedReason: nil, now: now, reserveAutomatic: refreshLimited))
        }
        refreshGate.documentDidFinish(isRefreshing: true)
        for _ in 0..<5 {
            XCTAssertNil(refreshGate.authorizeMainFrame(suspendedReason: nil, now: now, reserveAutomatic: refreshLimited))
        }
        XCTAssertEqual(refreshAutomaticReservations, 0)
        refreshGate.documentDidFinish(isRefreshing: true)
        XCTAssertEqual(refreshGate.authorizeMainFrame(suspendedReason: nil, now: now, reserveAutomatic: refreshLimited), "automatic cooldown")
        XCTAssertEqual(refreshAutomaticReservations, 1) // didFinish never renews the eight-hop budget.

        refreshGate.nativeActionApproved(now: now)
        XCTAssertNil(refreshGate.authorizeMainFrame(suspendedReason: nil, now: now.addingTimeInterval(20), reserveAutomatic: refreshLimited))
        refreshGate.documentDidFinish(isRefreshing: true)
        XCTAssertEqual(refreshGate.authorizeMainFrame(suspendedReason: nil, now: now.addingTimeInterval(31), reserveAutomatic: refreshLimited), "automatic cooldown")
        XCTAssertEqual(refreshAutomaticReservations, 2) // didFinish never extends the original deadline.

        refreshGate.nativeActionApproved(now: now)
        refreshGate.documentDidFinish(isRefreshing: false)
        XCTAssertEqual(refreshGate.authorizeMainFrame(suspendedReason: nil, now: now, reserveAutomatic: refreshLimited), "automatic cooldown")
        XCTAssertEqual(refreshAutomaticReservations, 3)

        // A completed page cannot confer a new native approval to its own reload/form script.
        gate.clear()
        for _ in 0..<20 {
            XCTAssertEqual(gate.authorizeMainFrame(suspendedReason: nil, now: now, reserveAutomatic: limited), "automatic cooldown")
        }
        XCTAssertEqual(automaticReservations, 21)

        // Suspension blocks even the remainder of a previously approved redirect chain.
        gate.nativeActionApproved(now: now)
        XCTAssertEqual(gate.authorizeMainFrame(suspendedReason: "403 verification", now: now, reserveAutomatic: limited), "已暂停访问：403 verification")
        XCTAssertEqual(automaticReservations, 21)

        // A chain has a real deadline as well as a hop count.
        gate.nativeActionApproved(now: now)
        XCTAssertEqual(gate.authorizeMainFrame(suspendedReason: nil, now: now.addingTimeInterval(31), reserveAutomatic: limited), "automatic cooldown")
        XCTAssertEqual(automaticReservations, 22)

        // All webpage-originated new chains use the automatic, rate-limited access path.
        gate.clear()
        var policy = AccessPolicy()
        var limitedReservations = 0
        let automatic: () -> String? = {
            limitedReservations += 1
            return policy.begin(.geminiPage, isManual: false, now: now)
        }
        XCTAssertNil(gate.authorizeMainFrame(suspendedReason: nil, now: now, reserveAutomatic: automatic))
        gate.clear()
        XCTAssertEqual(gate.authorizeMainFrame(suspendedReason: nil, now: now, reserveAutomatic: automatic) != nil, true)
        XCTAssertEqual(limitedReservations, 2)
        XCTAssertEqual(policy.entries[AccessAction.geminiPage.rawValue]?.nextAllowedAt, now.addingTimeInterval(AccessAction.geminiPage.minimumInterval))

        // Denial from a server wait is returned intact; no hidden native-approval fallback.
        gate.clear()
        XCTAssertEqual(gate.authorizeMainFrame(suspendedReason: nil, now: now) { "Retry-After: 3600" }, "Retry-After: 3600")
        XCTAssertEqual(gate.authorizeMainFrame(suspendedReason: nil, now: now, reserveAutomatic: limited), "automatic cooldown")
        print("PASS: native manual navigation, script reload limits, suspension and redirect-chain tests")
    }
}
