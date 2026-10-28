import Foundation

enum ProviderID: String, CaseIterable, Identifiable, Codable {
    case deepseek = "deepseek"
    case mimo = "mimo"
    case gemini = "gemini"
    case chatgpt = "chatgpt"
    case antigravity = "antigravity"

    var id: String { rawValue }

    static let dashboardOrder: [ProviderID] = [.deepseek, .mimo, .chatgpt, .gemini, .antigravity]

    var shortName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .mimo: return "小米 MiMo"
        case .chatgpt: return "OpenAI · Codex"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        }
    }

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek API"
        case .mimo: return "小米 MiMo (按量)"
        case .gemini: return "Google AI Pro (Gemini)"
        case .chatgpt: return "Codex（ChatGPT 订阅）"
        case .antigravity: return "谷歌反重力 (Antigravity)"
        }
    }

    var subtitle: String {
        switch self {
        case .deepseek: return "官方公开余额接口"
        case .mimo: return "明确点击读取当前余额页"
        case .gemini: return "Google AI Pro 会员配额"
        case .chatgpt: return "Codex 官方 5 小时 / 7 天额度"
        case .antigravity: return "Google 官方 Language Server 限额"
        }
    }

    var consoleURL: URL {
        switch self {
        case .deepseek:
            return URL(string: "https://platform.deepseek.com/usage")!
        case .mimo:
            return URL(string: "https://platform.xiaomimimo.com/#/console/balance")!
        case .gemini:
            return URL(string: "https://gemini.google.com/usage")!
        case .chatgpt:
            return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .antigravity:
            return URL(string: "http://127.0.0.1:62433")!
        }
    }

    var secondaryURL: URL? {
        switch self {
        case .chatgpt:
            return URL(string: "https://chatgpt.com/#settings/Subscription")
        default:
            return nil
        }
    }
}

enum DataOrigin: String, Codable {
    case officialAPI = "官方接口"
    case webpage = "网页读取"
    case manual = "手动录入"
}

enum ConnectionStatus: String, Codable {
    case ready = "已同步"
    case unavailable = "未提供"
    case cached = "本地缓存"
    case loading = "正在按需同步..."
    case needsSetup = "待配置/登录"
    case manualCalibrated = "手动校准"
    case error = "读取受限"
}

struct DeepSeekBalanceSnapshot: Codable {
    var isAvailable: Bool
    var currency: String
    var totalBalance: Double
    var grantedBalance: Double
    var toppedUpBalance: Double
    var updatedAt: Date
    var status: ConnectionStatus
    var source: DataOrigin?
    var errorMessage: String?

    var currencySymbol: String {
        currency.uppercased() == "USD" ? "$" : "¥"
    }

    static var placeholder: DeepSeekBalanceSnapshot {
        DeepSeekBalanceSnapshot(
            isAvailable: true,
            currency: "CNY",
            totalBalance: 0.0,
            grantedBalance: 0.0,
            toppedUpBalance: 0.0,
            updatedAt: .distantPast,
            status: .needsSetup,
            errorMessage: nil
        )
    }
}

struct MiMoBalanceSnapshot: Codable {
    var cashBalance: Double
    var previousBalance: Double?
    var currencySymbol: String
    var tokenPlanUsedPercent: Double?
    var tokenPlanSummary: String?
    var updatedAt: Date
    var status: ConnectionStatus
    var source: DataOrigin?
    var note: String?

    var currencyCode: String?

    var deltaFromPrevious: Double? {
        guard let prev = previousBalance, prev != cashBalance else { return nil }
        return cashBalance - prev
    }

    static var placeholder: MiMoBalanceSnapshot {
        MiMoBalanceSnapshot(
            cashBalance: 0.0,
            previousBalance: nil,
            currencySymbol: "¥",
            tokenPlanUsedPercent: nil,
            tokenPlanSummary: nil,
            updatedAt: .distantPast,
            status: .needsSetup,
            note: "打开官方余额页；可手动录入或点击小窗读取明确现金余额"
        )
    }
}

struct QuotaWindowSnapshot: Codable {
    var fiveHourRemainingPercent: Double?
    var fiveHourResetText: String?
    var weeklyRemainingPercent: Double?
    var weeklyResetText: String?
    var fiveHourResetsAt: Date?
    var weeklyResetsAt: Date?
    var planLabel: String
    var updatedAt: Date
    var status: ConnectionStatus
    var source: DataOrigin?
    var note: String?

    static func restoredCodex(_ snapshot: Self, version: Int?) -> Self {
        guard version == 2 else { return .defaultChatGPT() }
        var restored = snapshot
        if restored.status == .ready || restored.status == .loading { restored.status = .cached }
        return restored
    }

    func codexRemaining(weekly: Bool, now: Date = Date()) -> Double? {
        let reset = weekly ? weeklyResetsAt : fiveHourResetsAt
        if let reset, reset <= now { return nil }
        return weekly ? weeklyRemainingPercent : fiveHourRemainingPercent
    }

    static func defaultGemini() -> QuotaWindowSnapshot {
        QuotaWindowSnapshot(
            fiveHourRemainingPercent: nil,
            fiveHourResetText: nil,
            weeklyRemainingPercent: nil,
            weeklyResetText: nil,
            planLabel: "Google AI Pro",
            updatedAt: .distantPast,
            status: .needsSetup,
            note: "打开官方用量页；小窗读取或点开状态栏时同步已显示的配额"
        )
    }

    static func defaultChatGPT() -> QuotaWindowSnapshot {
        QuotaWindowSnapshot(
            fiveHourRemainingPercent: nil,
            fiveHourResetText: nil,
            weeklyRemainingPercent: nil,
            weeklyResetText: nil,
            planLabel: "Codex（ChatGPT 订阅）",
            updatedAt: .distantPast,
            status: .needsSetup,
            note: "点开状态栏或点击查询，通过已登录的 Codex CLI 获取官方额度"
        )
    }
}

struct AntigravityQuotaSnapshot: Codable {
    var fiveHourRemainingPercent: Double?
    var fiveHourResetText: String?
    var fiveHourResetsAt: Date?

    var weeklyRemainingPercent: Double?
    var weeklyResetText: String?
    var weeklyResetsAt: Date?

    var argonWeeklyRemainingPercent: Double?
    var argonWeeklyResetText: String?
    var argonWeeklyResetsAt: Date?

    var thirdPartyWeeklyRemainingPercent: Double?
    var thirdPartyWeeklyResetText: String?

    var updatedAt: Date
    var status: ConnectionStatus
    var source: DataOrigin?
    var note: String?

    static var placeholder: AntigravityQuotaSnapshot {
        AntigravityQuotaSnapshot(
            fiveHourRemainingPercent: nil,
            fiveHourResetText: nil,
            fiveHourResetsAt: nil,
            weeklyRemainingPercent: nil,
            weeklyResetText: nil,
            weeklyResetsAt: nil,
            argonWeeklyRemainingPercent: nil,
            argonWeeklyResetText: nil,
            argonWeeklyResetsAt: nil,
            thirdPartyWeeklyRemainingPercent: nil,
            thirdPartyWeeklyResetText: nil,
            updatedAt: .distantPast,
            status: .needsSetup,
            source: .officialAPI,
            note: "点击「查询」读取本机 Antigravity 官方 Language Server 限额"
        )
    }
}

enum MenuBarDisplayStyle: String, CaseIterable, Codable, Identifiable {
    case iconOnly = "iconOnly"
    case compactBalances = "compactBalances"
    case allFour = "allFour"
    case allFive = "allFive"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly: return "仅图标"
        case .compactBalances: return "API 余额"
        case .allFour: return "四家摘要"
        case .allFive: return "五家摘要"
        }
    }
}

// MARK: - DeepSeek Official API Response Models
struct DeepSeekAPIResponse: Codable {
    let is_available: Bool
    let balance_infos: [DeepSeekBalanceInfo]
}

struct DeepSeekBalanceInfo: Codable {
    let currency: String
    let total_balance: String
    let granted_balance: String
    let topped_up_balance: String
}
