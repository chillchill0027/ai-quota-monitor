import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var manager: QuotaManager
    var presentation: DashboardPresentation = .window
    var onContentHeightChange: ((CGFloat) -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            headerBar
            if manager.showingSettings {
                SettingsInlineView(manager: manager)
            } else {
                VStack(spacing: 8) {
                    ForEach(ProviderID.dashboardOrder.filter { manager.isProviderVisible($0) }) { provider in
                        providerCard(provider)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        .background(DashboardSurfaceBackground(presentation: presentation))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: DashboardContentHeightKey.self, value: geometry.size.height)
            }
        }
        .onPreferenceChange(DashboardContentHeightKey.self) { height in
            if height > 0 { onContentHeightChange?(height) }
        }
        .alert(item: $manager.showingProviderDetails) { provider in
            Alert(title: Text(provider.shortName), message: Text(refreshDetails(provider)),
                  dismissButton: .default(Text("好")))
        }
    }

    @ViewBuilder
    private func providerCard(_ provider: ProviderID) -> some View {
        switch provider {
        case .deepseek:
            balanceCard(.deepseek, amount: manager.deepseek.totalBalance,
                        symbol: manager.deepseek.currencySymbol, updatedAt: manager.deepseek.updatedAt)
                .popover(isPresented: $manager.showingDeepSeekKeyPopover, arrowEdge: .trailing) {
                    DeepSeekKeyConfigurationView(manager: manager)
                }
        case .mimo:
            balanceCard(.mimo, amount: manager.mimo.cashBalance,
                        symbol: manager.mimo.currencySymbol, updatedAt: manager.mimo.updatedAt)
                .popover(isPresented: $manager.showingMiMoCalibratePopover, arrowEdge: .trailing) {
                    MiMoCalibrationView(manager: manager)
                }
        case .chatgpt: openAICard
        case .gemini:
            geminiCard.popover(isPresented: $manager.showingGeminiCalibratePopover, arrowEdge: .trailing) {
                WindowCalibrationView(manager: manager, provider: .gemini)
            }
        case .antigravity:
            antigravityCard.popover(isPresented: $manager.showingAntigravityCalibratePopover, arrowEdge: .trailing) {
                WindowCalibrationView(manager: manager, provider: .antigravity)
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Text(manager.showingSettings ? "设置" : "AI 额度")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            GlassControlGroup {
                HStack(spacing: 8) {
                    if !manager.showingSettings { refreshButton }
                    settingsButton
                }
            }
        }
        .frame(height: 28)
    }

    private var refreshButton: some View {
        Button { manager.manualRefreshNow() } label: {
            Group {
                if manager.isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 15, height: 15)
                } else {
                    Label("全部刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(width: 70, height: 16)
        }
        .modifier(QuotaGlassControl())
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(manager.isRefreshing)
        .accessibilityLabel("全部刷新")
        .help("刷新全部五家，包括重新加载并读取两个用量小窗\n\(manager.statusBannerText)")
    }

    private var settingsButton: some View {
        Button {
            manager.showingSettings.toggle()
        } label: {
            Image(systemName: manager.showingSettings ? "xmark" : "gearshape")
                .font(.system(size: 12))
                .frame(width: 16, height: 16)
        }
        .modifier(QuotaGlassControl())
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .help(manager.showingSettings ? "返回看板" : "设置")
        .accessibilityLabel(manager.showingSettings ? "返回看板" : "设置")
    }

    private func balanceCard(_ provider: ProviderID, amount: Double, symbol: String, updatedAt: Date) -> some View {
        ProviderCardContainer {
            VStack(alignment: .leading, spacing: 8) {
                providerHeading(provider)
                Text(updatedAt == .distantPast ? "—" : "\(symbol) \(String(format: "%.2f", amount))")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(updatedAt != .distantPast && amount < 5 ? .orange : .primary)
                    .accessibilityLabel(updatedAt == .distantPast ? "余额未读取" : "余额 \(symbol) \(String(format: "%.2f", amount))")
            }
        }
    }

    private var openAICard: some View {
        ProviderCardContainer {
            VStack(spacing: 10) {
                providerHeading(.chatgpt)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(spacing: 8) {
                        codexRow(weekly: false, now: context.date)
                        codexRow(weekly: true, now: context.date)
                    }
                }
            }
        }
    }

    private func codexRow(weekly: Bool, now: Date) -> some View {
        let reset = weekly ? manager.chatgpt.weeklyResetsAt : manager.chatgpt.fiveHourResetsAt
        let expired = reset.map { $0 <= now } ?? false
        let missing = expired ? "已过期" : (manager.chatgpt.status == .ready || manager.chatgpt.status == .unavailable ? "未提供" : "未读取")
        let hint = reset.map { expired ? "已到重置时间，请刷新" : "\(QuotaManager.shortTimeFormatter.string(from: $0)) 重置" } ?? "以官方用量页为准"
        return QuotaBarRow(label: weekly ? "7 天" : "5 小时",
            remainingPercent: manager.chatgpt.codexRemaining(weekly: weekly, now: now),
            resetHint: hint, tint: .primary, missingLabel: missing)
    }

    private var geminiCard: some View {
        ProviderCardContainer {
            VStack(spacing: 10) {
                providerHeading(.gemini)
                VStack(spacing: 8) {
                    QuotaBarRow(label: "5 小时", remainingPercent: manager.gemini.fiveHourRemainingPercent,
                        resetHint: manager.gemini.fiveHourResetText ?? "未提供重置时间", tint: .blue)
                    QuotaBarRow(label: "7 天", remainingPercent: manager.gemini.weeklyRemainingPercent,
                        resetHint: manager.gemini.weeklyResetText ?? "未提供重置时间", tint: .blue)
                }
            }
        }
    }

    private var antigravityCard: some View {
        ProviderCardContainer {
            VStack(spacing: 10) {
                providerHeading(.antigravity)
                VStack(spacing: 8) {
                    QuotaBarRow(label: "Gemini · 5 小时", remainingPercent: manager.antigravity.fiveHourRemainingPercent,
                        resetHint: manager.antigravity.fiveHourResetText ?? "未提供重置时间", tint: .blue)
                    QuotaBarRow(label: "Gemini · 7 天", remainingPercent: manager.antigravity.weeklyRemainingPercent,
                        resetHint: manager.antigravity.weeklyResetText ?? "未提供重置时间", tint: .blue)
                    QuotaBarRow(label: "Argon · 7 天", remainingPercent: manager.antigravity.argonWeeklyRemainingPercent,
                        resetHint: manager.antigravity.argonWeeklyResetText ?? "未提供重置时间", tint: .blue)
                }
            }
        }
    }

    private func providerHeading(_ provider: ProviderID) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button("刷新此项") { manager.manualRefreshNow(provider: provider) }
                    .disabled(manager.isRefreshing)
                if provider == .mimo || provider == .gemini {
                    Button("打开用量小窗") { SafeWebExtractor.shared.openSafeWindow(for: provider) }
                }
                Button(provider == .antigravity ? "打开 Hub" : "打开官方用量页") {
                    if provider == .antigravity {
                        NSWorkspace.shared.open(AntigravityQuotaService.currentHubURL())
                    } else {
                        SafeWebExtractor.shared.openOfficialPage(for: provider)
                    }
                }
                Divider()
                if provider == .deepseek {
                    Button("配置 API Key") {
                        manager.apiKeyInput = manager.deepseekAPIKey
                        manager.revealingAPIKey = false
                        manager.saveConfirmation = ""
                        manager.showingDeepSeekKeyPopover = true
                    }
                } else if provider != .chatgpt {
                    Button("手动校准") { showCalibration(provider) }
                }
                if provider == .deepseek || provider == .chatgpt || provider == .antigravity {
                    Button("已处理账户，解除暂停") {
                        switch provider {
                        case .deepseek: manager.resumeDeepSeekAfterUserAction()
                        case .chatgpt: manager.resumeCodexAfterUserAction()
                        case .antigravity: manager.resumeAntigravityAfterUserAction()
                        default: break
                        }
                    }
                }
                Button("刷新详情") { manager.showingProviderDetails = provider }
            } label: {
                HStack(spacing: 8) {
                    ProviderIcon(provider: provider)
                    Text(provider.shortName).font(.system(size: 12, weight: .semibold))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("\(provider.shortName)：刷新、用量页与设置")
            Spacer(minLength: 8)
            StatusBadge(status: status(provider), isRefreshing: manager.refreshingProviders.contains(provider))
                .help(refreshDetails(provider))
        }
    }

    private func status(_ provider: ProviderID) -> ConnectionStatus {
        if manager.refreshProblems[provider] != nil {
            return provider == .deepseek && !manager.hasDeepSeekKey ? .needsSetup : .error
        }
        switch provider {
        case .deepseek: return manager.deepseek.status
        case .mimo: return manager.mimo.status
        case .chatgpt: return manager.chatgpt.status
        case .gemini: return manager.gemini.status
        case .antigravity: return manager.antigravity.status
        }
    }

    private func refreshDetails(_ provider: ProviderID) -> String {
        let date: Date
        let source: DataOrigin?
        let note: String?
        switch provider {
        case .deepseek:
            date = manager.deepseek.updatedAt; source = manager.deepseek.source
            note = manager.deepseek.errorMessage ?? (manager.deepseek.isAvailable ? "可供 API 调用" : "不可供 API 调用")
        case .mimo:
            date = manager.mimo.updatedAt; source = manager.mimo.source; note = manager.mimo.note
        case .chatgpt:
            date = manager.chatgpt.updatedAt; source = manager.chatgpt.source; note = manager.chatgpt.note
        case .gemini:
            date = manager.gemini.updatedAt; source = manager.gemini.source; note = manager.gemini.note
        case .antigravity:
            date = manager.antigravity.updatedAt; source = manager.antigravity.source; note = manager.antigravity.note
        }
        let time = date == .distantPast ? "尚未读取" : "上次读取：\(QuotaManager.shortTimeFormatter.string(from: date))"
        return [status(provider).rawValue, manager.refreshProblems[provider], time, source?.rawValue, note]
            .compactMap { $0 }.joined(separator: "\n")
    }

    private func showCalibration(_ provider: ProviderID) {
        manager.manualInputError = ""
        switch provider {
        case .mimo:
            manager.mimoCurrencyInput = manager.mimo.currencyCode ?? "CNY"
            manager.mimoManualInput = manager.mimo.updatedAt == .distantPast ? "" : String(format: "%.2f", manager.mimo.cashBalance)
            manager.showingMiMoCalibratePopover = true
        case .gemini:
            manager.geminiFiveHourInput = number(manager.gemini.fiveHourRemainingPercent)
            manager.geminiWeeklyInput = number(manager.gemini.weeklyRemainingPercent)
            manager.showingGeminiCalibratePopover = true
        case .antigravity:
            manager.antigravityFiveHourInput = number(manager.antigravity.fiveHourRemainingPercent)
            manager.antigravityWeeklyInput = number(manager.antigravity.weeklyRemainingPercent)
            manager.antigravityArgonInput = number(manager.antigravity.argonWeeklyRemainingPercent)
            manager.showingAntigravityCalibratePopover = true
        default: break
        }
    }

    private func number(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "" }
}

private extension ProviderID {
    var iconName: String { self == .chatgpt ? "openai" : rawValue }
}

struct ProviderIcon: View {
    let provider: ProviderID
    var size: CGFloat = 21
    private var icon: NSImage? {
        guard let url = Bundle.main.url(forResource: provider.iconName, withExtension: "png", subdirectory: "ProviderIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        // Native macOS menu labels use NSImage's logical size instead of SwiftUI's frame.
        image.size = NSSize(width: size, height: size)
        image.isTemplate = provider == .chatgpt
        return image
    }
    var body: some View {
        Group {
            if let image = icon {
                Image(nsImage: image)
                    .renderingMode(provider == .chatgpt ? .template : .original)
                    .resizable().scaledToFit()
            } else {
                Image(systemName: "circle.grid.2x2.fill").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct DashboardContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct DeepSeekKeyConfigurationView: View {
    @ObservedObject var manager: QuotaManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DeepSeek API Key").font(.headline)
            HStack(spacing: 6) {
                Group {
                    if manager.revealingAPIKey {
                        TextField("API Key", text: $manager.apiKeyInput)
                    } else {
                        SecureField("API Key", text: $manager.apiKeyInput)
                    }
                }
                .textFieldStyle(.roundedBorder)
                Button { manager.revealingAPIKey.toggle() } label: {
                    Image(systemName: manager.revealingAPIKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(manager.revealingAPIKey ? "隐藏 API Key" : "显示 API Key")
            }
            Button(saveTitle) { manager.saveDeepSeekKey() }
                .buttonStyle(.borderedProminent)
            if !manager.saveConfirmation.isEmpty {
                Text(manager.saveConfirmation).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 290)
        .onDisappear { manager.revealingAPIKey = false }
    }

    private var saveTitle: String {
        if manager.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "清除 Key" }
        return manager.isRefreshing ? "保存" : "保存并查询"
    }
}

struct ProviderCardContainer<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GlassContentSurface())
    }
}

struct StatusBadge: View {
    let status: ConnectionStatus
    var isRefreshing = false
    private var color: Color {
        if isRefreshing { return .blue }
        switch status {
        case .ready: return .green
        case .loading: return .blue
        case .manualCalibrated: return .teal
        case .needsSetup, .unavailable, .cached: return .secondary
        case .error: return .red
        }
    }
    private var title: String {
        if isRefreshing || status == .loading { return "刷新中" }
        switch status {
        case .ready: return "已刷新"
        case .cached: return "缓存"
        case .manualCalibrated: return "手动"
        case .needsSetup: return "待配置"
        case .error: return "失败"
        case .unavailable: return "未提供"
        case .loading: return "刷新中"
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            if isRefreshing || status == .loading {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 8, height: 8)
            } else {
                Circle().fill(color).frame(width: 4, height: 4)
            }
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.primary)
        }
        .foregroundColor(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(color.opacity(0.08), in: Capsule())
        .accessibilityLabel("刷新状态：\(title)")
    }
}

struct QuotaBarRow: View {
    let label: String
    let remainingPercent: Double?
    let resetHint: String
    let tint: Color
    var missingLabel = "未读取"
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundColor(.primary.opacity(0.85))
                Spacer()
                if let percent = remainingPercent {
                    Text(String(format: "%.0f%% 剩余", percent))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(percent < 20 ? .orange : .primary)
                } else {
                    Text(missingLabel).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            GeometryReader { geometry in
                let percent = max(0, min(100, remainingPercent ?? 0))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill((percent < 20 ? Color.orange : tint).gradient)
                        .frame(width: geometry.size.width * CGFloat(percent / 100))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .help(resetHint)
        .accessibilityElement(children: .combine)
        .accessibilityHint(resetHint)
    }
}

private struct MiMoCalibrationView: View {
    @ObservedObject var manager: QuotaManager
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("小米 MiMo 现金余额").font(.headline)
            Picker("币种", selection: $manager.mimoCurrencyInput) {
                Text("人民币 CNY").tag("CNY")
                Text("美元 USD").tag("USD")
            }
            TextField("余额", text: $manager.mimoManualInput).textFieldStyle(.roundedBorder)
            Button("保存") {
                if let amount = Double(manager.mimoManualInput), manager.updateMiMoManualBalance(amount) {
                    manager.showingMiMoCalibratePopover = false
                } else { manager.manualInputError = "请输入有效金额（可为负数）" }
            }.buttonStyle(.borderedProminent)
            if !manager.manualInputError.isEmpty { Text(manager.manualInputError).font(.caption).foregroundColor(.red) }
        }.padding(16).frame(width: 260)
    }
}

private struct WindowCalibrationView: View {
    @ObservedObject var manager: QuotaManager
    let provider: ProviderID
    private var isGemini: Bool { provider == .gemini }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(provider.shortName) 剩余额度").font(.headline)
            percentageInput("5 小时", text: isGemini ? $manager.geminiFiveHourInput : $manager.antigravityFiveHourInput)
            percentageInput("7 天", text: isGemini ? $manager.geminiWeeklyInput : $manager.antigravityWeeklyInput)
            if !isGemini { percentageInput("Argon · 7 天", text: $manager.antigravityArgonInput) }
            Button("保存") { save() }.buttonStyle(.borderedProminent)
            if !manager.manualInputError.isEmpty { Text(manager.manualInputError).font(.caption).foregroundColor(.red) }
        }.padding(16).frame(width: 260)
    }
    private func percentageInput(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            TextField("0–100", text: text).textFieldStyle(.roundedBorder).frame(width: 80)
            Text("%").foregroundColor(.secondary)
        }
    }
    private func save() {
        let values = isGemini ? [manager.geminiFiveHourInput, manager.geminiWeeklyInput]
            : [manager.antigravityFiveHourInput, manager.antigravityWeeklyInput, manager.antigravityArgonInput]
        guard values.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Double($0) != nil }) else {
            manager.manualInputError = "请输入 0–100；未知可留空"
            return
        }
        if isGemini {
            if manager.updateGeminiPercentages(fiveHour: Double(values[0]), weekly: Double(values[1])) {
                manager.showingGeminiCalibratePopover = false
            }
        } else if manager.updateAntigravityManualPercentages(fiveHour: Double(values[0]), weekly: Double(values[1]), argon: Double(values[2])) {
            manager.showingAntigravityCalibratePopover = false
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
