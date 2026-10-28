import Foundation
import WebKit

/// One provider owns one WebKit document and navigation state. The native data store
/// handles its own cookies; this object never enumerates or exports credentials.
@MainActor
final class WebPageSession: NSObject, WebPageRefreshDriver, WKNavigationDelegate {
    let provider: ProviderID
    let webView: WKWebView
    private let access: AccessPolicyStore
    private var navigationGate = WebNavigationGate()
    private var activeNavigation: WKNavigation?
    private let retiredNavigations = NSHashTable<WKNavigation>(options: [.weakMemory, .objectPointerPersonality])
    private var hasLiveDocument = false
    private var generation = 0
    private var interactiveLoginUntil = Date.distantPast
    private var interactiveLoginSteps = 0
    private var pendingReads: [UUID: CheckedContinuation<String?, Never>] = [:]
    private(set) var isLoading = false
    private(set) var isExtracting = false
    private(set) var isRefreshRunning = false
    private(set) var failureMessage: String?
    private(set) var title = ""
    var isVisible: () -> Bool = { false }
    var onStateChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?

    var currentURL: URL? { webView.url }

    init(provider: ProviderID, access: AccessPolicyStore? = nil) {
        self.provider = provider
        self.access = access ?? .shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1050, height: 640), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    /// The caller has already reserved this provider's access budget exactly once.
    func startQuotaReload() {
        isRefreshRunning = true
        startQuotaNavigation()
    }

    func startVisibleNavigation(url: URL? = nil) -> String? {
        guard !isRefreshRunning else { return "该用量页正在刷新，请稍候" }
        if let denial = access.begin(provider.pageAccessAction, isManual: true) { return denial }
        interactiveLoginUntil = Date().addingTimeInterval(120)
        interactiveLoginSteps = 24
        startQuotaNavigation(url: url)
        return nil
    }

    private func startQuotaNavigation(url: URL? = nil) {
        failureMessage = nil
        generation += 1
        finishAllReads()
        retireActiveNavigation()
        hasLiveDocument = true
        webView.stopLoading()
        navigationGate.nativeActionApproved()
        isLoading = true // Prevent an old DOM from being mistaken for the new request.
        onStateChanged?()
        if let url {
            activeNavigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        } else if WebPageRefresh.isQuotaURL(webView.url, provider: provider) {
            activeNavigation = webView.reload()
        } else {
            activeNavigation = webView.load(URLRequest(url: provider.consoleURL, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    func readBodyText() async -> String? {
        guard !isLoading, failureMessage == nil else { return nil }
        let id = UUID()
        let readGeneration = generation
        isExtracting = true
        onStateChanged?()
        let value: String? = await withTaskCancellationHandler {
            if Task.isCancelled { return nil }
            return await withCheckedContinuation { continuation in
                pendingReads[id] = continuation
                webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] value, error in
                    guard let self else { return }
                    let text = error == nil && self.generation == readGeneration ? value as? String : nil
                    self.finishRead(id, text: text)
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    self?.finishRead(id, text: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishRead(id, text: nil) }
        }
        isExtracting = !pendingReads.isEmpty
        onStateChanged?()
        return value
    }

    private func finishRead(_ id: UUID, text: String?) {
        pendingReads.removeValue(forKey: id)?.resume(returning: text)
    }
    private func finishAllReads() {
        let reads = pendingReads.values
        pendingReads.removeAll()
        for continuation in reads { continuation.resume(returning: nil) }
        isExtracting = false
    }

    /// A user-triggered refresh may run while its window is closed, but hidden pages
    /// are unloaded immediately after that bounded operation finishes.
    func stopRefresh() {
        isRefreshRunning = false
        navigationGate.clear()
        if !isVisible() { unload() }
        onStateChanged?()
    }

    func cancelAndUnload() {
        if isRefreshRunning { failureMessage = "用量小窗已关闭，本次刷新已取消" }
        unload()
    }

    func unload() {
        generation += 1
        hasLiveDocument = false
        retireActiveNavigation()
        navigationGate.clear()
        interactiveLoginUntil = .distantPast
        interactiveLoginSteps = 0
        finishAllReads()
        webView.stopLoading()
        if let blankNavigation = webView.loadHTMLString("", baseURL: nil) {
            retiredNavigations.add(blankNavigation)
        }
        isLoading = false
        onStateChanged?()
    }

    private func fail(_ message: String, recordFailure: Bool = false, suspend: Bool = false, retryAfter: TimeInterval? = nil) {
        failureMessage = message
        if recordFailure { access.failed(provider.pageAccessAction, retryAfter: retryAfter, suspendReason: suspend ? message : nil) }
        unload()
        onFailure?(message)
        onStateChanged?()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard hasLiveDocument, let navigation, !retiredNavigations.contains(navigation) else { return }
        if activeNavigation !== navigation {
            retireActiveNavigation()
            activeNavigation = navigation
        }
        generation += 1
        finishAllReads()
        isLoading = true
        onStateChanged?()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isCurrentNavigation(navigation) else { return }
        isLoading = false
        navigationGate.documentDidFinish(isRefreshing: isRefreshRunning)
        title = webView.title ?? provider.displayName
        onStateChanged?()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isCurrentNavigation(navigation) { navigationFailed(error) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isCurrentNavigation(navigation) { navigationFailed(error) }
    }
    private func isCurrentNavigation(_ navigation: WKNavigation?) -> Bool {
        hasLiveDocument && navigation != nil && activeNavigation === navigation
    }
    private func retireActiveNavigation() {
        if let activeNavigation { retiredNavigations.add(activeNavigation) }
        activeNavigation = nil
    }
    private func navigationFailed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        fail("页面加载失败，请手动重试或打开对应小窗登录", recordFailure: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        let allowed: Set<String> = provider == .gemini
            ? ["gemini.google.com", "accounts.google.com"]
            : ["platform.xiaomimimo.com", "id.mi.com", "account.xiaomi.com"]
        guard url.scheme == "https", let host = url.host?.lowercased(), allowed.contains(host) else {
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false { fail("已停止离开官方站点；登录受限时请使用常用浏览器") }
            return
        }
        if let denial = access.suspension(provider.pageAccessAction) ?? access.serverWait(provider.pageAccessAction) {
            decisionHandler(.cancel)
            fail(denial)
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false {
            // Native window opening authorizes a bounded visible sign-in transaction.
            // It does not authorize quota-page scripts to reload indefinitely.
            let isLoginHop = WebPageRefresh.isAuthenticationURL(url) || WebPageRefresh.isAuthenticationURL(webView.url)
            let visibleLoginPermit = isVisible() && isLoginHop && Date() < interactiveLoginUntil && interactiveLoginSteps > 0
            if visibleLoginPermit {
                interactiveLoginSteps -= 1
            } else if let denial = navigationGate.authorizeMainFrame(suspendedReason: nil, reserveAutomatic: {
                access.begin(provider.pageAccessAction, isManual: false)
            }) {
                decisionHandler(.cancel)
                fail(denial)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
           [401, 403, 429].contains(response.statusCode) {
            decisionHandler(.cancel)
            fail("站点返回 \(response.statusCode)，请在对应小窗或官方浏览器处理登录/验证", recordFailure: true,
                 suspend: true, retryAfter: DeepSeekService.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: Date()))
            return
        }
        decisionHandler(.allow)
    }
}
