import SwiftUI
import UIKit
import ReaderCore

/// 在线漫画：按话取图片地址，纵向连续阅读。
///
/// 和本地 CBZ 分开，是因为取图链路完全不同：这里每张图都要带源站 header
/// （防盗链），并且需要落盘缓存，否则每次翻回去都要重新下载。
struct OnlineComicView: View {
    let book: Book
    var initialChapter: Int? = nil

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var manifest: OnlineManifest?
    @State private var source: SearchTarget?
    @State private var chapterIndex = 0
    @State private var pages: [String] = []
    @State private var headers: [String: String] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showBars = true
    @State private var showCatalog = false
    @State private var showSettings = false
    @State private var showComments = false
    @State private var bookmarked = false
    @State private var toast: String?
    @State private var autoRunning = false
    @State private var autoResetToken = 0
    @State private var autoKickToken = 0
    @State private var showCache = false
    @State private var cacheCount = 5
    @State private var cacheDone = 0
    @State private var cacheTotal = 0
    @State private var cacheRunning = false
    @State private var cacheResult: String?
    @State private var cacheError: String?

    @AppStorage("comic.autoScrollSpeed") private var autoScrollSpeed = 3.0
    @AppStorage("comic.online.background") private var backgroundRaw = "canvas"

    private var chapters: [OnlineChapter] { manifest?.chapters ?? [] }

    private var background: Color {
        switch backgroundRaw {
        case "black": return Color(hex: 0x111417)
        case "white": return Color(hex: 0xF7F8FA)
        default: return Palette.comicCanvas
        }
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            if isLoading {
                ProgressView().tint(Palette.accent)
            } else if let errorMessage {
                VStack(spacing: 10) {
                    EmptyStateView(symbol: "exclamationmark.triangle",
                                   title: "这一话打不开", message: errorMessage)
                    Button("重试") { loadChapter() }
                        .buttonStyle(SecondaryButtonStyle(height: 40))
                        .frame(width: 140)
                }
            } else {
                pageList
            }

            if showBars {
                VStack(spacing: 0) {
                    ComicTopBar(
                        title: book.title,
                        subtitle: currentSubtitle,
                        onBack: { dismiss() },
                        onCatalog: { showCatalog = true },
                        onComments: { showComments = true },
                        onSettings: { showSettings = true }
                    )
                    Spacer()
                    ComicBottomBar(
                        chipText: "E\(chapterIndex + 1) : P1",
                        counterText: "\(chapterIndex + 1) / \(max(chapters.count, 1)) 话",
                        sliderValue: Binding(
                            get: { Double(chapterIndex) },
                            set: { jumpToChapter(Int($0)) }
                        ),
                        sliderRange: 0...Double(max(chapters.count - 1, 0)),
                        onPrevious: { moveChapter(-1) },
                        onNext: { moveChapter(1) },
                        previousEnabled: chapterIndex > 0,
                        nextEnabled: chapterIndex + 1 < chapters.count,
                        bookmarked: bookmarked,
                        onBookmark: toggleBookmark,
                        downloadText: "缓存",
                        onDownload: { showCache = true },
                        shareURL: sourceURL,
                        shareText: book.title,
                        autoOn: autoRunning,
                        onAuto: toggleAuto
                    )
                }
                .transition(.opacity)
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.black.opacity(0.72))
                        .clipShape(Capsule())
                        .padding(.bottom, 150)
                }
                .transition(.opacity)
            }
        }
        .navigationBarHidden(true)
        .edgeDismiss()
        .task { loadInitial() }
        .sheet(isPresented: $showCatalog) {
            catalogSheet.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showComments) {
            if chapters.indices.contains(chapterIndex) {
                ComicCommentsSheet(
                    comicId: manifest?.bookUrl ?? "",
                    chapter: chapters[chapterIndex],
                    source: source,
                    runtime: env.veneraRuntime
                )
                .presentationDetents([.medium, .large])
            } else {
                EmptyStateView(symbol: "text.bubble",
                               title: "评论不可用",
                               message: "当前章节还没有加载完成。")
            }
        }
        .sheet(isPresented: $showSettings) {
            onlineSettings.presentationDetents([.height(360)])
        }
        .sheet(isPresented: $showCache) {
            comicCacheSheet.presentationDetents([.height(380), .medium])
        }
        .onDisappear {
            autoRunning = false
        }
    }

    // MARK: 页面

    private var pageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    AutoScrollDriver(
                        isRunning: autoRunning,
                        pointsPerSecond: autoPointsPerSecond,
                        resetToken: autoResetToken,
                        kickToken: autoKickToken,
                        onReachBottom: handleAutoBottom
                    )
                    .frame(width: 1, height: 1)

                    ForEach(Array(pages.enumerated()), id: \.offset) { index, url in
                        OnlineComicPage(urlString: url,
                                        headers: headers,
                                        cacheURL: cacheURL(index: index),
                                        placeholderHeight: index == 0 ? 600 : 480)
                            .id(index)
                    }

                    if !pages.isEmpty {
                        Text("— 本话完 —")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink3)
                            .padding(.vertical, 26)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: [.top, .bottom])
            .simultaneousGesture(
                TapGesture().onEnded {
                    withAnimation(.easeInOut(duration: 0.16)) { showBars.toggle() }
                    if autoRunning {
                        autoKickToken += 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            if autoRunning { autoKickToken += 1 }
                        }
                    }
                }
            )
            .onChange(of: chapterIndex) { _ in
                proxy.scrollTo(0, anchor: .top)
            }
        }
    }

    // MARK: 目录 / 设置

    private var catalogSheet: some View {
        NavigationStack {
            List {
                ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        showCatalog = false
                        jumpToChapter(index)
                    } label: {
                        HStack {
                            Text(chapter.name)
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            Spacer()
                            if index == chapterIndex {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.accent)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("目录 · \(chapters.count) 话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showCatalog = false }
                }
            }
        }
    }

    private var onlineSettings: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("背景")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                HStack(spacing: 10) {
                    ForEach([("canvas", "浅灰"), ("white", "白"), ("black", "黑")], id: \.0) { item in
                        Button {
                            backgroundRaw = item.0
                        } label: {
                            VStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(item.0 == "canvas" ? Palette.comicCanvas :
                                            item.0 == "white" ? Color(hex: 0xF7F8FA) : Color(hex: 0x111417))
                                    .frame(height: 40)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(backgroundRaw == item.0 ? Palette.accent : Palette.line,
                                                          lineWidth: backgroundRaw == item.0 ? 1.8 : 1)
                                    }
                                Text(item.1)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Palette.ink3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("自动阅读")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                HStack(spacing: 8) {
                    Text("滚动速度")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink3)
                    Text("慢")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.ink3)
                    Slider(value: $autoScrollSpeed, in: 1...8, step: 1)
                        .tint(Palette.accent)
                    Text("快")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.ink3)
                }
                Text("底部自动按钮只开启 / 停止，速度在这里调。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.ink3)
                Spacer()
            }
            .padding(Spacing.l)
            .navigationTitle("显示")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSettings = false }
                }
            }
        }
    }

    // MARK: 数据

    private var remainingChapters: Int {
        max(chapters.count - chapterIndex - 1, 0)
    }

    private var comicCacheSheet: some View {
        NavigationStack {
            Form {
                Section {
                    if remainingChapters > 0 {
                        Stepper(value: Binding(
                            get: { min(max(cacheCount, 1), remainingChapters) },
                            set: { cacheCount = $0 }
                        ), in: 1...remainingChapters) {
                            Text("缓存后面 \(min(max(cacheCount, 1), remainingChapters)) 话")
                                .font(.system(size: 15))
                        }
                        Text("从第 \(chapterIndex + 2) 话开始，最多 \(remainingChapters) 话")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink3)
                    } else {
                        Text("已经是最后一话，没有可缓存的后续章节")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink3)
                    }
                } header: {
                    Text("缓存范围")
                }

                Section {
                    HStack {
                        Text("当前已缓存")
                        Spacer()
                        Text("\(env.onlineReading.cachedChapterCount(for: book)) 话")
                            .foregroundStyle(Palette.ink2)
                    }
                    .font(.system(size: 14))

                    if cacheTotal > 0 {
                        ProgressView(value: Double(cacheDone), total: Double(cacheTotal))
                            .tint(Palette.accent)
                        Text("\(cacheDone) / \(cacheTotal) 话")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Palette.ink3)
                    }
                    if let cacheResult {
                        Text(cacheResult)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.accent)
                    }
                    if let cacheError {
                        Text(cacheError)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("状态")
                }

                Section {
                    Button {
                        cacheFollowingComicChapters()
                    } label: {
                        HStack {
                            Spacer()
                            if cacheRunning {
                                ProgressView().controlSize(.small)
                            }
                            Text(cacheRunning ? "缓存中…" : "开始缓存")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                    }
                    .disabled(cacheRunning || remainingChapters == 0)
                }
            }
            .navigationTitle("缓存后续章节")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showCache = false }
                }
            }
        }
    }

    private var currentSubtitle: String {
        guard chapters.indices.contains(chapterIndex) else { return "" }
        return "第 \(chapterIndex + 1) 话 · \(chapters[chapterIndex].name)"
    }

    private var sourceURL: URL? {
        guard let source, case .legado(let legado) = source else { return nil }
        let raw = legado.url
        return raw.isEmpty ? nil : URL(string: raw)
    }

    private func loadInitial() {
        guard manifest == nil else { return }
        do {
            let manifest = try env.onlineReading.manifest(for: book)
            self.manifest = manifest

            let record = try env.sources.fetch(id: manifest.sourceId)
            let target = record.flatMap {
                SourceImportService(repo: env.sources).target(from: $0)
            }
            source = target
            switch target {
            case .some(.legado(let legado)):
                headers = env.sourceClient.imageHeaders(source: legado)
            case .some(.venera):
                headers = env.veneraRuntime.imageHeaders
            case .none:
                errorMessage = "这本书所属的书源已被删除。"
            }

            let saved = initialChapter ?? UserDefaults.standard.integer(forKey: chapterKey)
            chapterIndex = min(max(saved, 0), max(manifest.chapters.count - 1, 0))
            loadChapter()
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func jumpToChapter(_ index: Int) {
        guard chapters.indices.contains(index) else { return }
        chapterIndex = index
        loadChapter()
    }

    private func moveChapter(_ delta: Int) {
        jumpToChapter(chapterIndex + delta)
    }

    private func loadChapter() {
        guard chapters.indices.contains(chapterIndex) else {
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil
        pages = []
        autoResetToken += 1
        UserDefaults.standard.set(chapterIndex, forKey: chapterKey)
        refreshBookmark()

        let chapter = chapters[chapterIndex]
        let source = self.source
        let comicId = manifest?.bookUrl ?? ""
        Task {
            guard let source else {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "书源不可用，无法取图。"
                }
                return
            }
            do {
                let urls: [String]
                switch source {
                case .legado(let legado):
                    urls = try await env.sourceClient.comicPages(source: legado, chapter: chapter)
                case .venera(let script):
                    urls = try await env.veneraRuntime.pages(
                        source: script,
                        comicId: comicId,
                        epId: chapter.url
                    )
                }
                await MainActor.run {
                    pages = urls
                    isLoading = false
                    autoResetToken += 1
                }
            } catch {
                await MainActor.run {
                    pages = []
                    isLoading = false
                    errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    private var chapterKey: String { "comic.chapter.\(book.id)" }

    private func cacheURL(index: Int) -> URL {
        env.paths.cache
            .appendingPathComponent(book.id, isDirectory: true)
            .appendingPathComponent("online", isDirectory: true)
            .appendingPathComponent("\(chapterIndex)", isDirectory: true)
            .appendingPathComponent("\(index).img", isDirectory: false)
    }

    // MARK: 操作

    private func refreshBookmark() {
        let list = (try? env.bookmarks.list(bookId: book.id)) ?? []
        bookmarked = list.contains { $0.chapterIndex == chapterIndex && $0.offset == 0 }
    }

    private func toggleBookmark() {
        let list = (try? env.bookmarks.list(bookId: book.id)) ?? []
        if let existing = list.first(where: { $0.chapterIndex == chapterIndex && $0.offset == 0 }) {
            try? env.bookmarks.delete(id: existing.id)
            bookmarked = false
            showToast("已取消收藏本话")
        } else {
            let name = chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].name : "第 \(chapterIndex + 1) 话"
            try? env.bookmarks.add(Bookmark(
                bookId: book.id,
                chapterIndex: chapterIndex,
                offset: 0,
                excerpt: name
            ))
            bookmarked = true
            showToast("已收藏本话")
        }
        Haptics.selection()
    }

    private func toggleAuto() {
        autoRunning.toggle()
        if autoRunning {
            autoResetToken += 1
            showToast("自动滚动已开启 · 速度在设置里调")
        } else {
            showToast("自动滚动已停止")
        }
    }

    private var autoPointsPerSecond: CGFloat {
        CGFloat(18 + max(1, autoScrollSpeed) * 10)
    }

    private func handleAutoBottom() {
        guard autoRunning else { return }
        guard chapterIndex + 1 < chapters.count else {
            autoRunning = false
            showToast("已到最后一话，自动滚动停止")
            return
        }
        moveChapter(1)
    }

    private func cacheFollowingComicChapters() {
        guard !cacheRunning, remainingChapters > 0 else { return }
        guard let sourceSnapshot = source else {
            cacheError = "书源不可用，无法缓存。"
            return
        }

        let start = chapterIndex + 1
        let target = min(max(cacheCount, 1), remainingChapters)
        let comicId = manifest?.bookUrl ?? ""
        let headersSnapshot = headers

        cacheRunning = true
        cacheDone = 0
        cacheTotal = target
        cacheResult = nil
        cacheError = nil

        Task {
            var added = 0
            do {
                for offset in 0..<target {
                    let index = start + offset
                    guard chapters.indices.contains(index) else { break }
                    let chapter = chapters[index]
                    let wasCached = chapterIsCached(index)

                    let urls: [String]
                    switch sourceSnapshot {
                    case .legado(let legado):
                        urls = try await env.sourceClient.comicPages(source: legado, chapter: chapter)
                    case .venera(let script):
                        urls = try await env.veneraRuntime.pages(
                            source: script,
                            comicId: comicId,
                            epId: chapter.url
                        )
                    }

                    for (pageIndex, raw) in urls.enumerated() {
                        if Task.isCancelled { break }
                        let target = comicCacheURL(chapter: index, index: pageIndex)
                        if OnlineComicImageCache.shared.image(for: target) == nil,
                           let url = URL(string: raw) {
                            _ = await OnlineComicImageCache.shared.download(
                                url: url, headers: headersSnapshot, to: target
                            )
                        }
                    }

                    if !wasCached && chapterIsCached(index) { added += 1 }
                    await MainActor.run { cacheDone = offset + 1 }
                }
                await MainActor.run {
                    cacheRunning = false
                    cacheResult = added > 0
                        ? "已缓存 \(target) 话，新增 \(added) 话"
                        : "这 \(target) 话之前已经缓存过了"
                }
            } catch {
                await MainActor.run {
                    cacheRunning = false
                    cacheError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    private func comicCacheURL(chapter: Int, index: Int) -> URL {
        env.paths.cache
            .appendingPathComponent(book.id, isDirectory: true)
            .appendingPathComponent("online", isDirectory: true)
            .appendingPathComponent("\(chapter)", isDirectory: true)
            .appendingPathComponent("\(index).img", isDirectory: false)
    }

    private func chapterIsCached(_ chapter: Int) -> Bool {
        let directory = env.paths.cache
            .appendingPathComponent(book.id, isDirectory: true)
            .appendingPathComponent("online", isDirectory: true)
            .appendingPathComponent("\(chapter)", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        return files.contains { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeInOut(duration: 0.15)) { toast = nil }
        }
    }
}

// MARK: - 单张远程图

private struct OnlineComicPage: View {
    let urlString: String
    let headers: [String: String]
    let cacheURL: URL
    let placeholderHeight: CGFloat

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                Rectangle()
                    .fill(Palette.surface.opacity(0.6))
                    .frame(height: placeholderHeight)
                    .overlay {
                        if failed {
                            VStack(spacing: 6) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .font(.system(size: 20, weight: .light))
                                Text("这张图没加载出来")
                                    .font(Typo.micro)
                            }
                            .foregroundStyle(Palette.ink3)
                        } else {
                            ProgressView().tint(Palette.accent.opacity(0.7))
                        }
                    }
            }
        }
        .task(id: urlString) { await load() }
    }

    private func load() async {
        guard let url = URL(string: urlString) else {
            failed = true
            return
        }
        if let cached = OnlineComicImageCache.shared.image(for: cacheURL) {
            image = cached
            return
        }
        if let downloaded = await OnlineComicImageCache.shared.download(
            url: url, headers: headers, to: cacheURL
        ) {
            image = downloaded
        } else {
            failed = true
        }
    }
}

/// 远程漫画页的内存 + 磁盘缓存。同样的图翻回来不再走网络。
final class OnlineComicImageCache {
    static let shared = OnlineComicImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default

    private init() {
        memory.countLimit = 10
    }

    func image(for url: URL) -> UIImage? {
        let key = url.path as NSString
        if let cached = memory.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    func download(url: URL, headers: [String: String], to cacheURL: URL) async -> UIImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = UIImage(data: data) else {
            return nil
        }

        try? fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)

        let key = cacheURL.path as NSString
        memory.setObject(image, forKey: key)
        return image
    }
}
