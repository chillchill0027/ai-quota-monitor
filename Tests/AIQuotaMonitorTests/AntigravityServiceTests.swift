import Foundation

enum AntigravityServiceTests {
    static let sampleJSON = """
    {
      "response": {
        "groups": [
          {
            "displayName": "Gemini Models",
            "description": "Models within this group: Gemini Flash, Gemini Pro",
            "buckets": [
              {
                "bucketId": "gemini-weekly",
                "displayName": "Weekly Limit Remaining",
                "description": "You have used some of your weekly limit, it will fully refresh in 6 days, 23 hours.",
                "window": "weekly",
                "remainingFraction": 0.9908586,
                "resetTime": "2026-11-02T07:44:10Z"
              },
              {
                "bucketId": "gemini-5h",
                "displayName": "Five Hour Limit Remaining",
                "description": "You have used some of your 5-hour limit, it will fully refresh in 4 hours, 43 minutes.",
                "window": "5h",
                "remainingFraction": 0.9680051,
                "resetTime": "2026-10-26T12:44:10Z"
              }
            ]
          },
          {
            "displayName": "Claude and GPT models",
            "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
            "buckets": [
              {
                "bucketId": "3p-weekly",
                "displayName": "Weekly Limit Remaining",
                "window": "weekly",
                "remainingFraction": 1.0,
                "resetTime": "2026-11-02T08:00:12Z"
              }
            ]
          },
          {
            "displayName": "Gemini 4 Argon",
            "description": "Argon quota is separate.",
            "buckets": [
              {
                "bucketId": "gemini-argon-wtu-weekly",
                "displayName": "Gemini 4 Argon Weekly Limit",
                "window": "weekly",
                "remainingFraction": 1.0,
                "resetTime": "2026-11-02T08:00:12Z"
              }
            ]
          }
        ],
        "description": "Quota is consumed proportionally to the cost of the tokens."
      }
    }
    """

    @MainActor
    static func run() async throws {
        try testResponseDecodingAndSnapshot()
        try testClampingAndMalformedResponse()
        testResetCountdownFormatting()
        try await testQuotaManagerIntegration()
        print("PASS: 4 Antigravity Language Server quota parsing and lifecycle tests")
    }

    private static func testResponseDecodingAndSnapshot() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-26T08:00:00Z")!
        let data = Data(sampleJSON.utf8)
        let response = try JSONDecoder().decode(AntigravityQuotaService.Response.self, from: data)
        let snapshot = response.snapshot(now: now)

        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(snapshot.fiveHourRemainingPercent, 96.8)
        XCTAssertEqual(snapshot.weeklyRemainingPercent, 99.1)
        XCTAssertEqual(snapshot.argonWeeklyRemainingPercent, 100.0)
        XCTAssertEqual(snapshot.thirdPartyWeeklyRemainingPercent, 100.0)

        // Reset text should be non-empty countdown strings
        XCTAssertEqual(snapshot.fiveHourResetText?.contains("剩余"), true)
        XCTAssertEqual(snapshot.weeklyResetText?.contains("剩余"), true)
        XCTAssertEqual(snapshot.argonWeeklyResetText?.contains("剩余"), true)
    }

    private static func testClampingAndMalformedResponse() throws {
        let now = Date()
        // Over 100% and negative values
        let clampedJSON = """
        {
          "response": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  { "window": "5h", "remainingFraction": 1.5 },
                  { "window": "weekly", "remainingFraction": -0.2 }
                ]
              }
            ]
          }
        }
        """
        let clamped = try JSONDecoder().decode(AntigravityQuotaService.Response.self, from: Data(clampedJSON.utf8)).snapshot(now: now)
        XCTAssertEqual(clamped.fiveHourRemainingPercent, 100.0)
        XCTAssertEqual(clamped.weeklyRemainingPercent, 0.0)
        XCTAssertEqual(clamped.status, .ready)

        // Empty response
        let emptyJSON = #"{"response":{"groups":[]}}"#
        let empty = try JSONDecoder().decode(AntigravityQuotaService.Response.self, from: Data(emptyJSON.utf8)).snapshot(now: now)
        XCTAssertEqual(empty.status, .unavailable)
        XCTAssertNil(empty.fiveHourRemainingPercent)
        XCTAssertNil(empty.weeklyRemainingPercent)
        XCTAssertNil(empty.argonWeeklyRemainingPercent)
    }

    private static func testResetCountdownFormatting() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let bucketFuture = AntigravityQuotaService.Response.Bucket(
            bucketId: "test", displayName: "Test", description: nil, window: "weekly",
            remainingFraction: 0.5,
            resetTime: ISO8601DateFormatter().string(from: base.addingTimeInterval(86400 * 3 + 3600 * 4))
        )
        XCTAssertEqual(bucketFuture.resetCountdown(now: base), "3d 4h")

        let bucketHours = AntigravityQuotaService.Response.Bucket(
            bucketId: "test", displayName: "Test", description: nil, window: "5h",
            remainingFraction: 0.5,
            resetTime: ISO8601DateFormatter().string(from: base.addingTimeInterval(3600 * 2 + 60 * 15))
        )
        XCTAssertEqual(bucketHours.resetCountdown(now: base), "2h 15m")

        let bucketMinutes = AntigravityQuotaService.Response.Bucket(
            bucketId: "test", displayName: "Test", description: nil, window: "5h",
            remainingFraction: 0.5,
            resetTime: ISO8601DateFormatter().string(from: base.addingTimeInterval(60 * 25))
        )
        XCTAssertEqual(bucketMinutes.resetCountdown(now: base), "25m")

        let bucketPast = AntigravityQuotaService.Response.Bucket(
            bucketId: "test", displayName: "Test", description: nil, window: "5h",
            remainingFraction: 0.5,
            resetTime: ISO8601DateFormatter().string(from: base.addingTimeInterval(-10))
        )
        XCTAssertEqual(bucketPast.resetCountdown(now: base), "即将重置")
    }

    @MainActor
    private static func testQuotaManagerIntegration() async throws {
        let suite = "AIQuotaMonitor.antigravity-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var queryCount = 0
        let manager = QuotaManager(
            defaults: defaults,
            access: AccessPolicyStore(defaults: defaults),
            key: "sk-test",
            bindWeb: false,
            antigravityReader: {
                queryCount += 1
                var snap = AntigravityQuotaSnapshot.placeholder
                snap.fiveHourRemainingPercent = 95.0
                snap.weeklyRemainingPercent = 98.0
                snap.argonWeeklyRemainingPercent = 100.0
                snap.status = .ready
                snap.updatedAt = Date()
                return snap
            }
        )

        // Manual refresh specifically for antigravity
        await manager.performManualRefresh(provider: .antigravity)
        XCTAssertEqual(queryCount, 1)
        XCTAssertEqual(manager.antigravity.status, .ready)
        XCTAssertEqual(manager.antigravity.fiveHourRemainingPercent, 95.0)
        XCTAssertEqual(manager.antigravity.weeklyRemainingPercent, 98.0)
        XCTAssertEqual(manager.antigravity.argonWeeklyRemainingPercent, 100.0)

        // Manual calibration
        let ok = manager.updateAntigravityManualPercentages(fiveHour: 80, weekly: 90, argon: 85)
        XCTAssertEqual(ok, true)
        XCTAssertEqual(manager.antigravity.fiveHourRemainingPercent, 80.0)
        XCTAssertEqual(manager.antigravity.weeklyRemainingPercent, 90.0)
        XCTAssertEqual(manager.antigravity.argonWeeklyRemainingPercent, 85.0)
        XCTAssertEqual(manager.antigravity.status, .manualCalibrated)
        XCTAssertEqual(manager.antigravity.source, .manual)

        // Invalid percentages rejected
        XCTAssertEqual(manager.updateAntigravityManualPercentages(fiveHour: -5, weekly: nil, argon: nil), false)
        XCTAssertEqual(manager.updateAntigravityManualPercentages(fiveHour: 105, weekly: nil, argon: nil), false)
    }
}
