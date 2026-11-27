import SwiftUI
import ReaderCore

/// 漫画阅读器里的章节评论。数据完全来自源脚本的 `loadChapterComments`，
/// App 不伪造评论；源没声明这个接口时明确告诉用户。
struct ComicCommentsSheet: View {
    let comicId: String
    let chapter: OnlineChapter
    let source: SearchTarget?
    let runtime: VeneraRuntime

    @Environment(\.dismiss) private var dismiss
    @State private var comments: [VeneraComment] = []
    @State private var page = 0
    @State private var maxPage = 1
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && comments.isEmpty {
                    ProgressView().tint(Palette.accent)
                } else if let errorText, comments.isEmpty {
                    EmptyStateView(symbol: "text.bubble",
                                   title: "评论加载失败",
                                   message: errorText)
                } else if comments.isEmpty {
                    EmptyStateView(symbol: "text.bubble",
                                   title: "这一话还没有评论",
                                   message: "源站返回的评论列表是空的。")
                } else {
                    commentList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.bg)
            .navigationTitle("本章评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task { await load(reset: true) }
    }

    private var commentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(chapter.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                    .padding(.bottom, 2)

                ForEach(comments) { comment in
                    commentRow(comment)
                }

                if page < maxPage {
                    Button {
                        Task { await load(reset: false) }
                    } label: {
                        Text(isLoading ? "加载中…" : "加载更多")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }

                if let errorText {
                    Text(errorText)
                        .font(Typo.micro)
                        .foregroundStyle(Palette.danger)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, 14)
        }
    }

    private func commentRow(_ comment: VeneraComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                avatar(comment.avatar)
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(comment.userName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    if !comment.time.isEmpty {
                        Text(displayTime(comment.time))
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.ink3)
                    }
                }
                Spacer(minLength: 0)
                if let replyCount = comment.replyCount, replyCount > 0 {
                    Text("\(replyCount) 回复")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.ink3)
                }
            }

            Text(comment.content)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink2)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func avatar(_ urlString: String) -> some View {
        if let url = URL(string: urlString), !urlString.isEmpty {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    avatarPlaceholder
                }
            }
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Palette.accentSoft
            Image(systemName: "person.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.accent)
        }
    }

    private func displayTime(_ raw: String) -> String {
        // 源站时间格式不统一：能按 Unix 秒解析就本地化，否则原样显示。
        if let seconds = Double(raw), seconds > 1_000_000_000 {
            let date = Date(timeIntervalSince1970: seconds)
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return raw
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        guard case .venera(let script)? = source else {
            errorText = "当前书源没有提供章节评论。"
            return
        }

        isLoading = true
        errorText = nil
        if reset {
            page = 0
            maxPage = 1
            comments = []
        }

        do {
            let next = page + 1
            let result = try await runtime.chapterComments(
                source: script,
                comicId: comicId,
                epId: chapter.url,
                page: next
            )
            comments += result.comments
            page = next
            maxPage = result.maxPage
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}
