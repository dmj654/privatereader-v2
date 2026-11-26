import Foundation
import SwiftSoup

/// legado 规则执行器。
///
/// 支持的写法（2500 个网友源里最常见的部分）：
/// - CSS：`class.book-item@tag.h3@text`、`id.content@html`、`tag.a.0@href`
/// - 净化：`内容##广告正则##`（`##` 后可留空表示删除）
/// - 串联：`规则A&&规则B`，B 作用在 A 的结果上
/// - 备选：`规则A||规则B`，取第一个非空
/// - 模板：`/search?q={{key}}&page={{page}}`
/// - 相对地址：自动按 baseUrl 补全
///
/// 暂不支持的（会在结果为 `@js:` 时原样返回空串，交由后续 JS 引擎处理）：
/// - `@js:` 脚本、`<js>` 脚本块
/// - 复杂 JSONPath（只做基础取值）
public enum RuleRunner {

    // MARK: 对外

    /// 从 HTML 里按规则取一个字符串。
    public static func string(_ rule: String,
                              html: String,
                              baseUrl: String = "",
                              variables: [String: String] = [:]) -> String {
        evaluateString(rule, html: html, baseUrl: baseUrl, variables: variables)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 HTML 里按列表规则取多个片段（每个片段的 outerHTML）。
    public static func elements(_ rule: String,
                                html: String,
                                baseUrl: String = "",
                                variables: [String: String] = [:]) -> [String] {
        let resolved = applyVariables(rule, variables: variables)
        guard !resolved.isEmpty else { return [] }

        // JSON 源：`$.data[*]` 这类先按基础 JSONPath 取
        if resolved.hasPrefix("$.") {
            return jsonElements(resolved, json: html)
        }

        let tokens = resolved.components(separatedBy: "@")
        guard let first = tokens.first, !first.isEmpty else { return [] }
        guard let doc = try? SwiftSoup.parse(html) else { return [] }

        // 列表规则常见 `class.book-list@tag.li`，要一路选下去
        let (firstSelector, firstIndex) = cssToken(first)
        guard var matched = try? doc.select(firstSelector).array(), !matched.isEmpty else { return [] }

        if let firstIndex {
            let resolvedIndex = firstIndex < 0 ? matched.count + firstIndex : firstIndex
            guard matched.indices.contains(resolvedIndex) else { return [] }
            matched = [matched[resolvedIndex]]
        }

        for token in tokens.dropFirst() {
            guard !isAttributeToken(token) else { break }
            let (selector, index) = cssToken(token)
            var next: [Element] = []
            for element in matched {
                guard let found = try? element.select(selector).array() else { continue }
                next.append(contentsOf: found)
            }
            if let index {
                let resolvedIndex = index < 0 ? next.count + index : index
                guard next.indices.contains(resolvedIndex) else { return [] }
                next = [next[resolvedIndex]]
            }
            guard !next.isEmpty else { return [] }
            matched = next
        }

        return matched.compactMap { try? $0.outerHtml() }
    }

    /// 相对地址补全。空字符串保持空，绝对地址原样返回。
    public static func resolveURL(_ raw: String, baseUrl: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return text }
        guard let base = URL(string: baseUrl) else { return text }
        return URL(string: text, relativeTo: base)?.absoluteString ?? text
    }

    // MARK: 字符串规则

    private static func evaluateString(_ rule: String,
                                       html: String,
                                       baseUrl: String,
                                       variables: [String: String]) -> String {
        let resolved = applyVariables(rule, variables: variables)
        guard !resolved.isEmpty else { return "" }

        // `||` 备选：取第一个非空
        if resolved.contains("||") {
            for candidate in resolved.components(separatedBy: "||") {
                let value = evaluateString(candidate, html: html, baseUrl: baseUrl, variables: [:])
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
            return ""
        }

        // `&&` 串联：第一段取结果，后续段作用在结果上
        if resolved.contains("&&") {
            var current = html
            for (index, segment) in resolved.components(separatedBy: "&&").enumerated() {
                if segment.hasPrefix("##") {
                    current = purify(segment, text: current)
                } else {
                    current = evaluateString(segment,
                                             html: index == 0 ? html : current,
                                             baseUrl: baseUrl,
                                             variables: [:])
                }
            }
            return current
        }

        // 纯净化规则
        if resolved.hasPrefix("##") {
            return purify(resolved, text: html)
        }

        // `选择器@属性##净化`：先取值，再对取到的文字做净化。
        // 这类写法在 ruleContent 里非常常见，不能把它整个丢给 CSS 解析。
        if let purifyStart = resolved.range(of: "##") {
            let base = String(resolved[..<purifyStart.lowerBound])
            let purifyPart = "##" + resolved[purifyStart.upperBound...]
            let value = evaluateString(base, html: html, baseUrl: baseUrl, variables: [:])
            return purify(purifyPart, text: value)
        }

        // 纯地址 / 未替换的模板：直接原样返回，别拿去当 CSS 选择器
        if isURLRule(resolved) || resolved.contains("{{") {
            return resolved
        }

        // 脚本规则：本阶段不执行，返回空串，调用方会当作"这条源不支持"
        if resolved.hasPrefix("@js:") || resolved.hasPrefix("<js>") {
            return ""
        }

        if resolved.hasPrefix("$.") {
            return jsonString(resolved, json: html)
        }

        // CSS
        return evaluateCSS(resolved, html: html, baseUrl: baseUrl)
    }

    // MARK: CSS

    private static func evaluateCSS(_ rule: String, html: String, baseUrl: String) -> String {
        let tokens = rule.components(separatedBy: "@")
        guard let first = tokens.first, !first.isEmpty else { return "" }

        guard let doc = try? SwiftSoup.parse(html) else { return "" }
        let (selector, index) = cssToken(first)
        guard var matched = try? doc.select(selector).array(), !matched.isEmpty else { return "" }

        if let index {
            let resolvedIndex = index < 0 ? matched.count + index : index
            guard matched.indices.contains(resolvedIndex) else { return "" }
            matched = [matched[resolvedIndex]]
        }

        // 后续 token 依次在"上一步选中的元素"里继续选，或取属性
        var current: [Element] = matched
        var attribute: String?

        for token in tokens.dropFirst() {
            if isAttributeToken(token) {
                attribute = token
                continue
            }
            let (subSelector, subIndex) = cssToken(token)
            var next: [Element] = []
            for element in current {
                guard let found = try? element.select(subSelector).array() else { continue }
                next.append(contentsOf: found)
            }
            if let subIndex {
                let resolvedIndex = subIndex < 0 ? next.count + subIndex : subIndex
                guard next.indices.contains(resolvedIndex) else { return "" }
                next = [next[resolvedIndex]]
            }
            guard !next.isEmpty else { return "" }
            current = next
            attribute = nil
        }

        guard let element = current.first else { return "" }
        return value(of: element, attribute: attribute, baseUrl: baseUrl)
    }

    private static func value(of element: Element, attribute: String?, baseUrl: String) -> String {
        switch attribute {
        case nil, "text":
            return (try? element.text()) ?? ""
        case "ownText":
            return (try? element.ownText()) ?? ""
        case "html":
            return (try? element.html()) ?? ""
        case "outerHtml":
            return (try? element.outerHtml()) ?? ""
        case "href":
            return resolveURL((try? element.attr("href")) ?? "", baseUrl: baseUrl)
        case "src":
            let src = (try? element.attr("src")) ?? ""
            if !src.isEmpty { return resolveURL(src, baseUrl: baseUrl) }
            // 常见懒加载：src 为空时取 data-src / data-original
            let lazy = (try? element.attr("data-src")) ?? ""
            if !lazy.isEmpty { return resolveURL(lazy, baseUrl: baseUrl) }
            let original = (try? element.attr("data-original")) ?? ""
            return resolveURL(original, baseUrl: baseUrl)
        default:
            let raw = (try? element.attr(attribute ?? "")) ?? ""
            // 属性值里如果是相对地址也顺手补全
            if raw.hasPrefix("/") || raw.hasPrefix("./") || raw.hasPrefix("../") {
                return resolveURL(raw, baseUrl: baseUrl)
            }
            return raw
        }
    }

    /// `class.x` / `id.x` / `tag.x` / 裸 CSS，末尾可带 `.索引`。
    private static func cssToken(_ token: String) -> (selector: String, index: Int?) {
        var text = token.trimmingCharacters(in: .whitespaces)
        var index: Int?

        if let range = text.range(of: #"\.(-?\d+)$"#, options: .regularExpression) {
            index = Int(text[range].dropFirst())
            text.removeSubrange(range)
        }

        if text.hasPrefix("class.") {
            text = "." + text.dropFirst("class.".count)
        } else if text.hasPrefix("id.") {
            text = "#" + text.dropFirst("id.".count)
        } else if text.hasPrefix("tag.") {
            text = String(text.dropFirst("tag.".count))
        }
        return (text, index)
    }

    private static func isAttributeToken(_ token: String) -> Bool {
        if token.isEmpty { return false }
        if token.hasPrefix("tag.") || token.hasPrefix("class.") || token.hasPrefix("id.") {
            return false
        }
        // 含 CSS 结构字符的当选择器，其余当属性名
        if token.contains(".") || token.contains("#") || token.contains("[") || token.contains(" ") {
            return false
        }
        return true
    }

    // MARK: 净化

    /// `##正则##替换`：没有替换段表示删除；多个 `##` 串联依次执行。
    private static func purify(_ rule: String, text: String) -> String {
        let body = rule.hasPrefix("##") ? String(rule.dropFirst(2)) : rule
        let parts = body.components(separatedBy: "##")
        guard let pattern = parts.first, !pattern.isEmpty else { return text }

        let replacement = parts.count > 1 ? parts[1] : ""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    // MARK: 模板

    /// 纯地址规则：http(s) 开头，或以 / ./ ../ 开头的相对路径。
    private static func isURLRule(_ text: String) -> Bool {
        text.hasPrefix("http://") || text.hasPrefix("https://")
            || text.hasPrefix("/") || text.hasPrefix("./") || text.hasPrefix("../")
    }

    private static func applyVariables(_ rule: String, variables: [String: String]) -> String {
        guard rule.contains("{{"), !variables.isEmpty else { return rule }
        var result = rule
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    // MARK: JSONPath（基础）

    private static func jsonElements(_ path: String, json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return []
        }
        let values = jsonValues(path: path, root: root)
        return values.compactMap { value -> String? in
            if let text = value as? String { return text }
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: []),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
    }

    private static func jsonString(_ path: String, json: String) -> String {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return ""
        }
        guard let value = jsonValues(path: path, root: root).first else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    /// 支持 `$.a.b`、`$.a[0].b`、`$.a[*].b`。
    private static func jsonValues(path: String, root: Any) -> [Any] {
        var current: [Any] = [root]
        let body = path.hasPrefix("$.") ? String(path.dropFirst(2)) : path
        let segments = body.split(separator: ".").map(String.init)

        for segment in segments {
            var next: [Any] = []
            var key = segment
            var indexes: [Int] = []
            var wildcard = false

            if let bracket = key.firstIndex(of: "[") {
                let indexPart = key[key.index(after: bracket)...].replacingOccurrences(of: "]", with: "")
                key = String(key[..<bracket])
                if indexPart == "*" {
                    wildcard = true
                } else if let value = Int(indexPart) {
                    indexes = [value]
                }
            }

            for item in current {
                let base: Any?
                if key.isEmpty {
                    base = item
                } else {
                    base = (item as? [String: Any])?[key]
                }
                guard let base else { continue }

                if wildcard, let array = base as? [Any] {
                    next.append(contentsOf: array)
                } else if let index = indexes.first, let array = base as? [Any] {
                    if array.indices.contains(index) { next.append(array[index]) }
                } else {
                    next.append(base)
                }
            }
            current = next
        }
        return current
    }
}
