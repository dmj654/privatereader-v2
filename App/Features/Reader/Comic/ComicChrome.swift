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
        HStack(spacing: 10) {
            square("chevron.left", action: onBack)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)

            Spacer(minLength: 0)

            square("list.bullet", action: onCatalog)
            square(bookmarked ? "bookmark.fill" : "bookmark", action: onBookmark)
            square("slider.horizontal.3", action: onSettings)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func square(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .frame(width: 42, height: 42)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

/// 漫画阅读器底栏：页码、滑杆、上一/下一、收藏/下载/分享/自动。
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
        VStack(spacing: 12) {
            HStack {
                Text(chipText)
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.accentDeep)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Palette.accentSoft)
                    .clipShape(Capsule())

                Spacer(minLength: 0)

                Text(counterText)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Palette.ink3)
            }

            HStack(spacing: 10) {
                navButton("backward.end.fill", enabled: navigationEnabled && previousEnabled, action: onPrevious)

                Slider(value: $sliderValue, in: sliderRange, step: 1)
                    .tint(Palette.accent)
                    .disabled(!navigationEnabled || sliderRange.upperBound <= sliderRange.lowerBound)

                navButton("forward.end.fill", enabled: navigationEnabled && nextEnabled, action: onNext)
            }

            HStack(spacing: 0) {
                action(bookmarked ? "heart.fill" : "heart",
                       "收藏",
                       tint: bookmarked ? Palette.accent : Palette.ink2,
                       action: onBookmark)
                action("arrow.down.circle", downloadText, action: onDownload)
                shareAction
                action("timer", autoSeconds == 0 ? "自动" : "\(autoSeconds)s",
                       tint: autoSeconds > 0 ? Palette.accent : Palette.ink2,
                       action: onAuto)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(Palette.surface.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.line).frame(height: 0.5)
        }
        .padding(.horizontal, 6)
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Palette.ink2 : Palette.ink3.opacity(0.4))
                .frame(width: 46, height: 46)
                .background(Palette.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func action(_ symbol: String,
                        _ title: String,
                        tint: Color = Palette.ink2,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 10.5))
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
                VStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .medium))
                        .frame(height: 20)
                    Text("分享")
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
        } else {
            ShareLink(item: shareText) {
                VStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .medium))
                        .frame(height: 20)
                    Text("分享")
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
        }
    }
}
