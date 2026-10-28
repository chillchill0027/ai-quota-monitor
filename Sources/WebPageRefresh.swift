import Foundation

/// A provider-owned page performs exactly one navigation per explicit refresh operation.
/// Implementations set isLoading before startQuotaReload returns and bound each DOM read.
@MainActor
protocol WebPageRefreshDriver: AnyObject {
    var currentURL: URL? { get }
    var isLoading: Bool { get }
    var failureMessage: String? { get }
    func startQuotaReload()
    func readBodyText() async -> String?
    func stopRefresh()
}

enum WebPageRefreshOutcome {
    case mimo(WebQuotaParser.Money)
    case gemini(WebQuotaParser.GeminiQuota)
    case failure(String)

    var failureMessage: String? {
        if case .failure(let message) = self { return message }
        return nil
    }
    var succeeded: Bool { failureMessage == nil }
}

/// Waits only for the already-requested page/SPA rendering. It never retries navigation,
/// calls a private endpoint or exports a browser credential.
@MainActor
enum WebPageRefresh {
    static func refresh(provider: ProviderID, driver: any WebPageRefreshDriver,
                        accessCheck: () -> String?, timeoutSeconds: TimeInterval = 20,
                        maxDOMReads: Int = 8, pollIntervalNanoseconds: UInt64 = 400_000_000) async -> WebPageRefreshOutcome {
        guard provider == .mimo || provider == .gemini else { return .failure("该服务不使用网页额度读取") }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 600,
              (1...32).contains(maxDOMReads) else { return .failure("网页刷新参数无效，未发起访问") }
        if Task.isCancelled { return .failure("刷新已取消；保留上次记录") }
        if let denial = accessCheck() { return .failure(denial) }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1_000_000_000)
        driver.startQuotaReload()
        defer { driver.stopRefresh() }
        var reads = 0

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if Task.isCancelled { return .failure("刷新已取消；保留上次记录") }
            if let failure = driver.failureMessage { return .failure(failure) }
            if !driver.isLoading {
                if isAuthenticationURL(driver.currentURL) {
                    return .failure("需要登录，请打开该服务用量小窗完成登录后再手动刷新")
                }
                guard isQuotaURL(driver.currentURL, provider: provider) else {
                    return .failure("页面未进入该服务用量页，请在小窗完成登录后再刷新")
                }
                guard reads < maxDOMReads else {
                    return .failure("页面已刷新，但未读取到明确额度；保留上次记录，请在小窗查看")
                }
                reads += 1
                let text = await driver.readBodyText()
                if Task.isCancelled { return .failure("刷新已取消；保留上次记录") }
                if DispatchTime.now().uptimeNanoseconds >= deadline { break }
                if let failure = driver.failureMessage { return .failure(failure) }
                // A redirect/navigation during the read invalidates that DOM observation.
                let stillLoading = driver.isLoading
                if !stillLoading, isAuthenticationURL(driver.currentURL) {
                    return .failure("需要登录，请打开该服务用量小窗完成登录后再手动刷新")
                }
                if !stillLoading, isQuotaURL(driver.currentURL, provider: provider), let text {
                    if isChallengeText(text) {
                        return .failure("检测到验证或访问限制，请在官方页面处理；未继续自动尝试")
                    }
                    switch provider {
                    case .mimo:
                        if let value = WebQuotaParser.parseMiMoBalance(text) { return .mimo(value) }
                    case .gemini:
                        let value = WebQuotaParser.parseGemini(text)
                        if value.hasValues { return .gemini(value) }
                    default: break
                    }
                    if isLoginText(text) {
                        return .failure("当前会话需要登录，请在用量小窗登录后再刷新")
                    }
                }
                if reads >= maxDOMReads {
                    return .failure("页面已刷新，但未读取到明确额度；保留上次记录，请在小窗查看")
                }
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { break }
            let wait = min(max(1_000_000, pollIntervalNanoseconds), deadline - now)
            do { try await Task.sleep(nanoseconds: wait) }
            catch { return .failure("刷新已取消；保留上次记录") }
        }
        return .failure("网页额度刷新超时；已停止本次访问，保留上次记录")
    }

    static func isQuotaURL(_ url: URL?, provider: ProviderID) -> Bool {
        guard let url, url.scheme?.lowercased() == "https" else { return false }
        switch provider {
        case .gemini:
            return url.host?.lowercased() == "gemini.google.com" && url.path == "/usage"
        case .mimo:
            return url.host?.lowercased() == "platform.xiaomimimo.com"
                && (url.fragment == "/console/balance" || url.path == "/console/balance")
        default: return false
        }
    }

    static func isAuthenticationURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        if ["accounts.google.com", "id.mi.com", "account.xiaomi.com"].contains(host) { return true }
        if ["gemini.google.com", "platform.xiaomimimo.com"].contains(host) {
            let path = (url.path + "#" + (url.fragment ?? "")).lowercased()
            return path.contains("/login") || path.contains("/signin") || path.contains("/sign-in")
        }
        return false
    }

    static func isChallengeText(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["verify you are human", "unusual traffic", "access denied", "captcha", "安全验证", "异常访问", "访问过于频繁"]
            .contains(where: text.contains)
    }

    private static func isLoginText(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["sign in to continue", "please sign in", "登录后查看", "请先登录", "登录后使用"].contains(where: text.contains)
    }
}
