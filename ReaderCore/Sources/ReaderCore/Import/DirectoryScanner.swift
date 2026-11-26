import Foundation

/// 扫描 App 自己的目录，找出待导入的书。
/// 用途：文件选择器不好用时的兜底——用电脑把书拷进 App 目录，再一键扫描。
public enum DirectoryScanner {
    /// 这些是 App 自己的工作目录，绝不能当书扫进来，否则会把已导入的书再导一遍。
    /// `Done` 是导入成功后原文件的归档处，也要跳过。
    public static let reservedDirectories: Set<String> = ["Books", "Covers", "Cache", "Backups", "Done"]

    public static let supportedExtensions: Set<String> = ["txt", "epub", "pdf", "cbz", "zip"]

    /// 递归扫描，默认 3 层，跳过隐藏文件与保留目录。
    public static func scan(root: URL,
                            maximumDepth: Int = 3,
                            extensions: Set<String> = supportedExtensions) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [URL] = []
        let rootPath = root.standardizedFileURL.path

        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let isDirectory = values?.isDirectory ?? false

            // 计算相对层级
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: rootPath, with: "")
            let depth = relative.split(separator: "/").count

            if isDirectory {
                if reservedDirectories.contains(name) || depth >= maximumDepth {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile ?? false else { continue }
            let ext = url.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }
            results.append(url)
        }

        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
