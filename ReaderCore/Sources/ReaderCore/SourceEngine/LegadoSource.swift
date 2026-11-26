import Foundation

/// 解析后的 legado 书源。
///
/// `BookSource` 是数据库里的那一行（只存原始 JSON 和开关状态），
/// `LegadoSource` 才是把 JSON 拆出来的规则视图——搜索、详情、目录、正文都读它。
///
/// 字段全部容忍缺失：2500 个网友源里什么写法都有，缺一个键不能让整条源作废。
public struct LegadoSource: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    /// 0 文本 / 1 音频 / 2 图片 / 3 文件。漫画源是 2。
    public var type: Int
    public var enabled: Bool
    public var header: String?
    public var searchUrl: String
    public var exploreUrl: String?
    public var ruleSearch: SearchRule
    /// 发现页规则。结构与搜索一致，只是入口地址来自 exploreUrl 里的分类。
    public var ruleExplore: SearchRule
    public var ruleBookInfo: BookInfoRule
    public var ruleToc: TocRule
    public var ruleContent: ContentRule
    public var rawJson: String

    public init(id: String,
                name: String,
                url: String,
                type: Int = 0,
                enabled: Bool = true,
                header: String? = nil,
                searchUrl: String = "",
                exploreUrl: String? = nil,
                ruleSearch: SearchRule = SearchRule(),
                ruleExplore: SearchRule = SearchRule(),
                ruleBookInfo: BookInfoRule = BookInfoRule(),
                ruleToc: TocRule = TocRule(),
                ruleContent: ContentRule = ContentRule(),
                rawJson: String = "") {
        self.id = id
        self.name = name
        self.url = url
        self.type = type
        self.enabled = enabled
        self.header = header
        self.searchUrl = searchUrl
        self.exploreUrl = exploreUrl
        self.ruleSearch = ruleSearch
        self.ruleExplore = ruleExplore
        self.ruleBookInfo = ruleBookInfo
        self.ruleToc = ruleToc
        self.ruleContent = ruleContent
        self.rawJson = rawJson
    }

    public var isComic: Bool { type == 2 }
    public var isText: Bool { type == 0 }
}

// MARK: - 四类规则

public struct SearchRule: Equatable, Sendable {
    public var bookList: String
    public var name: String
    public var author: String
    public var kind: String
    public var wordCount: String
    public var lastChapter: String
    public var intro: String
    public var coverUrl: String
    public var bookUrl: String

    public init(bookList: String = "",
                name: String = "",
                author: String = "",
                kind: String = "",
                wordCount: String = "",
                lastChapter: String = "",
                intro: String = "",
                coverUrl: String = "",
                bookUrl: String = "") {
        self.bookList = bookList
        self.name = name
        self.author = author
        self.kind = kind
        self.wordCount = wordCount
        self.lastChapter = lastChapter
        self.intro = intro
        self.coverUrl = coverUrl
        self.bookUrl = bookUrl
    }
}

public struct BookInfoRule: Equatable, Sendable {
    public var name: String
    public var author: String
    public var kind: String
    public var wordCount: String
    public var lastChapter: String
    public var intro: String
    public var coverUrl: String
    public var tocUrl: String

    public init(name: String = "",
                author: String = "",
                kind: String = "",
                wordCount: String = "",
                lastChapter: String = "",
                intro: String = "",
                coverUrl: String = "",
                tocUrl: String = "") {
        self.name = name
        self.author = author
        self.kind = kind
        self.wordCount = wordCount
        self.lastChapter = lastChapter
        self.intro = intro
        self.coverUrl = coverUrl
        self.tocUrl = tocUrl
    }
}

public struct TocRule: Equatable, Sendable {
    public var chapterList: String
    public var chapterName: String
    public var chapterUrl: String
    public var updateTime: String
    public var nextTocUrl: String

    public init(chapterList: String = "",
                chapterName: String = "",
                chapterUrl: String = "",
                updateTime: String = "",
                nextTocUrl: String = "") {
        self.chapterList = chapterList
        self.chapterName = chapterName
        self.chapterUrl = chapterUrl
        self.updateTime = updateTime
        self.nextTocUrl = nextTocUrl
    }
}

public struct ContentRule: Equatable, Sendable {
    public var content: String
    public var nextContentUrl: String

    public init(content: String = "", nextContentUrl: String = "") {
        self.content = content
        self.nextContentUrl = nextContentUrl
    }
}
