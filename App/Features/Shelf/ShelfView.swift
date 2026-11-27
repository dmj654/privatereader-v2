import SwiftUI
import ReaderCore

/// 书架上所有「需要弹出来的东西」都走这一个入口。
/// 原因：同一个视图上挂多个 `.sheet` / `.confirmationDialog` 会互相抢占，
/// 表现出来就是「点了没反应」。合成一个状态机之后不存在这个隐患。
private enum ShelfPresentation: Identifiable {
    case importMenu
    case picker
    case groupManager
    case report(ImportReport)
    case delete(Book)
    case detail(Book)
    case bookActions(Book)
    case sort

    var id: String {
        switch self {
        case .importMenu: return "importMenu"
        case .picker: return "picker"
        case .groupManager: return "groupManager"
        case .report: return "report"
        case .delete(let book): return "delete-\(book.id)"
        case .detail(let book): return "detail-\(book.id)"
        case .bookActions(let book): return "actions-\(book.id)"
        case .sort: return "sort"
        }
    }
}

struct ShelfView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var router: TabRouter

    @State private var books: [Book] = []
    @State private var progressByBook: [String: Double] = [:]
    @State private var cachedChaptersByBook: [String: Int] = [:]
    @State private var filter: ShelfFilter = .all
    @State private var sort: ShelfSort = .lastRead
    @State private var groups: [BookGroup] = []

    @State private var presentation: ShelfPresentation?
    @State private var isImporting = false
    @State private var lastReport: ImportReport?
    @State private var readingBook: Book?
    @State private var importError: String?
    @State private var updateCount = 0
    @State private var isCheckingUpdates = false
    @State private var isBackfillingCovers = false

    private let columns = [
        GridItem(.flexible(), spacing: 13),
        GridItem(.flexible(), spacing: 13),
        GridItem(.flexible(), spacing: 13)
    ]

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                chips
                banners
                content
            }
        }
        .navigationBarHidden(true)
        .task {
            reload()
            await checkUpdates()
        }
        .onChange(of: router.selection) { tab in
            // Tab 一直活在层级里，onAppear 不会再触发；
            // 从搜索页加入书架后切回来必须重新读一次。
            if tab == .shelf { reload() }
        }
        .onAppear { reload() }
        .sheet(item: Binding(
            get: { presentation.flatMap { isSheet($0) ? $0 : nil } },
            set: { presentation = $0 }
        )) { item in
            sheetContent(for: item)
        }
        .confirmationDialog(
            dialogTitle,
            isPresented: Binding(
                get: { presentation != nil && isDialog(presentation) },
                set: { if !$0 { presentation = nil } }
            ),
            titleVisibility: .visible,
            presenting: presentation
        ) { item in
            dialogButtons(for: item)
        } message: { item in
            dialogMessage(for: item)
        }
        .fullScreenCover(item: $readingBook, onDismiss: { reload() }) { book in
            if book.type == .novel {
                NovelReaderView(book: book, env: env)
                    .environmentObject(env)
            } else if book.origin == .remote {
                OnlineComicView(book: book)
                    .environmentObject(env)
            } else {
                ComicReaderView(book: book)
                    .environmentObject(env)
            }
        }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(Palette.accent)
                        Text("正在解析并导入…")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink2)
                    }
                    .padding(24)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Shadow.card, radius: 12, y: 4)
                }
            }
        }
    }

    // MARK: 呈现分派

    @ViewBuilder
    private func sheetContent(for item: ShelfPresentation) -> some View {
        switch item {
        case .picker:
            DocumentPicker(
                types: ImportTypes.all,
                allowsMultipleSelection: true,
                onPick: { urls in
                    presentation = nil
                    env.importLog.append("选择器返回 \(urls.count) 个文件")
                    startImport(urls: urls, archiveOriginals: true)
                },
                onCancel: {
                    presentation = nil
                    env.importLog.append("选择器被取消")
                }
            )
            .ignoresSafeArea()

        case .groupManager:
            GroupManagerSheet(groups: groups, onChanged: reload)
                .environmentObject(env)

        case .report(let report):
            ImportResultSheet(report: report)

        case .detail(let book):
            NavigationStack {
                DetailView(book: book)
                    .environmentObject(env)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("关闭") { presentation = nil }
                        }
                    }
            }

        case .bookActions(let book):
            BookActionsSheet(
                book: book,
                coverURL: env.library.absoluteCoverURL(for: book),
                groups: groups,
                currentGroupID: book.groupId,
                onDetail: {
                    presentation = nil
                    afterDismiss { presentation = .detail(book) }
                },
                onMove: { groupID in
                    try? env.books.updateGroup(bookId: book.id, groupId: groupID)
                    presentation = nil
                    reload()
                },
                onFinished: {
                    try? env.books.updateStatus(bookId: book.id,
                                                status: book.status == .finished ? .reading : .finished)
                    presentation = nil
                    reload()
                },
                onToggleDropped: {
                    let target = book.groupId == BookGroup.builtinDroppedID
                        ? BookGroup.builtinReadingID
                        : BookGroup.builtinDroppedID
                    try? env.books.updateGroup(bookId: book.id, groupId: target)
                    presentation = nil
                    reload()
                },
                onDelete: { removeFiles in
                    delete(book, removeFiles: removeFiles)
                    presentation = nil
                    reload()
                }
            )
            .presentationDetents([.height(452)])
            .presentationDragIndicator(.visible)

        case .sort:
            ShelfSortSheet(current: sort) { option in
                sort = option
                reload()
                presentation = nil
            }
            .presentationDetents([.height(320)])

        case .importMenu, .delete:
            EmptyView()
        }
    }

    private func isSheet(_ item: ShelfPresentation) -> Bool {
        switch item {
        case .picker, .groupManager, .report, .detail, .bookActions, .sort: return true
        case .importMenu, .delete: return false
        }
    }

    private func isDialog(_ item: ShelfPresentation?) -> Bool {
        switch item {
        case .importMenu, .delete: return true
        default: return false
        }
    }

    private var dialogTitle: String {
        if case .delete = presentation { return "删除这本书？" }
        return "导入书籍"
    }

    @ViewBuilder
    private func dialogButtons(for item: ShelfPresentation) -> some View {
        switch item {
        case .importMenu:
            Button("从文件选择…") {
                env.importLog.append("点击「从文件选择」")
                presentation = nil
                afterDismiss { presentation = .picker }
            }
            Button("扫描 App 目录") {
                env.importLog.append("点击「扫描 App 目录」")
                presentation = nil
                scanAndImport()
            }
            Button("载入示例书（诊断用）") {
                presentation = nil
                importSample()
            }
            Button("查看导入日志") {
                presentation = nil
                let log = ImportReport(outcomes: [], logTail: tailOfLog())
                afterDismiss { presentation = .report(log) }
            }
            Button("取消", role: .cancel) { presentation = nil }

        case .delete(let book):
            Button("只删记录，保留文件") {
                presentation = nil
                delete(book, removeFiles: false)
            }
            Button("删除记录和文件", role: .destructive) {
                presentation = nil
                delete(book, removeFiles: true)
            }
            Button("取消", role: .cancel) { presentation = nil }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func dialogMessage(for item: ShelfPresentation) -> some View {
        switch item {
        case .importMenu:
            Text("支持 txt / epub / pdf / cbz / zip。也可以把书拷进「文件」App 里「私阅读」文件夹，再用扫描。")
        case .delete:
            Text("只删记录时，原文件仍留在 App 内。")
        default:
            EmptyView()
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("书架").font(Typo.display).foregroundStyle(Palette.ink)
                Text("\(books.count) 本 · \(books.filter { $0.status == .reading }.count) 本在读")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer()
            HStack(spacing: 9) {
                iconButton("plus") { presentation = .importMenu }
                Button { presentation = .sort } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14, weight: .medium))
                        Text(sort.title)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 9)
                    .frame(height: 36)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("排序方式：\(sort.title)")
                Button { presentation = .groupManager } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17))
                        .foregroundStyle(Palette.ink2)
                        .frame(width: 36, height: 36)
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Palette.line, lineWidth: 1)
                        }
                }
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.l)
        .padding(.bottom, Spacing.m)
        .glassTopBar()
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .frame(width: 36, height: 36)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1)
                }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部", active: filter == .all) { filter = .all }
                chip("小说", active: filter == .novel) { filter = .novel }
                chip("漫画", active: filter == .comic) { filter = .comic }
                ForEach(groups) { group in
                    chip(group.name, active: filter == .group(group.id)) { filter = .group(group.id) }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.l)
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Chip(title: title, isOn: active)
        }
        .buttonStyle(.plain)
    }

    // MARK: 提示条

    @ViewBuilder
    private var banners: some View {
        if updateCount > 0 {
            banner(
                icon: "arrow.triangle.2.circlepath",
                tint: Palette.accent,
                text: "\(updateCount) 本在追的书有更新",
                onDetail: nil,
                onClose: { updateCount = 0 }
            )
        }

        if let message = env.startupMessage {
            banner(
                icon: "exclamationmark.triangle.fill",
                tint: Palette.danger,
                text: message,
                onDetail: nil,
                onClose: nil
            )
        }

        if let report = lastReport {
            banner(
                icon: report.failureCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                tint: report.failureCount == 0 ? Palette.accent : Palette.danger,
                text: "导入完成：成功 \(report.successCount)" + (report.failureCount > 0 ? "，失败 \(report.failureCount)" : ""),
                onDetail: { presentation = .report(report) },
                onClose: { lastReport = nil }
            )
        }
    }

    /// 开机扫一遍在线书目录。只在书架出现时做一次，失败静默。
    private func checkUpdates() async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }

        let checker = UpdateChecker(online: env.onlineReading, books: env.books)
        let updates = await checker.checkAll(limit: 12)
        guard !updates.isEmpty else { return }
        updateCount = updates.count
        reload()
    }

    private func banner(icon: String,
                        tint: Color,
                        text: String,
                        onDetail: (() -> Void)?,
                        onClose: (() -> Void)?) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink2)
                .lineLimit(3)
            Spacer(minLength: 0)
            if let onDetail {
                Button("详情", action: onDetail)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, 12)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if books.isEmpty {
            VStack(spacing: 4) {
                EmptyStateView(
                    symbol: "books.vertical",
                    title: "书架还是空的",
                    message: "支持 txt / epub / pdf / cbz / zip"
                )
                Button("导入第一本书") { presentation = .importMenu }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 64)

                Text("也可以把书拷进「文件」App 的「私阅读」文件夹，再点右上角 + 选「扫描 App 目录」")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 14)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(displayBooks) { book in
                        BookCell(
                            book: book,
                            coverURL: env.library.absoluteCoverURL(for: book),
                            progress: progressByBook[book.id] ?? 0,
                            cachedChapterCount: cachedChaptersByBook[book.id]
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { open(book) }
                        .onLongPressGesture(minimumDuration: 0.35) {
                            Haptics.impact(.medium)
                            presentation = .bookActions(book)
                        }
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, 110)
            }
        }
    }

    private var displayBooks: [Book] {
        sort.apply(to: filter.apply(to: books))
    }

    private func reload() {
        do {
            groups = try env.groups.all()
            books = try env.books.all()
            var map: [String: Double] = [:]
            var cacheMap: [String: Int] = [:]
            for book in books {
                map[book.id] = (try? env.progress.fetch(bookId: book.id))?.percent ?? 0
                if book.origin == .remote {
                    cacheMap[book.id] = env.onlineReading.cachedChapterCount(for: book)
                }
            }
            progressByBook = map
            cachedChaptersByBook = cacheMap
            backfillCoversIfNeeded()
        } catch {
            books = []
            env.importLog.append("读取书架失败：\(error.localizedDescription)")
        }
    }

    /// 在线书旧记录没有 coverPath，补一次源站封面；不挡列表首屏。
    private func backfillCoversIfNeeded() {
        guard !isBackfillingCovers else { return }
        let missing = books.filter { $0.origin == .remote && $0.coverPath == nil }
        guard !missing.isEmpty else { return }
        isBackfillingCovers = true
        Task {
            var changed = false
            for book in missing {
                if await env.backfillCover(for: book) != nil {
                    changed = true
                }
            }
            await MainActor.run {
                isBackfillingCovers = false
                if changed { reload() }
            }
        }
    }

    // MARK: 导入

    private func scanAndImport() {
        let urls = DirectoryScanner.scan(root: env.paths.root)
        env.importLog.append("扫描 \(env.paths.root.path)，命中 \(urls.count) 个文件")

        guard !urls.isEmpty else {
            importError = "App 目录里没找到可导入的文件。\n\n把书拷进「文件」App 里的「私阅读」文件夹，或者直接用「从文件选择」。"
            return
        }
        startImport(urls: urls, archiveOriginals: true)
    }

    private func startImport(urls: [URL], archiveOriginals: Bool) {
        guard !urls.isEmpty else { return }
        isImporting = true
        lastReport = nil

        let library = env.library
        let log = env.importLog
        let paths = env.paths

        ImportRunner.run(
            urls: urls,
            library: library,
            log: log,
            paths: paths,
            archiveOriginals: archiveOriginals
        ) { result in
            isImporting = false
            reload()
            if result.outcomes.isEmpty {
                importError = "没有产生任何导入结果，请查看导入日志。"
                presentation = .report(result)
            } else {
                if result.failureCount == 0 { Haptics.success() }
                lastReport = result
            }
        }
    }

    /// 对话框关闭有一段动画，紧接着换呈现会被吞掉，所以推迟一点。
    private func afterDismiss(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
    }

    /// 内置一本三章的示例书。
    /// 作用是把问题切开：如果示例能导入并阅读，说明书架、数据库、阅读器都是好的，
    /// 问题只出在文件选择器或文件权限上；如果连示例都进不去，那是更底层的问题。
    private func importSample() {
        let text = """
        第一章 起

        这是一本用来验证导入与阅读链路的示例书。它不经过文件选择器，直接由 App 生成。

        如果你能看到这一章，说明解析、入库、书架、阅读器都是通的。

        第二章 承

        第二段正文。翻页、进度、书签、字号都可以在这一章里试。

        第三章 转

        读到这一章，说明跨章翻页也正常。示例书可以随手删掉，不影响其他书。
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("示例书.txt")
        do {
            try text.data(using: .utf8)?.write(to: url)
        } catch {
            importError = "示例书写入失败：\(error.localizedDescription)"
            return
        }
        env.importLog.append("载入内置示例书（诊断）")
        startImport(urls: [url], archiveOriginals: false)
    }

    private func tailOfLog() -> String {
        let text = env.importLog.read()
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 60 { lines = Array(lines.suffix(60)) }
        return lines.joined(separator: "\n")
    }

    /// 点封面直接读——书架的第一用途是"接着上次读"，
    /// 详情页退到长按菜单里，那是"我要管理这本书"时才需要的信息。
    private func open(_ book: Book) {
        // 长按已经弹出面板时，松手不再当作点击
        guard presentation == nil else { return }
        // 小说和漫画都直接进阅读器；详情页留给长按菜单里的「书籍信息」。
        readingBook = book
    }

    // MARK: 书籍操作

    private func delete(_ book: Book, removeFiles: Bool) {
        try? env.library.delete(book, removeFiles: removeFiles)
        reload()
    }


}


extension ShelfSort {
    var title: String {
        switch self {
        case .lastRead: return "按最近阅读"
        case .added: return "按添加时间"
        case .title: return "按书名"
        }
    }

    var shortTitle: String {
        switch self {
        case .lastRead: return "最近"
        case .added: return "添加"
        case .title: return "书名"
        }
    }
}
