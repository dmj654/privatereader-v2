import SwiftUI

/// 漫画阅读器顶栏。本地与在线共用同一套，避免两本书看起来像两个 App。
struct ComicTopBar: View {
    let title: String
    let subtitle: String
    let bookmarked: Bool

    let onBack: () -> Void
    let onCatalog: () -> Void
    let onBookmark: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            square("chevron.left", action: onBack)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            square("list.bullet", action: onCatalog)
            square(bookmarked ? "bookmark.fill" : "bookmark", action: onBookmark)
            square("slider.horizontal.3", action: onSettings)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    /// 参考图里的按钮是浅灰实底、无描边，和阅读页的图片拉开一点层次。
    private func square(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .background(Color(hex: 0xF2F3F5))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 漫画阅读器底栏：页码、滑杆、上一/下一、收藏/下载/分享/启动。
/// 参考图是贴底、整宽的白面板，不再做成浮在页面上的圆角卡片。
struct ComicBottomBar: View {
    let chipText: String
    let counterText: String
    @Binding var sliderValue: Double
    let sliderRange: ClosedRange<Double>

    let onPrevious: () -> Void
    let onNext: () -> Void
    let previousEnabled: Bool
    let nextEnabled: Bool
    var navigationEnabled: Bool = true

    let bookmarked: Bool
    let onBookmark: () -> Void
    let downloadText: String
    let onDownload: () -> Void
    let shareURL: URL?
    let shareText: String
    let autoSeconds: Int
    let onAuto: () -> Void

    var body: some View {
        VStack(spacing: 11) {
            HStack {
                Text(chipText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.accentDeep)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Palette.accentSoft)
                    .clipShape(Capsule())

                Spacer(minLength: 0)

                Text(counterText)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Palette.ink3)
            }

            HStack(spacing: 10) {
                navButton("backward.end.fill",
                          enabled: navigationEnabled && previousEnabled,
                          action: onPrevious)

                ComicScrubber(value: $sliderValue,
                              range: sliderRange,
                              enabled: navigationEnabled)

                navButton("forward.end.fill",
                          enabled: navigationEnabled && nextEnabled,
                          action: onNext)
            }

            HStack(spacing: 0) {
                action(bookmarked ? "heart.fill" : "heart",
                       "收藏",
                       tint: bookmarked ? Palette.accent : Palette.ink,
                       action: onBookmark)
                action("arrow.down.to.line", downloadText, action: onDownload)
                shareAction
                action("clock.arrow.circlepath",
                       autoSeconds == 0 ? "启动" : "\(autoSeconds)s",
                       tint: autoSeconds > 0 ? Palette.accent : Palette.ink,
                       action: onAuto)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Palette.surface.ignoresSafeArea(edges: .bottom))
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(enabled ? Palette.ink : Palette.ink3.opacity(0.35))
                .frame(width: 50, height: 50)
                .background(Color(hex: 0xF2F3F5))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func action(_ symbol: String,
                        _ title: String,
                        tint: Color = Palette.ink,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.ink3)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var shareAction: some View {
        if let shareURL {
            ShareLink(item: shareURL) {
                actionLabel("square.and.arrow.up", "分享")
            }
        } else {
            ShareLink(item: shareText) {
                actionLabel("square.and.arrow.up", "分享")
            }
        }
    }

    private func actionLabel(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .frame(height: 20)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.ink3)
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// 参考图里的滑杆是一整条浅灰胶囊；只有当前进度那一段用极浅的强调色填充。
/// 没有圆点，避免在单页/单话时出现一个和背景差不多、但看起来又像脏点的拇指。
private struct ComicScrubber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let enabled: Bool

    private var progress: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(hex: 0xF2F3F5))

                if progress > 0 {
                    Capsule()
                        .fill(Palette.accentSoft)
                        .frame(width: max(0, proxy.size.width * progress))
                }
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard enabled, range.upperBound > range.lowerBound else { return }
                        let ratio = min(max(drag.location.x / max(proxy.size.width, 1), 0), 1)
                        let raw = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                        value = min(max(raw.rounded(), range.lowerBound), range.upperBound)
                    }
            )
        }
        .frame(height: 36)
    }
}
