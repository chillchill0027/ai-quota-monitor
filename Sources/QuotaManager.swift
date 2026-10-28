import Foundation
import SwiftUI

/// Manual clicks bypass ordinary automatic-refresh cooldowns, never authentication/server restrictions.
@MainActor
final class QuotaManager: ObservableObject {
    static let shared = QuotaManager()
    @Published var deepseek: DeepSeekBalanceSnapshot = .placeholder
    @Published var mimo: MiMoBalanceSnapshot = .placeholder
    @Published var gemini: QuotaWindowSnapshot = .defaultGemini()
    @Published var chatgpt: QuotaWindowSnapshot = .defaultChatGPT()
    @Published var antigravity: AntigravityQuotaSnapshot = .placeholder
    @Published var menuBarStyle: MenuBarDisplayStyle = .compactBalances { didSet { saveState() } }
    @Published private(set) var visibleProviders: Set<ProviderID> = Set(ProviderID.allCases)
    @Published var isRefreshing = false
    @Published private(set) var refreshingProviders: Set<ProviderID> = []
    @Published private(set) var refreshProblems: [ProviderID: String] = [:]
    @Published var lastInteractiveRefreshAt: Date?
    @Published var statusBannerText = "展开按需同步 · 手动刷新无普通冷却"
    @Published var showingSettings = false
    @Published var showingDeepSeekKeyPopover = false
    @Published var revealingAPIKey = false
    @Published var showingProviderDetails: ProviderID?
    @Published var mimoManualInput = ""
    @Published var mimoCurrencyInput = "CNY"
    @Published var showingMiMoCalibratePopover = false
    @Published var showingGeminiCalibratePopover = false
    @Published var geminiFiveHourInput = ""
    @Published var geminiWeeklyInput = ""
    @Published var showingAntigravityCalibratePopover = false
    @Published var antigravityFiveHourInput = ""
    @Published var antigravityWeeklyInput = ""
    @Published var antigravityArgonInput = ""
    @Published var apiKeyInput = ""
    @Published var saveConfirmation = ""
    @Published var manualInputError = ""

    private let defaults: UserDefaults
    private let access: AccessPolicyStore
    private var savedAPIKey: String
    private var credentialGeneration = 0
    private let keyWriter: (String) -> Bool
    private let deepSeekReader: (String) async -> DeepSeekService.FetchResult
    private let codexReader: () async throws -> QuotaWindowSnapshot
    private let antigravityReader: () async throws -> AntigravityQuotaSnapshot
    private let webQuotaRefresher: ([ProviderID], Bool) async -> [ProviderID: String]
    private let now: () -> Date
    private var lastAutomaticRefreshAt: Date?
    private let stateStorageKey = "com.chill.AIQuotaMonitor.persistedState.v1"
    private let deepseekKeychainAccount = "deepseek_api_key"
    private let popoverExpandCooldownSeconds: TimeInterval = 300

    struct PersistedState: Codable {
        var deepseek: DeepSeekBalanceSnapshot
        var mimo: MiMoBalanceSnapshot
        var gemini: QuotaWindowSnapshot
        var chatgpt: QuotaWindowSnapshot
        var antigravity: AntigravityQuotaSnapshot?
        var menuBarStyle: MenuBarDisplayStyle
        var lastInteractiveRefreshAt: Date?
        var codexQuotaVersion: Int?
        var webQuotaVersion: Int?
        var lastAutomaticRefreshAt: Date?
        // Raw strings keep future/unknown providers from invalidating quota caches.
        var visibleProviders: [String]? = nil
    }

    init(defaults: UserDefaults = .standard, access: AccessPolicyStore? = nil, key: String? = nil,
         bindWeb: Bool = true,
         keyWriter: @escaping (String) -> Bool = { KeychainHelper.save(key: "deepseek_api_key", value: $0) },
         visibleQuotaReader _: (() async -> Void)? = nil,
         webQuotaRefresher: (([ProviderID], Bool) async -> [ProviderID: String])? = nil,
         deepSeekReader: @escaping (String) async -> DeepSeekService.FetchResult = { await DeepSeekService.fetchResult(apiKey: $0) },
         codexReader: @escaping () async throws -> QuotaWindowSnapshot = { try await CodexQuotaService.fetch() },
         antigravityReader: @escaping () async throws -> AntigravityQuotaSnapshot = { try await AntigravityQuotaService.fetch() },
         now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.access = access ?? AccessPolicyStore.shared
        self.now = now
        savedAPIKey = key ?? KeychainHelper.read(key: "deepseek_api_key") ?? ""
        self.keyWriter = keyWriter
        self.deepSeekReader = deepSeekReader
        self.codexReader = codexReader
        self.antigravityReader = antigravityReader
        if let webQuotaRefresher {
            self.webQuotaRefresher = webQuotaRefresher
        } else if bindWeb {
            self.webQuotaRefresher = { await SafeWebExtractor.shared.refreshQuotaPages(providers: $0, isManual: $1) }
        } else {
            self.webQuotaRefresher = { _, _ in [:] }
        }
        loadState()
        apiKeyInput = savedAPIKey
        if bindWeb { bindWebExtractorCallbacks() }
    }

    var deepseekAPIKey: String { savedAPIKey }
    var hasDeepSeekKey: Bool { !savedAPIKey.isEmpty }

    func isProviderVisible(_ provider: ProviderID) -> Bool {
        visibleProviders.contains(provider)
    }

    func canToggleProvider(_ provider: ProviderID) -> Bool {
        !visibleProviders.contains(provider) || visibleProviders.count > 1
    }

    @discardableResult
    func toggleProviderVisibility(_ provider: ProviderID) -> Bool {
        guard canToggleProvider(provider) else { return false }
        if visibleProviders.contains(provider) {
            visibleProviders.remove(provider)
        } else {
            visibleProviders.insert(provider)
        }
        saveState()
        return true
    }

    func saveDeepSeekKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty || DeepSeekService.makeRequest(apiKey: key) != nil else {
            saveConfirmation = "Key 格式无效，未保存也未联网"
            return
        }
        guard keyWriter(key) else {
            saveConfirmation = "钥匙串保存失败；原有 Key 保持不变"
            return
        }
        if savedAPIKey != key {
            savedAPIKey = key
            credentialGeneration += 1
            refreshProblems.removeValue(forKey: .deepseek)
            access.clearSuspension(.deepseekAPI)
            deepseek = .placeholder
            saveState()
        }
        guard !key.isEmpty else {
            saveConfirmation = "已清除 API Key；未发送查询"
            return
        }
        guard !isRefreshing else {
            saveConfirmation = "已保存；当前查询结束后请手动点击查询新 Key 的余额"
            return
        }
        saveConfirmation = "已保存；已安排余额查询，认证与服务端限制仍有效"
        manualRefreshNow(provider: .deepseek)
    }

    func resumeDeepSeekAfterUserAction() {
        access.clearSuspension(.deepseekAPI)
        saveConfirmation = "已解除本地认证暂停；服务端等待时间继续有效，未发送查询"
    }

    func resumeCodexAfterUserAction() {
        access.clearSuspension(.codexAPI)
        saveConfirmation = "Codex 本地认证暂停已解除；服务端等待时间继续有效，未发送查询"
    }

    func resumeAntigravityAfterUserAction() {
        access.clearSuspension(.antigravityAPI)
        saveConfirmation = "Antigravity 本地认证暂停已解除；服务端等待时间继续有效，未发送查询"
    }

    private func bindWebExtractorCallbacks() {
        let extractor = SafeWebExtractor.shared
        extractor.onMiMoExtracted = { [weak self] money in
            self?.acceptMiMo(money)
        }
        extractor.onGeminiExtracted = { [weak self] quota in
            self?.acceptGemini(quota)
        }
        extractor.onExtractionFailed = { [weak self] provider, message in
            guard let self else { return }
            self.statusBannerText = message
            self.refreshProblems[provider] = message
            if provider == .mimo { self.mimo.status = .error; self.mimo.note = message }
            if provider == .gemini { self.gemini.status = .error; self.gemini.note = message }
            self.saveState()
        }
    }

    func acceptMiMo(_ money: WebQuotaParser.Money) {
        refreshProblems.removeValue(forKey: .mimo)
        let previous = mimo.updatedAt != .distantPast && mimo.currencyCode == money.currency ? mimo.cashBalance : nil
        mimo = MiMoBalanceSnapshot(cashBalance: money.amount, previousBalance: previous,
            currencySymbol: money.currencySymbol, tokenPlanUsedPercent: nil, tokenPlanSummary: nil,
            updatedAt: now(), status: .ready, source: .webpage,
            note: "已刷新官方现金余额页 · 不含 Token Plan", currencyCode: money.currency)
        saveState()
    }

    func acceptGemini(_ quota: WebQuotaParser.GeminiQuota) {
        refreshProblems.removeValue(forKey: .gemini)
        // Replace the entire observation. Missing windows must not inherit older percentages.
        gemini = .defaultGemini()
        gemini.fiveHourRemainingPercent = quota.fiveHour?.remainingPercent
        gemini.fiveHourResetText = quota.fiveHour?.resetText
        gemini.weeklyRemainingPercent = quota.weekly?.remainingPercent
        gemini.weeklyResetText = quota.weekly?.resetText
        gemini.updatedAt = now()
        gemini.status = quota.hasValues ? .ready : .unavailable
        gemini.source = .webpage
        gemini.note = "已刷新官方用量页 · 缺失窗口不推算"
        saveState()
    }

    /// Triggered ONLY when clicking the menu bar icon to expand the popover (enforces cooldown).
    @discardableResult
    func onUserInteractionOpenPopover() -> Task<Void, Never> {
        Task { await performRefresh(provider: nil, isManual: false) }
    }

    func onUserInteractionReopenDashboard() {
        // Dock/relaunch is distinct from an explicit status-bar expansion and stays local.
    }

    /// Native manual refresh has no app-imposed time cooldown; hard server/auth restrictions still apply.
    @discardableResult
    func manualRefreshNow(provider: ProviderID? = nil) -> Task<Void, Never> {
        Task { await performRefresh(provider: provider, isManual: true) }
    }

    /// Backward-compatible entry point
    func performManualRefresh(provider: ProviderID? = nil, includeVisibleWeb: Bool = false) async {
        await performRefresh(provider: provider, includeVisibleWeb: includeVisibleWeb, isManual: true)
    }

    func performRefresh(provider: ProviderID? = nil, includeVisibleWeb: Bool = false, isManual: Bool = false) async {
        guard !isRefreshing else { return }
        if !isManual, provider == nil {
            let startedAt = now()
            if let last = lastAutomaticRefreshAt, startedAt.timeIntervalSince(last) < popoverExpandCooldownSeconds {
                let remaining = max(1, Int(ceil(popoverExpandCooldownSeconds - startedAt.timeIntervalSince(last))))
                statusBannerText = "展开刷新每 5 分钟一次（剩余 \(remaining)s）· 可手动全部刷新"
                return
            }
            lastAutomaticRefreshAt = startedAt
            saveState()
        }
        isRefreshing = true
        refreshingProviders = provider.map { [$0] } ?? Set(ProviderID.allCases)
        for target in refreshingProviders { refreshProblems.removeValue(forKey: target) }
        defer { isRefreshing = false; refreshingProviders = [] }
        statusBannerText = isManual ? "正在刷新各家额度（手动无普通冷却）…" : "状态栏展开：正在刷新各家额度…"
        let webProviders: [ProviderID] = provider == nil ? [.mimo, .gemini] :
            ((provider == .mimo || provider == .gemini) ? [provider!] : [])
        async let web = refreshWebQuotas(webProviders, isManual: isManual)
        async let ds: String? = (provider == nil || provider == .deepseek) ? await refreshDeepSeek(isManual: isManual) : nil
        async let codex: String? = (provider == nil || provider == .chatgpt) ? await refreshCodex(isManual: isManual) : nil
        async let agy: String? = (provider == nil || provider == .antigravity) ? await refreshAntigravity(isManual: isManual) : nil
        let (webMessages, dsMessage, codexMessage, agyMessage) = await (web, ds, codex, agy)
        var messages: [String] = []
        if let dsMessage { messages.append(dsMessage) }
        for webProvider in webProviders {
            messages.append(webMessages[webProvider] ?? "\(webProvider.displayName) 未返回刷新结果")
        }
        if let codexMessage { messages.append(codexMessage) }
        if let agyMessage { messages.append(agyMessage) }
        statusBannerText = messages.joined(separator: " · ")
        lastInteractiveRefreshAt = now()
        saveState()
    }

    private func refreshWebQuotas(_ providers: [ProviderID], isManual: Bool) async -> [ProviderID: String] {
        guard !providers.isEmpty else { return [:] }
        return await webQuotaRefresher(providers, isManual)
    }

    private func refreshDeepSeek(isManual: Bool) async -> String {
        guard hasDeepSeekKey else {
            refreshProblems[.deepseek] = "未配置 API Key"
            return "DeepSeek 未配置 Key"
        }
        if let denial = access.begin(.deepseekAPI, isManual: isManual) {
            refreshProblems[.deepseek] = denial
            return "DeepSeek：\(denial)"
        }
        let queryKey = savedAPIKey
        let generation = credentialGeneration
        deepseek.status = .loading
        let result = await deepSeekReader(queryKey)
        guard generation == credentialGeneration else {
            if result.snapshot.status != .ready && !result.requiresUserAction {
                access.failed(.deepseekAPI, retryAfter: result.retryAfter)
            }
            return "已忽略旧 Key 的查询结果"
        }
        if result.snapshot.status == .ready {
            deepseek = result.snapshot
            deepseek.source = .officialAPI
            access.succeeded(.deepseekAPI)
        } else {
            let message = result.snapshot.errorMessage ?? "查询失败"
            deepseek.status = .error
            deepseek.errorMessage = message
            refreshProblems[.deepseek] = message
            access.failed(.deepseekAPI, retryAfter: result.retryAfter,
                          suspendReason: result.requiresUserAction ? "请检查账户并保存更新后的 API Key" : nil)
        }
        lastInteractiveRefreshAt = now()
        return deepseek.status == .ready ? "DeepSeek 已刷新" : "DeepSeek 查询异常"
    }

    private func refreshCodex(isManual: Bool) async -> String {
        if let denial = access.begin(.codexAPI, isManual: isManual) {
            refreshProblems[.chatgpt] = denial
            return "Codex：\(denial)"
        }
        chatgpt.status = .loading
        do {
            chatgpt = try await codexReader()
            chatgpt.source = .officialAPI
            access.succeeded(.codexAPI)
        } catch {
            let queryError = error as? CodexQuotaService.QueryError
            let requiresAccountAction = queryError?.requiresUserAction ?? false
            chatgpt.status = .error
            let detail = queryError?.errorDescription ?? "官方额度查询失败"
            chatgpt.note = requiresAccountAction
                ? "\(detail)；保留上次数据，请在官方客户端处理后从设置解除暂停"
                : "\(detail)；保留上次数据，可手动重试，自动刷新继续冷却"
            refreshProblems[.chatgpt] = detail
            access.failed(.codexAPI, suspendReason: requiresAccountAction ? "请在官方 Codex 客户端检查账户，再从设置确认恢复" : nil)
        }
        lastInteractiveRefreshAt = now()
        return chatgpt.status == .error ? "Codex 查询失败" : "Codex 已刷新"
    }

    private func refreshAntigravity(isManual: Bool) async -> String {
        if let denial = access.begin(.antigravityAPI, isManual: isManual) {
            refreshProblems[.antigravity] = denial
            return "反重力：\(denial)"
        }
        antigravity.status = .loading
        do {
            antigravity = try await antigravityReader()
            antigravity.source = .officialAPI
            access.succeeded(.antigravityAPI)
        } catch {
            let detail = error.localizedDescription
            antigravity.status = .error
            antigravity.note = "\(detail)；保留上次数据，可手动重试"
            refreshProblems[.antigravity] = detail
            access.failed(.antigravityAPI)
        }
        lastInteractiveRefreshAt = now()
        return antigravity.status == .error ? "反重力查询异常" : "反重力已刷新"
    }

    @discardableResult
    func updateMiMoManualBalance(_ amount: Double) -> Bool {
        guard amount.isFinite, ["CNY", "USD"].contains(mimoCurrencyInput) else {
            manualInputError = "请输入有限金额并选择币种"
            return false
        }
        acceptMiMo(WebQuotaParser.Money(amount: amount, currency: mimoCurrencyInput))
        mimo.status = .manualCalibrated
        mimo.source = .manual
        mimo.note = "手动录入现金余额 · 未联网核实"
        manualInputError = ""
        saveState()
        return true
    }

    @discardableResult
    func updateGeminiPercentages(fiveHour: Double?, weekly: Double?) -> Bool {
        guard [fiveHour, weekly].allSatisfy({ $0 == nil || ($0!.isFinite && (0...100).contains($0!)) }) else {
            manualInputError = "剩余比例必须在 0–100 之间，未知可留空"
            return false
        }
        gemini = .defaultGemini()
        gemini.fiveHourRemainingPercent = fiveHour
        gemini.weeklyRemainingPercent = weekly
        gemini.updatedAt = now()
        gemini.status = .manualCalibrated
        gemini.source = .manual
        gemini.note = "手动录入剩余比例 · 未联网核实"
        manualInputError = ""
        saveState()
        return true
    }

    @discardableResult
    func updateAntigravityManualPercentages(fiveHour: Double?, weekly: Double?, argon: Double?) -> Bool {
        guard [fiveHour, weekly, argon].allSatisfy({ $0 == nil || ($0!.isFinite && (0...100).contains($0!)) }) else {
            manualInputError = "剩余比例必须在 0–100 之间，未知可留空"
            return false
        }
        antigravity = .placeholder
        refreshProblems.removeValue(forKey: .antigravity)
        antigravity.fiveHourRemainingPercent = fiveHour
        antigravity.weeklyRemainingPercent = weekly
        antigravity.argonWeeklyRemainingPercent = argon
        antigravity.updatedAt = now()
        antigravity.status = .manualCalibrated
        antigravity.source = .manual
        antigravity.note = "手动录入剩余比例 · 未连接本地服务"
        manualInputError = ""
        saveState()
        return true
    }

    var statusBarCompactTitle: String {
        statusBarTitle(for: menuBarStyle)
    }

    func statusBarTitle(for style: MenuBarDisplayStyle) -> String {
        let ds = deepseek.updatedAt != .distantPast ? "\(deepseek.currencySymbol)\(String(format: "%.1f", deepseek.totalBalance))" : "--"
        let mi = mimo.updatedAt != .distantPast ? "\(mimo.currencySymbol)\(String(format: "%.1f", mimo.cashBalance))" : "--"
        switch style {
        case .iconOnly: return ""
        case .compactBalances: return " DS:\(ds) Mi:\(mi)"
        case .allFour:
            let gem = gemini.fiveHourRemainingPercent.map { String(format: "%.0f%%", $0) } ?? "--"
            let codex = chatgpt.codexRemaining(weekly: false).map { String(format: "%.0f%%", $0) } ?? "--"
            return " DS:\(ds) Mi:\(mi) G:\(gem) C:\(codex)"
        case .allFive:
            let gem = gemini.fiveHourRemainingPercent.map { String(format: "%.0f%%", $0) } ?? "--"
            let codex = chatgpt.codexRemaining(weekly: false).map { String(format: "%.0f%%", $0) } ?? "--"
            let agy = antigravity.fiveHourRemainingPercent.map { String(format: "%.0f%%", $0) } ?? "--"
            return " DS:\(ds) Mi:\(mi) G:\(gem) C:\(codex) A:\(agy)"
        }
    }

    func saveState() {
        let state = PersistedState(deepseek: deepseek, mimo: mimo, gemini: gemini, chatgpt: chatgpt,
            antigravity: antigravity, menuBarStyle: menuBarStyle, lastInteractiveRefreshAt: lastInteractiveRefreshAt,
            codexQuotaVersion: 2, webQuotaVersion: 1, lastAutomaticRefreshAt: lastAutomaticRefreshAt,
            visibleProviders: ProviderID.dashboardOrder.filter { visibleProviders.contains($0) }.map(\.rawValue))
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateStorageKey) }
    }

    private func loadState() {
        guard let data = defaults.data(forKey: stateStorageKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        deepseek = state.deepseek
        if deepseek.status == .ready || deepseek.status == .loading { deepseek.status = .cached }
        deepseek.source = deepseek.source ?? .officialAPI
        if state.webQuotaVersion == 1 {
            mimo = state.mimo
            gemini = state.gemini
            if mimo.status == .ready || mimo.status == .loading { mimo.status = .cached }
            if gemini.status == .ready || gemini.status == .loading { gemini.status = .cached }
        }
        if let agy = state.antigravity {
            antigravity = agy
            if antigravity.status == .ready || antigravity.status == .loading { antigravity.status = .cached }
        }
        chatgpt = .restoredCodex(state.chatgpt, version: state.codexQuotaVersion)
        let restoredProviders = Set((state.visibleProviders ?? []).compactMap(ProviderID.init(rawValue:)))
        visibleProviders = restoredProviders.isEmpty ? Set(ProviderID.allCases) : restoredProviders
        lastInteractiveRefreshAt = state.lastInteractiveRefreshAt
        lastAutomaticRefreshAt = state.lastAutomaticRefreshAt
        // Its didSet persists the state, so restore it only after every cached field.
        menuBarStyle = state.menuBarStyle
    }

    static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
