import SwiftUI

/// 漫画底部面板：页码、滑杆、翻页、自动、设置、退出。
struct ComicPanel: View {
    @Binding var index: Int
    let pageCount: Int
    @Binding var mode: ComicMode
    @Binding var autoSeconds: Int
    let onDisplay: () -> Void
    let onHide: () -> Void
    let onExit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("P \(index + 1)")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
                Text("/ \(pageCount)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.ink3)
                Spacer()
                Text(mode.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Palette.surfaceAlt)
                    .clipShape(Capsule())

                Button(action: onHide) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink3)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起菜单")
            }

            if pageCount > 1 {
                Slider(
                    value: Binding(
                        get: { Double(index) },
                        set: { index = min(max(Int($0.rounded()), 0), pageCount - 1) }
                    ),
                    in: 0...Double(pageCount - 1),
                    step: 1
                )
                .tint(Palette.accent)
            }

            HStack(spacing: 0) {
                action("chevron.left", "上一页", enabled: index > 0) {
                    index = max(index - 1, 0)
                }
                action("chevron.right", "下一页", enabled: index < pageCount - 1) {
                    index = min(index + 1, pageCount - 1)
                }
                action("arrow.triangle.2.circlepath", autoLabel, enabled: true) {
                    cycleAuto()
                }
                action("slider.horizontal.3", "设置", enabled: true, action: onDisplay)
                action("xmark", "退出", enabled: true, action: onExit)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 26)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Palette.surface.opacity(0.86)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.line).frame(height: 0.5)
        }
    }

    private var autoLabel: String {
        autoSeconds == 0 ? "自动" : "\(autoSeconds)s"
    }

    private func cycleAuto() {
        switch autoSeconds {
        case 0: autoSeconds = 3
        case 3: autoSeconds = 5
        case 5: autoSeconds = 10
        default: autoSeconds = 0
        }
    }

    private func action(_ symbol: String,
                        _ title: String,
                        enabled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(enabled ? Palette.ink2 : Palette.ink3.opacity(0.45))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 显示设置：模式、适应方式、背景、自动翻页间隔。
struct ComicDisplaySheet: View {
    @Binding var mode: ComicMode
    @Binding var fitRaw: String
    @Binding var backgroundRaw: String
    @Binding var autoPageSeconds: Int
    @Binding var autoScrollSpeed: Double

    @Environment(\.dismiss) private var dismiss

    private let backgrounds: [(id: String, title: String, color: Color)] = [
        ("canvas", "浅灰", Palette.comicCanvas),
        ("white", "白", Color(hex: 0xF7F8FA)),
        ("black", "黑", Color(hex: 0x111417))
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 12) {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                label("阅读模式")
                                Picker("", selection: $mode) {
                                    ForEach(ComicMode.allCases) { item in
                                        Text(item.title).tag(item)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }

                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                label("单页适应")
                                Picker("", selection: $fitRaw) {
                                    ForEach(ComicFit.allCases) { item in
                                        Text(item.title).tag(item.rawValue)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }

                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                label("背景")
                                HStack(spacing: 9) {
                                    ForEach(backgrounds, id: \.id) { item in
                                        Button {
                                            backgroundRaw = item.id
                                        } label: {
                                            VStack(spacing: 5) {
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .fill(item.color)
                                                    .frame(height: 34)
                                                    .overlay {
                                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                            .strokeBorder(
                                                                backgroundRaw == item.id ? Palette.accent : Palette.line,
                                                                lineWidth: backgroundRaw == item.id ? 1.6 : 1
                                                            )
                                                    }
                                                Text(item.title)
                                                    .font(.system(size: 10.5))
                                                    .foregroundStyle(backgroundRaw == item.id ? Palette.ink : Palette.ink3)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                label("自动阅读")
                                HStack(spacing: 8) {
                                    ForEach([2, 3, 5, 10], id: \.self) { seconds in
                                        Button {
                                            autoPageSeconds = seconds
                                        } label: {
                                            Text("\(seconds)s/页")
                                                .font(.system(size: 12, weight: autoPageSeconds == seconds ? .semibold : .regular))
                                                .foregroundStyle(autoPageSeconds == seconds ? .white : Palette.ink2)
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 32)
                                                .background(autoPageSeconds == seconds ? Palette.accent : Palette.surfaceAlt)
                                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                HStack(spacing: 8) {
                                    Text("滚动速度")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Palette.ink3)
                                    Text("慢")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Palette.ink3)
                                    Slider(value: $autoScrollSpeed, in: 1...8, step: 1)
                                        .tint(Palette.accent)
                                    Text("快")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Palette.ink3)
                                }

                                Text("自动按钮只开启 / 停止；单页模式按翻页间隔，条漫模式按滚动速度。")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Palette.ink3)
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("显示")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Palette.ink2)
    }
}
