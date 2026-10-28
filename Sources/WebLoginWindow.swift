import SwiftUI
import WebKit

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
    }
}

struct WebLoginWindowView: View {
    @ObservedObject var extractor: SafeWebExtractor

    var body: some View {
        VStack(spacing: 0) {
            // 顶部安全工具栏（修复 Picker 宽度，防止遮挡右侧「刷新页面」按钮）
            HStack(spacing: 12) {
                Picker("", selection: Binding(get: { extractor.activeProvider }, set: { extractor.selectProvider($0) })) {
                    Text("小米 MiMo").tag(ProviderID.mimo)
                    Text("Google AI Pro").tag(ProviderID.gemini)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)

                Button {
                    extractor.reloadCurrentPage()
                } label: {
                    Label("刷新页面", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button("常用浏览器") { extractor.openOfficialPage(for: extractor.activeProvider) }
                Button("已处理验证") { extractor.resumeBrowsingAfterUserAction() }
                    .help("仅解除认证暂停，保留服务端等待；不会自动访问")
                Spacer()

                Button {
                    Task {
                        await extractor.extractFromCurrentDOM(provider: extractor.activeProvider, silent: false)
                    }
                } label: {
                    Label("读取当前页（不刷新）", systemImage: "tray.and.arrow.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(extractor.isPageLoading || extractor.isExtracting)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            // 地址与状态提示条
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.green)
                Text(extractor.webView.url?.host ?? "未加载官方页面")
                    .font(.caption).textSelection(.enabled)
                Text("页面由 WebKit 正常加载；不导出 Cookie，不绕过登录验证，关闭后卸载")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if extractor.isPageLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(extractor.lastExtractionHint)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(extractor.lastExtractionHint.hasPrefix("✅") ? .green : .blue)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // 原生 WKWebView 主体
            WebViewContainer(webView: extractor.webView)
                .id(extractor.activeProvider)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 920, minHeight: 640)
    }
}
