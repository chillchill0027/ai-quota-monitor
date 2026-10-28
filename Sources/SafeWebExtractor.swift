import Foundation
import WebKit
import AppKit
import SwiftUI

/// User-driven browsing and local text extraction only. Native manual actions bypass ordinary cooldowns.
/// Web navigation types are never proof of a human gesture.
struct WebNavigationGate {
    private var budget = NavigationBudget()

    mutating func nativeActionApproved(now: Date = Date()) { budget.grant(now: now) }
    mutating func clear() { budget.clear() }

    /// A bounded explicit refresh includes SPA navigation after the initial document loads.
    /// Finishing a document must not renew its hop count or deadline.
    mutating func documentDidFinish(isRefreshing: Bool) {
        if !isRefreshing { clear() }
    }

    /// A webpage with no native permit must use the automatic (limited) policy path.
    mutating func authorizeMainFrame(suspendedReason: String?, now: Date = Date(),
                                    reserveAutomatic: () -> String?) -> String? {
        if let suspendedReason { return "已暂停访问：\(suspendedReason)" }
        if budget.consume(now: now) { return nil }
        if let denial = reserveAutomatic() { return denial }
        budget.grant(now: now)
        guard budget.consume(now: now) else { return "导航许可已失效，请手动刷新" }
        return nil
    }
}

/// The browser only follows native approvals or the limited automatic policy path.
@MainActor
final class SafeWebExtractor: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = SafeWebExtractor()
    @Published var activeProvider: ProviderID = .mimo
    @Published var isPageLoading = false
    @Published var isExtracting = false
    @Published var pageTitle = ""
    @Published var currentURLString = ""
    @Published var lastExtractionHint = "手动刷新不受普通冷却；认证暂停和服务端等待仍生效，页面读取不额外联网"

    private let access: AccessPolicyStore
    private let mimoSession: WebPageSession
    private let geminiSession: WebPageSession
    private var browserWindow: NSWindow?

    var onMiMoExtracted: ((WebQuotaParser.Money) -> Void)?
    var onGeminiExtracted: ((WebQuotaParser.GeminiQuota) -> Void)?
    var onExtractionFailed: ((ProviderID, String) -> Void)?

    private override init() {
        let store = AccessPolicyStore.shared
        self.access = store
        let mimo = WebPageSession(provider: .mimo, access: store)
        let gemini = WebPageSession(provider: .gemini, access: store)
        self.mimoSession = mimo
        self.geminiSession = gemini
        super.init()
        bindSession(mimo)
        bindSession(gemini)
    }

    private func bindSession(_ session: WebPageSession) {
        session.isVisible = { [weak self, weak session] in
            guard let self, let session else { return false }
            return self.browserWindow?.isVisible == true && self.activeProvider == session.provider
        }
        session.onStateChanged = { [weak self] in
            self?.syncActiveSessionState()
        }
        session.onFailure = { [weak self, weak session] message in
            guard let self, let session else { return }
            self.report(session.provider, message)
        }
    }

    func session(for provider: ProviderID) -> WebPageSession {
        provider == .mimo ? mimoSession : geminiSession
    }

    var webView: WKWebView {
        session(for: activeProvider).webView
    }

    private func syncActiveSessionState() {
        let session = session(for: activeProvider)
        isPageLoading = session.isLoading
        isExtracting = session.isExtracting
        pageTitle = session.title.isEmpty ? activeProvider.displayName : session.title
        currentURLString = session.currentURL?.absoluteString ?? ""
    }

    func openOfficialPage(for provider: ProviderID) {
        // Normal-browser recovery may bypass an embedded authentication pause, but not
        // a server Retry-After attached to the same quota page URL.
        if let denial = access.serverWait(provider.pageAccessAction) {
            report(provider, denial)
            return
        }
        if let denial = access.begin(provider.browserAccessAction, isManual: true) {
            report(provider, denial)
            return
        }
        NSWorkspace.shared.open(provider.consoleURL)
    }

    func openSafeWindow(for provider: ProviderID, customURL: URL? = nil) {
        guard provider == .mimo || provider == .gemini else { openOfficialPage(for: provider); return }
        if browserWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 730),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: WebLoginWindowView(extractor: self))
            browserWindow = window
        }
        let wasSamePage = activeProvider == provider && Self.isQuotaURL(session(for: provider).currentURL, provider: provider)
        activeProvider = provider
        browserWindow?.title = "用量小窗 — \(provider.displayName)"
        NSApp.activate(ignoringOtherApps: true)
        browserWindow?.makeKeyAndOrderFront(nil)
        syncActiveSessionState()
        if !wasSamePage {
            if let denial = session(for: provider).startVisibleNavigation(url: customURL) {
                report(provider, denial)
            }
        }
    }

    func selectProvider(_ provider: ProviderID) {
        guard activeProvider != provider else { return }
        activeProvider = provider
        syncActiveSessionState()
        if browserWindow?.isVisible == true {
            let session = session(for: provider)
            if !Self.isQuotaURL(session.currentURL, provider: provider) {
                if let denial = session.startVisibleNavigation() {
                    report(provider, denial)
                }
            }
        }
    }

    func reloadCurrentPage() {
        guard browserWindow?.isVisible == true else { return }
        let session = session(for: activeProvider)
        if let denial = session.startVisibleNavigation() {
            report(activeProvider, denial)
        }
    }

    func resumeBrowsingAfterUserAction() {
        access.clearSuspension(activeProvider.pageAccessAction)
        lastExtractionHint = "已解除本地暂停；手动刷新无普通冷却，服务端等待仍保留"
    }

    func windowDidMiniaturize(_ notification: Notification) {
        mimoSession.cancelAndUnload()
        geminiSession.cancelAndUnload()
        syncActiveSessionState()
    }

    func windowWillClose(_ notification: Notification) {
        mimoSession.cancelAndUnload()
        geminiSession.cancelAndUnload()
        syncActiveSessionState()
    }

    /// The status bar may reread a visible, already-loaded quota page, never navigate or reload it.
    func refreshVisibleQuotaIfAvailable() async {
        guard browserWindow?.isVisible == true else { return }
        let currentSession = session(for: activeProvider)
        guard !currentSession.isLoading, !currentSession.isExtracting,
              Self.isQuotaURL(currentSession.currentURL, provider: activeProvider),
              access.suspension(activeProvider.pageAccessAction) == nil else { return }
        await extractFromCurrentDOM(provider: activeProvider, silent: true)
    }

    func extractFromCurrentDOM(provider: ProviderID, silent: Bool = false) async {
        guard !isExtracting else { return }
        let currentSession = session(for: provider)
        guard provider == activeProvider, browserWindow?.isVisible == true,
              !currentSession.isLoading, Self.isQuotaURL(currentSession.currentURL, provider: provider) else {
            if !silent { report(provider, "请在可见小窗中打开对应官方用量页，等待加载后再读取") }
            return
        }
        isExtracting = true
        defer { isExtracting = false }
        guard let text = await currentSession.readBodyText() else {
            if !silent { report(provider, "本地页面读取失败；可点击重试") }
            return
        }
        if WebPageRefresh.isChallengeText(text) {
            access.failed(provider.pageAccessAction, suspendReason: "检测到安全验证")
            currentSession.unload()
            report(provider, "检测到验证或访问限制；页面已卸载，请在常用浏览器处理")
            return
        }
        switch provider {
        case .mimo:
            guard let money = WebQuotaParser.parseMiMoBalance(text) else {
                if !silent { report(provider, "未识别到明确现金余额；保留上次数据，不读取充值按钮金额") }
                return
            }
            onMiMoExtracted?(money)
        case .gemini:
            let quota = WebQuotaParser.parseGemini(text)
            guard quota.hasValues else {
                if !silent { report(provider, "未识别到明确的 5 小时/每周配额及已用/剩余含义，请手动录入") }
                return
            }
            onGeminiExtracted?(quota)
        default: return
        }
        access.succeeded(provider.pageAccessAction)
        lastExtractionHint = "✅ 已读取当前页面；未刷新页面、未额外查询接口"
    }

    func refreshQuotaPages(providers: [ProviderID], isManual: Bool) async -> [ProviderID: String] {
        let targets = providers.filter { $0 == .mimo || $0 == .gemini }
        guard !targets.isEmpty else { return [:] }
        async let mimoMsg: String? = targets.contains(.mimo) ? refreshProviderQuota(.mimo, isManual: isManual) : nil
        async let geminiMsg: String? = targets.contains(.gemini) ? refreshProviderQuota(.gemini, isManual: isManual) : nil
        let (mimo, gemini) = await (mimoMsg, geminiMsg)
        var results: [ProviderID: String] = [:]
        if let mimo { results[.mimo] = mimo }
        if let gemini { results[.gemini] = gemini }
        return results
    }

    private func refreshProviderQuota(_ provider: ProviderID, isManual: Bool) async -> String {
        let targetSession = session(for: provider)
        let outcome = await WebPageRefresh.refresh(
            provider: provider,
            driver: targetSession,
            accessCheck: { [weak self] in
                self?.access.begin(provider.pageAccessAction, isManual: isManual)
            }
        )
        switch outcome {
        case .mimo(let money):
            access.succeeded(provider.pageAccessAction)
            onMiMoExtracted?(money)
            lastExtractionHint = "✅ 小米现金余额已刷新（¥\(String(format: "%.2f", money.amount))）"
            return "\(provider.displayName) 已刷新"
        case .gemini(let quota):
            access.succeeded(provider.pageAccessAction)
            onGeminiExtracted?(quota)
            lastExtractionHint = "✅ Gemini 官方用量已刷新"
            return "\(provider.displayName) 已刷新"
        case .failure(let reason):
            report(provider, reason)
            return "\(provider.displayName)：\(reason)"
        }
    }

    static func isQuotaURL(_ url: URL?, provider: ProviderID) -> Bool {
        WebPageRefresh.isQuotaURL(url, provider: provider)
    }

    private func report(_ provider: ProviderID, _ message: String) {
        lastExtractionHint = message
        onExtractionFailed?(provider, message)
    }
}
