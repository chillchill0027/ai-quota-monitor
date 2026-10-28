import Foundation

/// The only DeepSeek network operation is the documented account-balance GET.
/// A caller must apply its own user-interaction and cooldown policy before calling this service.
enum DeepSeekService {
    static let balanceEndpoint = URL(string: "https://api.deepseek.com/user/balance")!

    struct FetchResult {
        let snapshot: DeepSeekBalanceSnapshot
        let retryAfter: TimeInterval?
        let requiresUserAction: Bool
    }

    /// A redirect must not move the API key to another URL, even on the same host.
    final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        return config
    }

    static func makeRequest(apiKey: String) -> URLRequest? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject control characters / multiline values before they reach an HTTP header.
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else { return nil }
        var request = URLRequest(url: balanceEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func fetchBalance(apiKey: String) async -> DeepSeekBalanceSnapshot {
        await fetchResult(apiKey: apiKey).snapshot
    }

    static func fetchResult(apiKey: String) async -> FetchResult {
        guard let request = makeRequest(apiKey: apiKey) else {
            return failure("请检查 DeepSeek API Key（不能为空、含空格或换行）", requiresUserAction: true)
        }
        let session = URLSession(configuration: sessionConfiguration(), delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            // Exactly one application-level attempt. No retry loop or credential fallback.
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return failure("余额接口返回了非 HTTP 响应") }
            return parseResponse(data: data, response: http)
        } catch {
            // Avoid displaying arbitrary error descriptions that could include request details.
            let message = (error as? URLError)?.code == .timedOut
                ? "余额查询超时；未自动重试，请稍后手动刷新"
                : "余额查询网络失败；未自动重试，请检查网络后手动刷新"
            return failure(message)
        }
    }

    static func parseResponse(data: Data, response: HTTPURLResponse, now: Date = Date()) -> FetchResult {
        guard response.url == balanceEndpoint else {
            return failure("余额接口地址不符合预期，已拒绝读取", now: now, requiresUserAction: true)
        }
        switch response.statusCode {
        case 200...299:
            guard data.count <= 1_000_000,
                  let decoded = try? JSONDecoder().decode(DeepSeekAPIResponse.self, from: data),
                  let selected = decoded.balance_infos.first(where: { $0.currency == "CNY" })
                    ?? decoded.balance_infos.first(where: { $0.currency == "USD" }),
                  decoded.balance_infos.filter({ $0.currency == selected.currency }).count == 1,
                  let total = decimalAmount(selected.total_balance),
                  let granted = decimalAmount(selected.granted_balance),
                  let toppedUp = decimalAmount(selected.topped_up_balance) else {
                return failure("余额响应缺失或金额格式异常；未将异常数据当作 0 元", now: now)
            }
            return FetchResult(snapshot: DeepSeekBalanceSnapshot(
                isAvailable: decoded.is_available,
                currency: selected.currency,
                totalBalance: total,
                grantedBalance: granted,
                toppedUpBalance: toppedUp,
                updatedAt: now,
                status: .ready,
                errorMessage: nil
            ), retryAfter: nil, requiresUserAction: false)
        case 401:
            return failure("DeepSeek 认证失败 (401)；请检查 API Key，已停止继续查询", now: now, requiresUserAction: true)
        case 403:
            return failure("DeepSeek 拒绝访问 (403)；请在官方控制台检查账户，已停止继续查询", now: now, requiresUserAction: true)
        case 429:
            return failure("DeepSeek 请求受限 (429)；进入冷却，不自动重试", now: now,
                           retryAfter: retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now) ?? 15 * 60)
        case 300...399:
            return failure("余额接口发生重定向，已拒绝跟随；请检查官方服务", now: now, requiresUserAction: true)
        case 500...599:
            return failure("DeepSeek 服务暂不可用 (\(response.statusCode))；未自动重试", now: now,
                           retryAfter: retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now))
        default:
            return failure("DeepSeek 余额查询失败 (HTTP \(response.statusCode))；未自动重试", now: now)
        }
    }

    /// Validate with Decimal first, then convert only for the existing display model.
    /// Decimal(string:) alone accepts numeric prefixes, so syntax must be checked first.
    static func decimalAmount(_ text: String) -> Double? {
        guard text.range(of: #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              text.filter({ $0.isNumber }).count <= 38,
              let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN else { return nil }
        let value = NSDecimalNumber(decimal: amount).doubleValue
        return value.isFinite ? value : nil
    }

    static func retryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
           let seconds = TimeInterval(value), seconds.isFinite {
            return seconds
        }
        // HTTP-date formats allowed by RFC 9110, including historical sender formats.
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }

    private static func failure(_ message: String, now: Date = Date(), retryAfter: TimeInterval? = nil,
                                requiresUserAction: Bool = false) -> FetchResult {
        var snapshot = DeepSeekBalanceSnapshot.placeholder
        snapshot.isAvailable = false
        snapshot.updatedAt = now
        snapshot.status = .error
        snapshot.errorMessage = message
        return FetchResult(snapshot: snapshot, retryAfter: retryAfter, requiresUserAction: requiresUserAction)
    }
}
