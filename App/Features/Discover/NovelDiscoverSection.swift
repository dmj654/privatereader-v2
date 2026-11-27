import SwiftUI
import ReaderCore

/// 小说发现：小说源没有 explore 规则时，用分类关键词搜索形成可浏览的发现流。
/// 不伪造榜单，也不和漫画源串台。
struct NovelDiscoverSection: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var targets: [SearchTarget] = []
    @State private var selectedID: String?
    @State private var genre = "都市"
    @State private var books: [OnlineBook] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadTask: Task<Void, Never>?

    private static let genres = ["都市", "玄幻", "仙侠", "科幻", "历史", "悬疑", "游戏", "言情"]

    private var selectedTarget: SearchTarget? {
        guard let selectedID else { return nil }
        return targets.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            genreChips
            content
        }
        .task { loadSources() }
        .onDisappear { loadTask?.cancel() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("小说发现")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("选分类浏览，或直接在搜索页搜书名")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 8)
            if targets.count > 1 {
                Menu {
                    ForEach(targets) { target in
                        Button {
                            selectedID = target.id
                            load(force: false)
                        } label: {
                            if target.id == selectedID {
                                Label(target.name, systemImage: "checkmark")
                            } else {
                                Text(target.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedTarget?.name ?? "选择源")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Palette.accent.opacity(0.08))
                    .clipShape(Capsule())
                }
            }
        }
    }

    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.genres, id: \.self) { item in
                    Button {
                        genre = item
                        load(force: false)
                    } label: {
                        Text(item)
                            .font(.system(size: 12, weight: genre == item ? .semibold : .regular))
                            .foregroundStyle(genre == item ? .white : Palette.ink2)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(genre == item ? Palette.accent : Palette.surfaceAlt)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if targets.isEmpty {
            emptyCard("还没有可用的小说源", detail: "先到「我的 → 书源管理」导入并启用小说源。")
        } else if isLoading {
            HStack {
                Spacer()
                ProgressView().tint(Palette.accent)
                Text("正在按「\(genre)」查找")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                Spacer()
            }
            .frame(height: 90)
        } else if let errorMessage {
            VStack(spacing: 10) {
                emptyCard("这次没取到内容", detail: errorMessage)
                Button("重试") { load(force: true) }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            .frame(maxWidth: .infinity)
        } else if books.isEmpty {
            emptyCard("这个分类暂时没有结果", detail: "换一个分类，或到搜索页直接搜书名。")
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 11),
                                GridItem(.flexible(), spacing: 11),
                                GridItem(.flexible(), spacing: 11)],
                      spacing: 16) {
                ForEach(books) { book in
                    NavigationLink {
                        OnlineDetailView(online: book)
                    } label: {
                        NovelDiscoverCard(book: book)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
    }

    private func emptyCard(_ title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: "books.vertical")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.ink3)
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Palette.ink2)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func loadSources() {
        let all = (try? SourceImportService(repo: env.sources).enabledTargets()) ?? []
        let novel = all.filter { !$0.isComic && $0.hasSearchEndpoint }
        targets = novel
        if selectedID == nil || !novel.contains(where: { $0.id == selectedID }) {
            selectedID = novel.first?.id
        }
        if selectedID != nil, books.isEmpty { load(force: false) }
    }

    private func load(force: Bool) {
        loadTask?.cancel()
        guard let target = selectedTarget else { return }
        guard let source = target.legadoSource else {
            errorMessage = "这个源暂不支持分类发现"
            books = []
            return
        }
        let key = "\(target.id)|\(genre)" as NSString
        if !force, let cached = NovelDiscoverCache.shared.books(for: key) {
            books = cached
            errorMessage = nil
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil
        let genre = self.genre
        loadTask = Task {
            do {
                let result = try await env.sourceClient.search(source: source, key: genre, page: 1)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    books = result
                    NovelDiscoverCache.shared.store(result, for: key)
                    isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    books = []
                    errorMessage = readable(error)
                    isLoading = false
                }
            }
        }
    }

    private func readable(_ error: Error) -> String {
        if let source = error as? SourceError {
            switch source {
            case .emptyRule(let field): return "书源缺少「\(field)」规则"
            case .invalidURL: return "书源地址无效"
            case .http(let code): return "站点返回 HTTP \(code)"
            case .emptyContent: return "这个分类没有取到内容"
            case .decodingFailed: return "网页编码无法识别"
            case .cancelled: return "已取消"
            }
        }
        return error.localizedDescription
    }
}

private struct NovelDiscoverCard: View {
    let book: OnlineBook

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.surfaceAlt)
                if let url = URL(string: book.coverUrl), !book.coverUrl.isEmpty {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(height: 142)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(book.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)

            Text(book.author.isEmpty ? "未知作者" : book.author)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
        }
    }

    private var placeholder: some View {
        Image(systemName: "book.closed")
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(Palette.ink3)
    }
}

private final class NovelDiscoverCache {
    static let shared = NovelDiscoverCache()
    private let cache = NSCache<NSString, NovelDiscoverBox>()

    func books(for key: NSString) -> [OnlineBook]? {
        cache.object(forKey: key)?.books
    }

    func store(_ books: [OnlineBook], for key: NSString) {
        let box = NovelDiscoverBox()
        box.books = books
        cache.setObject(box, forKey: key)
    }
}

private final class NovelDiscoverBox {
    var books: [OnlineBook] = []
}
