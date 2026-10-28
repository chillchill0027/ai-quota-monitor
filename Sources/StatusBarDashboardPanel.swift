import AppKit
import SwiftUI

enum StatusBarPanelGeometry {
    static func frame(anchoredTo anchor: NSRect, within visibleFrame: NSRect, size: NSSize) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(size.width, max(1, bounds.width))
        let height = min(size.height, max(1, bounds.height))
        let x = min(max(anchor.midX - width / 2, bounds.minX), bounds.maxX - width)
        let y = min(max(anchor.minY - 6 - height, bounds.minY), bounds.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
private final class DashboardFloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// A nonactivating panel can join another app's full-screen Space without
/// activating our regular Dock application or relying on NSPopover's private window.
@MainActor
final class StatusBarDashboardPanel {
    private let panel: DashboardFloatingPanel
    private let onShow: () -> Void
    private weak var anchorButton: NSStatusBarButton?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var presentationGeneration = 0
    private var preferredSize = NSSize(width: 390, height: 650)
    private var presentationAnchor: NSRect?
    private var presentationVisibleFrame: NSRect?

    var isShown: Bool { panel.isVisible }

    init(manager: QuotaManager, onShow: @escaping () -> Void) {
        self.onShow = onShow
        panel = DashboardFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 650),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = "AI 额度看板（状态栏）"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .transient, .ignoresCycle]
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.animationBehavior = .none

        // Scrolling keeps all providers reachable on shorter displays.
        let hosting = NSHostingView(rootView:
            ScrollView(.vertical) {
                DashboardView(manager: manager, presentation: .window, onContentHeightChange: { [weak self] height in
                    DispatchQueue.main.async { [weak self] in self?.updateContentHeight(height) }
                })
            }
        )
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 24
            glass.contentView = hosting
            panel.contentView = glass
        } else {
            // DashboardView supplies its existing vibrancy fallback on macOS 14/15.
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = 24
            hosting.layer?.masksToBounds = true
            panel.contentView = hosting
        }
        panel.onCancel = { [weak self] in self?.close() }
    }

    func toggle(from button: NSStatusBarButton) {
        if isShown { close() } else { show(from: button) }
    }

    private func show(from button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        var anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var screen = buttonWindow.screen ?? NSScreen.screens.first { $0.frame.intersects(anchor) }

        // Full-screen menu bars can use a proxy on another display. A real click
        // identifies that display; programmatic/reopen actions keep the button anchor.
        if let event = NSApp.currentEvent, event.window === buttonWindow,
           event.type == .leftMouseUp || event.type == .rightMouseUp {
            let point = NSEvent.mouseLocation
            if let clickedScreen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
               clickedScreen !== screen {
                screen = clickedScreen
                anchor = NSRect(x: point.x - button.bounds.width / 2,
                                y: clickedScreen.frame.maxY - button.bounds.height,
                                width: button.bounds.width, height: button.bounds.height)
            }
        }
        guard let screen else { return }
        presentationAnchor = anchor
        presentationVisibleFrame = screen.visibleFrame
        panel.setFrame(StatusBarPanelGeometry.frame(anchoredTo: anchor, within: screen.visibleFrame,
                                                    size: preferredSize), display: false)
        anchorButton = button
        presentationGeneration += 1
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        guard panel.isVisible else { return }
        button.highlight(true)
        startMonitoring()
        // Only hidden -> visible expansion participates in the existing five-minute policy.
        onShow()
    }

    func close() {
        presentationGeneration += 1
        stopMonitoring()
        panel.orderOut(nil)
        anchorButton?.highlight(false)
        anchorButton = nil
        presentationAnchor = nil
        presentationVisibleFrame = nil
    }

    private func updateContentHeight(_ height: CGFloat) {
        preferredSize.height = max(1, ceil(height))
        guard isShown, let anchor = presentationAnchor, let visibleFrame = presentationVisibleFrame else { return }
        let frame = StatusBarPanelGeometry.frame(anchoredTo: anchor, within: visibleFrame, size: preferredSize)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func startMonitoring() {
        stopMonitoring()
        let generation = presentationGeneration
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Only mouse events are observed globally; no keyboard/accessibility permission is needed.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, NSApp.modalWindow == nil, self.panel.attachedSheet == nil else { return }
                self.close(ifGeneration: generation)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, self.isShown, let window = event.window else { return event }
            if window === self.anchorButton?.window || self.belongsToPanel(window) { return event }
            // Menus use their own tracking loop. Preserve calibration popovers and
            // alerts; do not close merely because the panel temporarily loses key status.
            if NSApp.modalWindow == nil, self.panel.attachedSheet == nil,
               window.styleMask.contains(.titled) {
                self.close()
            }
            return event
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close(ifGeneration: generation) }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close(ifGeneration: generation) }
        }
    }

    private func belongsToPanel(_ window: NSWindow) -> Bool {
        if window === panel { return true }
        if let parent = window.parent, belongsToPanel(parent) { return true }
        if let parent = window.sheetParent, belongsToPanel(parent) { return true }
        return false
    }

    private func close(ifGeneration generation: Int) {
        guard isShown, generation == presentationGeneration else { return }
        close()
    }

    private func stopMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        localMonitor = nil
        globalMonitor = nil
        spaceObserver = nil
        screenObserver = nil
    }
}
