import Foundation

public enum LegadoParserError: LocalizedError, Equatable {
    case invalidJSON
    case empty

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "这不是有效的 JSON 文件"
        case .empty: return "文件里没有可用的书源"
        }
    }
}

/// legado（开源阅读）书源导入。
///
/// 两种常见结构都要吃：
/// - 顶层数组：`[{...}, {...}]`，2500 源合集就是这种；
/// - 顶层单个对象：`{...}`，网友分享的单条源。
///
/// 解析只做"拆包 + 取字段"，不碰规则语义。规则怎么执行是 `RuleRunner` 的事。
public enum LegadoParser {

    public static func parse(json: String) throws -> [LegadoSource] {
        guard let data = json.data(using: .utf8) else { throw LegadoParserError.invalidJSON }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> [LegadoSource] {
        var data = data
        // 有些编辑器/网盘导出的 JSON 带 UTF-8 BOM，JSONSerialization 会直接判失败
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data = data.dropFirst(3)
        }

        let dicts = try extractDicts(from: data)
        var result: [LegadoSource] = []
        var seen = Set<String>()

        for (index, dict) in dicts.enumerated() {
            // 每条源都有一份规则字符串，逐条回收临时对象，几千条时峰值内存能降一半
            guard let source = autoreleasepool(invoking: { source(from: dict, index: index) }) else {
                continue
            }
            // 同一个 URL 只留第一条：不少合集里会重复收录
            guard seen.insert(source.id).inserted else { continue }
            result.append(source)
        }

        guard !result.isEmpty else { throw LegadoParserError.empty }
        return result
    }

    /// 把各种常见导出形态统一成「一组字典」。
    ///
    /// 网友分享的源不止标准数组一种：有套 `bookSources` 的、有按 URL 建索引的、
    /// 有一行一条的 JSONL，还有 Windows 工具存成 GBK 的。
    private static func extractDicts(from data: Data) throws -> [[String: Any]] {
        if let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let dicts = flatten(root) {
            return dicts
        }

        // 编码兜底：GBK / UTF-16 的 JSON，先转成 UTF-8 再解析
        if let decoded = TextDecoder.decode(data),
           let converted = decoded.text.data(using: .utf8),
           converted != data,
           let root = try? JSONSerialization.jsonObject(with: converted, options: [.fragmentsAllowed]),
           let dicts = flatten(root) {
            return dicts
        }

        // JSON Lines：一行一条源，整份不是合法 JSON 数组
        if let decoded = TextDecoder.decode(data) {
            let lines = decoded.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if lines.count > 1 {
                let dicts = lines.compactMap { line -> [String: Any]? in
                    guard let lineData = line.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                        return nil
                    }
                    return object
                }
                if !dicts.isEmpty { return dicts }
            }
        }

        throw LegadoParserError.invalidJSON
    }

    private static func flatten(_ root: Any) -> [[String: Any]]? {
        if let array = root as? [[String: Any]] { return array }
        guard let single = root as? [String: Any] else { return nil }

        if let nested = single["bookSources"] as? [[String: Any]] { return nested }
        if let nested = single["data"] as? [[String: Any]] { return nested }

        // {"https://a.example": {...}, "https://b.example": {...}}
        let values = single.values.compactMap { $0 as? [String: Any] }
        if values.count == single.count,
           !values.isEmpty,
           values.allSatisfy({ $0["bookSourceName"] != nil || $0["bookSourceUrl"] != nil }) {
            return values
        }

        return [single]
    }

    // MARK: 单条

    private static func source(from dict: [String: Any], index: Int) -> LegadoSource? {
        let name = string(dict, "bookSourceName").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = string(dict, "bookSourceUrl").trimmingCharacters(in: .whitespacesAndNewlines)
        // 老式分享会在地址后附 "##分组/备注"，真正能请求的只有前半段
        let url = rawURL.components(separatedBy: "##").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? rawURL
        // 名字和地址都空的条目没有意义，通常是占位项
        guard !name.isEmpty || !url.isEmpty else { return nil }

        let raw = rawJSONString(dict)

        let search = dictValue(dict, "ruleSearch")
        let explore = dictValue(dict, "ruleExplore")
        let info = dictValue(dict, "ruleBookInfo")
        let toc = dictValue(dict, "ruleToc")
        let content = dictValue(dict, "ruleContent")

        return LegadoSource(
            id: url.isEmpty ? "source-\(index)-\(name)" : url,
            name: name.isEmpty ? url : name,
            url: url,
            type: int(dict, "bookSourceType"),
            enabled: bool(dict, "enabled", fallback: true),
            header: string(dict, "header").isEmpty ? nil : string(dict, "header"),
            searchUrl: string(dict, "searchUrl"),
            exploreUrl: string(dict, "exploreUrl").isEmpty ? nil : string(dict, "exploreUrl"),
            ruleSearch: SearchRule(
                bookList: string(search, "bookList"),
                name: string(search, "name"),
                author: string(search, "author"),
                kind: string(search, "kind"),
                wordCount: string(search, "wordCount"),
                lastChapter: string(search, "lastChapter"),
                intro: string(search, "intro"),
                coverUrl: string(search, "coverUrl"),
                bookUrl: string(search, "bookUrl")
            ),
            ruleExplore: SearchRule(
                bookList: string(explore, "bookList"),
                name: string(explore, "name"),
                author: string(explore, "author"),
                kind: string(explore, "kind"),
                wordCount: string(explore, "wordCount"),
                lastChapter: string(explore, "lastChapter"),
                intro: string(explore, "intro"),
                coverUrl: string(explore, "coverUrl"),
                bookUrl: string(explore, "bookUrl")
            ),
            ruleBookInfo: BookInfoRule(
                name: string(info, "name"),
                author: string(info, "author"),
                kind: string(info, "kind"),
                wordCount: string(info, "wordCount"),
                lastChapter: string(info, "lastChapter"),
                intro: string(info, "intro"),
                coverUrl: string(info, "coverUrl"),
                tocUrl: string(info, "tocUrl")
            ),
            ruleToc: TocRule(
                chapterList: string(toc, "chapterList"),
                chapterName: string(toc, "chapterName"),
                chapterUrl: string(toc, "chapterUrl"),
                updateTime: string(toc, "updateTime"),
                nextTocUrl: string(toc, "nextTocUrl")
            ),
            ruleContent: ContentRule(
                content: string(content, "content"),
                nextContentUrl: string(content, "nextContentUrl")
            ),
            rawJson: raw
        )
    }

    // MARK: 取值（容忍 NSNumber / Bool / 缺失）

    private static func dictValue(_ dict: [String: Any], _ key: String) -> [String: Any] {
        dict[key] as? [String: Any] ?? [:]
    }

    private static func string(_ dict: [String: Any], _ key: String) -> String {
        if let value = dict[key] as? String { return value }
        if let value = dict[key] as? NSNumber { return value.stringValue }
        return ""
    }

    private static func int(_ dict: [String: Any], _ key: String) -> Int {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? NSNumber { return value.intValue }
        if let value = dict[key] as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func bool(_ dict: [String: Any], _ key: String, fallback: Bool) -> Bool {
        if let value = dict[key] as? Bool { return value }
        if let value = dict[key] as? NSNumber { return value.boolValue }
        if let value = dict[key] as? String {
            let lower = value.lowercased()
            if lower == "true" || lower == "1" { return true }
            if lower == "false" || lower == "0" { return false }
        }
        return fallback
    }

    private static func rawJSONString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
