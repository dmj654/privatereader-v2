import Foundation

public enum TxtParser {
    public static func parse(url: URL) throws -> ParsedNovel {
        guard let data = try? Data(contentsOf: url) else {
            throw ImportError.unreadableFile(url.lastPathComponent)
        }
        guard let decoded = TextDecoder.decode(data) else {
            throw ImportError.unreadableFile(url.lastPathComponent)
        }

        var chapters = ChapterSplitter.split(decoded.text)
        guard !chapters.isEmpty else { throw ImportError.emptyContent }

        // 若首「章」标题异常长，多半是书名，取书名并把首章改成正文
        var title = url.deletingPathExtension().lastPathComponent
        if let firstChapter = chapters.first, firstChapter.title.count > 40 {
            let head = firstChapter.title
            title = head
            chapters[0] = NovelChapter(title: "正文", body: firstChapter.body)
        }

        return ParsedNovel(title: title, author: nil, chapters: chapters, coverData: nil)
    }
}
