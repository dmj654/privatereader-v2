import Foundation

#if canImport(PDFKit)
import PDFKit

public enum PdfParser {
    public static func parse(url: URL) throws -> ParsedNovel {
        guard let document = PDFDocument(url: url) else {
            throw ImportError.unreadableFile(url.lastPathComponent)
        }
        guard document.pageCount > 0 else { throw ImportError.emptyContent }

        var chapters: [NovelChapter] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(NovelChapter(title: "第 \(index + 1) 页", body: text))
        }

        guard chapters.contains(where: { !$0.body.isEmpty }) else { throw ImportError.emptyContent }

        return ParsedNovel(
            title: url.deletingPathExtension().lastPathComponent,
            author: document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String,
            chapters: chapters,
            coverData: nil
        )
    }
}
#endif
