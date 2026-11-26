import SwiftUI
import ReaderCore

/// 书架排序面板。
///
/// 以前排序挂在系统 `Menu` 上，按钮只显示「最近/添加/书名」两个字：
/// 用户看不出当前是什么逻辑，也点不出完整选项。
/// 现在点按钮就弹这张面板，三项写全，当前项打勾。
struct ShelfSortSheet: View {
    let current: ShelfSort
    let onSelect: (ShelfSort) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    ForEach(ShelfSort.allCases, id: \.self) { option in
                        Button {
                            onSelect(option)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: symbol(for: option))
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Palette.ink2)
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .font(.system(size: 14.5, weight: current == option ? .semibold : .regular))
                                        .foregroundStyle(Palette.ink)
                                    Text(option.detail)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Palette.ink3)
                                }

                                Spacer(minLength: 0)

                                if current == option {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Palette.accent)
                                }
                            }
                            .padding(.horizontal, 18)
                            .frame(height: 60)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Palette.line)
                                .frame(height: 0.5)
                                .padding(.leading, 18)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, 6)
            }
            .navigationTitle("排序方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func symbol(for option: ShelfSort) -> String {
        switch option {
        case .lastRead: return "clock"
        case .added: return "calendar"
        case .title: return "textformat"
        }
    }
}

extension ShelfSort {
    var detail: String {
        switch self {
        case .lastRead: return "最近打开过的排在最前，没读过的按加入时间"
        case .added: return "新加入书架的书排在最前"
        case .title: return "按书名排序，中文按拼音"
        }
    }
}
