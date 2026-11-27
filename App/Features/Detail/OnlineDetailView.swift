import SwiftUI
import ReaderCore

/// 在线书详情：简介、目录、加入书架、开始阅读、缓存。
struct OnlineDetailView: View {
    let online: OnlineBook

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var router: TabRouter
    @State private var detail: OnlineBook
    @State private var chapters: [OnlineChapter] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var shelfBook: Book?
    @State private var readerBook: Book?
    @State private var showReader = false
    @State private var showCatalog = false
    @State private var pendingChapter: Int?
    @State private var pendingCatalogChapter: Int?
    @State private var isOpening = false
    @State private var isAdding = false
    @State private var isCaching = false
    @State private var cacheUsage: OnlineLibrary.CacheUsage?
    @State private var cachedChapterCount = 0
    @State private var toast: String?

    init(online: OnlineBook) {
        self.online = online
        _detail = State(initialValue: online)
    }

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    actionArea

                    if let errorMessage {
                        Card {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(isComic ? "打不开这本漫画" : "打不开这本书")
                                    .font(Typo.headline)
                                    .foregroundStyle(Palette.danger)
                                Text(errorMessage)
                                    .font(Typo.micro)
                                    .foregroundStyle(Palette.ink3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if !detail.intro.isEmpty { introCard }
                    if !chapters.isEmpty { tocCard }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }

            if isLoading {
                ProgressView().tint(Palette.accent)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            router.detailActive = true
            router.hidesTabBar = true
        }
        .onDisappear {
            router.detailActive = false
            router.hidesTabBar = false
        }
        .task { await load() }
        .fullScreenCover(isPresented: $showReader, onDismiss: {
            refreshCacheUsage()
        }) {
            if let readerBook {
                if readerBook.type == .comic {
                    OnlineComicView(book: readerBook, initialChapter: pendingChapter)
                        .environmentObject(env)
                } else {
                    NovelReaderView(book: readerBook, env: env, initialChapter: pendingChapter)
                        .environmentObject(env)
                }
            } else if let shelfBook {
                if shelfBook.type == .comic {
                    OnlineComicView(book: shelfBook, initialChapter: pendingChapter)
                        .environmentObject(env)
                } else {
                    NovelReaderView(book: shelfBook, env: env, initialChapter: pendingChapter)
                        .environmentObject(env)
                }
            }
        }
        .sheet(isPresented: $showCatalog, onDismiss: {
            guard let index = pendingCatalogChapter else { return }
            pendingCatalogChapter = nil
            startReading(chapter: index)
        }) {
            catalogSheet
                .presentationDetents([.medium, .large])
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.72))
                    .clipShape(Capsule())
                    .padding(.bottom, 26)
                    .transition(.opacity)
            }
        }
    }

    // MARK: 头部

    private var isComic: Bool {
        (try? env.sources.fetch(id: online.sourceId))?.type == 2
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            OnlineCoverView(url: detail.coverUrl, title: detail.name)
                .frame(width: 92, height: 126)

            VStack(alignment: .leading, spacing: 5) {
                Text(detail.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)

                Text([detail.author, detail.kind]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)

                if !detail.lastChapter.isEmpty {
                    Text("最新：\(detail.lastChapter)")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if !detail.wordCount.isEmpty { tag(detail.wordCount) }
                    if !chapters.isEmpty { tag("\(chapters.count) \(isComic ? "话" : "章")") }
                    if shelfBook != nil { tag("在追") }
                    tag("已缓存 \(cachedChapterCount) \(isComic ? "话" : "章")")
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            }
    }

    // MARK: 操作

    private var actionArea: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                Button {
                    startReading(chapter: nil)
                } label: {
                    if isOpening || isAdding {
                        ProgressView().tint(.white)
                    } else {
                        Label("开始阅读", systemImage: "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isOpening || isAdding || chapters.isEmpty)

                if shelfBook == nil {
                    Button {
                        addToShelf()
                    } label: {
                        Text("加入书架")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 96, height: 46)
                            .background(Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                                    .strokeBorder(Palette.lineStrong, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isOpening || isAdding || chapters.isEmpty)
                }
            }

            if let cacheBook = readerBook ?? shelfBook, !isComic {
                HStack(spacing: 9) {
                    Button {
                        cacheAll(cacheBook)
                    } label: {
                        Text(isCaching ? "缓存中…" : "缓存全本")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Palette.lineStrong, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isCaching)

                    Text(cachedChapterCount > 0
                         ? "已缓存 \(cachedChapterCount) 章 · \(cacheUsage?.text ?? "0 KB")"
                         : "还没有缓存正文")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var introCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                Text("简介")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                Text(detail.intro)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.ink2)
                    .lineSpacing(4)
                    .lineLimit(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tocCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("目录")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink2)
                    Spacer()
                    Text("共 \(chapters.count) \(isComic ? "话" : "章")")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                    Button("全部") { showCatalog = true }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.accent)
                }

                ForEach(Array(chapters.prefix(8).enumerated()), id: \.offset) { index, chapter in
                    Button {
                        startReading(chapter: index)
                    } label: {
                        HStack(spacing: 9) {
                            Text("\(index + 1)")
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(Palette.ink3)
                                .frame(width: 26, alignment: .trailing)
                            Text(chapter.name)
                                .font(.system(size: 14.5))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            Image(systemName: "play.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.accent.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if chapters.count > 8 {
                    Button {
                        showCatalog = true
                    } label: {
                        Text("还有 \(chapters.count - 8) \(isComic ? "话" : "章")，查看全部")
                            .font(Typo.micro)
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var catalogSheet: some View {
        NavigationStack {
            List {
                ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        pendingCatalogChapter = index
                        showCatalog = false
                    } label: {
                        HStack {
                            Text(chapter.name)
                                .font(.system(size: 14.5))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(2)
                            Spacer()
                            Image(systemName: "play.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.accent)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle("目录 · \(chapters.count) \(isComic ? "话" : "章")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showCatalog = false }
                }
            }
        }
    }

    // MARK: 数据

    private func load() async {
        if let existing = findExisting() {
            shelfBook = existing
            readerBook = existing
            chapters = (try? OnlineReadingService(
                library: OnlineLibrary(paths: env.paths),
                sources: env.sources,
                client: env.sourceClient,
                venera: env.veneraRuntime
            ).manifest(for: existing).chapters) ?? []
            refreshCacheUsage(for: existing)
            isLoading = false
            return
        }

        guard let source = resolveSource() else {
            errorMessage = "这本书所属的书源已被删除或关闭，无法加载。"
            isLoading = false
            return
        }

        do {
            var info = online
            switch source {
            case .legado(let legado):
                if let enriched = try? await env.sourceClient.bookInfo(source: legado, book: online) {
                    info = enriched
                }
                let toc = try await env.sourceClient.chapters(source: legado, book: info)
                detail = info
                chapters = toc
                errorMessage = toc.isEmpty ? "这个源没有返回目录。" : nil
            case .venera(let script):
                let info = try await env.veneraRuntime.detail(
                    source: script,
                    comicId: online.bookUrl
                )
                detail = OnlineBook(
                    sourceId: script.id,
                    name: info.title,
                    author: info.author,
                    coverUrl: info.coverUrl,
                    intro: info.intro,
                    kind: info.kind,
                    lastChapter: info.lastChapter,
                    bookUrl: info.comicId
                )
                chapters = info.chapters
                errorMessage = chapters.isEmpty ? "这个源没有返回目录。" : nil
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private func findExisting() -> Book? {
        guard let all = try? env.books.all() else { return nil }
        return all.first {
            $0.origin == .remote
                && $0.sourceId == online.sourceId
                && $0.sourceUrl == online.bookUrl
        }
    }

    private func resolveSource() -> SearchTarget? {
        guard let record = try? env.sources.fetch(id: online.sourceId) else { return nil }
        return SourceImportService(repo: env.sources).target(from: record)
    }

    private func startReading(chapter: Int?) {
        guard !isOpening, !isAdding, !chapters.isEmpty else { return }
        pendingChapter = chapter
        // 阅读不是“加入书架”的副作用。已经入库的书可直接打开，其余只准备
        // 临时 Book 和在线清单，退出后不会出现在书架里。
        if let book = shelfBook ?? readerBook {
            readerBook = book
            showReader = true
            return
        }
        isOpening = true
        Task {
            do {
                let book = try await prepareReaderBook()
                await MainActor.run {
                    readerBook = book
                    isOpening = false
                    refreshCacheUsage(for: book)
                    showReader = true
                }
            } catch {
                await MainActor.run {
                    isOpening = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func prepareReaderBook() async throws -> Book {
        guard let source = resolveSource() else {
            throw SourceError.emptyRule("这本书所属的书源已被删除或关闭")
        }
        let service = OnlineBookService(
            client: env.sourceClient,
            library: OnlineLibrary(paths: env.paths),
            venera: env.veneraRuntime,
            paths: env.paths
        )
        var target = detail
        if target.bookUrl.isEmpty { target.bookUrl = online.bookUrl }
        let bundle: OnlineBookBundle
        switch source {
        case .legado(let legado):
            bundle = try await service.prepare(
                target,
                source: legado,
                knownDetail: target,
                knownChapters: chapters
            )
        case .venera(let script):
            bundle = try await service.prepareVenera(
                target, source: script, runtime: env.veneraRuntime
            )
        }
        return env.fallbackCoverIfNeeded(for: bundle.book)
    }

    private func addToShelf() {
        guard !isAdding, !isOpening else { return }
        isAdding = true
        Task {
            do {
                let book = try await preparedBookForShelf()
                if (try? env.books.fetch(id: book.id)) == nil {
                    try env.books.insert(book)
                }
                await MainActor.run {
                    shelfBook = book
                    readerBook = book
                    isAdding = false
                    refreshCacheUsage(for: book)
                    showToast("已加入书架")
                }
            } catch {
                await MainActor.run {
                    isAdding = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    /// 加入书架时优先复用刚才临时阅读的 Book，书 id、进度、封面都不会换一套。
    private func preparedBookForShelf() async throws -> Book {
        if let shelfBook { return shelfBook }
        if let readerBook { return readerBook }
        return try await prepareReaderBook()
    }

    private func cacheAll(_ book: Book) {
        isCaching = true
        Task {
            do {
                _ = try await env.chapterProvider.downloadAll(for: book)
                await MainActor.run {
                    isCaching = false
                    refreshCacheUsage(for: book)
                    showToast("缓存完成")
                }
            } catch {
                await MainActor.run {
                    isCaching = false
                    refreshCacheUsage(for: book)
                    showToast("缓存中断：\(error.localizedDescription)")
                }
            }
        }
    }

    private func refreshCacheUsage(for book: Book? = nil) {
        guard let target = book ?? readerBook ?? shelfBook else { return }
        cacheUsage = env.chapterProvider.cacheUsage(for: target)
        cachedChapterCount = env.onlineReading.cachedChapterCount(for: target)
    }

    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.18)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.18)) { toast = nil }
        }
    }
}
