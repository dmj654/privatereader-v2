import SwiftUI
import ReaderCore

/// 排版 / 交互设置。
/// 主题入口只显示背景，设置入口显示全部——换背景是随手动作，调字号是坐下来慢慢调。
struct TypographySheet: View {
    enum Focus: Equatable {
        case theme
        case typography
    }

    @Binding var style: ReaderStyle
    @Binding var theme: ReaderTheme
    var focus: Focus = .typography
    @ObservedObject var prefs: ReaderPreferences
    let onChange: () -> Void
    let onEditZones: () -> Void
    let onEditSpeechZones: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if focus == .typography {
                    fontSection
                    sizeSection
                    lineSpacingSection
                    letterSpacingSection
                    paragraphSection
                    marginSection
                    alignSection
                    indentSection
                }

                backgroundSection

                if focus == .typography {
                    animationSection
                    zoneSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .background(Palette.surface)
    }

    // MARK: 字体

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("字体")
            HStack(spacing: 8) {
                ForEach(ReaderFontFamily.allCases, id: \.self) { family in
                    optionChip(family.title, selected: style.fontFamily == family) {
                        update { $0.fontFamily = family }
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: 字号

    private var sizeSection: some View {
        row("字号", value: "\(Int(style.fontSize))") {
            HStack(spacing: 8) {
                smallButton("A−") { update { $0.fontSize = max(12, $0.fontSize - 1) } }
                smallButton("A+") { update { $0.fontSize = min(30, $0.fontSize + 1) } }
            }
        }
    }

    // MARK: 行距

    private var lineSpacingSection: some View {
        row("行距", value: String(format: "%.2f", style.lineHeightMultiple)) {
            HStack(spacing: 8) {
                smallButton("紧") { update { $0.lineHeightMultiple = max(1.2, $0.lineHeightMultiple - 0.1) } }
                smallButton("中") { update { $0.lineHeightMultiple = 1.95 } }
                smallButton("松") { update { $0.lineHeightMultiple = min(3.0, $0.lineHeightMultiple + 0.1) } }
            }
        }
    }

    // MARK: 字间距

    private var letterSpacingSection: some View {
        row("字间距", value: String(format: "%.1f", style.letterSpacing)) {
            HStack(spacing: 8) {
                smallButton("−") { update { $0.letterSpacing = max(-1, $0.letterSpacing - 0.5) } }
                smallButton("＋") { update { $0.letterSpacing = min(3, $0.letterSpacing + 0.5) } }
            }
        }
    }

    // MARK: 段间距

    private var paragraphSection: some View {
        row("段间距", value: "\(Int(style.paragraphSpacing))") {
            HStack(spacing: 8) {
                smallButton("−") { update { $0.paragraphSpacing = max(0, $0.paragraphSpacing - 4) } }
                smallButton("＋") { update { $0.paragraphSpacing = min(32, $0.paragraphSpacing + 4) } }
            }
        }
    }

    // MARK: 页边距

    private var marginSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("页边距")
            HStack(spacing: 8) {
                optionChip("窄", selected: style.marginHorizontal < 20) {
                    update { $0.marginHorizontal = 16 }
                }
                optionChip("中", selected: style.marginHorizontal >= 20 && style.marginHorizontal < 26) {
                    update { $0.marginHorizontal = 22 }
                }
                optionChip("宽", selected: style.marginHorizontal >= 26) {
                    update { $0.marginHorizontal = 30 }
                }
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: 对齐

    private var alignSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("对齐")
            HStack(spacing: 8) {
                optionChip("左对齐", selected: !style.justified) {
                    update { $0.justified = false }
                }
                optionChip("两端对齐", selected: style.justified) {
                    update { $0.justified = true }
                }
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: 首行缩进

    private var indentSection: some View {
        HStack {
            Text("首行缩进两字")
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink2)
            Spacer()
            Toggle("", isOn: Binding(
                get: { style.indentFirstLine },
                set: { value in update { $0.indentFirstLine = value } }
            ))
            .labelsHidden()
            .tint(Palette.accent)
        }
        .padding(.vertical, 6)
    }

    // MARK: 背景

    private var backgroundSection: some View {
        row("背景", value: nil) {
            HStack(spacing: 10) {
                ForEach(ReaderTheme.allCases) { item in
                    Button {
                        theme = item
                        onChange()
                    } label: {
                        Circle()
                            .fill(item.background)
                            .frame(width: 26, height: 26)
                            .overlay {
                                Circle().strokeBorder(
                                    theme == item ? Palette.accent : Palette.line,
                                    lineWidth: theme == item ? 2 : 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 翻页动画

    private var animationSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("翻页动画")
            HStack(spacing: 8) {
                ForEach(PageTurnMode.allCases) { mode in
                    optionChip(mode.title, selected: prefs.pageTurn == mode) {
                        prefs.pageTurn = mode
                    }
                }
            }
            Text(prefs.pageTurn.detail)
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.line).frame(height: 1)
        }
        .padding(.top, 6)
    }

    // MARK: 屏幕区域

    private var zoneSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("点击区域")

            zoneEntry(
                symbol: "hand.tap",
                title: "阅读区域",
                detail: "九宫格逐格设置：翻页、菜单、上下章或无动作",
                action: onEditZones
            )

            zoneEntry(
                symbol: "headphones",
                title: "听书区域",
                detail: "九宫格逐格设置：上/下一句、暂停、翻页或无动作",
                action: onEditSpeechZones
            )

            if !prefs.zones.isUsable {
                Text("阅读的九个区域全是「无动作」，点屏幕不会有反应。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
            }
            if !prefs.speechZones.isUsable {
                Text("听书的九个区域全是「无动作」，听书时点屏幕不会有反应。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.line).frame(height: 1)
        }
    }

    private func zoneEntry(symbol: String,
                           title: String,
                           detail: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(13)
            .background(Palette.bg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 组件

    private func update(_ mutate: (inout ReaderStyle) -> Void) {
        var copy = style
        mutate(&copy)
        style = copy
        onChange()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13.5))
            .foregroundStyle(Palette.ink2)
    }

    private func row<Content: View>(_ title: String,
                                    value: String?,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink2)
            if let value {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink3)
                    .frame(minWidth: 32, alignment: .leading)
            }
            Spacer()
            content()
        }
        .padding(.vertical, 8)
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink2)
                .frame(minWidth: 34)
                .padding(.vertical, 5)
                .background(Color(hex: 0xEDF0F3))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func optionChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Palette.ink2)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(selected ? Palette.ink : Color(hex: 0xF0F3F6))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
