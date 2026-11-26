import SwiftUI
import ReaderCore

/// 发现页的「榜单 / 分类」。只展示自带 exploreUrl 的源；
/// 没有这类规则的源不在这里出现，免得点进去一片空白。
struct ExploreSection: View {
    var kind: SearchViewModel.Kind = .novel

    @EnvironmentObject private var env: AppEnvironment

    @State private var sources: [LegadoSource] = []
    @State private var selectedSourceId: String?
    @State private var categories: [ExploreCategory] = []
    @State private var selectedCategory: ExploreCategory?
    @State private var books: [OnlineBook] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    private var selectedSource: LegadoSource? {
        sources.first { $0.id == selectedSourceId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("榜单 / 分类")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(Palette.ink)

            if sources.isEmpty {
                Text("已启用的书源里没有带发现规则的源。搜索仍然可用。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
            } else {
                sourceChips
                if !categories.isEmpty { categoryChips }
                content
            }
        }
        .onAppear(perform: loadSources)
        .onChange(of: kind) { _ in
            sources = []
            selectedSourceId = nil
            categories = []
            selectedCategory = nil
            books = []
            errorText = nil
            loadSources()
        }
    }

    // MARK: 选择器

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sources) { source in
                    Button {
                        select(source: source)
                    } label: {
                        Chip(title: source.name, isOn: source.id == selectedSourceId)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { category in
                    Button {
                        select(category: category)
                    } label: {
                        Chip(title: category.name, isOn: category.id == selectedCategory?.id)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 结果

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在取榜单…")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        } else if let errorText {
            HStack(spacing: 8) {
                Text(errorText)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("重试") { loadBooks() }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            .padding(11)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            }
        } else if books.isEmpty {
            Text("这个分类暂时没有取到书。")
                .font(Typo.micro)
                .foregroundStyle(Palette.ink3)
                .padding(.vertical, 8)
        } else {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                ForEach(books) { book in
                    NavigationLink {
                        OnlineDetailView(online: book)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            OnlineCoverView(url: book.coverUrl, title: book.name)
                                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                            Text(book.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            Text(book.author.isEmpty ? " " : book.author)
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.ink3)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: 数据

    private func loadSources() {
        guard sources.isEmpty else { return }
        let all = (try? SourceImportService(repo: env.sources).enabledSources()) ?? []
        let wantedComic = kind == .comic
        sources = all.filter {
            $0.isComic == wantedComic
                && !$0.exploreUrl.isNilOrEmpty
                && !$0.ruleExplore.bookList.isEmpty
        }

        guard let first = sources.first else { return }
        select(source: first)
    }

    private func select(source: LegadoSource) {
        selectedSourceId = source.id
        categories = env.sourceClient.categories(source: source)
        if let first = categories.first {
            select(category: first)
        } else {
            selectedCategory = nil
            books = []
            errorText = "这个源没有可用的发现分类。"
        }
    }

    private func select(category: ExploreCategory) {
        selectedCategory = category
        loadBooks()
    }

    private func loadBooks() {
        guard let source = selectedSource, let category = selectedCategory else { return }
        task?.cancel()
        isLoading = true
        errorText = nil

        task = Task {
            do {
                let result = try await env.sourceClient.explore(source: source, category: category)
                if Task.isCancelled { return }
                await MainActor.run {
                    books = result
                    isLoading = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    books = []
                    isLoading = false
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}
