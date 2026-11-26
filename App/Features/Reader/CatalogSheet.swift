import SwiftUI
import ReaderCore

/// 阅读器里的目录，做成从下往上弹的面板。
///
/// 之前是左侧抽屉。抽屉的问题是：为了省出左侧空间，正文会被压暗，而且抽屉宽度固定，
/// 长章节名一律被截断。底部面板横向空间大，也能顺手放书的信息——你点开目录，
/// 第一眼想确认的本来就是"这是哪本书、我读到哪了"。
struct CatalogSheet: View {
    let book: Book
    let coverURL: URL?
    let chapters: [NovelChapter]
    let currentIndex: Int
    let progressPercent: Double
    let bookmarks: [Bookmark]

    let onSelect: (Int) -> Void
    let onDeleteBookmark: (Bookmark) -> Void
    /// 在线阅读换源入口。本地书为 nil，不显示。
    var onSwitchSource: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var tab = 0

    private var filtered: [(index: Int, title: String)] {
        let all = chapters.enumerated().map { (index: $0.offset, title: $0.element.title) }
        guard !keyword.isEmpty else { return all }
        return all.filter { $0.title.contains(keyword) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            searchField
            if tab == 0 {
                chapterList
            } else {
                bookmarkList
            }
        }
        .background(Palette.surface)
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCoverView(book: book, coverURL: coverURL)
                .frame(width: 46, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)

                Text(book.author ?? (book.origin == .local ? "本地文件" : "在线书源"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)

                HStack(spacing: 6) {
                    Text("共 \(chapters.count) 章")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)

                    if let onSwitchSource {
                        Button(action: onSwitchSource) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("章节不全？换源")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Palette.accentSoft)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3.opacity(0.5))
                    Text("已读 \(Int(progressPercent * 100))%")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.accent)
                }
                .padding(.top, 1)
            }

            Spacer(minLength: 0)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
                    .frame(width: 28, height: 28)
                    .background(Palette.bg)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var tabs: some View {
        HStack(spacing: 20) {
            tabButton("目录", index: 0)
            tabButton("书签", index: 1)
            Spacer()
            if tab == 0 {
                Text("第 \(currentIndex + 1) 章")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink3)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.line).frame(height: 1)
        }
    }

    private func tabButton(_ title: String, index: Int) -> some View {
        Button { tab = index } label: {
            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 14, weight: tab == index ? .semibold : .regular))
                    .foregroundStyle(tab == index ? Palette.ink : Palette.ink3)
                Rectangle()
                    .fill(tab == index ? Palette.accent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink3)
            TextField("搜索章节名", text: $keyword)
                .font(.system(size: 13))
            if !keyword.isEmpty {
                Button { keyword = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(hex: 0xEBEFF3))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, 10)
    }

    // MARK: 列表

    private var chapterList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered, id: \.index) { item in
                        Button {
                            onSelect(item.index)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                if item.index == currentIndex {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Palette.accent)
                                        .frame(width: 3, height: 16)
                                }
                                Text(item.title)
                                    .font(.system(size: 14.5))
                                    .foregroundStyle(item.index == currentIndex ? Palette.accent : Palette.ink2)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Spacing.xl)
                            .padding(.vertical, 14)
                            .background(item.index == currentIndex ? Palette.accentSoft.opacity(0.45) : Color.clear)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Color(hex: 0xF3F6F9)).frame(height: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(item.index)
                    }
                }
                .padding(.bottom, 24)
            }
            .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
        }
    }

    private var bookmarkList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if bookmarks.isEmpty {
                    EmptyStateView(
                        symbol: "bookmark",
                        title: "还没有书签",
                        message: "阅读时点右侧书签按钮，会记住当前这一页"
                    )
                } else {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            onSelect(bookmark.chapterIndex)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("第 \(bookmark.chapterIndex + 1) 章 · 第 \(bookmark.offset + 1) 页")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Palette.ink3)
                                    Text(bookmark.excerpt ?? "书签")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Palette.ink2)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                                Button {
                                    onDeleteBookmark(bookmark)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.ink3)
                                        .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, Spacing.xl)
                            .padding(.vertical, 13)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Color(hex: 0xF3F6F9)).frame(height: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }
}
