import Foundation

/// 按「第 N 章 / 回 / 节 / 卷」切分正文。
/// 命中太少时退化为单章，避免把整本书切碎。
public enum ChapterSplitter {
    private static let patterns = [
        "(?m)^[\\s\\u3000]*(第[0-9零一二三四五六七八九十百千两]{1,12}[章回节卷][^\\n]{0,40})$",
        "(?m)^[\\s\\u3000]*(Chapter\\s+[0-9]{1,4}[^\\n]{0,40})$"
    ]

    public static func split(_ text: String) -> [NovelChapter] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
            guard matches.count >= 2 else { continue }
            return buildChapters(from: normalized, matches: matches)
        }

        return [NovelChapter(title: "正文", body: normalized)]
    }

    private static func buildChapters(from text: String, matches: [NSTextCheckingResult]) -> [NovelChapter] {
        var chapters: [NovelChapter] = []
        let nsText = text as NSString

        for (index, match) in matches.enumerated() {
            let titleRange = match.range(at: 1)
            guard titleRange.location != NSNotFound else { continue }
            let title = nsText.substring(with: titleRange).trimmingCharacters(in: .whitespaces)

            let bodyStart = match.range.location + match.range.length
            let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : nsText.length

            guard bodyEnd >= bodyStart else { continue }
            let body = nsText.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            chapters.append(NovelChapter(title: title, body: body))
        }

        return chapters
    }
}
