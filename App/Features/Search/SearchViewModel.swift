import SwiftUI
import ReaderCore

/// 搜索页状态。
///
/// 结果按「书名 + 作者」合并：同一本书在不同源里的条目收进一本书里，
/// 界面上只出现一本书，点进去直接看详情，需要时再换源。
@MainActor
final class SearchViewModel: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case novel
        case comic

        var id: String { rawValue }
        var title: String { self == .novel ? "小说" : "漫画" }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case sources
        case name

        var id: String { rawValue }
        var title: String { self == .sources ? "按源数" : "按书名" }
    }

    struct Filters: Equatable {
        /// 书名或作者必须与关键词完全一致
        var exactMatch = false
        /// 至少被这么多个源收录
        var minSources = 1
        var sort: SortMode = .sources
    }

    struct MergedBook: Identifiable {
        let id: String
        var name: String
        var author: String
        var coverUrl: String
        var kindText: String
        var lastChapter: String
        var entries: [OnlineBook]
        var sourceNames: [String]
        var isComic: Bool
    }

    @Published var query = ""
    @Published private(set) var kind: Kind = .novel
    @Published private(set) var books: [MergedBook] = []
    @Published private(set) var history: [String] = []
    @Published private(set) var isSearching = false
    @Published private(set) var totalSources = 0
    @Published private(set) var finishedSources = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var hasSearched = false
    @Published private(set) var sourceNames: [String: String] = [:]
    @Published var errorMessage: String?
    @Published var filters = Filters()

    private var task: Task<Void, Never>?
    private var coordinator: SearchCoordinator?
    private var searchedKey = ""
    private var failedSources: [SearchTarget] = []
    private static let historyKey = "search.history"

    /// 每个分类各自留一份结果。来回切「小说/漫画」不该重新搜、也不该白屏。
    private struct CachedResults {
        var query: String
        var books: [MergedBook]
        var total: Int
        var finished: Int
        var failed: [SearchTarget]
        var failedCount: Int
        var sourceNames: [String: String]
    }
    private var cache: [Kind: CachedResults] = [:]

    init() {
        history = UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
    }

    var hasResults: Bool { !books.isEmpty }

    var activeFilterCount: Int {
        var count = 0
        if filters.exactMatch { count += 1 }
        if filters.minSources > 1 { count += 1 }
        if filters.sort != .sources { count += 1 }
        return count
    }

    /// 应用筛选后的展示列表。
    var visibleBooks: [MergedBook] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = books

        if filters.exactMatch, !key.isEmpty {
            list = list.filter {
                $0.name.lowercased() == key
                    || $0.author.lowercased() == key
                    || $0.entries.contains { matchesID($0.bookUrl, key: key) }
            }
        }
        if filters.minSources > 1 {
            list = list.filter { $0.entries.count >= filters.minSources }
        }

        switch filters.sort {
        case .sources:
            list.sort { lhs, rhs in
                if lhs.entries.count != rhs.entries.count {
                    return lhs.entries.count > rhs.entries.count
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return list
    }

    private func matchesID(_ bookUrl: String, key: String) -> Bool {
        let url = bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !url.isEmpty, !key.isEmpty else { return false }
        let strippedURL = url.hasPrefix("jm") ? String(url.dropFirst(2)) : url
        let strippedKey = key.hasPrefix("jm") ? String(key.dropFirst(2)) : key
        return url == key || strippedURL == strippedKey
    }

    // MARK: 搜索

    func search(env: AppEnvironment, force: Bool = false) {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard force || key != searchedKey || books.isEmpty else { return }

        task?.cancel()
        searchedKey = key
        remember(key)

        isSearching = true
        hasSearched = true
        errorMessage = nil
        books = []
        failedCount = 0
        finishedSources = 0
        totalSources = 0
        failedSources = []

        let wantedComic = kind == .comic

        task = Task { [weak self] in
            guard let self else { return }
            let sources: [SearchTarget]
            do {
                // 两千多个源的 JSON 解析必须离开主线程：放在主线程会让
                // 「切分类 / 点搜索」先卡一两秒，看起来就是点了没反应。
                let repo = env.sources
                sources = try await Task.detached(priority: .userInitiated) {
                    try SourceImportService(repo: repo).enabledTargets()
                }.value.filter { $0.isComic == wantedComic }
            } catch {
                self.isSearching = false
                self.errorMessage = "读取书源失败：\(error.localizedDescription)"
                return
            }

            guard !sources.isEmpty else {
                self.isSearching = false
                self.errorMessage = wantedComic
                    ? "还没有启用的漫画源。去「发现 → 书源」导入漫画源。"
                    : "还没有启用的小说源。去「发现 → 书源」导入书源。"
                return
            }

            self.totalSources = sources.count
            self.finishedSources = 0

            let coordinator = SearchCoordinator(client: env.sourceClient,
                                               venera: env.veneraRuntime)
            self.coordinator = coordinator

            for await result in await coordinator.search(sources: sources, key: key) {
                if Task.isCancelled { return }
                self.apply(result)
            }

            self.isSearching = false
            if self.failedCount == 0 && self.books.isEmpty && self.finishedSources > 0 {
                self.errorMessage = "已执行 \(self.finishedSources) 个源，但规则都解析出 0 条。请到「发现 → 书源」对这几个源点「测一下」，看具体返回。"
            }
            self.saveCache()
        }
    }

    func setKind(_ newKind: Kind, env: AppEnvironment) {
        guard newKind != kind else { return }

        // 只缓存已经搜完的结果。半途切走时缓存下来，
        // 切回来会看到一堆「看起来完整、其实只搜了几个源」的结果。
        if !isSearching {
            saveCache()
        }
        task?.cancel()
        task = nil
        isSearching = false
        kind = newKind
        errorMessage = nil

        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = cache[newKind], cached.query == key, !cached.books.isEmpty {
            restore(cached)
            return
        }

        books = []
        failedCount = 0
        finishedSources = 0
        totalSources = 0
        failedSources = []

        if !key.isEmpty {
            search(env: env, force: true)
        }
    }

    func retryFailed(env: AppEnvironment) {
        guard !failedSources.isEmpty, !searchedKey.isEmpty else { return }
        let retry = failedSources
        failedSources = []
        failedCount = 0
        isSearching = true

        let coordinator = coordinator ?? SearchCoordinator(client: env.sourceClient,
                                                          venera: env.veneraRuntime)
        self.coordinator = coordinator

        Task { [weak self] in
            guard let self else { return }
            for await result in await coordinator.search(sources: retry, key: self.searchedKey) {
                self.apply(result)
            }
            self.isSearching = false
            self.saveCache()
        }
    }

    func selectHistory(_ text: String, env: AppEnvironment) {
        query = text
        searchedKey = ""
        search(env: env, force: true)
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
    }

    func resetFilters() {
        filters = Filters()
    }

    // MARK: 合并

    private func apply(_ result: SourceSearchResult) {
        finishedSources += 1
        sourceNames[result.source.id] = result.source.name

        if let error = result.errorText, !error.isEmpty {
            failedCount += 1
            failedSources.append(result.source)
            return
        }

        for online in result.books {
            merge(online, sourceName: result.source.name)
        }
    }

    private func merge(_ online: OnlineBook, sourceName: String) {
        let key = identity(of: online)
        if let index = books.firstIndex(where: { $0.id == key }) {
            if !books[index].entries.contains(where: { $0.sourceId == online.sourceId }) {
                books[index].entries.append(online)
                books[index].sourceNames.append(sourceName)
            }
            if books[index].coverUrl.isEmpty { books[index].coverUrl = online.coverUrl }
            if !online.lastChapter.isEmpty { books[index].lastChapter = online.lastChapter }
        } else {
            books.append(MergedBook(
                id: key,
                name: online.name,
                author: online.author,
                coverUrl: online.coverUrl,
                kindText: online.kind,
                lastChapter: online.lastChapter,
                entries: [online],
                sourceNames: [sourceName],
                isComic: kind == .comic
            ))
        }
    }

    private func identity(of book: OnlineBook) -> String {
        let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return author.isEmpty ? name : name + "|" + author
    }

    private func remember(_ key: String) {
        var list = history.filter { $0 != key }
        list.insert(key, at: 0)
        history = Array(list.prefix(12))
        UserDefaults.standard.set(history, forKey: Self.historyKey)
    }

    // MARK: 缓存

    private func saveCache() {
        guard !searchedKey.isEmpty else { return }
        cache[kind] = CachedResults(
            query: searchedKey,
            books: books,
            total: totalSources,
            finished: finishedSources,
            failed: failedSources,
            failedCount: failedCount,
            sourceNames: sourceNames
        )
    }

    private func restore(_ cached: CachedResults) {
        books = cached.books
        totalSources = cached.total
        finishedSources = cached.finished
        failedSources = cached.failed
        failedCount = cached.failedCount
        sourceNames = cached.sourceNames
        searchedKey = cached.query
    }
}
