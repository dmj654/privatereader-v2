import Foundation

/// 书源净化规则。
///
/// 网站常在正文里塞"本章未完，请点击下一页"、"最新网址"、水印字。
/// legado 的写法是 `##正则##替换`，这里把它做成可开关、可统计命中条数的类型。
///
/// 为什么单独统计命中数：净化最容易"看起来开了但没生效"。
/// 设置页要能显示"这条规则命中了多少次"，才能判断规则本身写错了还是正文确实干净。
public struct Purifier: Sendable {

    public struct Outcome: Equatable, Sendable {
        public let text: String
        public let hitCount: Int

        public init(text: String, hitCount: Int) {
            self.text = text
            self.hitCount = hitCount
        }
    }

    public var isEnabled: Bool
    public var rules: [String]

    public init(isEnabled: Bool = true, rules: [String] = []) {
        self.isEnabled = isEnabled
        self.rules = rules
    }

    /// 从 `ruleContent.content` 这类规则串里抽出净化段：
    /// - `id.content@html&&##广告##&&##最新网址##` → ["##广告##", "##最新网址##"]
    /// - `id.content@html##最新网址：[^\n]*` → ["##最新网址：[^\n]*"]
    ///   后者是 legado 源里最常见的写法，不能只认 `&&` 开头的段。
    public static func extractRules(from rule: String) -> [String] {
        rule.components(separatedBy: "&&")
            .compactMap { segment -> String? in
                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("##") { return trimmed }
                guard let range = trimmed.range(of: "##") else { return nil }
                let suffix = String(trimmed[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
                return suffix.isEmpty ? nil : suffix
            }
    }

    public func apply(to text: String) -> Outcome {
        guard isEnabled, !rules.isEmpty, !text.isEmpty else {
            return Outcome(text: text, hitCount: 0)
        }

        var result = text
        var hits = 0

        for rule in rules {
            let body = rule.hasPrefix("##") ? String(rule.dropFirst(2)) : rule
            let parts = body.components(separatedBy: "##")
            let pattern = parts[0]
            guard !pattern.isEmpty else { continue }
            let replacement = parts.count > 1 ? parts[1] : ""

            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.dotMatchesLineSeparators]) else {
                continue
            }
            let range = NSRange(location: 0, length: (result as NSString).length)
            hits += regex.numberOfMatches(in: result, options: [], range: range)
            result = regex.stringByReplacingMatches(in: result,
                                                    options: [],
                                                    range: range,
                                                    withTemplate: replacement)
        }

        return Outcome(text: result, hitCount: hits)
    }
}
