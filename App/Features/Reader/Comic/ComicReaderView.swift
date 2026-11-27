import SwiftUI
import UIKit
import ReaderCore

enum ComicMode: String, CaseIterable, Identifiable {
    case page
    case strip

    var id: String { rawValue }
    var title: String { self == .page ? "单页" : "条漫" }
}

enum ComicFit: String, CaseIterable, Identifiable {
    case width
    case height

    var id: String { rawValue }
    var title: String { self == .width ? "适应宽度" : "适应高度" }
}

struct ComicReaderView: View {
    let book: Book

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var store: ComicPageStore?
    @State private var pages: [URL] = []
    @State private var index = 0
    @State private var mode: ComicMode = .page
    @State private var showPanel = true
    @State private var showDisplay = false
    @State private var isZoomed = false
    @State private var autoTask: Task<Void, Never>?
    @State private var autoRunning = false
    @State private var stripResetToken = 0
    @State private var bookmarked = false
    @State private var showCatalog = false
    @State private var toast: String?

    @AppStorage("comic.fit") private var fitRaw = ComicFit.height.rawValue
    @AppStorage("comic.background") private var backgroundRaw = "canvas"
    @AppStorage("comic.autoPageSeconds") private var autoPageSeconds = 5
    @AppStorage("comic.autoScrollSpeed") private var autoScrollSpeed = 3.0

    private var fit: ComicFit { ComicFit(rawValue: fitRaw) ?? .height }

    private var background: Color {
        switch backgroundRaw {
        case "black": return Color(hex: 0x111417)
        case "white": return Color(hex: 0xF7F8FA)
        default: return Palette.comicCanvas
        }
    }

    private var decodeOptions: ComicPageStore.DecodeOptions {
        let longest = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        return ComicPageStore.DecodeOptions(maxPixelSize: Int(longest * 2))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background.ignoresSafeArea()

                if pages.isEmpty {
                    ProgressView().tint(Palette.accent)
                } else if mode == .page {
                    // 图片层要铺到状态栏和底部安全区里，否则第一张图上方会留一条
                    // 与图片无关的底色，看起来像"顶部留白"。
                    pageContent(size: proxy.size)
                        .ignoresSafeArea()
                } else {
                    StripReader(book: book,
                                store: store,
                                pages: pages,
                                background: background,
                                autoRunning: autoRunning,
                                pointsPerSecond: stripPointsPerSecond,
                                resetToken: stripResetToken,
                                onReachBottom: stripReachedBottom,
                                onTap: togglePanel)
                        .ignoresSafeArea()
                }

                if showPanel {
                    VStack(spacing: 0) {
                        ComicTopBar(
                            title: book.title,
                            subtitle: pages.isEmpty ? "" : "共 \(pages.count) 页 · 第 \(index + 1) 页",
                            onBack: { dismiss() },
                            onCatalog: { showCatalog = true },
                            onComments: nil,
                            onSettings: { showDisplay = true }
                        )
                        Spacer()
                        ComicBottomBar(
                            chipText: "P\(index + 1)",
                            counterText: "\(index + 1) / \(max(pages.count, 1))",
                            sliderValue: Binding(
                                get: { Double(index) },
                                set: { index = min(max(Int($0), 0), max(pages.count - 1, 0)) }
                            ),
                            sliderRange: 0...Double(max(pages.count - 1, 0)),
                            onPrevious: { turn(by: -1) },
                            onNext: { turn(by: 1) },
                            previousEnabled: index > 0,
                            nextEnabled: index < pages.count - 1,
                            navigationEnabled: mode == .page,
                            bookmarked: bookmarked,
                            onBookmark: toggleBookmark,
                            downloadText: "下载",
                            onDownload: { showLocalToast("本地漫画已保存在设备上") },
                            shareURL: localShareURL,
                            shareText: book.title,
                            autoOn: autoRunning,
                            onAuto: toggleAuto
                        )
                    }
                    .transition(.opacity)
                }
            }
        }
        .navigationBarHidden(true)
        .edgeDismiss()
        .task { load() }
        .onChange(of: index) { newValue in
            persistPage(newValue)
            prefetch(newValue)
            refreshBookmark()
            restartAuto()
        }
        .onChange(of: mode) { newValue in
            isZoomed = false
            stripResetToken += 1
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
            stopAutoTask()
            if autoRunning { restartAuto() }
        }
        .sheet(isPresented: $showCatalog) {
            pageCatalog
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDisplay) {
            ComicDisplaySheet(mode: $mode, fitRaw: $fitRaw,
                              backgroundRaw: $backgroundRaw,
                              autoPageSeconds: $autoPageSeconds,
                              autoScrollSpeed: $autoScrollSpeed)
                .presentationDetents([.height(420)])
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
                    .padding(.bottom, 130)
            }
        }
        .onDisappear {
            autoTask?.cancel()
            store?.clearCache()
        }
    }

    // MARK: 单页

    private func pageContent(size: CGSize) -> some View {
        ZStack {
            if let image = store?.image(for: book, index: index, options: decodeOptions) {
                ZoomablePageView(image: image, fit: fit, isZoomed: $isZoomed)
                    .padding(.horizontal, fit == .height ? 10 : 0)
            } else {
                ProgressView().tint(Palette.accent)
            }

            tapZones
        }
        .contentShape(Rectangle())
        .gesture(pageDrag)
    }

    /// 左中右三块：左右翻页，中间呼面板。放大后整块让给图片拖动。
    private var tapZones: some View {
        HStack(spacing: 0) {
            zone { turn(by: -1) }
            zone { togglePanel() }
            zone { turn(by: 1) }
        }
        .allowsHitTesting(!isZoomed && mode == .page)
    }

    private func zone(_ action: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private var pageDrag: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard !isZoomed, mode == .page else { return }
                let width = value.translation.width
                guard abs(width) > abs(value.translation.height), abs(width) > 50 else { return }
                turn(by: width < 0 ? 1 : -1)
            }
    }

    private func togglePanel() {
        withAnimation(.easeInOut(duration: 0.16)) { showPanel.toggle() }
    }

    private func turn(by delta: Int) {
        let target = index + delta
        guard pages.indices.contains(target) else {
            return
        }
        withAnimation(.easeOut(duration: 0.16)) { index = target }
    }

    // MARK: 数据

    private func load() {
        guard store == nil else { return }
        let store = ComicPageStore(paths: env.paths)
        self.store = store
        pages = store.pageURLs(for: book)

        let saved = UserDefaults.standard.integer(forKey: pageKey)
        index = min(max(saved, 0), max(pages.count - 1, 0))
        // 模式按书记住：同一本漫画下次打开还是上次的看法
        if let raw = UserDefaults.standard.string(forKey: modeKey),
           let savedMode = ComicMode(rawValue: raw) {
            mode = savedMode
        }
        prefetch(index)
        refreshBookmark()
        restartAuto()
    }

    private var pageKey: String { "comic.page.\(book.id)" }
    private var modeKey: String { "comic.mode.\(book.id)" }

    private var localShareURL: URL? {
        guard let path = book.filePath else { return nil }
        let url = env.paths.root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func refreshBookmark() {
        let list = (try? env.bookmarks.list(bookId: book.id)) ?? []
        bookmarked = list.contains { $0.chapterIndex == 0 && $0.offset == index }
    }

    private func toggleBookmark() {
        let list = (try? env.bookmarks.list(bookId: book.id)) ?? []
        if let existing = list.first(where: { $0.chapterIndex == 0 && $0.offset == index }) {
            try? env.bookmarks.delete(id: existing.id)
            bookmarked = false
            showLocalToast("已取消收藏")
        } else {
            try? env.bookmarks.add(Bookmark(
                bookId: book.id,
                chapterIndex: 0,
                offset: index,
                excerpt: "第 \(index + 1) 页"
            ))
            bookmarked = true
            showLocalToast("已收藏第 \(index + 1) 页")
        }
        Haptics.selection()
    }

    private func showLocalToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeInOut(duration: 0.15)) { toast = nil }
        }
    }

    private func toggleAuto() {
        autoRunning.toggle()
        if autoRunning {
            stripResetToken += 1
            restartAuto()
            showLocalToast(mode == .strip
                           ? "自动滚动已开启 · 速度在设置里调"
                           : "自动翻页已开启 · \(autoPageSeconds) 秒/页")
        } else {
            autoTask?.cancel()
            autoTask = nil
            showLocalToast("自动阅读已停止")
        }
    }

    private var stripPointsPerSecond: CGFloat {
        CGFloat(18 + max(1, autoScrollSpeed) * 10)
    }

    private func stripReachedBottom() {
        guard autoRunning else { return }
        autoRunning = false
        showLocalToast("已到最后一页，自动滚动已停止")
    }

    private var pageCatalog: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(pages.indices, id: \.self) { page in
                        Button {
                            index = page
                            showCatalog = false
                        } label: {
                            Text("\(page + 1)")
                                .font(.system(size: 12, weight: page == index ? .semibold : .regular))
                                .foregroundStyle(page == index ? .white : Palette.ink2)
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background(page == index ? Palette.accent : Palette.surfaceAlt)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Spacing.l)
            }
            .navigationTitle("页码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showCatalog = false }
                }
            }
        }
    }

    private func persistPage(_ value: Int) {
        UserDefaults.standard.set(value, forKey: pageKey)
    }

    private func prefetch(_ value: Int) {
        store?.prefetch(for: book, around: value, radius: 2, options: decodeOptions)
    }

    private func stopAutoTask() {
        autoTask?.cancel()
        autoTask = nil
    }

    private func restartAuto() {
        autoTask?.cancel()
        guard autoRunning, mode == .page else { return }
        autoTask = Task { @MainActor in
            while !Task.isCancelled {
                let seconds = autoPageSeconds
                guard autoRunning, seconds > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled, autoRunning else { return }
                if index + 1 < pages.count {
                    index += 1
                } else {
                    autoRunning = false
                    showLocalToast("已到最后一页，自动翻页停止")
                    return
                }
            }
        }
    }
}

// MARK: - 单页缩放

/// UIScrollView 包一层：双击放大、双指捏合、放大后单指拖动。
struct ZoomablePageView: UIViewRepresentable {
    let image: CGImage
    let fit: ComicFit
    @Binding var isZoomed: Bool

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 3
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.decelerationRate = .fast

        let imageView = UIImageView(image: UIImage(cgImage: image))
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scroll

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = UIImage(cgImage: image)
        context.coordinator.layoutIfNeeded(size: scroll.bounds.size, fit: fit)
        // updateUIView 可能发生在 SwiftUI 完成布局之前，此时 bounds 还是 0，
        // 布局会被 guard 掉。下一个 runloop 再试一次，图才画得出来。
        DispatchQueue.main.async {
            context.coordinator.layoutIfNeeded(size: scroll.bounds.size, fit: fit)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        private var isZoomed: Binding<Bool>
        private var lastSize: CGSize = .zero
        private var lastFit: ComicFit?

        init(isZoomed: Binding<Bool>) {
            self.isZoomed = isZoomed
        }

        func layoutIfNeeded(size: CGSize, fit: ComicFit) {
            guard size.width > 1, size.height > 1 else { return }
            guard size != lastSize || fit != lastFit else { return }
            lastSize = size
            lastFit = fit

            guard let imageView, let image = imageView.image else { return }
            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else { return }

            let scale: CGFloat
            switch fit {
            case .width:
                scale = size.width / imageSize.width
            case .height:
                scale = min(size.width / imageSize.width, size.height / imageSize.height)
            }
            let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            scrollView?.contentSize = fitted
            scrollView?.zoomScale = 1

            // 适应宽度时页面比屏幕高，允许上下滚；否则内容不超出，滚动自然关闭。
            scrollView?.alwaysBounceVertical = fit == .width
            // 适应高度时页面完整可见，别让 UIScrollView 吃掉翻页拖动；
            // 放大后再打开滚动，交给图片自己拖。
            scrollView?.isScrollEnabled = fit == .width
            isZoomed.wrappedValue = false
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.01
            isZoomed.wrappedValue = zoomed
            scrollView.isScrollEnabled = zoomed || lastFit == .width
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
                isZoomed.wrappedValue = false
            } else {
                let point = gesture.location(in: imageView)
                let size = scrollView.bounds.size
                let zoomScale: CGFloat = 2.2
                let width = size.width / zoomScale
                let height = size.height / zoomScale
                let rect = CGRect(x: point.x - width / 2,
                                  y: point.y - height / 2,
                                  width: width,
                                  height: height)
                scrollView.zoom(to: rect, animated: true)
                isZoomed.wrappedValue = true
            }
        }
    }
}
