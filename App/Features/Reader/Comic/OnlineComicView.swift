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
    @State private var source: LegadoSource?
    @State private var chapterIndex = 0
    @State private var pages: [String] = []
    @State private var headers: [String: String] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showBars = true
    @State private var showCatalog = false
    @State private var showSettings = false
    @State private var bookmarked = false
    @State private var toast: String?
    @State private var autoPage = 0
    @State private var autoTask: Task<Void, Never>?
    @State private var isDownloading = false
    @State private var downloadText = "下载"

    @AppStorage("comic.autoSeconds") private var autoSeconds = 0
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
                        bookmarked: bookmarked,
                        onBack: { dismiss() },
                        onCatalog: { showCatalog = true },
                        onBookmark: toggleBookmark,
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
                        downloadText: downloadText,
                        onDownload: downloadChapter,
                        shareURL: sourceURL,
                        shareText: book.title,
                        autoSeconds: autoSeconds,
                        onAuto: cycleAuto
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
        .sheet(isPresented: $showSettings) {
            onlineSettings.presentationDetents([.height(240)])
        }
        .onDisappear { autoTask?.cancel() }
    }

    // MARK: 页面

    private var pageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
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
                }
            )
            .onChange(of: autoPage) { page in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(page, anchor: .top)
                }
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

    private var currentSubtitle: String {
        guard chapters.indices.contains(chapterIndex) else { return "" }
        return "第 \(chapterIndex + 1) 话 · \(chapters[chapterIndex].name)"
    }

    private var sourceURL: URL? {
        guard let raw = manifest?.bookUrl, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func loadInitial() {
        guard manifest == nil else { return }
        do {
            let manifest = try env.onlineReading.manifest(for: book)
            self.manifest = manifest

            let record = try env.sources.fetch(id: manifest.sourceId)
            let executable = record.flatMap {
                SourceImportService(repo: env.sources).executable(from: $0)
            }
            source = executable
            if let executable {
                headers = env.sourceClient.imageHeaders(source: executable)
            } else {
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
        autoPage = 0
        UserDefaults.standard.set(chapterIndex, forKey: chapterKey)
        refreshBookmark()

        let chapter = chapters[chapterIndex]
        let source = self.source
        Task {
            guard let source else {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "书源不可用，无法取图。"
                }
                return
            }
            do {
                let urls = try await env.sourceClient.comicPages(source: source, chapter: chapter)
                await MainActor.run {
                    pages = urls
                    isLoading = false
                    restartAuto()
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

    private func cycleAuto() {
        switch autoSeconds {
        case 0: autoSeconds = 5
        case 5: autoSeconds = 10
        case 10: autoSeconds = 15
        default: autoSeconds = 0
        }
        restartAuto()
    }

    private func restartAuto() {
        autoTask?.cancel()
        guard autoSeconds > 0, !pages.isEmpty else { return }

        autoTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(autoSeconds) * 1_000_000_000)
                if Task.isCancelled { return }

                if autoPage + 1 < pages.count {
                    autoPage += 1
                } else if chapterIndex + 1 < chapters.count {
                    moveChapter(1)
                    return
                } else {
                    return
                }
            }
        }
    }

    private func downloadChapter() {
        guard !isDownloading, !pages.isEmpty else { return }
        isDownloading = true
        downloadText = "0/\(pages.count)"

        let urls = pages
        let chapter = chapterIndex
        let headers = self.headers
        let bookId = book.id

        Task {
            var done = 0
            for (index, raw) in urls.enumerated() {
                if Task.isCancelled { break }
                let cacheURL = env.paths.cache
                    .appendingPathComponent(bookId, isDirectory: true)
                    .appendingPathComponent("online", isDirectory: true)
                    .appendingPathComponent("\(chapter)", isDirectory: true)
                    .appendingPathComponent("\(index).img", isDirectory: false)

                if OnlineComicImageCache.shared.image(for: cacheURL) == nil,
                   let url = URL(string: raw) {
                    _ = await OnlineComicImageCache.shared.download(
                        url: url, headers: headers, to: cacheURL
                    )
                }
                done += 1
                let text = "\(done)/\(urls.count)"
                await MainActor.run { downloadText = text }
            }
            await MainActor.run {
                isDownloading = false
                downloadText = "下载"
                showToast("本话已缓存")
            }
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
