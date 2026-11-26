import Foundation
import SwiftSoup

public enum EpubParser {
    public static func parse(url: URL) throws -> ParsedNovel {
        let archive = try ArchiveReader(url: url)

        guard let containerData = try archive.data(for: "META-INF/container.xml"),
              let container = XMLTree.parse(containerData),
              let rootfile = container.descendants(named: "rootfile").first,
              let opfPath = rootfile.attributes["full-path"] else {
            throw ImportError.malformedArchive("缺少 container.xml 或 rootfile")
        }

        guard let opfData = try archive.data(for: opfPath),
              let opf = XMLTree.parse(opfData) else {
            throw ImportError.malformedArchive("OPF 无法解析")
        }

        let opfDirectory = (opfPath as NSString).deletingLastPathComponent

        let title = opf.descendants(named: "title").first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = opf.descendants(named: "creator").first?.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // manifest: id -> href / properties
        var manifest: [String: (href: String, properties: String, mediaType: String)] = [:]
        for item in opf.descendants(named: "item") {
            guard let id = item.attributes["id"],
                  let href = item.attributes["href"] else { continue }
            manifest[id] = (
                href: href,
                properties: item.attributes["properties"] ?? "",
                mediaType: item.attributes["media-type"] ?? ""
            )
        }

        // 封面：cover-image 属性优先，其次 meta[name=cover]
        var coverEntry: String?
        if let coverItem = manifest.values.first(where: { $0.properties.contains("cover-image") }) {
            coverEntry = resolve(coverItem.href, base: opfDirectory)
        } else if let metaCover = opf.descendants(named: "meta").first(where: { $0.attributes["name"] == "cover" }),
                  let id = metaCover.attributes["content"],
                  let item = manifest[id] {
            coverEntry = resolve(item.href, base: opfDirectory)
        }

        // spine 决定阅读顺序
        var chapters: [NovelChapter] = []
        for itemref in opf.descendants(named: "itemref") {
            guard let idref = itemref.attributes["idref"],
                  let item = manifest[idref] else { continue }
            let path = resolve(item.href, base: opfDirectory)
            guard let data = try archive.data(for: path) else { continue }
            let body = extractText(from: data)
            guard !body.isEmpty else { continue }
            let chapterTitle = extractingHeading(from: data) ?? "第 \(chapters.count + 1) 节"
            chapters.append(NovelChapter(title: chapterTitle, body: body))
        }

        guard !chapters.isEmpty else { throw ImportError.emptyContent }

        var coverData: Data?
        if let coverEntry, let data = try archive.data(for: coverEntry) {
            coverData = data
        }

        return ParsedNovel(
            title: (title?.isEmpty == false ? title! : url.deletingPathExtension().lastPathComponent),
            author: (author?.isEmpty == false ? author : nil),
            chapters: chapters,
            coverData: coverData
        )
    }

    private static func resolve(_ href: String, base: String) -> String {
        var value = href
        if let decoded = value.removingPercentEncoding { value = decoded }
        guard !base.isEmpty else { return value }
        return (base as NSString).appendingPathComponent(value)
    }

    private static func extractText(from data: Data) -> String {
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let document = try? SwiftSoup.parse(html) else { return "" }
        if let removable = try? document.select("script, style") {
            for element in removable {
                try? element.remove()
            }
        }
        let text = (try? document.text()) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractingHeading(from data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let document = try? SwiftSoup.parse(html) else { return nil }
        for tag in ["h1", "h2", "h3", "title"] {
            if let element = try? document.select(tag).first(), let text = try? element.text() {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
