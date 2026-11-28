import Foundation

/// 读取 Venera 漫画源声明的 `idMatch`。
///
/// `idMatch` 是源脚本里的一个正则字符串，用来表示“用户输入长这样时，
/// 它其实是一个漫画编号，不是书名”。禁漫天堂的规则是：
/// `^(\\d+|jm\\d+)$`，所以 `12345` 和 `jm12345` 都应该走编号直达。
///
/// 这里先做静态提取，不执行 JS。除了直接字面量，也支持常见的
/// `const PREFIX = "..."` / `idMatch = PREFIX`、`new RegExp("...")`
/// 和没有 `${}` 的模板字符串。真正依赖运行时计算的写法，交给
/// `VeneraRuntime.idMatchPattern(source:)` 兜底。
public enum VeneraIDMatch {

    public static func pattern(from source: VeneraSource) -> String? {
        extractPattern(from: source.js)
    }

    /// 返回完整命中的编号；不命中返回 nil。
    public static func id(from input: String, source: VeneraSource) -> String? {
        guard let pattern = pattern(from: source) else { return nil }
        return id(from: input, pattern: pattern)
    }

    /// 已经拿到正则字符串时直接匹配，供运行时兜底解析复用。
    public static func id(from input: String, pattern: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = trimmed as NSString
        guard let match = regex.firstMatch(in: trimmed,
                                           options: [],
                                           range: NSRange(location: 0, length: ns.length)),
              match.range.location != NSNotFound,
              match.range.length > 0 else { return nil }
        return ns.substring(with: match.range)
    }

    private static func extractPattern(from js: String) -> String? {
        if let direct = extractDirectLiteral(from: js) { return direct }
        if let referenced = extractReferencedLiteral(from: js) { return referenced }
        if let constructed = extractRegExpConstructor(from: js) { return constructed }
        return nil
    }

    /// 兼容几种常见的源写法：
    ///   idMatch: "..."
    ///   idMatch = '...'
    ///   class X { static idMatch = /.../i }
    ///   ...;idMatch="..."
    /// 只接受行首、代码块开头或分号/逗号后面的赋值，避免把注释里的同名字样
    /// 当成真实规则。
    private static func extractDirectLiteral(from js: String) -> String? {
        let extraction = #"(?m)(?:^|[;{},])[ \t]*(?:static[ \t]+)?(?:this\.)?idMatch[ \t]*[:=][ \t]*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|/((?:\\.|[^/\n\\])*)/([A-Za-z]*)|`((?:\\.|[^`\\])*)`)"#
        guard let regex = try? NSRegularExpression(pattern: extraction) else { return nil }
        let ns = js as NSString
        guard let match = regex.firstMatch(in: js,
                                           options: [],
                                           range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }

        if match.range(at: 1).location != NSNotFound {
            return unescapeJSString(ns.substring(with: match.range(at: 1)))
        }
        if match.range(at: 2).location != NSNotFound {
            return unescapeJSString(ns.substring(with: match.range(at: 2)))
        }
        if match.range(at: 3).location != NSNotFound {
            return ns.substring(with: match.range(at: 3))
                .replacingOccurrences(of: "\\/", with: "/")
        }
        if match.range(at: 5).location != NSNotFound {
            let value = ns.substring(with: match.range(at: 5))
            guard !value.contains("${") else { return nil }
            return unescapeJSString(value)
        }
        return nil
    }

    /// `const ID_PATTERN = "..."` 后面再 `idMatch = ID_PATTERN`。
    private static func extractReferencedLiteral(from js: String) -> String? {
        let constantPattern = #"(?m)(?:^|[;{}])[ \t]*(?:const|let|var)[ \t]+([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*=[ \t]*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|`((?:\\.|[^`\\])*)`)[ \t]*;"#
        guard let constantRegex = try? NSRegularExpression(pattern: constantPattern) else {
            return nil
        }
        let ns = js as NSString
        var constants: [String: String] = [:]
        constantRegex.enumerateMatches(in: js,
                                       options: [],
                                       range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let name = ns.substring(with: match.range(at: 1))
            for group in 2...4 where match.range(at: group).location != NSNotFound {
                let raw = ns.substring(with: match.range(at: group))
                if group == 4 && raw.contains("${") { continue }
                constants[name] = unescapeJSString(raw)
                return
            }
        }

        guard !constants.isEmpty else { return nil }

        let referencePattern = #"(?m)(?:^|[;{},])[ \t]*(?:static[ \t]+)?(?:this\.)?idMatch[ \t]*[:=][ \t]*([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*(?:[,;}]|$)"#
        guard let referenceRegex = try? NSRegularExpression(pattern: referencePattern),
              let match = referenceRegex.firstMatch(in: js,
                                                     options: [],
                                                     range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return constants[ns.substring(with: match.range(at: 1))]
    }

    /// `idMatch = new RegExp("^(\\d+)$")`。
    private static func extractRegExpConstructor(from js: String) -> String? {
        let pattern = #"(?m)(?:^|[;{},])[ \t]*(?:static[ \t]+)?(?:this\.)?idMatch[ \t]*[:=][ \t]*new[ \t]+RegExp[ \t]*\(\s*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|`((?:\\.|[^`\\])*)`)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = js as NSString
        guard let match = regex.firstMatch(in: js,
                                           options: [],
                                           range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            let raw = ns.substring(with: match.range(at: group))
            if group == 3 && raw.contains("${") { continue }
            return unescapeJSString(raw)
        }
        return nil
    }

    private static func unescapeJSString(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "\\\\", with: "\\")
        text = text.replacingOccurrences(of: "\\\"", with: "\"")
        text = text.replacingOccurrences(of: "\\'", with: "'")
        text = text.replacingOccurrences(of: "\\/", with: "/")
        return text
    }
}
