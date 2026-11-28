import Foundation
import JavaScriptCore
import SwiftSoup
import CryptoKit

public enum VeneraEngineError: LocalizedError {
    case invalidSource(String)
    case runtime(String)
    case script(String)
    case emptyResult(String)
    case unsupported(String)
    case idLookup(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let name): return "「\(name)」不是有效的 Venera 漫画源。"
        case .runtime(let message): return "Venera 运行时错误：\(message)"
        case .script(let message): return "Venera 源脚本报错：\(message)"
        case .emptyResult(let what): return "Venera 源没有返回\(what)。"
        case .unsupported(let message): return message
        case .idLookup(let message): return "编号直达失败：\(message)"
        }
    }
}

/// 一个 Venera 漫画源的执行器。
///
/// 设计要点：
/// - 每次操作新建一个 `JSContext`，把 Venera 官方的 `init.js` 和源脚本一起求值；
///   这样多源搜索可以真正并发，也不会把某个源的全局状态串到另一个源。
/// - JS 里的 `sendMessage` 由 Swift 同步实现；HTTP 用信号量等 URLSession 返回。
///   代价是占用一条后台线程，但搜索/详情都在后台，不阻塞 UI。
/// - JS 的 async/await 依赖 microtask；每次 `evaluateScript("void 0")` 都会把
///   microtask 队列排空，从而让 `await sendMessage(...)` 继续往下走。
public final class VeneraRuntime: @unchecked Sendable {

    private static let initScript: String = {
        guard let url = Bundle.module.url(forResource: "venera_init", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }()

    public init() {}

    private final class DetailCacheBox {
        let detail: VeneraDetail
        let savedAt: Date
        init(detail: VeneraDetail) {
            self.detail = detail
            self.savedAt = Date()
        }
    }

    /// 同一本书刚看过详情，加入书架 / 打开阅读时不要再去源站跑一遍脚本。
    private let detailCache = NSCache<NSString, DetailCacheBox>()
    private let detailCacheSeconds: TimeInterval = 600

    // MARK: - 对外

    /// 搜索。Venera 源如果声明了 `idMatch`（例如禁漫天堂 `^(\\d+|jm\\d+)$`），
    /// 输入纯编号或 `jm+编号` 时先直接拉详情；详情失败时仍回退普通关键词搜索。
    public func search(source: VeneraSource,
                       keyword: String,
                       page: Int = 1,
                       timeout: TimeInterval = 30) async throws -> [OnlineBook] {
        try await search(source: source,
                         keyword: keyword,
                         page: page,
                         timeout: timeout,
                         directOnly: false)
    }

    /// 用户在数字编号源选择页选中某个源后调用：只允许编号直达，
    /// 编号无效、详情打不开时明确报错，不再把编号当关键词回退搜索。
    public func searchByID(source: VeneraSource,
                           keyword: String,
                           timeout: TimeInterval = 40) async throws -> [OnlineBook] {
        do {
            return try await search(source: source,
                                    keyword: keyword,
                                    page: 1,
                                    timeout: timeout,
                                    directOnly: true)
        } catch let error as VeneraEngineError {
            if case .script(let message) = error {
                throw VeneraEngineError.idLookup(message)
            }
            throw error
        }
    }

    private func search(source: VeneraSource,
                        keyword: String,
                        page: Int,
                        timeout: TimeInterval,
                        directOnly: Bool) async throws -> [OnlineBook] {
        let result = try await perform(source: source, timeout: timeout, call: """
        await (async () => {
            const rawKeyword = \(jsLiteral(keyword));
            const keywordText = String(rawKeyword || '').trim();
            const idMatcher = __source.idMatch;
            const directOnly = \(directOnly ? "true" : "false");
            let directError = null;

            if (idMatcher && __source.comic && typeof __source.comic.loadInfo === 'function') {
                try {
                    let re = null;
                    if (typeof idMatcher === 'string') {
                        re = new RegExp(idMatcher, 'i');
                    } else if (typeof idMatcher.exec === 'function') {
                        re = idMatcher;
                    }
                    const match = re ? keywordText.match(re) : null;
                    if (match && match[0]) {
                        let comicId = String(match[0]).replace(/^JM/i, 'jm');
                        const d = await __source.comic.loadInfo(comicId);
                        if (d && String(d.title || '').length > 0) {
                            const tagObject = d.tags && typeof d.tags === 'object' ? d.tags : {};
                            const authorValue = tagObject['Author']
                                ?? tagObject['author']
                                ?? tagObject['作者']
                                ?? '';
                            const authorText = Array.isArray(authorValue)
                                ? authorValue.map(v => String(v || '')).join(' / ')
                                : String(authorValue || '');
                            const tagValues = [];
                            for (const value of Object.values(tagObject)) {
                                if (Array.isArray(value)) {
                                    for (const item of value) {
                                        const text = String(item || '').trim();
                                        if (text) tagValues.push(text);
                                    }
                                } else {
                                    const text = String(value || '').trim();
                                    if (text) tagValues.push(text);
                                }
                            }
                            const chapterCount = d.chapters && typeof d.chapters.size === 'number'
                                ? Number(d.chapters.size)
                                : 0;
                            return JSON.stringify({
                                comics: [{
                                    id: comicId,
                                    title: String(d.title || ''),
                                    subTitle: authorText,
                                    cover: String(d.cover || ''),
                                    description: String(d.description || ''),
                                    tags: tagValues,
                                    lastChapter: chapterCount > 0
                                        ? `ID 直达 · 共 ${chapterCount} 话`
                                        : 'ID 直达'
                                }],
                                maxPage: 1,
                                __directID: comicId
                            });
                        }
                        directError = '源没有返回编号 ' + comicId + ' 的详情';
                    } else {
                        directError = '编号 ' + keywordText + ' 不匹配源的 idMatch 规则';
                    }
                } catch (e) {
                    directError = '编号 ' + keywordText + ' 在这个源打不开：'
                        + String((e && e.message) ? e.message : e);
                }
            } else if (idMatcher) {
                directError = '这个源没有实现 comic.loadInfo，不能用编号直达';
            } else {
                directError = '这个源没有声明 idMatch，不能用编号直达';
            }

            if (directOnly) {
                throw directError || '编号直达失败';
            }

            const api = __source.search || {};
            let value;
            if (typeof api.load === 'function') {
                value = await api.load(\(jsLiteral(keyword)), [], \(max(1, page)));
            } else if (typeof api.loadNext === 'function') {
                value = await api.loadNext(\(jsLiteral(keyword)), [], null);
            } else {
                throw '源没有实现 search.load 或 search.loadNext';
            }
            return JSON.stringify(value);
        })()
        """)
        let decoded = jsonValue(result)
        guard let object = decoded as? [String: Any] else {
            throw VeneraEngineError.emptyResult("搜索结果")
        }
        let comics = (object["comics"] as? [[String: Any]])
            ?? (decoded as? [[String: Any]])
            ?? []
        return comics.compactMap { comic -> OnlineBook? in
            let id = string(comic["id"])
            let title = string(comic["title"])
            guard !id.isEmpty, !title.isEmpty else { return nil }
            let subtitle = string(comic["subTitle"]).isEmpty
                ? string(comic["subtitle"])
                : string(comic["subTitle"])
            let tags = (comic["tags"] as? [Any])?.map { string($0) }.filter { !$0.isEmpty } ?? []
            return OnlineBook(
                sourceId: source.id,
                name: title,
                author: subtitle,
                coverUrl: string(comic["cover"]),
                intro: string(comic["description"]),
                kind: tags.joined(separator: " / "),
                lastChapter: string(comic["lastChapter"]),
                bookUrl: id
            )
        }
    }

    // MARK: - 发现页

    /// 读取源声明的发现页列表。CopyManga 的类型是 `singlePageWithMultiPart`，
    /// 其他常见类型是 `multiPartPage`、`multiPageComicList`、`mixed`。
    public func explorePages(source: VeneraSource,
                             timeout: TimeInterval = 20) async throws -> [VeneraExplorePage] {
        let result = try await perform(source: source, timeout: timeout, call: """
        await (async () => {
            if (!Array.isArray(__source.explore) || __source.explore.length === 0) {
                throw '这个源没有实现发现页';
            }
            const pages = __source.explore.map(p => ({
                title: String(p.title || ''),
                type: String(p.type || '')
            }));
            return JSON.stringify(pages);
        })()
        """)
        guard let array = jsonValue(result) as? [[String: Any]] else {
            throw VeneraEngineError.emptyResult("发现页列表")
        }
        return array.compactMap { item in
            let title = string(item["title"])
            guard !title.isEmpty else { return nil }
            return VeneraExplorePage(title: title, type: string(item["type"]))
        }
    }

    public func explore(source: VeneraSource,
                        page: VeneraExplorePage,
                        timeout: TimeInterval = 30) async throws -> [VeneraExploreSection] {
        let result = try await perform(source: source, timeout: timeout, call: """
        await (async () => {
            if (!Array.isArray(__source.explore) || __source.explore.length === 0) {
                throw '这个源没有实现发现页';
            }
            const page = __source.explore.find(p => String(p.title || '') === \(jsLiteral(page.title)))
                || __source.explore[0];
            if (!page) {
                throw '这个发现页不存在';
            }
            const arg = page.type === 'multiPageComicList' ? 1
                : (page.type === 'mixed' ? 0 : null);
            let value;
            if (typeof page.load === 'function') {
                value = await page.load(arg);
            } else if (typeof page.loadNext === 'function') {
                value = await page.loadNext(null);
            } else {
                throw '这个发现页没有实现 load 或 loadNext';
            }

            const looksComic = (x) => !!x && typeof x === 'object'
                && ('id' in x) && ('title' in x) && !Array.isArray(x.comics);
            let list = [];
            if (Array.isArray(value)) {
                if (value.length && value[0] && Array.isArray(value[0].comics)) {
                    list = value;
                } else if (value.length && looksComic(value[0])) {
                    list = [{ title: String(page.title || ''), comics: value }];
                }
            } else if (value && Array.isArray(value.data)) {
                for (const item of value.data) {
                    if (Array.isArray(item)) {
                        list.push({ title: String(page.title || ''), comics: item });
                    } else if (item && Array.isArray(item.comics)) {
                        list.push(item);
                    }
                }
            } else if (value && Array.isArray(value.comics)) {
                list = [{ title: String(page.title || ''), comics: value.comics }];
            } else if (value && typeof value === 'object') {
                list = Object.keys(value).map(k => ({ title: k, comics: value[k] }));
            }

            list = list.filter(s => s && Array.isArray(s.comics) && s.comics.length > 0)
                .map(s => ({
                    title: String(s.title || ''),
                    comics: s.comics,
                    viewMore: s.viewMore ? String(s.viewMore) : null
                }));
            return JSON.stringify(list);
        })()
        """)
        guard let array = jsonValue(result) as? [[String: Any]] else {
            throw VeneraEngineError.emptyResult("发现页内容")
        }
        return array.compactMap { item in
            let rawComics = item["comics"] as? [[String: Any]] ?? []
            let books = rawComics.compactMap { onlineBook(from: $0, source: source) }
            guard !books.isEmpty else { return nil }
            let title = string(item["title"]).isEmpty ? page.title : string(item["title"])
            return VeneraExploreSection(title: title,
                                        books: books,
                                        viewMore: string(item["viewMore"]).isEmpty ? nil : string(item["viewMore"]))
        }
    }

    private func onlineBook(from comic: [String: Any], source: VeneraSource) -> OnlineBook? {
        let id = string(comic["id"])
        let title = string(comic["title"])
        guard !id.isEmpty, !title.isEmpty else { return nil }
        let subtitle = string(comic["subTitle"]).isEmpty
            ? string(comic["subtitle"])
            : string(comic["subTitle"])
        let tags = (comic["tags"] as? [Any])?.map { string($0) }.filter { !$0.isEmpty } ?? []
        return OnlineBook(
            sourceId: source.id,
            name: title,
            author: subtitle,
            coverUrl: string(comic["cover"]),
            intro: string(comic["description"]),
            kind: tags.joined(separator: " / "),
            lastChapter: "",
            bookUrl: id
        )
    }

    public func detail(source: VeneraSource,
                       comicId: String,
                       timeout: TimeInterval = 40,
                       forceRefresh: Bool = false) async throws -> VeneraDetail {
        let cacheKey = "\(source.id)|\(comicId)" as NSString
        if !forceRefresh,
           let box = detailCache.object(forKey: cacheKey),
           Date().timeIntervalSince(box.savedAt) < detailCacheSeconds {
            return box.detail
        }
        let result = try await perform(source: source, timeout: timeout, call: """
        await (async () => {
            const d = await __source.comic.loadInfo(\(jsLiteral(comicId)));
            if (d && d.chapters) {
                const flatten = (value) => {
                    if (Array.isArray(value)) return value;
                    let entries;
                    if (value instanceof Map) entries = Array.from(value.entries());
                    else if (value && typeof value === 'object') entries = Object.entries(value);
                    else return [];
                    const out = [];
                    for (const [key, item] of entries) {
                        if (item instanceof Map || (item && typeof item === 'object' && !Array.isArray(item))) {
                            const sub = item instanceof Map ? Array.from(item.entries()) : Object.entries(item);
                            for (const [subKey, subValue] of sub) out.push([subKey, subValue]);
                        } else {
                            out.push([key, item]);
                        }
                    }
                    return out;
                };
                const rawChapters = d.chapters;
                d.chapters = flatten(rawChapters);
                if (d.chapters.length === 0) {
                    d.__chaptersDebug = {
                        rawType: Object.prototype.toString.call(rawChapters),
                        rawIsMap: rawChapters instanceof Map,
                        rawSize: rawChapters && rawChapters.size,
                        rawKeys: rawChapters && typeof rawChapters === 'object'
                            ? Object.keys(rawChapters).slice(0, 5)
                            : []
                    };
                }
            }
            return JSON.stringify(d);
        })()
        """)
        let decoded = jsonValue(result)
        guard let object = decoded as? [String: Any] else {
            throw VeneraEngineError.emptyResult("漫画详情")
        }
        let title = string(object["title"])
        guard !title.isEmpty else {
            let dump = object.keys.sorted().map { "\($0)=\(String(describing: object[$0]))" }
                .joined(separator: " | ")
            throw VeneraEngineError.emptyResult("漫画标题（返回：\(dump)）")
        }

        let tagObject = object["tags"] as? [String: Any] ?? [:]
        let author = firstTag(tagObject, names: ["作者", "author", "Author"])
        let kind = tagObject.keys.sorted().map { key -> String in
            let value = tagValue(tagObject[key])
            return value.isEmpty ? key : "\(key): \(value)"
        }.joined(separator: " / ")

        var chapters: [OnlineChapter] = []
        if let pairs = object["chapters"] as? [[Any]], !pairs.isEmpty {
            for pair in pairs {
                let id = string(pair[0])
                let name = string(pair[1])
                if !id.isEmpty, !name.isEmpty {
                    chapters.append(OnlineChapter(name: name, url: id))
                }
            }
        } else if let dict = object["chapters"] as? [String: Any] {
            // 没有顺序信息时按标题里的数字尽量排一下。
            chapters = dict.map { OnlineChapter(name: string($0.value), url: $0.key) }
                .sorted { naturalLess($0.name, $1.name) }
        }
        if chapters.isEmpty {
            let debug = object["__chaptersDebug"] as? [String: Any] ?? [:]
            throw VeneraEngineError.emptyResult("章节为空（\(debug)）")
        }

        let subId = string(object["subId"])
        let intro = string(object["description"])
        let detail = VeneraDetail(
            comicId: comicId,
            title: title,
            author: author,
            coverUrl: string(object["cover"]),
            intro: intro,
            kind: kind,
            chapters: chapters,
            subId: subId,
            lastChapter: chapters.last?.name ?? ""
        )
        detailCache.setObject(DetailCacheBox(detail: detail), forKey: cacheKey)
        return detail
    }

    public func pages(source: VeneraSource,
                      comicId: String,
                      epId: String,
                      timeout: TimeInterval = 70) async throws -> [String] {
        let result = try await perform(source: source, timeout: timeout, call: """
        JSON.stringify(await __source.comic.loadEp(\(jsLiteral(comicId)), \(jsLiteral(epId))))
        """)
        let decoded = jsonValue(result)
        let images: [Any]
        if let object = decoded as? [String: Any], let list = object["images"] as? [Any] {
            images = list
        } else if let list = decoded as? [Any] {
            images = list
        } else {
            throw VeneraEngineError.emptyResult("章节图片")
        }
        var urls: [String] = []
        for image in images {
            if let text = image as? String, !text.isEmpty {
                urls.append(text)
            } else if let object = image as? [String: Any] {
                let url = string(object["url"])
                if !url.isEmpty { urls.append(url) }
            }
        }
        guard !urls.isEmpty else { throw VeneraEngineError.emptyResult("章节图片") }
        return urls
    }

    /// 漫画阅读器里的「本章评论」。只有源声明了 `loadChapterComments` 才有；
    /// 没声明的源明确报不支持，而不是返回空列表让用户以为评论被删了。
    public func chapterComments(source: VeneraSource,
                                comicId: String,
                                epId: String,
                                page: Int = 1,
                                timeout: TimeInterval = 30) async throws -> VeneraCommentPage {
        let result = try await perform(source: source, timeout: timeout, call: """
        await (async () => {
            if (typeof __source.comic.loadChapterComments !== 'function') {
                throw new Error('当前源没有提供章节评论');
            }
            const r = await __source.comic.loadChapterComments(
                \(jsLiteral(comicId)), \(jsLiteral(epId)), \(max(page, 1)), null
            );
            return JSON.stringify(r || { comments: [], maxPage: 1 });
        })()
        """)
        let decoded = jsonValue(result)
        let object = decoded as? [String: Any] ?? [:]
        let rawComments = object["comments"] as? [[String: Any]] ?? []
        let comments = rawComments.enumerated().compactMap { index, item -> VeneraComment? in
            let content = string(item["content"])
            guard !content.isEmpty else { return nil }
            let rawID = string(item["id"])
            let id = rawID.isEmpty ? "\(max(page, 1))-\(index)" : rawID
            let reply = (item["replyCount"] as? NSNumber)?.intValue
            return VeneraComment(
                id: id,
                userName: string(item["userName"]).isEmpty ? "匿名" : string(item["userName"]),
                avatar: string(item["avatar"]),
                content: content,
                time: string(item["time"]),
                replyCount: reply
            )
        }
        let maxPage = (object["maxPage"] as? NSNumber)?.intValue ?? 1
        return VeneraCommentPage(comments: comments, maxPage: max(maxPage, 1))
    }

    /// 漫画图片通常不带登录 cookie，但部分站点要 Referer；统一给一个移动端 UA。
    public var imageHeaders: [String: String] {
        ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
         "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"]
    }

    // MARK: - 执行

    private func perform(source: VeneraSource,
                         timeout: TimeInterval,
                         call: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let value = try self.execute(source: source, timeout: timeout, call: call)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func execute(source: VeneraSource, timeout: TimeInterval, call: String) throws -> Any? {
        guard !Self.initScript.isEmpty else {
            throw VeneraEngineError.runtime("缺少 venera_init.js 资源")
        }
        guard let context = JSContext() else {
            throw VeneraEngineError.runtime("无法创建 JavaScriptCore 上下文")
        }

        let bridge = VeneraJSBridge(context: context, source: source)
        context.setObject(bridge.sendBlock, forKeyedSubscript: "__nativeSendMessage" as NSString)
        context.setObject(bridge.delayBlock, forKeyedSubscript: "__nativeDelay" as NSString)
        context.exceptionHandler = { _, exception in
            _ = exception?.toString()
        }

        context.evaluateScript("globalThis.appVersion = '1.9.5';")
        context.evaluateScript(Self.initScript)
        context.evaluateScript(Self.bridgePrelude)

        context.evaluateScript(source.js)
        if let exception = context.exception, !exception.isUndefined {
            throw VeneraEngineError.script(exception.toString() ?? "源脚本第 1 行执行失败")
        }

        guard let className = Self.comicSourceClassName(in: source.js) else {
            throw VeneraEngineError.invalidSource(source.name)
        }
        context.evaluateScript("globalThis.__source = new \(className)();")
        if let exception = context.exception, !exception.isUndefined {
            throw VeneraEngineError.script(exception.toString() ?? "源实例创建失败")
        }

        // 少数源在 init 里登录/取 token；有 init 才等，等它真正结束（最多 2 秒），
        // 没有 init 的源不再白等 2 秒。这是发现页首屏慢的主要来源之一。
        context.evaluateScript("""
        globalThis.__initError = undefined;
        globalThis.__initDone = false;
        (async () => {
            try {
                if (__source.init) {
                    const p = __source.init();
                    if (p && typeof p.then === 'function') { await p; }
                }
            } catch (e) {
                globalThis.__initError = '' + e;
            }
            globalThis.__initDone = true;
        })();
        """)
        pump(context, until: Date().addingTimeInterval(2.0), doneKey: "__initDone")

        let deadline = Date().addingTimeInterval(timeout)
        context.evaluateScript("""
        globalThis.__done = false;
        globalThis.__error = undefined;
        globalThis.__result = undefined;
        (async () => {
            try {
                const __v = \(call);
                globalThis.__result = __normalize(__v);
            } catch (e) {
                globalThis.__error = (e && e.message) ? e.message : ('' + e);
            }
            globalThis.__done = true;
        })();
        """)

        pump(context, until: deadline)
        guard context.objectForKeyedSubscript("__done").toBool() else {
            throw VeneraEngineError.runtime("执行超时（\(Int(timeout)) 秒）")
        }
        if let error = context.objectForKeyedSubscript("__error"),
           !error.isUndefined, !error.isNull {
            throw VeneraEngineError.script(error.toString() ?? "未知脚本错误")
        }
        return context.objectForKeyedSubscript("__result")?.toObject()
    }

    private func pump(_ context: JSContext, until deadline: Date, doneKey: String = "__done") {
        while Date() < deadline {
            if context.objectForKeyedSubscript(doneKey).toBool() { return }
            _ = context.evaluateScript("void 0")
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    // MARK: - JS 辅助

    private static let bridgePrelude = """
    function sendMessage(msg) {
        if (msg && msg.method === 'delay') {
            return new Promise(function (resolve) {
                __nativeDelay(Number(msg.time) || 0);
                resolve();
            });
        }
        return __nativeSendMessage(msg);
    }

    function __normalize(v) {
        if (v instanceof Map) {
            const o = {};
            for (const [k, val] of v) { o[k] = __normalize(val); }
            return o;
        }
        if (Array.isArray(v)) { return v.map(__normalize); }
        if (v && typeof v === 'object') {
            const o = {};
            for (const k of Object.keys(v)) { o[k] = __normalize(v[k]); }
            return o;
        }
        return v;
    }

    (function () {
        const original = ComicSource.prototype.loadSetting;
        ComicSource.prototype.loadSetting = function (key) {
            const saved = original.call(this, key);
            if (saved !== null && saved !== undefined) return saved;
            const item = this.settings && this.settings[key];
            if (typeof item === 'string' || typeof item === 'number' || typeof item === 'boolean') {
                return item;
            }
            return item ? item.default : undefined;
        };
    })();
    """

    private static func comicSourceClassName(in script: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"class\s+([A-Za-z_$][A-Za-z0-9_$]*)\s+extends\s+ComicSource"#) else {
            return nil
        }
        let range = NSRange(script.startIndex..., in: script)
        guard let match = regex.firstMatch(in: script, range: range),
              match.numberOfRanges > 1,
              let nameRange = Range(match.range(at: 1), in: script) else { return nil }
        return String(script[nameRange])
    }

    private func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    /// Venera 的返回值里经常带 Map / 数组 / 嵌套对象。直接 `toObject()`
    /// 在不同 JavaScriptCore 版本上会丢字段，所以统一走 `JSON.stringify`
    /// 再把字符串解析成 Foundation 对象。
    private func jsonValue(_ value: Any?) -> Any? {
        guard let text = value as? String else { return value }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed]) else {
            return nil
        }
        return object
    }

    private func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private func firstTag(_ tags: [String: Any], names: [String]) -> String {
        for name in names {
            if let value = tags[name] {
                let text = tagValue(value)
                if !text.isEmpty { return text }
            }
        }
        return ""
    }

    private func tagValue(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? [Any] {
            return value.map { string($0) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        return ""
    }

    private func naturalLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }
}

// MARK: - sendMessage 桥

private final class VeneraJSBridge {
    let context: JSContext
    let source: VeneraSource
    private let store: VeneraHTMLStore
    private let session: URLSession

    let sendBlock: @convention(block) (JSValue) -> JSValue
    let delayBlock: @convention(block) (Double) -> Void

    init(context: JSContext, source: VeneraSource) {
        self.context = context
        self.source = source
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)
        let store = VeneraHTMLStore()
        self.store = store

        self.sendBlock = { [weak context] message in
            guard let context else { return JSValue(undefinedIn: nil) }
            do {
                let object = try Self.handle(message: message,
                                             context: context,
                                             source: source,
                                             store: store)
                return JSValue(object: object, in: context) ?? JSValue(nullIn: context)
            } catch {
                return JSValue(object: ["error": error.localizedDescription], in: context)
                    ?? JSValue(nullIn: context)
            }
        }
        self.delayBlock = { milliseconds in
            let seconds = min(max(milliseconds, 0) / 1000.0, 60)
            if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
        }
    }

    private static func handle(message: JSValue,
                               context: JSContext,
                               source: VeneraSource,
                               store: VeneraHTMLStore) throws -> Any? {
        guard let raw = message.toDictionary() else { return nil }
        var dict: [String: Any] = [:]
        for (key, value) in raw {
            if let key = key as? String { dict[key] = value }
        }
        guard let method = dict["method"] as? String else { return nil }

        switch method {
        case "http":
            return try http(dict)
        case "convert":
            return try convert(dict)
        case "html":
            return try html(dict, store: store)
        case "load_data":
            return loadData(dict, source: source)
        case "save_data":
            saveData(dict, source: source)
            return true
        case "delete_data":
            deleteData(dict, source: source)
            return true
        case "load_setting":
            return loadSetting(dict, source: source)
        case "random":
            return random(dict)
        case "uuid":
            return UUID().uuidString.lowercased()
        case "delay":
            return true
        case "log":
            return true
        case "getLocale":
            return "zh_CN"
        case "getPlatform":
            return "ios"
        case "isLogged":
            return false
        case "cookie":
            return try cookies(dict)
        case "UI":
            return ui(dict)
        case "compute":
            return nil
        case "setClipboard", "getClipboard":
            return true
        case "image":
            return nil
        default:
            return nil
        }
    }

    // MARK: HTTP

    private static func http(_ dict: [String: Any]) throws -> [String: Any] {
        guard let urlString = dict["url"] as? String,
              let url = URL(string: urlString) else {
            return ["error": "无效 URL：\(dict["url"] ?? "")"]
        }
        let method = (dict["http_method"] as? String)?.uppercased() ?? "GET"
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20

        if let headers = dict["headers"] as? [String: Any] {
            for (key, value) in headers {
                request.setValue(String(describing: value), forHTTPHeaderField: key)
            }
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent")
        }

        if method != "GET", method != "HEAD", let data = dict["data"], !(data is NSNull) {
            if let text = data as? String {
                request.httpBody = text.data(using: .utf8)
            } else if let bytes = data as? [Any] {
                request.httpBody = Data(bytes.compactMap { ($0 as? NSNumber)?.uint8Value })
            } else if JSONSerialization.isValidJSONObject(data),
                      let json = try? JSONSerialization.data(withJSONObject: data) {
                request.httpBody = json
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var response: HTTPURLResponse?
        var responseError: Error?
        let task = URLSession.shared.dataTask(with: request) { data, urlResponse, error in
            responseData = data
            response = urlResponse as? HTTPURLResponse
            responseError = error
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 25) == .timedOut {
            task.cancel()
            return ["error": "请求超时：\(urlString)"]
        }
        if let responseError {
            return ["error": responseError.localizedDescription]
        }

        var headers: [String: String] = [:]
        if let all = response?.allHeaderFields {
            for (key, value) in all { headers[String(describing: key)] = String(describing: value) }
        }
        let status = response?.statusCode ?? 0
        let data = responseData ?? Data()
        if dict["bytes"] as? Bool == true {
            return ["status": status, "headers": headers, "body": Array(data)]
        }
        let text = response.flatMap { SourceClient.decode(data: data, response: $0) } ?? ""
        return ["status": status, "headers": headers, "body": text]
    }

    // MARK: Convert

    private static func convert(_ dict: [String: Any]) throws -> Any? {
        let type = (dict["type"] as? String)?.lowercased() ?? ""
        let isEncode = dict["isEncode"] as? Bool ?? false
        let value = dict["value"]

        switch type {
        case "utf8", "gbk":
            if isEncode {
                let text = value as? String ?? ""
                let data = text.data(using: encoding(for: type)) ?? Data()
                return Array(data)
            }
            let data = bytes(from: value)
            return String(data: data, encoding: encoding(for: type)) ?? ""

        case "base64":
            if isEncode {
                return Data(bytes(from: value)).base64EncodedString()
            }
            let text = value as? String ?? ""
            return Array(Data(base64Encoded: text, options: [.ignoreUnknownCharacters]) ?? Data())

        case "md5", "sha1", "sha256", "sha512":
            let data = bytes(from: value)
            return Array(hash(data, type: type))

        case "hmac":
            let key = bytes(from: dict["key"])
            let data = bytes(from: value)
            let hashName = (dict["hash"] as? String)?.lowercased() ?? "sha256"
            let digest = hmac(key: key, data: data, hash: hashName)
            if dict["isString"] as? Bool == true {
                return digest.map { String(format: "%02x", $0) }.joined()
            }
            return Array(digest)

        default:
            throw VeneraEngineError.unsupported("这个源用了 iOS 运行时暂不支持的加密算法：\(type)")
        }
    }

    private static func encoding(for type: String) -> String.Encoding {
        if type == "gbk" {
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return String.Encoding(rawValue: cf)
        }
        return .utf8
    }

    private static func bytes(from value: Any?) -> Data {
        if let data = value as? Data { return data }
        if let text = value as? String { return text.data(using: .utf8) ?? Data() }
        if let list = value as? [Any] {
            return Data(list.compactMap { ($0 as? NSNumber)?.uint8Value })
        }
        return Data()
    }

    private static func hash(_ data: Data, type: String) -> [UInt8] {
        switch type {
        case "md5": return Array(Insecure.MD5.hash(data: data))
        case "sha1": return Array(Insecure.SHA1.hash(data: data))
        case "sha512": return Array(SHA512.hash(data: data))
        default: return Array(SHA256.hash(data: data))
        }
    }

    private static func hmac(key: Data, data: Data, hash: String) -> [UInt8] {
        let symmetricKey = SymmetricKey(data: key)
        switch hash {
        case "md5":
            return Array(HMAC<Insecure.MD5>.authenticationCode(for: data, using: symmetricKey))
        case "sha1":
            return Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symmetricKey))
        case "sha512":
            return Array(HMAC<SHA512>.authenticationCode(for: data, using: symmetricKey))
        default:
            return Array(HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey))
        }
    }

    // MARK: HTML

    private static func html(_ dict: [String: Any], store: VeneraHTMLStore) throws -> Any? {
        let function = dict["function"] as? String ?? ""
        let key = int(dict["key"])
        switch function {
        case "parse":
            let text = dict["data"] as? String ?? ""
            let document = try SwiftSoup.parse(text)
            store.documents[key] = document
            return true
        case "dispose":
            store.dispose(document: key)
            return true
        case "querySelector":
            guard let document = store.documents[key],
                  let element = try document.select(dict["query"] as? String ?? "").first() else { return nil }
            return store.id(for: element)
        case "querySelectorAll":
            guard let document = store.documents[key] else { return [] }
            let elements = try document.select(dict["query"] as? String ?? "").array()
            return elements.map { store.id(for: $0) }
        case "getElementById":
            guard let document = store.documents[key],
                  let element = try document.getElementById(dict["id"] as? String ?? "") else { return nil }
            return store.id(for: element)
        case "dom_querySelector":
            guard let element = store.elements[key],
                  let child = try element.select(dict["query"] as? String ?? "").first() else { return nil }
            return store.id(for: child)
        case "dom_querySelectorAll":
            guard let element = store.elements[key] else { return [] }
            return try element.select(dict["query"] as? String ?? "").array().map { store.id(for: $0) }
        case "getText":
            guard let element = store.elements[key] else { return "" }
            return try element.text()
        case "getAttributes":
            guard let element = store.elements[key],
                  let attributes = element.getAttributes() else { return [:] }
            var result: [String: String] = [:]
            for attribute in attributes.asList() {
                result[attribute.getKey()] = attribute.getValue()
            }
            return result
        case "getChildren":
            guard let element = store.elements[key] else { return [] }
            return element.children().array().map { store.id(for: $0) }
        case "getNodes":
            guard let element = store.elements[key] else { return [] }
            return element.getChildNodes().map { store.id(for: $0) }
        case "getInnerHTML":
            guard let element = store.elements[key] else { return "" }
            return try element.html()
        case "getParent":
            guard let element = store.elements[key],
                  let parent = element.parent() as? Element else { return nil }
            return store.id(for: parent)
        case "getClassNames":
            guard let element = store.elements[key] else { return [] }
            return Array(try element.classNames())
        case "getId":
            guard let element = store.elements[key] else { return nil }
            let id = try element.id()
            return id.isEmpty ? nil : id
        case "getLocalName":
            return store.elements[key]?.tagName() ?? ""
        case "getPreviousSibling":
            guard let element = store.elements[key],
                  let sibling = try element.previousElementSibling() else { return nil }
            return store.id(for: sibling)
        case "getNextSibling":
            guard let element = store.elements[key],
                  let sibling = try element.nextElementSibling() else { return nil }
            return store.id(for: sibling)
        case "node_text":
            if let textNode = store.nodes[key] as? TextNode {
                return textNode.text()
            }
            if let element = store.nodes[key] as? Element {
                return (try? element.text()) ?? ""
            }
            return ""
        case "node_type":
            guard let node = store.nodes[key] else { return "unknown" }
            let name = node.nodeName()
            if name == "#text" { return "text" }
            if name == "#comment" { return "comment" }
            if name == "#document" { return "document" }
            return node is Element ? "element" : "unknown"
        case "node_toElement":
            guard let node = store.nodes[key] as? Element else { return nil }
            return store.id(for: node)
        default:
            return nil
        }
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    // MARK: 存储

    private static func storageKey(_ source: VeneraSource, _ dataKey: String) -> String {
        "venera.data.\(source.key).\(dataKey)"
    }

    private static func loadData(_ dict: [String: Any], source: VeneraSource) -> Any? {
        let dataKey = dict["data_key"] as? String ?? ""
        guard !dataKey.isEmpty else { return nil }
        let key = storageKey(source, dataKey)
        guard let stored = UserDefaults.standard.string(forKey: key) else { return nil }
        if let data = stored.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return object
        }
        return stored
    }

    private static func saveData(_ dict: [String: Any], source: VeneraSource) {
        let dataKey = dict["data_key"] as? String ?? ""
        guard !dataKey.isEmpty, let value = dict["data"] else { return }
        let key = storageKey(source, dataKey)
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(text, forKey: key)
        } else if let text = value as? String {
            UserDefaults.standard.set(text, forKey: key)
        } else {
            UserDefaults.standard.set(String(describing: value), forKey: key)
        }
    }

    private static func deleteData(_ dict: [String: Any], source: VeneraSource) {
        let dataKey = dict["data_key"] as? String ?? ""
        guard !dataKey.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: storageKey(source, dataKey))
    }

    private static func loadSetting(_ dict: [String: Any], source: VeneraSource) -> Any? {
        let settingKey = dict["setting_key"] as? String ?? ""
        guard !settingKey.isEmpty else { return nil }
        return UserDefaults.standard.string(forKey: "venera.setting.\(source.key).\(settingKey)")
    }

    // MARK: 杂项

    private static func random(_ dict: [String: Any]) -> Any {
        let minValue = (dict["min"] as? NSNumber)?.doubleValue ?? 0
        let maxValue = (dict["max"] as? NSNumber)?.doubleValue ?? 1
        if dict["type"] as? String == "double" {
            return Double.random(in: minValue...max(minValue, maxValue))
        }
        let lower = Int(minValue)
        let upper = Int(maxValue)
        return Int.random(in: lower...max(lower, upper))
    }

    private static func cookies(_ dict: [String: Any]) throws -> Any? {
        guard let urlString = dict["url"] as? String, let url = URL(string: urlString) else { return [] }
        switch dict["function"] as? String ?? "" {
        case "set":
            let cookies = (dict["cookies"] as? [[String: Any]]) ?? []
            for item in cookies {
                guard let name = item["name"] as? String, let value = item["value"] as? String else { continue }
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .path: "/",
                    .domain: item["domain"] as? String ?? url.host ?? ""
                ]
                if let domain = item["domain"] as? String { properties[.domain] = domain }
                if let cookie = HTTPCookie(properties: properties) {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
            }
            return true
        case "get":
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            return cookies.map { ["name": $0.name, "value": $0.value, "domain": $0.domain] }
        case "delete":
            for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
            return true
        default:
            return []
        }
    }

    private static func ui(_ dict: [String: Any]) -> Any? {
        switch dict["function"] as? String ?? "" {
        case "showSelectDialog":
            return dict["initialIndex"] as? Int ?? 0
        case "showInputDialog":
            return nil
        case "showLoading":
            return 0
        default:
            return nil
        }
    }
}

// MARK: - HTML 文档/元素注册表

private final class VeneraHTMLStore {
    var documents: [Int: Document] = [:]
    var elements: [Int: Element] = [:]
    var nodes: [Int: Node] = [:]
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 1

    func id(for node: Node) -> Int {
        let objectID = ObjectIdentifier(node)
        if let existing = ids[objectID] { return existing }
        let newID = nextID
        nextID += 1
        ids[objectID] = newID
        nodes[newID] = node
        if let element = node as? Element { elements[newID] = element }
        return newID
    }

    func dispose(document key: Int) {
        documents.removeValue(forKey: key)
    }
}

