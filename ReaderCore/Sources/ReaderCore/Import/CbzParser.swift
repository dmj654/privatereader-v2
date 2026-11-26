import Foundation

public enum CbzParser {
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic"]

    public static func parse(url: URL) throws -> ParsedComic {
        let archive = try ArchiveReader(url: url)
        let images = archive.entryPaths.filter { path in
            imageExtensions.contains((path as NSString).pathExtension.lowercased())
        }
        guard !images.isEmpty else { throw ImportError.emptyContent }

        let sorted = NaturalSort.sorted(images)
        var coverData: Data?
        if let first = sorted.first {
            coverData = try archive.data(for: first)
        }

        return ParsedComic(
            title: url.deletingPathExtension().lastPathComponent,
            pages: sorted.map { ComicPage(entryName: $0) },
            coverData: coverData
        )
    }

    /// 导入时把图片真正落盘，返回按顺序排列的文件名。
    public static func extractPages(from url: URL, to directory: URL) throws -> [String] {
        let archive = try ArchiveReader(url: url)
        let images = archive.entryPaths.filter { path in
            imageExtensions.contains((path as NSString).pathExtension.lowercased())
        }
        let sorted = NaturalSort.sorted(images)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var names: [String] = []
        for (index, path) in sorted.enumerated() {
            guard let data = try archive.data(for: path) else { continue }
            let ext = (path as NSString).pathExtension.lowercased()
            let name = String(format: "%04d.%@", index, ext.isEmpty ? "jpg" : ext)
            try data.write(to: directory.appendingPathComponent(name))
            names.append(name)
        }
        return names
    }
}
