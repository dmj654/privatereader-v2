import SwiftUI
import UIKit
import ReaderCore

@MainActor
final class NovelReaderViewModel: ObservableObject {
    private(set) var book: Book

    private let provider: ChapterProvider
    private let progressRepo: ProgressRepository
    private let bookmarkRepo: BookmarkRepository
    private let booksRepo: BookRepository
    private let positionStore: ReadingPositionStore
    private let log: ImportLog?
    private var pendingPage: Int?
    private var lastLoggedChapter = -1

    // 章节富文本缓存：正文与分页、朗读必须共用同一份字符串，偏移才对得上
    private var cachedAttributed: NSAttributedString?
    private var cachedKey: CacheKey?
    private struct CacheKey: Equatable {
        let chapter: Int
        let style: ReaderStyle
        let theme: String
        let purifyEnabled: Bool
        let purifyRules: String
    }

    // 朗读
    @Published private(set) var speechIndex: Int?
    private var speechQueue: SpeechQueue?
    private var speechSentences: [SpeechSentence] = []
    /// 实际送进合成器的朗读单元 = 原始句子，但把过短的句子并到后一句。
    /// AVSpeechSynthesizer 对「喜欢。」这种两三个字的 utterance 偶尔不回调完成，
    /// 表现为读到这儿就停住；合并后就不会出现极短的一条。
    private var speechUnits: [SpeechSentence] = []
    private var speechSentenceKey: CacheKey?

    @Published private(set) var chapters: [NovelChapter] = []
    @Published var chapterIndex: Int = 0
    @Published var pageIndex: Int = 0
    @Published private(set) var pageRanges: [NSRange] = []

    /// 排版与主题：改了立刻写回偏好，下次打开还是这一套。
    @Published var style: ReaderStyle = .default {
        didSet { preferences?.style = style }
    }
    @Published var theme: ReaderTheme = .day {
        didSet { preferences?.theme = theme }
    }

    @Published var isLoading = true
    @Published var errorMessage: String?
    /// 在线书正在下载这一章正文。界面据此显示"正在加载本章"，而不是空白页。
    @Published private(set) var isContentLoading = false
    @Published var bookmarks: [Bookmark] = []
    @Published var isMenuVisible = false
    @Published var isDarkChrome = false

    /// 正文净化：规则来自书源，开关按书保存在阅读器里。
    /// 命中数不是装饰——用户要能判断是「规则生效了」还是「这段正文本来就没有广告」。
    @Published private(set) var isPurifierEnabled = false
    @Published private(set) var purifierHitCount = 0
    @Published private(set) var purifierRuleCount = 0
    private var purifier = Purifier(isEnabled: false, rules: [])

    /// 偏好只在阅读器活着时有意义，用 weak 防止它反向延长偏好对象的生命周期。
    private weak var preferences: ReaderPreferences?

    private var lastPageSize: CGSize = .zero
    private var lastSavedAt: TimeInterval = 0
    /// 用户最后一次手动翻页/跳章的时间。朗读的"念完了"回调会晚到，
    /// 需要知道这次晚到是不是紧跟在一次手动移动之后。
    private var lastManualMoveAt: TimeInterval = 0
    private var sessionStartedAt: Date?

    private let initialChapter: Int?

    init(book: Book,
         provider: ChapterProvider,
         progressRepo: ProgressRepository,
         bookmarkRepo: BookmarkRepository,
         booksRepo: BookRepository,
         initialChapter: Int? = nil,
         log: ImportLog? = nil) {
        self.book = book
        self.initialChapter = initialChapter
        self.provider = provider
        self.progressRepo = progressRepo
        self.bookmarkRepo = bookmarkRepo
        self.booksRepo = booksRepo
        self.positionStore = ReadingPositionStore(repo: progressRepo)
        self.log = log
    }

    var currentChapter: NovelChapter? {
        guard chapters.indices.contains(chapterIndex) else { return nil }
        return chapters[chapterIndex]
    }

    var chapterTitle: String {
        currentChapter?.title ?? book.title
    }

    var pageCount: Int { max(pageRanges.count, 1) }
    var displayPage: Int { min(pageIndex + 1, pageCount) }

    /// 刚刚手动翻过页 / 跳过章。窗口取 1 秒：
    /// 句末回调通常在一瞬间到达，1 秒足够覆盖，又不会误伤正常连读。
    var isManuallyMovedRecently: Bool {
        Date().timeIntervalSince1970 - lastManualMoveAt < 1.0
    }

    private func markManualMove() {
        lastManualMoveAt = Date().timeIntervalSince1970
    }

    var progressPercent: Double {
        let within = pageCount > 1 ? Double(pageIndex) / Double(pageCount - 1) : 0
        return ProgressMath.percent(chapterIndex: chapterIndex, chapterCount: chapters.count, chapterProgress: within)
    }

    // MARK: 加载

    /// 接上偏好：把上次的字号、行距、主题拿进来，并让之后的修改自动写回。
    /// 必须在 `load()` 之前调用——分页要用正确的排版参数，否则第一屏会按默认字号排一次再重排。
    func attach(preferences: ReaderPreferences) {
        self.preferences = preferences
        if style != preferences.style { style = preferences.style }
        if theme != preferences.theme { theme = preferences.theme }
    }

    /// 接上当前书源里的净化规则。规则为空时按钮明确不可用，不假装生效。
    func configurePurifier(rules: [String], enabled: Bool) {
        purifierRuleCount = rules.count
        purifier = Purifier(isEnabled: enabled && !rules.isEmpty, rules: rules)
        isPurifierEnabled = purifier.isEnabled
        cachedAttributed = nil
        cachedKey = nil
        purifierHitCount = 0
        repaginate()
    }

    func setPurifierEnabled(_ enabled: Bool) {
        guard purifierRuleCount > 0 else { return }
        purifier.isEnabled = enabled
        isPurifierEnabled = enabled
        cachedAttributed = nil
        cachedKey = nil
        purifierHitCount = 0
        repaginate()
    }

    var hasPurifierRules: Bool { purifierRuleCount > 0 }

    func load() {
        isLoading = true
        do {
            chapters = try provider.chapters(for: book)
            if let initialChapter {
                chapterIndex = min(max(initialChapter, 0), max(chapters.count - 1, 0))
                pendingPage = nil
            } else if let saved = positionStore.restore(bookId: book.id, chapterCount: chapters.count) {
                chapterIndex = saved.chapterIndex
                pendingPage = saved.pageIndex
                log?.append("恢复位置：第 \(saved.chapterIndex + 1) 章 第 \(saved.pageIndex + 1) 页")
            } else {
                log?.append("无历史位置，从第 1 章开始")
            }
            bookmarks = (try? bookmarkRepo.list(bookId: book.id)) ?? []
            // 打开书就算看到了更新；角标不清会一直挂着，反而让人以为没追上。
            try? booksRepo.clearNewChapterCount(bookId: book.id)
            sessionStartedAt = Date()
            errorMessage = nil
        } catch {
            chapters = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
        loadBodyIfNeeded()
    }

    /// 在线书按需取正文：目录先到，正文后到，先给用户看到章名和页码。
    func loadBodyIfNeeded(forceRefresh: Bool = false) {
        guard book.origin == .remote else { return }
        guard chapters.indices.contains(chapterIndex) else { return }
        guard forceRefresh || chapters[chapterIndex].body.isEmpty else {
            Task { await provider.prefetch(for: book, around: chapterIndex) }
            return
        }
        guard !isContentLoading else { return }

        isContentLoading = true
        errorMessage = nil
        let index = chapterIndex

        Task { @MainActor in
            do {
                let body = try await provider.body(for: book, index: index, forceRefresh: forceRefresh)
                if chapters.indices.contains(index) {
                    chapters[index] = NovelChapter(title: chapters[index].title, body: body)
                }
                if index == chapterIndex {
                    // 正文变了，富文本缓存必须作废，否则分页还是按空的来
                    cachedAttributed = nil
                    cachedKey = nil
                    repaginate()
                    applyPendingPage()
                }
                isContentLoading = false
                Task { await provider.prefetch(for: book, around: index) }
                // 加载期间用户又跳到了别的章：这一章的请求被 isContentLoading 挡掉了，
                // 现在补一次，否则会停在空白页。
                if index != chapterIndex,
                   chapters.indices.contains(chapterIndex),
                   chapters[chapterIndex].body.isEmpty {
                    loadBodyIfNeeded()
                }
            } catch {
                isContentLoading = false
                if index == chapterIndex {
                    var text = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    let cached = provider.cachedChapterIndices(for: book)
                    if !cached.isEmpty {
                        text += "\n这一章还没缓存。已缓存 \(cached.count) 章，可以在目录里选已缓存的章节离线阅读。"
                    }
                    errorMessage = text
                } else if chapters.indices.contains(chapterIndex),
                          chapters[chapterIndex].body.isEmpty {
                    loadBodyIfNeeded()
                }
            }
        }
    }

    // MARK: 分页

    func repaginateIfNeeded(size: CGSize) {
        guard size.width > 40, size.height > 40 else { return }
        guard size != lastPageSize || pageRanges.isEmpty else { return }
        lastPageSize = size
        repaginate()
        applyPendingPage()
    }

    /// 分页尺寸拿到之后才知道总页数，所以页码要等第一次重排完再落。
    private func applyPendingPage() {
        guard let pending = pendingPage else { return }
        pageIndex = min(max(pending, 0), max(pageRanges.count - 1, 0))
        pendingPage = nil
    }

    func repaginate() {
        guard lastPageSize.width > 40 else { return }
        guard let attributed = chapterAttributed() else {
            // 正文还没到（在线章）：清掉上一章的页面范围，否则会一直显示上一页。
            pageRanges = []
            pageIndex = 0
            return
        }
        pageRanges = Paginator.pageRanges(attributedString: attributed, pageSize: lastPageSize)
        pageIndex = min(pageIndex, max(pageRanges.count - 1, 0))
    }

    /// 章标题作为正文的第一段参与排版，而不是浮在正文上方的装饰。
    /// 这样翻到本章第一页时标题自然出现在页首，分页也算得准，不会盖住文字。
    private func attributedBody(for chapter: NovelChapter, bodyOverride: String? = nil) -> NSAttributedString {
        let color = UIColor(theme.textColor)
        let result = NSMutableAttributedString()

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.alignment = .center
        titleParagraph.lineHeightMultiple = 1.45
        titleParagraph.paragraphSpacing = 22
        titleParagraph.paragraphSpacingBefore = 8

        let titleFont = UIFont.systemFont(ofSize: style.fontSize * 1.45, weight: .semibold)
        result.append(NSAttributedString(
            string: chapter.title + "\n",
            attributes: [
                .font: titleFont,
                .foregroundColor: color,
                .paragraphStyle: titleParagraph
            ]
        ))

        let rawBody = bodyOverride ?? purifier.apply(to: chapter.body).text
        let body = ReaderStyle.normalizedBody(chapter.body.isEmpty ? "" : rawBody)
        if !body.isEmpty {
            result.append(NSAttributedString(
                string: body,
                attributes: style.attributes(color: color.cgColor)
            ))
        }
        return result
    }

    var currentPageText: NSAttributedString {
        guard pageRanges.indices.contains(pageIndex),
              let attributed = chapterAttributed() else {
            return NSAttributedString(string: "")
        }
        let range = pageRanges[pageIndex]
        guard let page = pageSlice(attributed, range) else { return attributed }
        applySpeechHighlight(to: page, pageRange: range)
        return page
    }

    /// 整章富文本只构建一次。分页、朗读切句、高亮都基于同一份字符串，
    /// 否则句子的偏移和页的范围会错位，高亮就会漂。
    private func chapterAttributed() -> NSAttributedString? {
        guard let chapter = currentChapter else { return nil }
        // 在线章节还没下载完：不要先排一个只有标题的空页，等正文到了一起排。
        if book.origin == .remote, chapter.body.isEmpty { return nil }
        let key = CacheKey(
            chapter: chapterIndex,
            style: style,
            theme: theme.rawValue,
            purifyEnabled: purifier.isEnabled,
            purifyRules: purifier.rules.joined(separator: "|")
        )
        if key == cachedKey, let cached = cachedAttributed { return cached }

        let outcome = purifier.apply(to: chapter.body)
        purifierHitCount = outcome.hitCount
        let built = attributedBody(for: chapter, bodyOverride: outcome.text)
        cachedAttributed = built
        cachedKey = key
        return built
    }

    /// 切出一页，并处理"续页首行"。
    ///
    /// 分页会从段落中间切页。下一页开头这半段其实还是上一段的延续，
    /// 但 CoreText 会把它当成本段第一行，把首行缩进照搬过来——
    /// 视觉上就像凭空多了一个段落。这里把续页首段的缩进和段前距清掉。
    private func pageSlice(_ attributed: NSAttributedString, _ range: NSRange) -> NSMutableAttributedString? {
        guard range.location >= 0,
              range.location + range.length <= attributed.length else { return nil }

        let page = NSMutableAttributedString(attributedString: attributed.attributedSubstring(from: range))
        guard range.location > 0, page.length > 0 else { return page }

        let full = attributed.string as NSString
        let previous = full.character(at: range.location - 1)
        let startsAtParagraph = (previous == 0x000A || previous == 0x000D || previous == 0x2029)
        guard !startsAtParagraph else { return page }

        // 只处理页面第一段：找到第一个换行为止
        let pageText = page.string as NSString
        let newline = pageText.range(of: "\n")
        let paragraphLength = newline.location == NSNotFound
            ? pageText.length
            : min(newline.location + 1, pageText.length)
        guard paragraphLength > 0 else { return page }

        let paragraphRange = NSRange(location: 0, length: paragraphLength)
        let style = NSMutableParagraphStyle()
        if let existing = page.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
            style.setParagraphStyle(existing)
        }
        style.firstLineHeadIndent = 0
        style.paragraphSpacingBefore = 0
        page.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
        return page
    }

    private var speechHighlightColor: UIColor {
        theme.isDark
            ? UIColor(white: 1, alpha: 0.16)
            : UIColor(red: 0.72, green: 0.36, blue: 0.24, alpha: 0.14)
    }

    private func applySpeechHighlight(to page: NSMutableAttributedString, pageRange: NSRange) {
        // 用朗读队列里的句子，而不是原始切句结果：
        // 页首把句子切成两半时，队列里存的是"从页首开始"的截断句，高亮才对得上。
        guard let sentence = speechQueue?.current else { return }

        let overlap = NSIntersectionRange(sentence.range, pageRange)
        guard overlap.length > 0 else { return }

        let local = NSRange(location: overlap.location - pageRange.location, length: overlap.length)
        guard local.location >= 0, local.location + local.length <= page.length else { return }
        page.addAttribute(.backgroundColor, value: speechHighlightColor, range: local)
    }

    // MARK: 翻页

    func turnPage(by delta: Int) {
        guard !chapters.isEmpty else { return }
        markManualMove()
        pendingPage = nil
        let target = pageIndex + delta
        if target < 0 {
            if chapterIndex > 0 {
                chapterIndex -= 1
                repaginate()
                pageIndex = max(pageRanges.count - 1, 0)
                persistProgress()
                loadBodyIfNeeded()
            }
            return
        }
        if target >= pageRanges.count {
            if chapterIndex < chapters.count - 1 {
                chapterIndex += 1
                repaginate()
                pageIndex = 0
                persistProgress()
                loadBodyIfNeeded()
            }
            return
        }
        pageIndex = target
        persistProgress()
    }

    /// 取相邻页的富文本，给翻页动画用：新页要提前画出来，才能和旧页同时在场。
    ///
    /// 以前跨章返回 nil，调用方就 `snapBack()` —— 于是「本章最后一页」往左滑永远弹回去，
    /// 进不了下一章。现在跨章时把相邻章的首/尾页也排出来，动画照常推进，
    /// 动画结束后再真正换章。
    func pageText(offset: Int) -> NSAttributedString? {
        let target = pageIndex + offset

        if pageRanges.indices.contains(target) {
            guard let attributed = chapterAttributed() else { return nil }
            return pageSlice(attributed, pageRanges[target])
        }

        let neighbor = chapterIndex + (offset > 0 ? 1 : -1)
        guard chapters.indices.contains(neighbor), lastPageSize.width > 40 else { return nil }

        let attributed = attributedBody(for: chapters[neighbor])
        let ranges = Paginator.pageRanges(attributedString: attributed, pageSize: lastPageSize)
        guard let range = offset > 0 ? ranges.first : ranges.last else { return nil }
        return pageSlice(attributed, range)
    }

    /// 还能不能往这个方向翻。翻不动时不要再播动画，否则会出现"滑走又滑回原样"的怪现象。
    func canTurn(by delta: Int) -> Bool {
        guard !chapters.isEmpty else { return false }
        if delta < 0 {
            return pageIndex > 0 || chapterIndex > 0
        }
        return pageIndex < max(pageRanges.count - 1, 0) || chapterIndex < chapters.count - 1
    }

    /// 按全书百分比跳章。滑杆松手时调用。
    func seek(toPercent percent: Double) {
        guard !chapters.isEmpty else { return }
        jump(toChapter: ProgressMath.chapterIndex(fromPercent: percent, chapterCount: chapters.count))
    }

    func jump(toChapter index: Int) {
        guard chapters.indices.contains(index) else { return }
        markManualMove()
        pendingPage = nil
        chapterIndex = index
        repaginate()
        pageIndex = 0
        persistProgress()
        loadBodyIfNeeded()
    }

    // MARK: 持久化

    /// 保存阅读位置。
    /// 以前整个函数用 `try?` 包着，写失败完全没有痕迹——这就是"读到第 4 章、下次回到第 1 章"
    /// 查不出来的原因。现在失败会写进日志，成功也会读回来核对一次。
    func persistProgress(force: Bool = false) {
        guard chapters.count > 0 else { return }

        let now = Date().timeIntervalSince1970
        guard force || now - lastSavedAt > 1 else { return }
        lastSavedAt = now

        let position = ReadingPosition(chapterIndex: chapterIndex, pageIndex: pageIndex)
        do {
            guard let record = try positionStore.save(
                bookId: book.id,
                position: position,
                pageCount: pageCount,
                chapterCount: chapters.count,
                timestamp: Int(now)
            ) else { return }

            let verified = positionStore.verify(bookId: book.id, expecting: record)
            if !verified {
                log?.append("保存位置校验失败：期望第 \(record.chapterIndex + 1) 章，读回不一致")
            } else if record.chapterIndex != lastLoggedChapter {
                lastLoggedChapter = record.chapterIndex
                log?.append("保存位置：第 \(record.chapterIndex + 1) 章，全书 \(Int(record.percent * 100))%")
            }

            try? booksRepo.touch(bookId: book.id, at: Int(now))
        } catch {
            log?.append("保存位置失败：\(error.localizedDescription)")
        }
    }

    func finishSession() {
        persistProgress(force: true)
        guard let started = sessionStartedAt else { return }
        let seconds = Int(Date().timeIntervalSince(started))
        sessionStartedAt = nil
        guard seconds > 5 else { return }
        // 会话记录由 AppEnvironment 在关闭阅读器时写入，这里只负责提供时长
        pendingSessionDuration = seconds
    }

    private(set) var pendingSessionDuration: Int?

    // MARK: 书签

    func addBookmark() {
        let excerpt = currentPageText.string
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(excerpt.prefix(30))
        let bookmark = Bookmark(bookId: book.id, chapterIndex: chapterIndex, offset: pageIndex, excerpt: trimmed)
        try? bookmarkRepo.add(bookmark)
        bookmarks = (try? bookmarkRepo.list(bookId: book.id)) ?? []
    }

    func removeBookmark(_ bookmark: Bookmark) {
        try? bookmarkRepo.delete(id: bookmark.id)
        bookmarks = (try? bookmarkRepo.list(bookId: book.id)) ?? []
    }

    // MARK: 朗读

    var isSpeechPrepared: Bool { speechQueue != nil }

    /// 把两三个字的短句并到下一句。
    ///
    /// AVSpeechSynthesizer 对「喜欢。」这种极短 utterance 偶尔不回调完成，
    /// 表现就是读到这儿停住不动。合并后至少四个字，避开这个边界。
    /// 位置仍连续，高亮会同时覆盖这两句——它们本来就是连着的文字。
    private static func mergeShortSentences(_ sentences: [SpeechSentence]) -> [SpeechSentence] {
        var units: [SpeechSentence] = []
        for sentence in sentences {
            if let last = units.last, last.length < 4 {
                let end = max(last.location + last.length, sentence.location + sentence.length)
                units[units.count - 1] = SpeechSentence(
                    text: last.text + sentence.text,
                    location: last.location,
                    length: end - last.location
                )
            } else {
                units.append(sentence)
            }
        }
        return units
    }

    /// 准备朗读：从当前页开口，正好是眼睛看到的位置。
    ///
    /// 页首落在句子中间时，要把这句截断，从页首那半句念起——
    /// 不截断就会从上一页念起（听感错位），跳到下一句又会漏掉眼前这半句。
    func prepareSpeech(startAtCurrentPage: Bool = true) -> String? {
        guard let attributed = chapterAttributed(), attributed.length > 0 else { return nil }
        let key = CacheKey(chapter: chapterIndex, style: style, theme: theme.rawValue)

        if speechSentenceKey != key || speechSentences.isEmpty {
            speechSentences = SentenceSplitter.split(attributed.string)
            speechUnits = Self.mergeShortSentences(speechSentences)
            speechSentenceKey = key
        }
        guard !speechUnits.isEmpty else { return nil }

        var start = SpeechStart(index: 0, characterOffset: 0)
        if startAtCurrentPage, pageRanges.indices.contains(pageIndex) {
            // 章标题排在正文前面，但它不是正文。从章首开始听时跳过标题，
            // 否则"那一页的第一句"（正文第一句）会被标题顶掉。
            let titleLength = (currentChapter?.title as NSString?)?.length ?? 0
            start = SpeechStartLocator.start(
                sentences: speechUnits,
                pageLocation: pageRanges[pageIndex].location,
                titleLength: titleLength
            )
        }

        var queueSentences = speechUnits
        var queueStart = start.index

        if start.characterOffset > 0, queueSentences.indices.contains(start.index) {
            let original = queueSentences[start.index]
            let offset = min(start.characterOffset, original.length)

            if offset >= original.length, queueStart + 1 < queueSentences.count {
                // 页首落在这一句末尾的空白之后，下一句才是这一页的第一句
                queueStart += 1
            } else {
                let cutText = (original.text as NSString).substring(from: offset)
                if cutText.isEmpty, queueStart + 1 < queueSentences.count {
                    queueStart += 1
                } else {
                    // 截断前半句：位置与长度都从页首算，高亮才会落在眼前
                    queueSentences[start.index] = SpeechSentence(
                        text: cutText,
                        location: original.location + offset,
                        length: original.length - offset
                    )
                }
            }
        }

        speechQueue = SpeechQueue(sentences: queueSentences, index: queueStart)
        speechIndex = speechQueue?.index
        // realign 已经把队列换到新页了，之前的"手动移动"标记必须清掉。
        // 否则这条新句在本页念完时，onFinish 仍被当成"刚翻过页"而拒绝推进，
        // 最后被看护重新对齐到页首——同一句就读了两遍。
        lastManualMoveAt = 0
        // 这里**不要**再 syncPageToSpeech：起点本来就取自当前页，
        // 同步只会在句子跨页时把刚翻过去的那一页又拉回上一页。
        // 自动往下念时的翻页由 advanceSpeechText 内部的 sync 负责。
        return speechQueue?.current?.text
    }

    /// 念下一句。返回 nil 表示本章念完了。
    /// - Parameter respectsManualMove: 自动连读时为 true——刚翻页就不要按旧位置推进；
    ///   用户主动点"下一句"时传 false，那是明确意图，不该被 1 秒窗口吞掉。
    func advanceSpeechText(respectsManualMove: Bool = true) -> String? {
        guard var queue = speechQueue else { return nil }
        // 用户刚翻页/跳章：队列马上要按新页重建，此时推进旧位置会跳句。
        // 让 View 侧的 realign 接手。
        if respectsManualMove, isManuallyMovedRecently { return nil }
        guard queue.advance() else { return nil }
        speechQueue = queue
        speechIndex = queue.index
        syncPageToSpeech()
        return queue.current?.text
    }

    /// 回到上一句。已经在第一句时重新念当前这句。
    func rewindSpeechText() -> String? {
        guard var queue = speechQueue else { return nil }
        if queue.rewind() {
            speechQueue = queue
            speechIndex = queue.index
            syncPageToSpeech()
        }
        return queue.current?.text
    }

    /// 本章念完，接着念下一章。返回下一章第一句的文本。
    func beginNextChapterForSpeech(respectsManualMove: Bool = true) -> String? {
        // 朗读已经被结束（退出阅读器、点了退出、定时到点）就别再跳章开念。
        // 之前这里只看章节边界，于是 stop 之后排队到来的 didFinish 会把下一章念起来。
        guard speechQueue != nil else { return nil }
        // 用户刚翻页/跳章：让 realign 按他停下的那一页接手，不要在这里自作主张跳下一章。
        if respectsManualMove, isManuallyMovedRecently { return nil }
        guard chapterIndex + 1 < chapters.count else { return nil }

        chapterIndex += 1
        pendingPage = nil
        pageIndex = 0
        cachedKey = nil
        cachedAttributed = nil
        speechSentenceKey = nil
        speechSentences = []
        speechUnits = []
        repaginate()

        persistProgress(force: true)
        return prepareSpeech(startAtCurrentPage: true)
    }

    func endSpeech() {
        speechQueue = nil
        speechIndex = nil
    }

    /// 手动翻页后让朗读跟到当前页的第一句；不在朗读状态时返回 nil。
    /// 换源后把新清单接进来：书 id 不变，进度与书签继续沿用。
    @discardableResult
    func applySourceSwitch(_ updated: Book) -> Bool {
        guard updated.id == book.id else { return false }
        do {
            let newChapters = try provider.chapters(for: updated)
            guard !newChapters.isEmpty else { return false }

            // 换源后章节序号可能整体错位（新源多了序章/分卷），
            // 先按"当前这一章的标题"在新目录里对齐，找不到才退回原序号。
            let anchor = chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].title : nil

            book = updated
            chapters = newChapters
            if let anchor, let matched = Self.matchChapter(title: anchor, in: newChapters) {
                chapterIndex = matched
            } else {
                chapterIndex = min(max(chapterIndex, 0), newChapters.count - 1)
            }
            pageIndex = 0
            cachedAttributed = nil
            cachedKey = nil
            speechQueue = nil
            speechSentences = []
            repaginate()
            applyPendingPage()
            persistProgress(force: true)
            loadBodyIfNeeded()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// 按章节标题对齐换源后的位置。
    /// 先精确匹配，再比对去掉「第 N 章」后的标题，最后退化到互相包含。
    private static func matchChapter(title: String, in chapters: [NovelChapter]) -> Int? {
        let target = normalizeChapterTitle(title)
        guard !target.isEmpty else { return nil }

        if let exact = chapters.firstIndex(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == title.trimmingCharacters(in: .whitespacesAndNewlines)
        }) {
            return exact
        }
        if let same = chapters.firstIndex(where: { normalizeChapterTitle($0.title) == target }) {
            return same
        }
        return chapters.firstIndex(where: {
            let candidate = normalizeChapterTitle($0.title)
            return !candidate.isEmpty && (candidate.contains(target) || target.contains(candidate))
        })
    }

    private static func normalizeChapterTitle(_ title: String) -> String {
        var text = title
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "^第[0-9零一二三四五六七八九十百千两]+[章回节卷]",
                                  options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text
    }

    func realignSpeechToCurrentPage() -> String? {
        guard speechQueue != nil else { return nil }
        return prepareSpeech(startAtCurrentPage: true)
    }

    var speechStatusText: String {
        // 队列已经没了还写"朗读中"，用户会以为卡死。如实说停了，点播放能重开。
        guard let queue = speechQueue else { return "朗读已停止" }
        return "朗读中 · 第 \(chapterIndex + 1) 章 第 \(queue.index + 1)/\(queue.count) 句"
    }

    /// 当前该念的那一句。恢复时优先续念它，而不是回到页首重来。
    func currentSpeechText() -> String? {
        speechQueue?.current?.text
    }

    var speechDetailText: String {
        guard let queue = speechQueue else { return "" }
        let remaining = max(queue.count - queue.index - 1, 0)
        return "本章还剩 \(remaining) 句"
    }

    /// 让当前页跟上正在念的那一句。
    ///
    /// 先看当前页和这一句有没有交集：有一半在这页上就别翻。
    /// 以前只看句首位置，一句话跨页时会从下一页翻回上一页，用户看到的就是"页面自己往回跳"。
    private func syncPageToSpeech() {
        guard let sentence = speechQueue?.current else { return }

        if pageRanges.indices.contains(pageIndex) {
            let overlap = NSIntersectionRange(sentence.range, pageRanges[pageIndex])
            if overlap.length > 0 { return }
        }

        guard let target = pageRanges.firstIndex(where: { NSLocationInRange(sentence.location, $0) }) else {
            return
        }
        guard target != pageIndex else { return }
        pageIndex = target
        persistProgress(force: true)
    }
}
