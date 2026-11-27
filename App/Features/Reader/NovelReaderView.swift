import SwiftUI
import UIKit
import ReaderCore

/// 还没实现的入口，点了要给一句人话，不能静默。
/// 判定标准很简单：**界面上出现的按钮就是承诺**。做不到就该说出来，而不是让你怀疑是手滑还是卡住。
private struct PendingFeature: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

private struct SelectionRequest: Identifiable {
    let id = UUID()
    let text: String
}

/// 阅读器里的弹出层，合成一个状态机，避免多个 sheet 互相抢占。
private enum ReaderSheet: Identifiable {
    case catalog
    case settings(TypographySheet.Focus)
    case voice
    case sourceSwitch
    case cache

    var id: String {
        switch self {
        case .catalog: return "catalog"
        case .settings(let focus): return "settings-\(focus == .theme ? "theme" : "full")"
        case .voice: return "voice"
        case .sourceSwitch: return "sourceSwitch"
        case .cache: return "cache"
        }
    }
}

/// 阅读 / 听书是两种模式，不是同一页上叠个面板。
/// 听书时点屏幕控制的是"念到哪一句"，阅读时控制的是"翻到哪一页"，
/// 所以菜单、九宫格、点中间的反馈都分开。
private enum ReaderMode: Equatable {
    case reading
    case listening
}

enum NovelLayoutMode: String, CaseIterable, Identifiable {
    case paged
    case scroll

    var id: String { rawValue }
    var title: String { self == .paged ? "翻页" : "滚动" }
}

struct NovelReaderView: View {
    @StateObject private var model: NovelReaderViewModel
    @State private var book: Book
    @StateObject private var prefs = ReaderPreferences()
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var sheet: ReaderSheet?
    @State private var pending: PendingFeature?
    @State private var contentOffset: CGFloat = 0
    @State private var contentOpacity: Double = 1
    @State private var incomingText: NSAttributedString?
    @State private var incomingDirection: Int = 1
    @State private var viewWidth: CGFloat = 390
    @State private var scrubValue: Double?
    @State private var editingZones = false
    @StateObject private var speech = SpeechEngine()
    @StateObject private var battery = BatteryMonitor()
    @State private var sleepMinutes: Int?
    @State private var sleepWorkItem: DispatchWorkItem?
    @State private var showingTimerMenu = false

    /// 自动阅读：3 / 5 / 10 秒翻一页，跨章继续，到全书末尾停。
    @State private var autoTask: Task<Void, Never>?
    @State private var autoToast: String?
    @State private var autoRunning = false
    @AppStorage("novel.autoPageSeconds") private var autoPageSeconds = 5
    @AppStorage("novel.autoScrollSpeed") private var autoScrollSpeed = 3.0
    @AppStorage("novel.layoutMode") private var layoutRaw = NovelLayoutMode.paged.rawValue
    @State private var scrollResetToken = 0
    @State private var scrollStartToken = 0
    /// 自动滚动时的卷内进度；关掉自动阅读后用它回到对应的翻页位置。
    @State private var scrollProgress: Double = 0

    /// 长按选字后的两个入口。
    @State private var explainRequest: SelectionRequest?
    @State private var purifierRequest: SelectionRequest?
    @StateObject private var purifierStore = PurifierRuleStore.shared

    /// 当前是阅读还是听书。听书有自己的一套菜单和九宫格。
    @State private var mode: ReaderMode = .reading
    /// 正在编辑哪一套九宫格。
    @State private var zoneTarget: ZoneScheme = .reading

    /// 左边缘右滑退出：整页跟手位移，松手过了阈值就关掉阅读器。
    @State private var exitOffset: CGFloat = 0
    @State private var isEdgeExit = false

    /// 连续翻页时把"重新对齐朗读"合并成一次。
    /// 每翻一页都打断语音会赶不上，最后往往一句都没开口。
    @State private var speechRealignWork: DispatchWorkItem?

    /// "页面变了但引擎没在念"的兜底。realign 只有一条路径，
    /// 句末/跨章/在线章节加载都可能把它漏掉，这里统一补一次。
    @State private var speechResumeWork: DispatchWorkItem?

    /// 连续点「上一句/下一句」时，只让最后一次真正开口。
    /// 每点一次就 stop + speak，引擎来不及启动，听起来就是一跳一跳的。
    @State private var pendingSentenceWork: DispatchWorkItem?
    @State private var pendingSentenceText: String?
    /// 上一次手动切句的时间。恢复看护在这之后 1.2 秒内不抢话。
    @State private var lastSentenceCommandAt: TimeInterval = 0

    init(book: Book, env: AppEnvironment, initialChapter: Int? = nil) {
        _book = State(initialValue: book)
        _model = StateObject(wrappedValue: NovelReaderViewModel(
            book: book,
            provider: env.chapterProvider,
            progressRepo: env.progress,
            bookmarkRepo: env.bookmarks,
            booksRepo: env.books,
            initialChapter: initialChapter,
            log: env.importLog
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                model.theme.background.ignoresSafeArea()

                if model.isLoading {
                    ProgressView().tint(Palette.accent)
                } else if let error = model.errorMessage, model.pageRanges.isEmpty {
                    VStack(spacing: 10) {
                        EmptyStateView(symbol: "exclamationmark.triangle", title: "这一章没打开", message: error)
                        if model.book.origin == .remote {
                            Button("重试") { model.loadBodyIfNeeded(forceRefresh: true) }
                                .buttonStyle(SecondaryButtonStyle(height: 40))
                                .frame(width: 140)
                        }
                    }
                } else {
                    if autoRunning && layoutMode == .scroll {
                        scrollArea(size: proxy.size)
                            .overlay {
                                if model.isContentLoading {
                                    loadingBadge
                                }
                            }
                    } else {
                        pageArea(size: proxy.size)
                            .overlay {
                                if model.isContentLoading {
                                    loadingBadge
                                }
                            }
                    }
                }

                if model.isMenuVisible && !editingZones {
                    if mode == .listening {
                        listeningLayer
                    } else {
                        menuLayer(size: proxy.size)
                    }
                }

                if editingZones {
                    zoneEditor
                }

                if let autoToast {
                    VStack {
                        Spacer()
                        Text(autoToast)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.black.opacity(0.72))
                            .clipShape(Capsule())
                            .padding(.bottom, model.isMenuVisible ? 150 : 44)
                            .transition(.opacity)
                    }
                    .allowsHitTesting(false)
                }
            }
            // 退出时整页（包括菜单）一起走，才有"被推回去"的实感
            .offset(x: exitOffset)
            .statusBarHidden(model.isMenuVisible == false && !editingZones)
            .overlay(alignment: .topLeading) {
                // 加载失败时菜单不可达，必须留一个明确的返回入口，
                // 否则用户会卡在"这一章没打开"上，怎么划都出不去。
                if model.isLoading || model.errorMessage != nil {
                    Button {
                        closeReader()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(model.theme.textColor)
                            .frame(width: 40, height: 40)
                            .background(model.theme.background.opacity(0.92))
                            .clipShape(Circle())
                            .overlay {
                                Circle().strokeBorder(chromeLine, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 14)
                    .padding(.top, 8)
                }
            }
            .onAppear { viewWidth = proxy.size.width }
            .onChange(of: proxy.size) { viewWidth = $0.width }
            .onChange(of: model.pageIndex) { _ in scheduleSpeechResumeCheck() }
            .onChange(of: model.chapterIndex) { _ in
                scrollResetToken += 1
                scrollProgress = 0
                scheduleSpeechResumeCheck()
            }
            .onChange(of: layoutRaw) { _ in
                if autoRunning, layoutMode == .paged {
                    model.seekWithinChapter(to: scrollProgress)
                }
                stopAutoRead()
                scrollResetToken += 1
                if autoRunning, layoutMode == .paged {
                    restartAutoRead()
                }
            }
        }
        .navigationBarHidden(true)
        .preferredColorScheme(model.theme.chromeStyle)
        .onAppear {
            // 先接偏好再加载：分页要用上次的字号，否则第一屏会按默认排版闪一下再重排。
            model.attach(preferences: prefs)
            configurePurifier(for: model.book)
            model.load()
        }
        // 切后台也落一次盘：用户常常按 Home 键离开，而不是点返回。
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                model.persistProgress(force: true)
                // 进后台/锁屏前把正在播放的信息再写一遍，避免系统丢掉锁屏卡片
                speech.refreshNowPlaying()
                stopAutoRead()
            } else if autoRunning {
                restartAutoRead()
            }
        }
        .onDisappear {
            stopSpeech()
            stopAutoRead()
            model.finishSession()
            if let seconds = model.pendingSessionDuration {
                try? env.sessions.record(ReadingSession(bookId: model.book.id,
                                                        startedAt: Int(Date().timeIntervalSince1970) - seconds,
                                                        durationSec: seconds))
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .catalog:
                CatalogSheet(
                    book: model.book,
                    coverURL: env.library.absoluteCoverURL(for: model.book),
                    chapters: model.chapters,
                    currentIndex: model.chapterIndex,
                    progressPercent: model.progressPercent,
                    bookmarks: model.bookmarks,
                    onSelect: { index in
                        model.jump(toChapter: index)
                        // 正在听书时跳章，朗读必须跟着跳；否则它会继续念原来那一章。
                        restartSpeechFromCurrentPage()
                    },
                    onDeleteBookmark: { model.removeBookmark($0) },
                    onSwitchSource: book.origin == .remote ? {
                        // 目录面板先关掉，等关闭动画走完再弹换源，
                        // 两个 sheet 抢同一个呈现时序会互相吞掉。
                        sheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                            sheet = .sourceSwitch
                        }
                    } : nil
                )
                .presentationDetents([.fraction(0.72), .large])
                .presentationDragIndicator(.visible)

            case .sourceSwitch:
                SourceSwitchSheet(book: book) { updated in
                    stopSpeech()
                    stopAutoRead()
                    if model.applySourceSwitch(updated) {
                        book = updated
                        configurePurifier(for: updated)
                        Haptics.success()
                    }
                    sheet = nil
                }
                .presentationDetents([.medium, .large])

            case .voice:
                VoiceSheet(engine: speech)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)

            case .cache:
                CacheChaptersSheet(
                    book: model.book,
                    currentChapter: model.chapterIndex,
                    chapterCount: model.chapters.count
                )
                .presentationDetents([.height(360), .medium])
                .presentationDragIndicator(.visible)

            case .settings(let focus):
                TypographySheet(
                    style: $model.style,
                    theme: $model.theme,
                    focus: focus,
                    prefs: prefs,
                    onChange: { model.repaginate() },
                    onEditZones: {
                        sheet = nil
                        zoneTarget = .reading
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            withAnimation(.easeInOut(duration: 0.2)) { editingZones = true }
                        }
                    },
                    onEditSpeechZones: {
                        sheet = nil
                        zoneTarget = .speech
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            withAnimation(.easeInOut(duration: 0.2)) { editingZones = true }
                        }
                    }
                )
                .presentationDetents(detents(for: focus))
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $explainRequest) { request in
            DictionarySheet(term: request.text)
        }
        .sheet(item: $purifierRequest) { request in
            PurifierRuleEditor(selectedText: request.text,
                               bookId: model.book.id) {
                UserDefaults.standard.set(true, forKey: purifyKey(for: model.book))
                configurePurifier(for: model.book)
                showToast("净化规则已保存，本章已重新排版")
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("定时停止", isPresented: $showingTimerMenu, titleVisibility: .visible) {
            ForEach([5, 15, 30, 60], id: \.self) { minutes in
                Button("\(minutes) 分钟后停止") { scheduleSleepTimer(minutes: minutes) }
            }
            Button("关闭定时") { scheduleSleepTimer(minutes: nil) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("到点会停下朗读，正文停在原处。")
        }
        .alert(
            pending?.title ?? "",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { pending = nil }
        } message: {
            Text(pending?.detail ?? "")
        }
    }

    private func detents(for focus: TypographySheet.Focus) -> Set<PresentationDetent> {
        focus == .theme ? [.height(210)] : [.fraction(0.9), .large]
    }

    // MARK: 正文

    private func pageArea(size: CGSize) -> some View {
        VStack(spacing: 0) {
            headerRow

            ZStack {
                ZStack {
                    // 正在读的这一页
                    pageLayer(model.currentPageText, interactive: true)
                        .offset(x: contentOffset)

                    // 下一页提前画好，跟着一起动，中间不会露白
                    if let incoming = incomingText {
                        pageLayer(incoming, interactive: false)
                            .offset(x: contentOffset + CGFloat(incomingDirection) * max(viewWidth, 1))
                    }
                }
                .opacity(contentOpacity)
            }
            .simultaneousGesture(swipeGesture)
            .onChange(of: model.style) { _ in model.repaginate() }

            footerRow
        }
    }

    /// 顶部一行：左边章节名，右边全书第几章。不遮正文，正文从这一行下面开始排。
    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(model.chapterTitle)
                .font(.system(size: 10))
                .foregroundStyle(model.theme.textColor.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text("第\(model.chapterIndex + 1)/\(max(model.chapters.count, 1))章")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(model.theme.textColor.opacity(0.4))
                .lineLimit(1)
        }
        .padding(.horizontal, model.style.marginHorizontal)
        .frame(height: 22)
    }

    /// 底部一行：电量 + 页码。不画分隔线——阅读页要干净，
    /// 数字本身的位置已经足够把信息区和正文分开。
    private var footerRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: battery.symbolName)
                    .font(.system(size: 9))
                Text(battery.percentText)
                    .font(.system(size: 9.5))
                    .monospacedDigit()
            }
            .foregroundStyle(battery.isLow
                             ? Color(hex: 0xC65B4E)
                             : model.theme.textColor.opacity(0.4))

            Spacer(minLength: 8)

            Text("\(model.displayPage)/\(model.pageCount)")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(model.theme.textColor.opacity(0.4))
        }
        .padding(.horizontal, model.style.marginHorizontal)
        .frame(height: 25)
    }

    private func pageLayer(_ text: NSAttributedString, interactive: Bool) -> some View {
        GeometryReader { content in
            ZStack {
                // 页边距里的点击落在这里；正文区域由 UITextView 自己接收，
                // 这样长按选字不会被 SwiftUI 的透明九宫格抢走。
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            performTap(at: value.location, size: content.size)
                        }
                    )

                ReaderTextView(
                    attributedText: text,
                    background: UIColor(model.theme.background),
                    textInsets: .zero,
                    isInteractive: interactive,
                    onTapAt: { point, _ in
                        performTap(
                            at: CGPoint(x: point.x + model.style.marginHorizontal,
                                        y: point.y + model.style.marginTop),
                            size: content.size
                        )
                    },
                    onExplain: { text in
                        explainRequest = SelectionRequest(text: text)
                    },
                    onPurify: { text in
                        purifierRequest = SelectionRequest(text: text)
                    }
                )
                .padding(.horizontal, model.style.marginHorizontal)
                .padding(.top, model.style.marginTop)
            }
            .onAppear { model.repaginateIfNeeded(size: pageInnerSize(content.size)) }
            .onChange(of: content.size) { newValue in
                model.repaginateIfNeeded(size: pageInnerSize(newValue))
            }
        }
    }

    private func pageInnerSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width - model.style.marginHorizontal * 2, 40),
               height: max(size.height - 8, 40))
    }

    private var loadingBadge: some View {
        VStack(spacing: 8) {
            ProgressView().tint(Palette.accent)
            Text("正在加载本章…")
                .font(Typo.micro)
                .foregroundStyle(model.theme.textColor.opacity(0.5))
        }
        .padding(18)
        .background(model.theme.background.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 滚动模式

    private var layoutMode: NovelLayoutMode {
        NovelLayoutMode(rawValue: layoutRaw) ?? .paged
    }

    private var scrollPointsPerSecond: CGFloat {
        CGFloat(18 + max(1, autoScrollSpeed) * 10)
    }

    private func scrollArea(size: CGSize) -> some View {
        VStack(spacing: 0) {
            headerRow

            ReaderScrollTextView(
                attributedText: model.fullChapterText ?? NSAttributedString(string: ""),
                background: UIColor(model.theme.background),
                textInsets: UIEdgeInsets(top: model.style.marginTop,
                                         left: model.style.marginHorizontal,
                                         bottom: 28,
                                         right: model.style.marginHorizontal),
                autoRunning: autoRunning,
                pointsPerSecond: scrollPointsPerSecond,
                resetToken: scrollResetToken,
                startToken: scrollStartToken,
                initialProgress: scrollProgress,
                onTap: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.isMenuVisible.toggle()
                    }
                },
                onExplain: { text in
                    explainRequest = SelectionRequest(text: text)
                },
                onPurify: { text in
                    purifierRequest = SelectionRequest(text: text)
                },
                onProgress: { fraction in
                    scrollProgress = fraction
                },
                onReachBottom: handleScrollReachedBottom
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footerRow
        }
    }

    private func handleScrollReachedBottom() {
        guard autoRunning else { return }
        guard model.chapterIndex + 1 < model.chapters.count else {
            model.seekWithinChapter(to: 1)
            autoRunning = false
            showToast("已到全书末尾，自动阅读已停止")
            return
        }
        model.jump(toChapter: model.chapterIndex + 1)
        scrollResetToken += 1
        scrollProgress = 0
    }

    // MARK: 点击区域（九宫格）

    private func performTap(at point: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let column = min(max(Int(point.x / (size.width / 3)), 0), 2)
        let row = min(max(Int(point.y / (size.height / 3)), 0), 2)
        perform(activeZones[TapZone.grid[row][column]])
    }

    /// 听书用自己的九宫格：同样是九个格子，但动作是"上一句 / 下一句 / 暂停"这一套。
    private var activeZones: TapZoneConfig {
        mode == .listening ? prefs.speechZones : prefs.zones
    }

    private func perform(_ action: TapAction) {
        switch action {
        case .previousPage:
            turn(by: -1)
        case .nextPage:
            turn(by: 1)
        case .toggleMenu:
            withAnimation(.easeInOut(duration: 0.18)) { model.isMenuVisible.toggle() }
        case .previousChapter:
            model.jump(toChapter: model.chapterIndex - 1)
            if mode == .listening { restartSpeechFromCurrentPage() }
        case .nextChapter:
            model.jump(toChapter: model.chapterIndex + 1)
            if mode == .listening { restartSpeechFromCurrentPage() }
        case .previousSentence:
            speakPreviousSentence()
        case .nextSentence:
            speakNextSentence()
        case .toggleSpeechPlayback:
            toggleSpeechPlayback()
        case .none:
            break
        }
    }

    // MARK: 翻页

    private func turn(by direction: Int) {
        guard model.canTurn(by: direction) else { return }

        switch prefs.pageTurn {
        case .none:
            model.turnPage(by: direction)
            followSpeechAfterManualMove()
        case .fade:
            crossFade(direction)
        case .slide, .follow:
            slideTurn(direction)
        }
    }

    /// 淡出 → 换页 → 淡入。UIKit 视图做位移容易抖，透明度最稳。
    private func crossFade(_ direction: Int) {
        guard contentOpacity > 0.5 else { return }
        withAnimation(.easeInOut(duration: 0.12)) { contentOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            model.turnPage(by: direction)
            withAnimation(.easeInOut(duration: 0.16)) { contentOpacity = 1 }
            followSpeechAfterManualMove()
        }
    }

    /// 两页同时动：旧页滑出去的同时，新页从另一侧补上。
    /// 上一版是「旧页滑走 → 停顿 → 新页进来」，中间必然露一段白，那张截图就是这么来的。
    private func slideTurn(_ direction: Int) {
        guard let next = model.pageText(offset: direction) else {
            // 全书第一页往前 / 最后一页往后：没有相邻页可画，退化成淡入淡出
            crossFade(direction)
            return
        }

        incomingDirection = direction
        incomingText = next
        contentOffset = 0

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.26)) {
                contentOffset = -CGFloat(direction) * max(viewWidth, 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) {
            model.turnPage(by: direction)
            incomingText = nil
            contentOffset = 0
            followSpeechAfterManualMove()
        }
    }

    private func snapBack() {
        withAnimation(.easeOut(duration: 0.2)) {
            contentOffset = 0
            exitOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { incomingText = nil }
    }

    /// 跟手滑动：拖动时两页一起走，松手按位移决定落地还是弹回。
    /// 左边缘右滑留给退出（和 iOS 返回手势一致），这里不再接管。
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !editingZones else { return }

                // 边缘退出优先于翻页：从最左侧往右，整页跟着走。
                if canEdgeExit, isEdgeExit || startsAtLeftEdge(value) {
                    isEdgeExit = true
                    // 退出优先：把可能正在进行的翻页动画收掉，画面才不会抖
                    incomingText = nil
                    contentOffset = 0
                    exitOffset = max(0, min(value.translation.width, max(viewWidth, 1)))
                    return
                }

                guard !model.isMenuVisible else { return }
                guard prefs.pageTurn == .follow || prefs.pageTurn == .slide else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                let width = value.translation.width
                let direction = width < 0 ? 1 : -1
                let atBoundary = !model.canTurn(by: direction)

                if atBoundary {
                    incomingText = nil
                    contentOffset = width * 0.22
                } else {
                    if incomingDirection != direction || incomingText == nil {
                        incomingText = model.pageText(offset: direction)
                        incomingDirection = direction
                    }
                    contentOffset = width
                }
            }
            .onEnded { value in
                if isEdgeExit {
                    finishEdgeExit(value)
                    return
                }
                guard !model.isMenuVisible, !editingZones else {
                    snapBack()
                    return
                }
                let width = value.translation.width
                guard abs(width) > abs(value.translation.height), abs(width) > 56 else {
                    snapBack()
                    return
                }

                let direction = width < 0 ? 1 : -1
                guard model.canTurn(by: direction) else {
                    snapBack()
                    return
                }

                // 无动画与淡入淡出本来就没有"下一页"可预渲染，硬走滑动会露白。
                // 交给各自的翻页实现，滑动只负责识别方向。
                if prefs.pageTurn == .none {
                    contentOffset = 0
                    model.turnPage(by: direction)
                    followSpeechAfterManualMove()
                    return
                }
                if prefs.pageTurn == .fade {
                    contentOffset = 0
                    crossFade(direction)
                    return
                }

                guard incomingText != nil else {
                    snapBack()
                    return
                }

                withAnimation(.easeOut(duration: 0.2)) {
                    contentOffset = -CGFloat(direction) * max(viewWidth, 1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.21) {
                    model.turnPage(by: direction)
                    incomingText = nil
                    contentOffset = 0
                    followSpeechAfterManualMove()
                }
            }
    }

    /// 左边缘右滑退出。菜单打开时同样有效——用户不该为了退出还得先收面板。
    private var edgeExitGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !editingZones, canEdgeExit else { return }
                guard isEdgeExit || startsAtLeftEdge(value) else { return }
                isEdgeExit = true
                exitOffset = max(0, min(value.translation.width, max(viewWidth, 1)))
            }
            .onEnded { value in
                guard isEdgeExit else { return }
                finishEdgeExit(value)
            }
    }

    /// 只有「阅读菜单打开」时才允许边缘退出。
    /// 纯阅读时从左边滑是翻上一页；听书模式不退出，避免滑一下就离开书。
    private var canEdgeExit: Bool {
        model.isMenuVisible && mode == .reading
    }

    /// 起点在屏幕最左侧 30pt 内、向右拖。
    private func startsAtLeftEdge(_ value: DragGesture.Value) -> Bool {
        value.startLocation.x < 30
            && value.translation.width > 6
            && abs(value.translation.width) > abs(value.translation.height)
    }

    private func finishEdgeExit(_ value: DragGesture.Value) {
        isEdgeExit = false
        let distance = value.translation.width
        let projected = value.predictedEndTranslation.width
        let shouldClose = distance > 96 || (distance > 40 && projected > 200)

        if shouldClose {
            withAnimation(.easeOut(duration: 0.18)) {
                exitOffset = max(viewWidth, 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                closeReader()
            }
        } else {
            withAnimation(.easeOut(duration: 0.22)) { exitOffset = 0 }
        }
    }

    /// 关阅读器前先把声音停干净。只 dismiss 不 stop，排队中的回调会把下一章念出来。
    private func closeReader() {
        stopSpeech()
        dismiss()
    }

    // MARK: 区域编辑

    private var zoneEditor: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { }   // 吃掉点击，避免穿透到正文

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(zoneTarget == .speech ? "听书区域功能" : "阅读区域功能")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(zoneTarget == .speech
                             ? "听书时点这些格子做什么"
                             : "阅读时点这些格子做什么")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { editingZones = false }
                    } label: {
                        Text("完成")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 58)
                .padding(.bottom, 16)

                GeometryReader { proxy in
                    VStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { row in
                            HStack(spacing: 6) {
                                ForEach(0..<3, id: \.self) { column in
                                    zoneCell(TapZone.grid[row][column])
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: min(proxy.size.height - 40, 520))
                }

                Spacer(minLength: 0)
            }
        }
        .transition(.opacity)
    }

    private func zoneCell(_ zone: TapZone) -> some View {
        Menu {
            // 阅读区域不出现「朗读下一句」这类只在听书有意义的动作
            ForEach(availableActions) { action in
                Button {
                    setZoneAction(action, for: zone)
                } label: {
                    if zoneAction(zone) == action {
                        Label(action.title, systemImage: "checkmark")
                    } else {
                        Text(action.title)
                    }
                }
            }
        } label: {
            VStack(spacing: 7) {
                Text(zone.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Text(zoneAction(zone).title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(zoneAction(zone) == .none ? Color.white.opacity(0.38) : Color.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            }
        }
    }

    private var availableActions: [TapAction] {
        zoneTarget == .speech
            ? TapAction.allCases
            : TapAction.allCases.filter { !$0.isSpeechOnly }
    }

    private func zoneAction(_ zone: TapZone) -> TapAction {
        zoneTarget == .speech ? prefs.speechZones[zone] : prefs.zones[zone]
    }

    private func setZoneAction(_ action: TapAction, for zone: TapZone) {
        if zoneTarget == .speech {
            prefs.speechZones[zone] = action
        } else {
            prefs.zones[zone] = action
        }
    }

    // MARK: 朗读控制

    private func startSpeech() {
        stopAutoRead()
        autoRunning = false
        guard let text = model.prepareSpeech() else {
            pending = PendingFeature(
                title: "这一章没有可朗读的文字",
                detail: "章节内容可能是空的，或者还没加载完。"
            )
            return
        }
        wireSpeechCallbacks()
        speech.updateMetadata(title: model.book.title, subtitle: model.chapterTitle)
        speech.speak(text)
        // 封面要在出声之后设置：setArtwork 会刷新 Now Playing，
        // 还没出声时刷新会把卡片清掉。
        if let url = env.library.absoluteCoverURL(for: model.book),
           let image = UIImage(contentsOfFile: url.path) {
            speech.setArtwork(image)
        }
        // 点听书 = 进入听书模式：菜单只剩底部的朗读面板，
        // 点中间控制的是面板显隐，不再弹阅读菜单。
        mode = .listening
        withAnimation(.easeInOut(duration: 0.18)) { model.isMenuVisible = true }
    }

    /// 退出听书，回到阅读模式。声音必须停干净，否则面板没了声音还在。
    private func exitListening() {
        stopSpeech()
        withAnimation(.easeInOut(duration: 0.2)) {
            mode = .reading
            model.isMenuVisible = false
        }
    }

    /// 一句念完后自动接下一句；本章念完自动接下一章；全书念完就停。
    ///
    /// 所有回调都对 engine / viewModel 弱引用：闭包挂在 engine 自己身上，
    /// 强引用会形成自循环，阅读器关掉后 SpeechEngine 还活着，声音就一直停不下来。
    private func wireSpeechCallbacks() {
        let engine = speech
        let viewModel = model

        engine.onFinishUtterance = { [weak engine, weak viewModel] in
            guard let engine, let viewModel else { return }
            if let next = viewModel.advanceSpeechText() {
                engine.updateMetadata(title: viewModel.book.title, subtitle: viewModel.chapterTitle)
                engine.speak(next)
            } else if let nextChapter = viewModel.beginNextChapterForSpeech() {
                engine.updateMetadata(title: viewModel.book.title, subtitle: viewModel.chapterTitle)
                engine.speak(nextChapter)
            } else if viewModel.isManuallyMovedRecently {
                // 刚好在句末翻了页：realign 会在 0.3 秒后从新页接手。
                // 这里如果照常走"全书读完"的收尾，就会把朗读停掉——就是那个"翻页后不出声"。
                return
            } else {
                engine.stop()
                viewModel.endSpeech()
            }
        }
        engine.onRemotePlay = { [weak engine] in
            guard let engine else { return }
            if engine.isPaused { engine.resume() }
        }
        engine.onRemotePause = { [weak engine] in engine?.pause() }
        engine.onRemoteNext = { [weak engine, weak viewModel] in
            guard let engine, let viewModel else { return }
            if let next = viewModel.advanceSpeechText(respectsManualMove: false) {
                engine.speak(next)
            }
        }
        engine.onRemotePrevious = { [weak engine, weak viewModel] in
            guard let engine, let viewModel else { return }
            if let text = viewModel.rewindSpeechText() { engine.speak(text) }
        }
    }

    /// 手动翻页、跳章之后，让朗读跟到新的位置。
    ///
    /// 连续翻页时不能每页都立刻打断并重新开口：语音引擎来不及启动，
    /// 表现就是"连翻几页之后彻底没声了"。这里合并 0.3 秒内的多次翻页，只对齐最后一次。
    private func followSpeechAfterManualMove() {
        guard model.isSpeechPrepared else { return }

        // 翻页优先：把还没开口的"下一句"撤掉，避免翻完页又念回旧位置
        pendingSentenceWork?.cancel()
        pendingSentenceText = nil
        speechRealignWork?.cancel()
        let work = DispatchWorkItem {
            guard model.isSpeechPrepared else { return }
            if let text = model.realignSpeechToCurrentPage() {
                speech.updateMetadata(title: model.book.title, subtitle: model.chapterTitle)
                speech.speak(text)
            }
        }
        speechRealignWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)

        scheduleSpeechResumeCheck(after: 1.1)
    }

    /// 朗读中只要页面变了，就确认引擎真的在出声。
    /// 1.1 秒还没开口就重新对齐当前页；在线章节正在下载则等下载完再试。
    private func scheduleSpeechResumeCheck(after delay: TimeInterval = 1.1) {
        guard model.isSpeechPrepared, speech.isActive, !speech.isPaused else { return }
        // 用户正在连续切句：别用"从页首重念"去抢他刚选的句子
        guard Date().timeIntervalSince1970 - lastSentenceCommandAt > 1.2 else { return }

        speechResumeWork?.cancel()
        let work = DispatchWorkItem {
            guard model.isSpeechPrepared, speech.isActive, !speech.isPaused else { return }

            if model.isContentLoading {
                scheduleSpeechResumeCheck(after: 0.8)
                return
            }
            // 正在念就交给引擎自己的进度看门狗，别插话；
            // 刚念完不足 1.2 秒也别急着重念——"就回去了。"这种短句会被读第二遍。
            guard !speech.isSpeaking, speech.idleSeconds > 1.2 else {
                scheduleSpeechResumeCheck(after: 0.6)
                return
            }
            let text = model.currentSpeechText() ?? model.realignSpeechToCurrentPage()
            if let text {
                speech.updateMetadata(title: model.book.title, subtitle: model.chapterTitle)
                speech.speak(text)
            }
        }
        speechResumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 面板上的翻页 / 翻章之后，从新页的第一句重新念。
    private func restartSpeechFromCurrentPage() {
        guard model.isSpeechPrepared else { return }
        if let text = model.prepareSpeech(startAtCurrentPage: true) {
            speech.updateMetadata(title: model.book.title, subtitle: model.chapterTitle)
            speech.speak(text)
        }
    }

    // MARK: 听书九宫格的动作

    /// 朗读已经停下时，从当前页重新拉起整条链路。
    private func restartListeningFromCurrentPage() {
        guard let text = model.prepareSpeech() else { return }
        wireSpeechCallbacks()
        speech.updateMetadata(title: model.book.title, subtitle: model.chapterTitle)
        speech.speak(text)
        if let url = env.library.absoluteCoverURL(for: model.book),
           let image = UIImage(contentsOfFile: url.path) {
            speech.setArtwork(image)
        }
    }

    private func speakPreviousSentence() {
        guard model.isSpeechPrepared else {
            restartListeningFromCurrentPage()
            return
        }
        lastSentenceCommandAt = Date().timeIntervalSince1970
        if let text = model.rewindSpeechText() {
            scheduleSentence(text)
        }
    }

    private func speakNextSentence() {
        guard model.isSpeechPrepared else {
            restartListeningFromCurrentPage()
            return
        }
        lastSentenceCommandAt = Date().timeIntervalSince1970
        if let text = model.advanceSpeechText(respectsManualMove: false) {
            scheduleSentence(text)
        } else if let next = model.beginNextChapterForSpeech(respectsManualMove: false) {
            scheduleSentence(next)
        }
    }

    /// 连点合并：高亮立刻跟着走，声音只发最后一次，避免引擎被连续打断。
    private func scheduleSentence(_ text: String) {
        pendingSentenceText = text
        pendingSentenceWork?.cancel()

        let work = DispatchWorkItem {
            guard let text = pendingSentenceText else { return }
            pendingSentenceText = nil
            speech.updateMetadata(title: model.book.title, subtitle: model.chapterTitle)
            speech.speak(text)
        }
        pendingSentenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func toggleSpeechPlayback() {
        guard model.isSpeechPrepared else { return }
        if speech.isPaused {
            speech.resume()
        } else {
            speech.pause()
        }
    }

    private func stopSpeech() {
        speechRealignWork?.cancel()
        speechRealignWork = nil
        speech.stop()
        sleepWorkItem?.cancel()
        sleepWorkItem = nil
        sleepMinutes = nil
        model.endSpeech()
    }

    // MARK: 自动阅读

    private func toggleAutoRead() {
        if autoRunning {
            if layoutMode == .scroll {
                model.seekWithinChapter(to: scrollProgress)
            }
            autoRunning = false
            stopAutoRead()
            showToast("自动阅读已停止，回到左右翻页")
            return
        }

        autoRunning = true
        if layoutMode == .scroll {
            // 从当前页开始滚，而不是每次开启都退回本章开头。
            scrollProgress = model.pageCount > 1
                ? Double(model.pageIndex) / Double(model.pageCount - 1)
                : 0
            scrollStartToken += 1
        }
        if model.isMenuVisible {
            withAnimation(.easeInOut(duration: 0.18)) { model.isMenuVisible = false }
        }
        if layoutMode == .paged {
            showToast("自动阅读已开启 · \(autoPageSeconds) 秒/页")
            restartAutoRead()
        } else {
            showToast("自动阅读已开启 · 滚动速度在设置里调")
        }
    }

    private func restartAutoRead() {
        autoTask?.cancel()
        guard autoRunning, layoutMode == .paged, mode == .reading, !model.isLoading else { return }

        autoTask = Task { @MainActor in
            while !Task.isCancelled {
                let seconds = autoPageSeconds
                guard autoRunning, seconds > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard autoRunning, mode == .reading else { return }

                if model.isContentLoading { continue }
                if model.canTurn(by: 1) {
                    model.turnPage(by: 1)
                } else {
                    autoRunning = false
                    stopAutoRead()
                    showToast("已到全书末尾，自动阅读已停止")
                    return
                }
            }
        }
    }

    private func stopAutoRead() {
        autoTask?.cancel()
        autoTask = nil
    }

    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.16)) { autoToast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            withAnimation(.easeInOut(duration: 0.16)) {
                if autoToast == text { autoToast = nil }
            }
        }
    }

    // MARK: 净化

    private func configurePurifier(for book: Book) {
        let rules = purifierRules(for: book)
        let key = purifyKey(for: book)
        let enabled = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        model.configurePurifier(rules: rules, enabled: enabled)
    }

    private func togglePurifier() {
        guard model.hasPurifierRules else {
            showToast("当前书源没有配置净化规则，净化不会改动正文。")
            return
        }
        let enabled = !model.isPurifierEnabled
        UserDefaults.standard.set(enabled, forKey: purifyKey(for: model.book))
        model.setPurifierEnabled(enabled)
        if enabled {
            showToast("净化已开启：本章命中 \(model.purifierHitCount) 处")
        } else {
            showToast("净化已关闭：显示源站原文")
        }
    }

    private func purifyKey(for book: Book) -> String {
        "novel.purify.\(book.id)"
    }

    private func purifierRules(for book: Book) -> [String] {
        let sourceRules: [String]
        if book.origin == .remote,
           let manifest = try? env.onlineReading.manifest(for: book),
           let record = try? env.sources.fetch(id: manifest.sourceId),
           let target = SourceImportService(repo: env.sources).target(from: record),
           let legado = target.legadoSource {
            sourceRules = Purifier.extractRules(from: legado.ruleContent.content)
        } else {
            sourceRules = []
        }
        return sourceRules + purifierStore.legadoRules(for: book.id)
    }

    private func scheduleSleepTimer(minutes: Int?) {
        sleepWorkItem?.cancel()
        sleepMinutes = minutes
        guard let minutes else {
            sleepWorkItem = nil
            return
        }
        // 到点不只是停下声音，而是退出听书——否则面板还挂着，用户以为它随时会再响。
        let item = DispatchWorkItem { exitListening() }
        sleepWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(minutes) * 60, execute: item)
    }

    // MARK: 菜单

    // 菜单的底色、文字、分隔线全部取自当前阅读主题。
    // 以前顶栏用 #F4F6F8、底栏用纯白，正文是 #F8F9FA——三种灰叠在一起，
    // 上下各出现一道突兀的分层。统一成正文底色之后只剩一条细线。
    private var chromeText: Color { model.theme.textColor }
    private var chromeMuted: Color { model.theme.textColor.opacity(0.6) }
    private var chromeFaint: Color { model.theme.textColor.opacity(0.4) }
    private var chromeLine: Color { model.theme.textColor.opacity(0.07) }
    private var chromeFill: Color { model.theme.chromeSurface }
    /// 浮在正文上的圆钮必须有实色底 + 一点阴影，
    /// 否则在浅色主题的白底上看起来像"透明的一块"，正文会透过去。
    private var chromeShadow: Color {
        model.theme.isDark ? Color.black.opacity(0.45) : Color(hex: 0x101828, alpha: 0.10)
    }
    /// 顶栏「净化」这类小胶囊的实色底。
    private var chromeChip: Color {
        model.theme.isDark ? Color(hex: 0x232A33) : Palette.accentSoft
    }

    private func menuLayer(size: CGSize) -> some View {
        VStack {
            topBar
            Spacer()
            HStack {
                Spacer()
                sideButtons
                    .padding(.trailing, 15)
                    .padding(.bottom, 14)
            }
            bottomPanel
        }
        .transition(.opacity)
        .simultaneousGesture(edgeExitGesture)
    }

    /// 听书模式的菜单：只有底部朗读面板，没有顶栏和侧栏。
    /// 要回阅读菜单必须先退出听书——这是用户明确要的边界。
    private var listeningLayer: some View {
        VStack {
            Spacer()
            speechPanel
        }
        .transition(.opacity)
        .simultaneousGesture(edgeExitGesture)
    }

    // MARK: 朗读面板

    private var speechPanel: some View {
        SpeechPanel(
            isPaused: speech.isPaused,
            isStopped: !model.isSpeechPrepared,
            status: model.speechStatusText,
            detail: sleepLabel ?? model.speechDetailText,
            tint: model.theme.background,
            ink: model.theme.textColor,
            line: chromeLine,
            onPreviousChapter: {
                model.jump(toChapter: model.chapterIndex - 1)
                restartSpeechFromCurrentPage()
            },
            onPreviousPage: {
                model.turnPage(by: -1)
                restartSpeechFromCurrentPage()
            },
            onTogglePlay: {
                // 朗读队列已经结束（本章/全书读完，或恢复失败）时，
                // 这个按钮应当把朗读从当前页重新拉起来，而不是点了没反应。
                guard model.isSpeechPrepared else {
                    restartListeningFromCurrentPage()
                    return
                }
                if speech.isPaused { speech.resume() } else { speech.pause() }
            },
            onNextPage: {
                model.turnPage(by: 1)
                restartSpeechFromCurrentPage()
            },
            onNextChapter: {
                model.jump(toChapter: model.chapterIndex + 1)
                restartSpeechFromCurrentPage()
            },
            onCatalog: { sheet = .catalog },
            onSettings: { sheet = .settings(.typography) },
            onExit: { exitListening() },
            onVoice: { sheet = .voice },
            onTimer: { showingTimerMenu = true }
        )
    }

    private var sleepLabel: String? {
        guard let sleepMinutes else { return nil }
        return "定时 \(sleepMinutes) 分钟后停止"
    }

    private var topBar: some View {
        HStack {
            Button { closeReader() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(chromeMuted)
                    .frame(width: 36, height: 36)
            }
            Text(model.chapterTitle)
                .font(.system(size: 12.5))
                .foregroundStyle(chromeFaint)
                .lineLimit(1)

            if autoRunning {
                Button {
                    autoRunning = false
                    stopAutoRead()
                    showToast("自动阅读已停止")
                } label: {
                    Text(layoutMode == .scroll ? "自动滚动" : "自动 \(autoPageSeconds)s")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(chromeMuted)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(chromeLine)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止自动阅读")
            }

            Spacer()

            Button {
                togglePurifier()
            } label: {
                Text("净化")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(model.isPurifierEnabled
                                     ? (model.theme.isDark ? chromeMuted : Palette.accentDeep)
                                     : chromeFaint)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(chromeChip)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPurifierEnabled ? "关闭正文净化" : "开启正文净化")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .glassTopBar(tint: model.theme.background, tintOpacity: 0.94, line: chromeLine)
    }

    private var sideButtons: some View {
        VStack(spacing: 11) {
            sideButton("bookmark") {
                model.addBookmark()
                Haptics.impact(.light)
            }
            if book.origin == .remote {
                sideButton("arrow.left.arrow.right") { sheet = .sourceSwitch }
            } else {
                sideButton("magnifyingglass") {
                    pending = PendingFeature(
                        title: "全书搜索还没接上",
                        detail: "现在可以搜目录：点目录按钮，里面有搜索框。正文全文搜索会跟书源搜索一起做。"
                    )
                }
            }
            sideButton("list.bullet") { sheet = .catalog }
            sideButton(autoRunning ? "pause.fill" : "play.fill",
                       highlighted: autoRunning) {
                toggleAutoRead()
            }
            .accessibilityLabel(autoRunning ? "关闭自动阅读" : "开启自动阅读")
            sideButton("headphones", highlighted: true) { startSpeech() }
        }
    }

    private func sideButton(_ symbol: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(highlighted ? Color.white : chromeMuted)
                .frame(width: 40, height: 40)
                .background(highlighted ? Palette.accent : chromeFill)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(
                        highlighted ? Color.clear : model.theme.textColor.opacity(0.12),
                        lineWidth: 1
                    )
                }
                .shadow(color: chromeShadow, radius: 5, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var bottomPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Button("上一章") { model.jump(toChapter: model.chapterIndex - 1) }
                    .font(.system(size: 12.5))
                    .foregroundStyle(chromeMuted)

                Slider(
                    value: Binding(
                        get: { scrubValue ?? model.progressPercent },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        guard !editing, let value = scrubValue else { return }
                        scrubValue = nil
                        model.seek(toPercent: value)
                    }
                )
                .tint(Palette.accent)

                Button("下一章") { model.jump(toChapter: model.chapterIndex + 1) }
                    .font(.system(size: 12.5))
                    .foregroundStyle(chromeMuted)
            }
            .padding(.horizontal, 20)

            HStack {
                panelItem("list.bullet", "目录") { sheet = .catalog }
                panelItem("sun.max", "白天") {
                    model.theme = model.theme.isDark ? .day : .night
                }
                panelItem("circle.lefthalf.filled", "主题") {
                    sheet = .settings(.theme)
                }
                panelItem("slider.horizontal.3", "设置") {
                    sheet = .settings(.typography)
                }
                if model.book.origin == .remote {
                    panelItem("arrow.down.circle", "缓存") {
                        sheet = .cache
                    }
                } else {
                    panelItem("hand.tap", "区域") {
                        withAnimation(.easeInOut(duration: 0.2)) { editingZones = true }
                    }
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 30)
        .glassBottomPanel(tint: model.theme.background, tintOpacity: 0.94, line: chromeLine)
    }

    private func panelItem(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 19))
                Text(title).font(.system(size: 10))
            }
            .foregroundStyle(chromeMuted)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
