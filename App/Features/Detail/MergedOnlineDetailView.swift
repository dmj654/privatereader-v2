import SwiftUI
import ReaderCore

/// 合并结果的详情页。
///
/// 点书立刻进这一页：标题、封面、简介先用搜索结果填上，
/// 源和目录在后台补，页面不再整屏转圈。
struct MergedOnlineDetailView: View {
    let book: SearchViewModel.MergedBook

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var router: TabRouter
    @StateObject private var model: MergedDetailModel
    @State private var showSourcePicker = false
    @State private var showCatalog = false
    @State private var showReader = false
    @State private var pendingChapter: Int?
    @State private var isOpening = false

    init(book: SearchViewModel.MergedBook) {
        self.book = book
        _model = StateObject(wrappedValue: MergedDetailModel(book: book))
    }

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    sourceLine
                    actionArea
                    if !model.intro.isEmpty { introCard }
                    tocSection
                }
                .padding(.horizontal, Spacing.l)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(env: env) }
        .onAppear {
            router.detailActive = true
            router.hidesTabBar = true
        }
        .onDisappear {
            router.detailActive = false
            router.hidesTabBar = false
        }
        .sheet(isPresented: $showSourcePicker) {
            sourcePicker
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCatalog) {
            catalogSheet
                .presentationDetents([.medium, .large])
        }
        .overlay {
            if isOpening {
                ProgressView()
                    .tint(Palette.accent)
                    .padding(18)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Shadow.card, radius: 8, y: 3)
            }
        }
        .fullScreenCover(isPresented: $showReader, onDismiss: {
            model.refreshCacheCount(env: env)
        }) {
            if let readerBook = model.readerBook ?? model.shelfBook {
                if readerBook.type == .comic {
                    OnlineComicView(book: readerBook, initialChapter: pendingChapter)
                        .environmentObject(env)
                } else {
                    NovelReaderView(book: readerBook, env: env, initialChapter: pendingChapter)
                        .environmentObject(env)
                }
            }
        }
    }

    // MARK: 头部

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            OnlineCoverView(url: model.coverUrl, title: book.name)
                .frame(width: 92, height: 126)

            VStack(alignment: .leading, spacing: 5) {
                Text(model.name.isEmpty ? book.name : model.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)

                Text([model.author, book.kindText]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)

                if !model.lastChapter.isEmpty {
                    Text("最新：\(model.lastChapter)")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if !model.chapters.isEmpty {
                        tag("\(model.chapters.count) \(book.isComic ? "话" : "章")")
                    }
                    tag("已缓存 \(model.cachedChapterCount) \(book.isComic ? "话" : "章")")
                    tag("\(book.entries.count) 个源")
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

    // MARK: 来源

    private var sourceLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11))
                .foregroundStyle(Palette.accent)

            if model.chosen == nil {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                    Text("正在选择可用的源…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink3)
                } else {
                    Text(model.errorMessage ?? "没有可用的源")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.danger)
                        .lineLimit(2)
                }
            } else {
                Text("当前源：\(model.sourceName)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if model.shelfBook == nil, model.chosen != nil {
                Button {
                    showSourcePicker = true
                } label: {
                    Text("换源")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Palette.accentSoft)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else if model.shelfBook != nil {
                Text("已加入书架")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink3)
            }
        }
        .padding(11)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1)
        }
    }

    // MARK: 操作

    private var actionArea: some View {
        HStack(spacing: 10) {
            Button {
                startReading(chapter: nil)
            } label: {
                if model.isPreparing || model.isAdding {
                    ProgressView().tint(.white)
                } else {
                    Text("阅读")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isPreparing || model.isAdding || model.chosen == nil || model.chapters.isEmpty)

            if model.shelfBook == nil {
                Button {
                    Task { _ = await model.ensureShelf(env: env) }
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
                .disabled(model.isPreparing || model.isAdding || model.chosen == nil)
            }
        }
    }

    private var introCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                Text("简介")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                Text(model.intro)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.ink2)
                    .lineSpacing(4)
                    .lineLimit(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 目录

    @ViewBuilder
    private var tocSection: some View {
        if !model.chapters.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("目录")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink2)
                        Spacer()
                        Text("共 \(model.chapters.count) \(book.isComic ? "话" : "章")")
                            .font(Typo.micro)
                            .foregroundStyle(Palette.ink3)
                        Button("全部") { showCatalog = true }
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Palette.accent)
                    }

                    ForEach(Array(model.chapters.prefix(8).enumerated()), id: \.offset) { index, chapter in
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

                    if model.chapters.count > 8 {
                        Button {
                            showCatalog = true
                        } label: {
                            Text("还有 \(model.chapters.count - 8) \(book.isComic ? "话" : "章")，查看全部")
                                .font(Typo.micro)
                                .foregroundStyle(Palette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在获取目录…")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
            }
            .padding(.vertical, 6)
        }
    }

    private var catalogSheet: some View {
        NavigationStack {
            List {
                ForEach(Array(model.chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        showCatalog = false
                        startReading(chapter: index)
                    } label: {
                        HStack {
                            Text(chapter.name)
                                .font(.system(size: 14.5))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(2)
                            Spacer()
                            Image(systemName: "play.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.accent.opacity(0.8))
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("目录 · \(model.chapters.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showCatalog = false }
                }
            }
        }
    }

    // MARK: 换源

    private var sourcePicker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(book.entries.enumerated()), id: \.offset) { index, entry in
                        Button {
                            showSourcePicker = false
                            Task { await model.pick(sourceId: entry.sourceId, env: env) }
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(sourceName(index))
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Palette.ink)
                                        .lineLimit(1)
                                    Text(entry.lastChapter.isEmpty ? "最新章节未知" : entry.lastChapter)
                                        .font(Typo.micro)
                                        .foregroundStyle(Palette.ink3)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if entry.sourceId == model.chosen?.sourceId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Palette.accent)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("换源会重新取目录；选到取不到目录的源会提示你换回来。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showSourcePicker = false }
                }
            }
        }
    }

    private func sourceName(_ index: Int) -> String {
        guard book.sourceNames.indices.contains(index) else { return "书源 \(index + 1)" }
        return book.sourceNames[index]
    }

    // MARK: 动作

    private func startReading(chapter: Int?) {
        pendingChapter = chapter
        Task {
            isOpening = true
            if let book = await model.prepareForReading(env: env) {
                isOpening = false
                showReader = true
            } else {
                isOpening = false
            }
        }
    }
}

// MARK: - 详情模型

@MainActor
final class MergedDetailModel: ObservableObject {
    let book: SearchViewModel.MergedBook

    @Published var chosen: OnlineBook?
    @Published var sourceName = ""
    @Published var chapters: [OnlineChapter] = []
    @Published var intro = ""
    @Published var coverUrl = ""
    @Published var name = ""
    @Published var author = ""
    @Published var lastChapter = ""
    @Published var isLoading = true
    @Published var isAdding = false
    @Published var isPreparing = false
    @Published var errorMessage: String?
    @Published var shelfBook: Book?
    /// 只用于阅读、不写入书架的临时 Book；加入书架时会复用同一个 id。
    @Published var readerBook: Book?
    @Published var cachedChapterCount = 0

    private var source: SearchTarget?

    init(book: SearchViewModel.MergedBook) {
        self.book = book
        self.name = book.name
        self.author = book.author
        self.coverUrl = book.coverUrl
        self.lastChapter = book.lastChapter
        self.intro = book.entries.first(where: { !$0.intro.isEmpty })?.intro ?? ""
    }

    func load(env: AppEnvironment, preferred: String? = nil) async {
        // 从阅读器返回 / 视图重建时不要重新探测一遍，用户看到的还是同一个源。
        if preferred == nil, chosen != nil {
            isLoading = false
            return
        }
        // 同一本书本次运行内看过就直接复用，不再重新探测。
        if preferred == nil,
           let cached = MergedDetailCache.shared.snapshot(for: book) {
            apply(cached.chosen, source: cached.source, chapters: cached.chapters)
            name = cached.name
            author = cached.author
            coverUrl = cached.coverUrl
            lastChapter = cached.lastChapter
            intro = cached.intro
            shelfBook = findExisting(cached.chosen, env: env)
            readerBook = shelfBook
            if let readerBook {
                cachedChapterCount = env.onlineReading.cachedChapterCount(for: readerBook)
            }
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil
        chosen = nil
        chapters = []
        readerBook = nil
        cachedChapterCount = 0

        let ordered = orderedEntries(preferred: preferred)
        var candidates: [(OnlineBook, SearchTarget, [OnlineChapter])] = []
        var tried = 0

        // 先把候选源的目录都取回来，按章节数从多到少排；再逐个验证首章可读。
        // 先碰上一个「章节少但能读」的源就停，会错过更完整的版本。
        for entry in ordered.prefix(4) {
            guard let target = resolve(entry.sourceId, env: env) else { continue }
            tried += 1
            switch target {
            case .legado(let legado):
                if let toc = try? await env.sourceClient.chapters(source: legado, book: entry),
                   !toc.isEmpty {
                    candidates.append((entry, target, toc))
                }
            case .venera(let script):
                if let detail = try? await env.veneraRuntime.detail(
                    source: script, comicId: entry.bookUrl
                ), !detail.chapters.isEmpty {
                    let enriched = OnlineBook(
                        sourceId: script.id,
                        name: detail.title,
                        author: detail.author,
                        coverUrl: detail.coverUrl,
                        intro: detail.intro,
                        kind: detail.kind,
                        lastChapter: detail.lastChapter,
                        bookUrl: detail.comicId
                    )
                    candidates.append((enriched, target, detail.chapters))
                }
            }
        }

        candidates.sort { $0.2.count > $1.2.count }

        for candidate in candidates {
            if await canRead(source: candidate.1, entry: candidate.0,
                             chapter: candidate.2[0], env: env) {
                apply(candidate.0, source: candidate.1, chapters: candidate.2)
                shelfBook = findExisting(candidate.0, env: env)
                readerBook = shelfBook
                if let readerBook {
                    cachedChapterCount = env.onlineReading.cachedChapterCount(for: readerBook)
                }
                saveToCache()
                isLoading = false
                return
            }
        }

        if let fallback = candidates.first {
            // 都读不了也别让页面空着：给章节最多的那个，读的时候再报具体错误。
            apply(fallback.0, source: fallback.1, chapters: fallback.2)
            shelfBook = findExisting(fallback.0, env: env)
            readerBook = shelfBook
            if let readerBook {
                cachedChapterCount = env.onlineReading.cachedChapterCount(for: readerBook)
            }
            saveToCache()
            isLoading = false
        } else {
            isLoading = false
            errorMessage = tried == 0
                ? "这些源都已被删除或关闭，换一本书试试。"
                : "这几个源都没取到目录。可以稍后重试，或换一个关键词。"
        }
    }

    func pick(sourceId: String, env: AppEnvironment) async {
        await load(env: env, preferred: sourceId)
        readerBook = nil
        if chosen != nil { saveToCache() }
    }

    func refreshCacheCount(env: AppEnvironment) {
        guard let target = readerBook ?? shelfBook else {
            cachedChapterCount = 0
            return
        }
        cachedChapterCount = env.onlineReading.cachedChapterCount(for: target)
    }

    /// 打开阅读器：没有加入书架时只准备临时清单，不插数据库。
    func prepareForReading(env: AppEnvironment) async -> Book? {
        if let readerBook { return readerBook }
        if let shelfBook { return shelfBook }
        guard let chosen, let source else {
            errorMessage = "还没有选中可用的源。"
            return nil
        }

        isPreparing = true
        defer { isPreparing = false }

        if let existing = findExisting(chosen, env: env) {
            shelfBook = existing
            readerBook = existing
            cachedChapterCount = env.onlineReading.cachedChapterCount(for: existing)
            return existing
        }

        do {
            let service = OnlineBookService(
                client: env.sourceClient,
                library: OnlineLibrary(paths: env.paths),
                venera: env.veneraRuntime,
                paths: env.paths
            )
            let bundle: OnlineBookBundle
            switch source {
            case .legado(let legado):
                bundle = try await service.prepare(
                    chosen,
                    source: legado,
                    knownDetail: chosen,
                    knownChapters: chapters
                )
            case .venera(let script):
                bundle = try await service.prepareVenera(
                    chosen, source: script, runtime: env.veneraRuntime
                )
            }
            let book = env.fallbackCoverIfNeeded(for: bundle.book)
            readerBook = book
            cachedChapterCount = env.onlineReading.cachedChapterCount(for: book)
            return book
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// 加入书架（已加过就复用那本）。阅读器先用临时 Book，用户点“加入书架”
    /// 时才把同一个 id 写进数据库，进度和封面不丢。
    func ensureShelf(env: AppEnvironment) async -> Book? {
        if let shelfBook { return shelfBook }
        isAdding = true
        defer { isAdding = false }
        if let readerBook {
            do {
                if (try? env.books.fetch(id: readerBook.id)) == nil {
                    try env.books.insert(readerBook)
                }
                shelfBook = readerBook
                return readerBook
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return nil
            }
        }
        guard let book = await prepareForReading(env: env) else { return nil }
        do {
            if (try? env.books.fetch(id: book.id)) == nil {
                try env.books.insert(book)
            }
            shelfBook = book
            return book
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// 取第一章确认正文 / 图片真的能拿到。只看目录，很多死源也能骗过。
    private func canRead(source: SearchTarget,
                         entry: OnlineBook,
                         chapter: OnlineChapter,
                         env: AppEnvironment) async -> Bool {
        switch source {
        case .legado(let legado):
            if legado.isComic {
                let pages = try? await env.sourceClient.comicPages(source: legado, chapter: chapter)
                return !(pages?.isEmpty ?? true)
            }
            let text = try? await env.sourceClient.content(source: legado, chapter: chapter)
            return !(text?.isEmpty ?? true)
        case .venera(let script):
            let pages = try? await env.veneraRuntime.pages(
                source: script,
                comicId: entry.bookUrl,
                epId: chapter.url
            )
            return !(pages?.isEmpty ?? true)
        }
    }

    private func saveToCache() {
        guard let chosen, let source else { return }
        MergedDetailCache.shared.store(
            MergedDetailCache.Snapshot(
                chosen: chosen,
                source: source,
                sourceName: sourceName,
                chapters: chapters,
                intro: intro,
                coverUrl: coverUrl,
                name: name,
                author: author,
                lastChapter: lastChapter,
                savedAt: Date()
            ),
            for: book
        )
    }

    private func apply(_ entry: OnlineBook, source: SearchTarget, chapters: [OnlineChapter]) {
        chosen = entry
        self.source = source
        sourceName = source.name
        self.chapters = chapters
        readerBook = nil
        shelfBook = nil
        cachedChapterCount = 0
        name = entry.name.isEmpty ? book.name : entry.name
        author = entry.author.isEmpty ? book.author : entry.author
        coverUrl = entry.coverUrl.isEmpty ? book.coverUrl : entry.coverUrl
        lastChapter = entry.lastChapter.isEmpty ? book.lastChapter : entry.lastChapter

        intro = entry.intro
        if intro.isEmpty {
            intro = book.entries.first(where: { !$0.intro.isEmpty })?.intro ?? ""
        }
    }

    private func orderedEntries(preferred: String?) -> [OnlineBook] {
        var list = book.entries
        if let preferred,
           let index = list.firstIndex(where: { $0.sourceId == preferred }) {
            let entry = list.remove(at: index)
            list.insert(entry, at: 0)
            return list
        }

        return list.sorted { lhs, rhs in
            score(lhs) > score(rhs)
        }
    }

    private func score(_ entry: OnlineBook) -> Int {
        var value = 0
        if !entry.lastChapter.isEmpty { value += 2 }
        if !entry.intro.isEmpty { value += 1 }
        if !entry.coverUrl.isEmpty { value += 1 }
        return value
    }

    private func resolve(_ id: String, env: AppEnvironment) -> SearchTarget? {
        guard let record = try? env.sources.fetch(id: id) else { return nil }
        return SourceImportService(repo: env.sources).target(from: record)
    }

    private func findExisting(_ entry: OnlineBook, env: AppEnvironment) -> Book? {
        guard let all = try? env.books.all() else { return nil }
        return all.first {
            $0.origin == .remote
                && $0.sourceId == entry.sourceId
                && $0.sourceUrl == entry.bookUrl
        }
    }
}
