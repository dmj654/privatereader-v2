import SwiftUI
import ReaderCore

/// 输入漫画编号后弹出的源选择表。
/// 只展示“源脚本声明了 idMatch 且当前编号能匹配”的源，避免用户选了
/// 一个根本不支持编号的源，最后得到一个空搜索。
struct IDSourcePickerSheet: View {
    let query: String
    let options: [SearchTarget]
    let onSelect: (SearchTarget) -> Void

    @Environment(\.dismiss) private var dismiss

    private var sheetHeight: CGFloat {
        min(430, 152 + CGFloat(options.count) * 74)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("选择漫画源")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("编号 \(query) 可在以下源直接打开")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink3)
                        .frame(width: 30, height: 30)
                        .background(Palette.surfaceAlt)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 9) {
                    ForEach(options) { source in
                        Button {
                            onSelect(source)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Palette.accentSoft)
                                        .frame(width: 42, height: 42)
                                    Image(systemName: "number")
                                        .font(.system(size: 19, weight: .semibold))
                                        .foregroundStyle(Palette.accent)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Palette.ink)
                                        .lineLimit(1)
                                    Text(sourceSubtitle(source))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Palette.ink3)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Palette.ink3.opacity(0.7))
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .background(Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .strokeBorder(Palette.line, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }

            Button("取消") { dismiss() }
                .buttonStyle(SecondaryButtonStyle(height: 42))
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 20)
        }
        .background(Palette.bg)
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
    }

    private func sourceSubtitle(_ source: SearchTarget) -> String {
        if let version = source.veneraSource?.version, !version.isEmpty {
            return "Venera 漫画源 · v\(version) · 支持编号直达"
        }
        return "Venera 漫画源 · 支持编号直达"
    }
}
