import Foundation

/// These tests are entirely offline and never read a real API key.
enum DeepSeekServiceTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func run() async throws {
        testValidBalancesAndCurrencies()
        testInvalidBalancesNeverBecomeSuccessfulZero()
        testUnavailableAccountIsPreserved()
        testAuthenticationAndForbiddenStopFurtherQueries()
        testRateLimitAndRetryAfter()
        testHTTPFailuresAndUnexpectedEndpoints()
        testRequestHasOnlyExpectedEndpointAndHeaders()
        testSessionDoesNotUseCookiesOrFollowRedirects()
        print("PASS: 8 offline DeepSeek safety/response tests")
    }

    private static func response(_ status: Int = 200, headers: [String: String] = [:],
                                 url: URL = DeepSeekService.balanceEndpoint) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private static func parse(_ json: String, status: Int = 200,
                              headers: [String: String] = [:]) -> DeepSeekService.FetchResult {
        DeepSeekService.parseResponse(data: Data(json.utf8), response: response(status, headers: headers), now: now)
    }

    private static func testValidBalancesAndCurrencies() {
        let cny = parse(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"2.00","granted_balance":"0.00","topped_up_balance":"2.00"},{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#)
        XCTAssertEqual(cny.snapshot.status, .ready)
        XCTAssertEqual(cny.snapshot.currency, "CNY")
        XCTAssertEqual(cny.snapshot.totalBalance, 110)
        XCTAssertEqual(cny.snapshot.grantedBalance, 10)
        XCTAssertEqual(cny.snapshot.toppedUpBalance, 100)
        XCTAssertEqual(cny.snapshot.updatedAt, now)
        let usd = parse(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"2.10","granted_balance":"0.10","topped_up_balance":"2.00"}]}"#)
        XCTAssertEqual(usd.snapshot.currency, "USD")
        XCTAssertEqual(usd.snapshot.currencySymbol, "$")
        XCTAssertEqual(usd.snapshot.totalBalance, 2.1)
        XCTAssertNil(usd.retryAfter)
    }

    private static func testInvalidBalancesNeverBecomeSuccessfulZero() {
        for json in [#"{}"#, #"{"is_available":true,"balance_infos":[]}"#,
                     #"{"is_available":true,"balance_infos":[{"currency":"EUR","total_balance":"1","granted_balance":"0","topped_up_balance":"1"}]}"#,
                     #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"abc","granted_balance":"0","topped_up_balance":"0"}]}"#,
                     #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"0","granted_balance":"0"}]}"#,
                     #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"1","granted_balance":"0","topped_up_balance":"1"},{"currency":"CNY","total_balance":"2","granted_balance":"0","topped_up_balance":"2"}]}"#] {
            XCTAssertEqual(parse(json).snapshot.status, .error)
        }
        for amount in ["NaN", "Infinity", "-Infinity", "1oops", "1e999", "1,000.00", "1 2", "", ".5", "1.2.3", "999999999999999999999999999999999999999"] {
            XCTAssertNil(DeepSeekService.decimalAmount(amount))
        }
        XCTAssertEqual(DeepSeekService.decimalAmount("0"), 0)
        XCTAssertEqual(DeepSeekService.decimalAmount("0.00"), 0)
        XCTAssertEqual(DeepSeekService.decimalAmount("-0.01"), -0.01)
    }

    private static func testUnavailableAccountIsPreserved() {
        let result = parse(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}"#)
        XCTAssertEqual(result.snapshot.status, .ready)
        XCTAssertEqual(result.snapshot.isAvailable, false)
        XCTAssertEqual(result.snapshot.totalBalance, 0)
    }

    private static func testAuthenticationAndForbiddenStopFurtherQueries() {
        for status in [401, 403] {
            let result = parse("<html>blocked</html>", status: status)
            XCTAssertEqual(result.requiresUserAction, true)
            XCTAssertEqual(result.snapshot.status, .error)
            XCTAssertEqual(result.snapshot.errorMessage?.contains("\(status)"), true)
            XCTAssertNil(result.retryAfter)
        }
    }

    private static func testRateLimitAndRetryAfter() {
        let seconds = parse("", status: 429, headers: ["Retry-After": "3600"])
        XCTAssertEqual(seconds.retryAfter, 3600)
        XCTAssertEqual(seconds.requiresUserAction, false)
        let date = parse("", status: 429, headers: ["Retry-After": "Tue, 14 Nov 2023 23:13:20 GMT"])
        XCTAssertEqual(date.retryAfter, 3600)
        XCTAssertEqual(parse("", status: 429).retryAfter, 900)
        XCTAssertNil(DeepSeekService.retryAfter("NaN", now: now))
        XCTAssertNil(DeepSeekService.retryAfter("-1", now: now))
        XCTAssertEqual(DeepSeekService.retryAfter("0", now: now), 0)
        XCTAssertEqual(DeepSeekService.retryAfter("Tue, 14 Nov 2023 21:13:20 GMT", now: now), 0)
    }

    private static func testHTTPFailuresAndUnexpectedEndpoints() {
        for status in [500, 502, 503, 400, 404] {
            XCTAssertEqual(parse("", status: status).snapshot.status, .error)
        }
        XCTAssertEqual(parse("", status: 503, headers: ["Retry-After": "1200"]).retryAfter, 1200)
        for status in [301, 302, 307, 308] {
            XCTAssertEqual(parse("", status: status).requiresUserAction, true)
        }
        let unexpected = DeepSeekService.parseResponse(data: Data(), response: response(url: URL(string: "https://example.org/user/balance")!), now: now)
        XCTAssertEqual(unexpected.snapshot.status, .error)
        XCTAssertEqual(unexpected.requiresUserAction, true)
    }

    private static func testRequestHasOnlyExpectedEndpointAndHeaders() {
        let request = DeepSeekService.makeRequest(apiKey: " sk-test-only ")!
        XCTAssertEqual(request.url, DeepSeekService.balanceEndpoint)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-only")
        XCTAssertEqual(request.httpShouldHandleCookies, false)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.httpBody)
        XCTAssertNil(DeepSeekService.makeRequest(apiKey: ""))
        XCTAssertNil(DeepSeekService.makeRequest(apiKey: "sk-test\nInjected: value"))
        XCTAssertNil(DeepSeekService.makeRequest(apiKey: "sk-test key"))
    }

    private static func testSessionDoesNotUseCookiesOrFollowRedirects() {
        let configuration = DeepSeekService.sessionConfiguration()
        XCTAssertEqual(configuration.httpShouldSetCookies, false)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.waitsForConnectivity, false)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 1)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: DeepSeekService.balanceEndpoint) // not resumed: no network
        var accepted = true
        DeepSeekService.NoRedirectDelegate().urlSession(session, task: task,
            willPerformHTTPRedirection: response(302),
            newRequest: URLRequest(url: URL(string: "https://example.org/capture")!)) { request in
                accepted = request != nil
            }
        XCTAssertEqual(accepted, false)
    }
}
