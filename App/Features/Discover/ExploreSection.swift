import SwiftUI
import ReaderCore

/// 发现页的「推荐 / 热门 / 榜单」。
/// 同时支持 legado 的 exploreUrl 和 Venera 的 explore 页；没有发现规则的源不在这里出现。
struct ExploreSection: View {
    var kind: SearchViewModel.Kind = .novel

    @EnvironmentObject private var env: AppEnvironment

    @State private var targets: [SearchTarget] = []
    @State private var selectedTargetId: String?

    // legado
    @State private var categories: [ExploreCategory] = []
    @State private var selectedCategory: ExploreCategory?
    @State private var books: [OnlineBook] = []

    // Venera
    @State private var explorePages: [VeneraExplorePage] = []
    @State private var selectedPage: VeneraExplorePage?
    @State private var sections: [VeneraExploreSection] = []
    @State private var expandedSection: VeneraExploreSection?

    @State private var isLoading = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    private var selectedTarget: SearchTarget? {
        targets.first { $0.id == selectedTargetId }
    }

    private var selectedVenera: VeneraSource? {
        if case .venera(let source)? = selectedTarget { return source }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(kind == .comic ? "漫画发现" : "榜单 / 分类")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                if !targets.isEmpty { sourcePicker }
            }

            if targets.isEmpty {
                Text(kind == .comic
                     ? "已启用的漫画源里没有提供发现页的源。搜索仍然可用；导入带发现页的 Venera 源后会显示推荐和热门。"
                     : "已启用的书源里没有带发现规则的源。搜索仍然可用。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
                    .lineSpacing(2)
            } else {
                if !categories.isEmpty { categoryChips }
                if explorePages.count > 1 { pageChips }
                content
            }
        }
        .onAppear(perform: loadSources)
        .onChange(of: kind) { _ in
            reset()
            loadSources()
        }
        .sheet(item: $expandedSection) { section in
            VeneraSectionGridSheet(section: section)
        }
    }

    // MARK: 选择器

    private var sourcePicker: some View {
        Menu {
            ForEach(targets) { target in
                Button {
                    select(target: target)
                } label: {
                    if target.id == selectedTargetId {
                        Label(target.name, systemImage: "checkmark")
                    } else {
                        Text(target.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedTarget?.name ?? "选择源")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Palette.surfaceAlt)
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(Palette.line, lineWidth: 1)
            }
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

    private var pageChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(explorePages) { page in
                    Button {
                        select(page: page)
                    } label: {
                        Chip(title: page.title, isOn: page.id == selectedPage?.id)
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
                Text("正在取推荐…")
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
                Button("重试") { retry() }
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
        } else if selectedVenera != nil {
            if sections.isEmpty {
                Text("这个发现页没有返回内容。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
                    .padding(.vertical, 8)
            } else {
                veneraContent
            }
        } else if books.isEmpty {
            Text("这个分类暂时没有取到书。")
                .font(Typo.micro)
                .foregroundStyle(Palette.ink3)
                .padding(.vertical, 8)
        } else {
            bookGrid(books)
        }
    }

    private var veneraContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(section.title)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                        if section.books.count > 6 {
                            Button {
                                expandedSection = section
                            } label: {
                                HStack(spacing: 2) {
                                    Text("全部 \(section.books.count)")
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.ink3)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ], spacing: 12) {
                        ForEach(Array(section.books.prefix(6))) { book in
                            NavigationLink {
                                OnlineDetailView(online: book)
                            } label: {
                                ExploreBookCard(book: book)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func bookGrid(_ list: [OnlineBook]) -> some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ], spacing: 12) {
            ForEach(list) { book in
                NavigationLink {
                    OnlineDetailView(online: book)
                } label: {
                    ExploreBookCard(book: book)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    // MARK: 数据

    private func reset() {
        task?.cancel()
        targets = []
        selectedTargetId = nil
        categories = []
        selectedCategory = nil
        books = []
        explorePages = []
        selectedPage = nil
        sections = []
        isLoading = false
        errorText = nil
    }

    private func loadSources() {
        guard targets.isEmpty else { return }
        let all = (try? SourceImportService(repo: env.sources).enabledTargets()) ?? []
        let wantedComic = kind == .comic
        targets = all.filter { target in
            guard target.isComic == wantedComic else { return false }
            switch target {
            case .legado(let source):
                return !source.exploreUrl.isNilOrEmpty && !source.ruleExplore.bookList.isEmpty
            case .venera:
                // Venera 的 explore 写在 JS 里，只有真正打开时才知道有没有；
                // 先列出来，点进去没有会提示，而不是整类源都消失。
                return true
            }
        }

        guard let first = targets.first(where: { target in
            // 漫画默认先展示「拷贝漫画」这类首页源；没有就退回第一个。
            kind == .comic && target.name.contains("拷贝")
        }) ?? targets.first else { return }
        select(target: first)
    }

    private func select(target: SearchTarget) {
        task?.cancel()
        selectedTargetId = target.id
        categories = []
        selectedCategory = nil
        books = []
        explorePages = []
        selectedPage = nil
        sections = []
        errorText = nil

        switch target {
        case .legado(let source):
            isLoading = false
            categories = env.sourceClient.categories(source: source)
            if let first = categories.first {
                select(category: first)
            } else {
                errorText = "这个源没有可用的发现分类。"
            }
        case .venera(let source):
            loadVeneraPages(source: source)
        }
    }

    private func select(category: ExploreCategory) {
        selectedCategory = category
        loadBooks()
    }

    private func select(page: VeneraExplorePage) {
        selectedPage = page
        guard let source = selectedVenera else { return }
        loadVenera(source: source, page: page)
    }

    private func retry() {
        if let page = selectedPage, let source = selectedVenera {
            loadVenera(source: source, page: page)
        } else if let category = selectedCategory,
                  case .legado(let source)? = selectedTarget {
            selectedCategory = category
            loadBooks(source: source, category: category)
        } else if let target = selectedTarget {
            select(target: target)
        }
    }

    private func loadVeneraPages(source: VeneraSource) {
        isLoading = true
        errorText = nil
        task = Task {
            do {
                let pages = try await env.veneraRuntime.explorePages(source: source, timeout: 25)
                guard !pages.isEmpty else {
                    await MainActor.run {
                        isLoading = false
                        errorText = "这个源没有可用的发现页。"
                    }
                    return
                }
                let first = pages[0]
                let loaded = try await env.veneraRuntime.explore(source: source, page: first, timeout: 35)
                if Task.isCancelled { return }
                await MainActor.run {
                    explorePages = pages
                    selectedPage = first
                    sections = loaded
                    isLoading = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isLoading = false
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func loadVenera(source: VeneraSource, page: VeneraExplorePage) {
        task?.cancel()
        isLoading = true
        errorText = nil
        task = Task {
            do {
                let loaded = try await env.veneraRuntime.explore(source: source, page: page, timeout: 35)
                if Task.isCancelled { return }
                await MainActor.run {
                    sections = loaded
                    isLoading = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    sections = []
                    isLoading = false
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func loadBooks() {
        guard let category = selectedCategory,
              case .legado(let source)? = selectedTarget else { return }
        loadBooks(source: source, category: category)
    }

    private func loadBooks(source: LegadoSource, category: ExploreCategory) {
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

// MARK: - 卡片

private struct ExploreBookCard: View {
    let book: OnlineBook

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            OnlineCoverView(url: book.coverUrl, title: book.name)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(book.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(book.author.isEmpty ? " " : book.author)
                .font(.system(size: 10))
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
        }
    }
}

private struct VeneraSectionGridSheet: View {
    let section: VeneraExploreSection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 14) {
                    ForEach(section.books) { book in
                        NavigationLink {
                            OnlineDetailView(online: book)
                        } label: {
                            ExploreBookCard(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Palette.bg)
            .navigationTitle(section.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
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
