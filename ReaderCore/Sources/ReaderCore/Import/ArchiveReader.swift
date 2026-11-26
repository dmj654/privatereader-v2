import Foundation
import ZIPFoundation

/// ZIP / EPUB / CBZ 的统一读取层。
public struct ArchiveReader {
    private let archive: Archive

    public init(url: URL) throws {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw ImportError.malformedArchive(url.lastPathComponent)
        }
        self.archive = archive
    }

    public var entryPaths: [String] {
        archive.map(\.path)
    }

    public func data(for path: String) throws -> Data? {
        guard let entry = archive[normalized(path)] else { return nil }
        var result = Data()
        _ = try archive.extract(entry) { chunk in
            result.append(chunk)
        }
        return result
    }

    /// zip 内部路径可能带 ./ 前缀或百分号编码，统一成可比较的形式。
    private func normalized(_ path: String) -> String {
        var value = path
        if value.hasPrefix("./") { value.removeFirst(2) }
        if let decoded = value.removingPercentEncoding { value = decoded }
        return value
    }
}
