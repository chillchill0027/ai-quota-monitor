import SwiftUI

struct SettingsInlineView: View {
    @ObservedObject var manager: QuotaManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("显示供应商")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 12) {
                    ForEach(ProviderID.dashboardOrder) { provider in
                        providerButton(provider)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("状态栏显示")
                    .font(.system(size: 13, weight: .semibold))
                ForEach(MenuBarDisplayStyle.allCases) { style in
                    displayStyleButton(style)
                }
            }

            Divider()

            Button { NSApplication.shared.terminate(nil) } label: {
                Label("退出应用", systemImage: "power")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassContentSurface())
    }

    private func providerButton(_ provider: ProviderID) -> some View {
        let selected = manager.isProviderVisible(provider)
        return Button { manager.toggleProviderVisibility(provider) } label: {
            ProviderIcon(provider: provider, size: 28)
                .opacity(selected ? 1 : 0.3)
                .frame(width: 52, height: 52)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(3)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!manager.canToggleProvider(provider))
        .accessibilityLabel(provider.shortName)
        .accessibilityValue(selected ? "已显示" : "已隐藏")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(manager.canToggleProvider(provider) ? provider.shortName : "至少保留一个供应商")
    }

    private func displayStyleButton(_ style: MenuBarDisplayStyle) -> some View {
        let selected = manager.menuBarStyle == style
        let preview = manager.statusBarTitle(for: style).trimmingCharacters(in: .whitespaces)
        return Button { manager.menuBarStyle = style } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(style.label)
                        .font(.system(size: 12, weight: .medium))
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                        if !preview.isEmpty { Text(verbatim: preview) }
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.label)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
