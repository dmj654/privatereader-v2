import SwiftUI
import ReaderCore

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    group("阅读") {
                        NavigationLink { ReaderSettingsView() } label: {
                            row("textformat.size", "阅读设置", detail: nil)
                        }
                        divider
                        NavigationLink { StatsView() } label: {
                            row("chart.bar", "阅读统计", detail: nil)
                        }
                        divider
                        NavigationLink { SourcesView() } label: {
                            row("antenna.radiowaves.left.and.right", "书源管理", detail: sourceDetail)
                        }
                    }

                    group("存储") {
                        NavigationLink { StorageView() } label: {
                            row("internaldrive", "存储空间", detail: nil)
                        }
                    }

                    group("数据") {
                        NavigationLink { BackupView() } label: {
                            row("arrow.up.arrow.down.circle", "备份与恢复", detail: nil)
                        }
                        divider
                        NavigationLink { ImportLogView() } label: {
                            row("doc.text.magnifyingglass", "导入日志", detail: nil)
                        }
                    }

                    group("关于") {
                        row("info.circle", "版本", detail: version)
                        divider
                        row("shield", "隐私", detail: "全部数据留在本机")
                    }

                    Text("私阅读 · 本地优先。书、进度、书源都存在这台设备上。")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                        .padding(.top, 4)
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, 14)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var sourceDetail: String? {
        guard let all = try? env.sources.all() else { return nil }
        return "\(all.filter(\.enabled).count)/\(all.count)"
    }

    private var divider: some View {
        Rectangle().fill(Palette.line).frame(height: 0.5).padding(.leading, 44)
    }

    private func row(_ symbol: String, _ title: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Palette.accent)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 14.5))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink3.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .contentShape(Rectangle())
    }

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.ink3)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            }
        }
    }
}

struct ImportLogView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            ScrollView {
                Text(logText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Palette.ink2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(Spacing.l)
            }
        }
        .navigationTitle("导入日志")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var logText: String {
        let text = env.importLog.read()
        return text.isEmpty ? "还没有日志。" : text
    }
}
