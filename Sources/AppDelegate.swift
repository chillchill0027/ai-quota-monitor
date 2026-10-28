import SwiftUI
import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLease: InstanceLease?
    private var statusItem: NSStatusItem!
    private var statusPanel: StatusBarDashboardPanel!
    private var mainDashboardWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 使用 .regular 策略：在 Dock 栏提供清晰入口，且启动或双击时直接弹出看板窗口，解决刘海屏状态栏遮挡及「双击无反应」问题
        NSApp.setActivationPolicy(.regular)

        do {
            instanceLease = try InstanceLease.applicationLease()
        } catch InstanceLease.LeaseError.occupied {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.chill.AIQuotaMonitor")
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
                .activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法建立本地访问保护"
            alert.informativeText = "本次未启动额度查询。请检查本机应用数据目录权限后重试。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let manager = QuotaManager.shared

        // A nonactivating panel can appear in another app's full-screen Space.
        statusPanel = StatusBarDashboardPanel(manager: manager) {
            manager.onUserInteractionOpenPopover()
        }

        // 2. 创建顶部状态栏图标与自适应文字
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "AI 额度看板")
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("AI 额度看板")
            button.setAccessibilityIdentifier("quota-dashboard-status-item")
            button.target = self
            button.action = #selector(handleStatusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 3. 创建独立主窗口（双击 App 或点击 Dock 图标时立即显示，不怕 13 寸刘海遮挡状态栏）
        setupMainDashboardWindow(manager: manager)

        // 监听额度与显示模式变化，动态更新状态栏文字
        Publishers.CombineLatest4(
            manager.$deepseek,
            manager.$mimo,
            manager.$gemini,
            manager.$chatgpt
        )
        .combineLatest(manager.$antigravity, manager.$menuBarStyle)
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            self?.updateStatusItemButtonTitle()
        }
        .store(in: &cancellables)

        updateStatusItemButtonTitle()

        // 启动仅显示缓存；点开状态栏或点击查询按钮时才按需查询。
        showMainDashboardWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 再次双击或点击 Dock 仅显示主窗口，不查询
        QuotaManager.shared.onUserInteractionReopenDashboard()
        showMainDashboardWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusPanel?.close()
    }

    private func setupMainDashboardWindow(manager: QuotaManager) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "AI 额度看板"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Bring the existing dashboard to the user's current Space, including
        // another application's full-screen Space, rather than switching desktops.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
        let hosting = NSHostingView(rootView: DashboardView(manager: manager, onContentHeightChange: { [weak self] height in
            DispatchQueue.main.async { [weak self] in self?.updateMainDashboardHeight(height) }
        }))
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 24
            // NSGlassEffectView keeps contentView geometry synchronized through Auto Layout.
            glass.contentView = hosting
            window.contentView = glass
        } else {
            window.contentView = hosting
        }
        self.mainDashboardWindow = window
    }

    private func updateMainDashboardHeight(_ contentHeight: CGFloat) {
        guard let window = mainDashboardWindow else { return }
        let desired = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 390, height: ceil(contentHeight)))
        let bounds = (window.screen ?? NSScreen.main)?.visibleFrame
        let height = min(desired.height, bounds.map { $0.height - 16 } ?? desired.height)
        guard abs(window.frame.height - height) > 1 else { return }
        var frame = window.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        if let bounds {
            frame.origin.y = min(max(frame.origin.y, bounds.minY + 8), bounds.maxY - frame.height - 8)
        }
        window.setFrame(frame, display: true)
    }

    func showMainDashboardWindow() {
        statusPanel?.close()
        if mainDashboardWindow?.isMiniaturized == true {
            mainDashboardWindow?.deminiaturize(nil)
        }
        mainDashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusItemButtonTitle() {
        guard let button = statusItem.button else { return }
        let title = QuotaManager.shared.statusBarCompactTitle
        button.title = title
        if title.isEmpty {
            button.imagePosition = .imageOnly
        } else {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        }
    }

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        statusPanel.toggle(from: sender)
    }
}

@main
struct AIQuotaMonitorMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
