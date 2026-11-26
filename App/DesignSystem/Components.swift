import SwiftUI

// MARK: - 卡片

struct Card<Content: View>: View {
    var padding: CGFloat
    var content: Content

    init(padding: CGFloat = Spacing.l, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            }
            .shadow(color: Shadow.card, radius: Shadow.cardRadius, x: 0, y: Shadow.cardY)
    }
}

// MARK: - 主按钮

struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 46

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
    }
}

// MARK: - 次按钮

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 46

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.headline)
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .strokeBorder(Palette.lineStrong, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

// MARK: - Chip

struct Chip: View {
    let title: String
    var isOn: Bool = false

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Color.white : Palette.ink2)
            .padding(.horizontal, 15)
            .frame(height: 32)
            .background(isOn ? Palette.ink : Palette.surface)
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(isOn ? Color.clear : Palette.line, lineWidth: 1)
            }
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.ink3)
                .padding(.bottom, 4)
            Text(title)
                .font(Typo.headline)
                .foregroundStyle(Palette.ink)
            if let message {
                Text(message)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .padding(.horizontal, 24)
    }
}

// MARK: - 骨架块

struct SkeletonBox: View {
    var height: CGFloat = 14
    var width: CGFloat? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(hex: 0xEDF0F3))
            .frame(width: width, height: height)
    }
}

// MARK: - 占位页面（M0 用，随里程碑逐个替换）

struct PlaceholderScreen: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text(title)
                        .font(Typo.display)
                        .foregroundStyle(Palette.ink)
                    Spacer()
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.l)
                .glassTopBar()

                EmptyStateView(symbol: symbol, title: subtitle, message: "这一页在后续里程碑中实现")
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .navigationBarHidden(true)
    }
}
