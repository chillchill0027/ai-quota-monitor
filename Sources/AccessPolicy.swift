import Foundation

/// Local request budgets survive app restarts. They never schedule a retry.
enum AccessAction: String, Codable, CaseIterable {
    case deepseekAPI, codexAPI, antigravityAPI, deepseekPage, mimoPage, geminiPage, codexPage, antigravityPage
    case deepseekBrowser, mimoBrowser, geminiBrowser, codexBrowser, antigravityBrowser
    var minimumInterval: TimeInterval {
        switch self {
        case .deepseekAPI, .codexAPI, .antigravityAPI, .mimoPage, .geminiPage: return 300
        default: return 60
        }
    }
}

struct AccessPolicy: Codable {
    struct Entry: Codable {
        var nextAllowedAt: Date
        var failures: Int = 0
        var suspendedReason: String?
        /// Only an explicit server Retry-After sets this deadline. Manual clicks cannot shorten it.
        var serverRetryUntil: Date?
    }
    var entries: [String: Entry] = [:]

    /// nil means reserved; a message means no operation must be started.
    /// Manual native controls bypass the app's ordinary automatic-refresh cooldown only.
    mutating func begin(_ action: AccessAction, isManual: Bool = false, now: Date = Date()) -> String? {
        if let entry = entries[action.rawValue] {
            if let reason = entry.suspendedReason {
                return "已暂停访问：\(reason)"
            }
            if let denial = serverWait(action, now: now) { return denial }
            if !isManual && entry.nextAllowedAt > now {
                let rounded = ceil(entry.nextAllowedAt.timeIntervalSince(now))
                guard rounded.isFinite, rounded < Double(Int.max) else {
                    return "自动同步冷却中；手动刷新可跳过普通冷却"
                }
                let seconds = max(1, Int(rounded))
                if seconds >= 60 {
                    let minutes = Int(ceil(Double(seconds) / 60.0))
                    return "自动同步冷却中（约 \(minutes) 分钟）；可随时点「查询/刷新」手动更新"
                } else {
                    return "展开同步冷却中（剩余 \(seconds) 秒）；可随时点「查询/刷新」手动更新"
                }
            }
        }
        var entry = entries[action.rawValue] ?? Entry(nextAllowedAt: now)
        entry.nextAllowedAt = max(entry.nextAllowedAt, now.addingTimeInterval(action.minimumInterval))
        entries[action.rawValue] = entry
        return nil
    }

    /// Shared by embedded and external opening of the same provider quota page.
    func serverWait(_ action: AccessAction, now: Date = Date()) -> String? {
        guard let until = entries[action.rawValue]?.serverRetryUntil, until > now else { return nil }
        let rounded = ceil(until.timeIntervalSince(now) / 60)
        guard rounded.isFinite, rounded < Double(Int.max) else {
            return "服务端要求较长等待，请稍后再访问；手动刷新不能缩短等待"
        }
        return "服务端要求等待约 \(max(1, Int(rounded))) 分钟；手动刷新也需遵守"
    }

    mutating func succeeded(_ action: AccessAction) {
        guard var entry = entries[action.rawValue] else { return }
        entry.failures = 0
        entries[action.rawValue] = entry
    }

    mutating func failed(_ action: AccessAction, now: Date = Date(), retryAfter: TimeInterval? = nil, suspendReason: String? = nil) {
        var entry = entries[action.rawValue] ?? Entry(nextAllowedAt: now)
        entry.failures = min(8, entry.failures + 1)
        let backoff = min(86_400, 900 * pow(2, Double(entry.failures - 1)))
        let serverWait = (retryAfter?.isFinite == true) ? max(0, retryAfter ?? 0) : 0
        if serverWait > 0 {
            entry.serverRetryUntil = max(entry.serverRetryUntil ?? now, now.addingTimeInterval(serverWait))
        }
        entry.nextAllowedAt = max(entry.nextAllowedAt, now.addingTimeInterval(max(backoff, serverWait)))
        entry.suspendedReason = suspendReason ?? entry.suspendedReason
        entries[action.rawValue] = entry
    }

    /// Explicit confirmation may resolve authentication; it never erases a server Retry-After.
    mutating func clearSuspension(_ action: AccessAction) {
        entries[action.rawValue]?.suspendedReason = nil
    }
}

@MainActor
final class AccessPolicyStore {
    static let shared = AccessPolicyStore()
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let key = "com.chill.AIQuotaMonitor.accessPolicy.v1"
    private var policy: AccessPolicy
    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = now
        policy = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AccessPolicy.self, from: $0) } ?? AccessPolicy()
    }
    func suspension(_ action: AccessAction) -> String? {
        reload()
        return policy.entries[action.rawValue]?.suspendedReason
    }
    func serverWait(_ action: AccessAction) -> String? {
        reload()
        return policy.serverWait(action, now: clock())
    }
    func begin(_ action: AccessAction, isManual: Bool = false) -> String? {
        reload()
        let denial = policy.begin(action, isManual: isManual, now: clock())
        if denial == nil { save() }
        return denial
    }
    func succeeded(_ action: AccessAction) { reload(); policy.succeeded(action); save() }
    func failed(_ action: AccessAction, retryAfter: TimeInterval? = nil, suspendReason: String? = nil) {
        reload()
        policy.failed(action, now: clock(), retryAfter: retryAfter, suspendReason: suspendReason); save()
    }
    func clearSuspension(_ action: AccessAction) { reload(); policy.clearSuspension(action); save() }
    private func reload() {
        policy = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AccessPolicy.self, from: $0) } ?? AccessPolicy()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(policy) { defaults.set(data, forKey: key) }
    }
}

extension ProviderID {
    var browserAccessAction: AccessAction {
        switch self {
        case .deepseek: return .deepseekBrowser
        case .mimo: return .mimoBrowser
        case .gemini: return .geminiBrowser
        case .chatgpt: return .codexBrowser
        case .antigravity: return .antigravityBrowser
        }
    }
    var pageAccessAction: AccessAction {
        switch self {
        case .deepseek: return .deepseekPage
        case .mimo: return .mimoPage
        case .gemini: return .geminiPage
        case .chatgpt: return .codexPage
        case .antigravity: return .antigravityAPI
        }
    }
}

/// A bounded redirect chain may follow one explicit navigation, never an endless script reload.
struct NavigationBudget {
    private var remaining = 0
    private var expiresAt = Date.distantPast
    mutating func grant(now: Date = Date()) { remaining = 8; expiresAt = now.addingTimeInterval(30) }
    var canContinue: Bool { remaining > 0 && Date() <= expiresAt }
    mutating func clear() { remaining = 0; expiresAt = .distantPast }
    mutating func consume(now: Date = Date()) -> Bool {
        guard remaining > 0, now <= expiresAt else { return false }
        remaining -= 1
        return true
    }
}
