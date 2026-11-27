import SwiftUI
import ReaderCore

/// 依赖容器。所有页面从这里拿仓储，不自己造。
@MainActor
final class AppEnvironment: ObservableObject {
    let paths: SandboxPaths
    let database: AppDatabase

    let books: BookRepository
    let groups: GroupRepository
    let progress: ProgressRepository
    let bookmarks: BookmarkRepository
    let sources: SourceRepository
    let sessions: SessionRepository
    let cache: CacheRepository
    /// Venera JavaScript 漫画源运行时。搜索/详情/图片都走独立上下文。
    let veneraRuntime: VeneraRuntime
    let sourceClient: SourceClient
    let onlineReading: OnlineReadingService
    let library: LibraryService
    let chapterProvider: ChapterProvider
    let importLog: ImportLog

    @Published var startupMessage: String?

    init() {
        let paths = SandboxPaths.live
        var database: AppDatabase
        var message: String?

        do {
            try paths.prepare()
            database = try AppDatabase.open(at: paths.database)
        } catch {
            database = (try? AppDatabase.inMemory()) ?? AppDatabase.fallback()
            message = "本地数据库打开失败，本次运行使用临时库：\(error.localizedDescription)"
        }

        self.paths = paths
        self.database = database
        self.books = BookRepository(db: database.writer)
        self.groups = GroupRepository(db: database.writer)
        self.progress = ProgressRepository(db: database.writer)
        self.bookmarks = BookmarkRepository(db: database.writer)
        self.sources = SourceRepository(db: database.writer)
        self.sessions = SessionRepository(db: database.writer)
        self.cache = CacheRepository(db: database.writer)
        let sourceClient = SourceClient()
        self.sourceClient = sourceClient
        let runtime = VeneraRuntime()
        self.veneraRuntime = runtime
        self.library = LibraryService(books: BookRepository(db: database.writer), paths: paths)
        let onlineReading = OnlineReadingService(
            library: OnlineLibrary(paths: paths),
            sources: SourceRepository(db: database.writer),
            client: sourceClient,
            venera: runtime
        )
        self.onlineReading = onlineReading
        self.chapterProvider = ChapterProvider(paths: paths, online: onlineReading)
        self.importLog = ImportLog(directory: paths.root)
        self.startupMessage = message

        // 每次启动写一行，方便区分「这次是新装的」还是「上次的日志」
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        self.importLog.append("--- 启动 v\(version)，沙盒 \(paths.root.path) ---")
    }

    /// 老版本加入书架时没有落封面。书架出现时按需补一次，不阻塞列表。
    /// 源站没有封面规则或封面下载失败时，用书名/作者生成一张本地封面。
    func backfillCover(for book: Book) async -> Book? {
        guard book.origin == .remote, book.coverPath == nil else { return nil }

        var relative: String?
        if let manifest = try? onlineReading.manifest(for: book),
           !manifest.coverUrl.isEmpty,
           let record = try? sources.fetch(id: manifest.sourceId),
           let target = SourceImportService(repo: sources).target(from: record) {
            let headers: [String: String]
            let baseURL: String?
            switch target {
            case .legado(let source):
                headers = sourceClient.imageHeaders(source: source)
                baseURL = source.url
            case .venera:
                headers = veneraRuntime.imageHeaders
                baseURL = nil
            }
            relative = await OnlineCoverStore.download(
                urlString: manifest.coverUrl,
                baseURL: baseURL,
                headers: headers,
                bookID: book.id,
                paths: paths
            )
        }

        if relative == nil { return nil }

        var updated = book
        updated.coverPath = relative
        do {
            try books.upsert(updated)
        } catch {
            return nil
        }
        return updated
    }
}
