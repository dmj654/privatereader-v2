import Foundation

/// 读取 Venera 漫画源声明的 `idMatch`。
///
/// `idMatch` 是源脚本里的一个正则字符串，用来表示“用户输入长这样时，
/// 它其实是一个漫画编号，不是书名”。禁漫天堂的规则是：
/// `^(\\d+|jm\\d+)$`，所以 `12345` 和 `jm12345` 都应该走编号直达。
///
/// 这里不执行 JS，只从脚本源码里提取这个字面量；提取失败就当作这个源
/// 不支持编号直达，不会影响普通搜索。
public enum VeneraIDMatch {

    public static func pattern(from source: VeneraSource) -> String? {
        extractPattern(from: source.js)
    }

    /// 返回完整命中的编号；不命中返回 nil。
    public static func id(from input: String, source: VeneraSource) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pattern = pattern(from: source) else { return nil }
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
        // 兼容几种常见的源写法：
        //   idMatch: "..."
        //   idMatch = '...'
        //   class X { idMatch = /.../i }
        //   ...;idMatch="..."
        // 只接受行首、代码块开头或分号/逗号后面的赋值，避免把注释里的同名字样
        // 当成真实规则；真正的动态赋值（不是字面量）仍然识别不了。
        let extraction = #"(?m)(?:^|[;{},])[ \t]*(?:this\.)?idMatch[ \t]*[:=][ \t]*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|/((?:\\.|[^/\n\\])*)/([A-Za-z]*))"#
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
