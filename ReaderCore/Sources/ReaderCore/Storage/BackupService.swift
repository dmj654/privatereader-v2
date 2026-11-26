import Foundation
import ZIPFoundation

public struct BackupManifest: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var formatVersion: Int
    public var appVersion: String
    public var createdAt: Int
    public var bookCount: Int
    public var sourceCount: Int
    public var includesBooks: Bool
    public var databaseBytes: Int

    public init(formatVersion: Int = BackupManifest.currentFormat,
                appVersion: String,
                createdAt: Int,
                bookCount: Int,
                sourceCount: Int,
                includesBooks: Bool,
                databaseBytes: Int) {
        self.formatVersion = formatVersion
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.bookCount = bookCount
        self.sourceCount = sourceCount
        self.includesBooks = includesBooks
        self.databaseBytes = databaseBytes
    }

    public var createdAtText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(createdAt)))
    }
}

public enum BackupError: LocalizedError, Equatable {
    case unreadable
    case missingManifest
    case missingDatabase
    case unsupportedVersion(Int)
    case unsafeEntry(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "备份包打不开，可能已损坏"
        case .missingManifest: return "备份包里没有 manifest.json"
        case .missingDatabase: return "备份包里没有数据库"
        case .unsupportedVersion(let version):
            return "这份备份来自更新的版本（格式 \(version)），当前 App 还读不了。请先升级 App。"
        case .unsafeEntry(let path): return "备份包里有异常路径：\(path)"
        case .empty: return "备份包里没有可恢复的内容"
        }
    }
}

public struct BackupInput: Sendable {
    public var appVersion: String
    public var bookCount: Int
    public var sources: [String]
    public var includeBooks: Bool

    public init(appVersion: String, bookCount: Int, sources: [String], includeBooks: Bool) {
        self.appVersion = appVersion
        self.bookCount = bookCount
        self.sources = sources
        self.includeBooks = includeBooks
    }
}

/// 打包：manifest + 数据库（含 WAL）+ 封面 + 书源；书文件可选。
///
/// 不做增量，也不加密——这是给自己用的备份，能在「文件」里直接看到内容反而更安心。
public struct BackupExporter {
    private let paths: SandboxPaths
    private let fileManager = FileManager.default

    public init(paths: SandboxPaths) {
        self.paths = paths
    }

    public func export(_ input: BackupInput,
                       formatVersion: Int = BackupManifest.currentFormat) throws -> URL {
        let database = paths.database
        guard fileManager.fileExists(atPath: database.path) else { throw BackupError.missingDatabase }

        let staged = paths.root
            .appendingPathComponent("BackupStaging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)

        // 数据库：WAL / SHM 一起带，否则最近读的进度可能不在主文件里
        try copy(database, to: staged.appendingPathComponent("library.db"))
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try copy(sidecar, to: staged.appendingPathComponent("library.db\(suffix)"))
            }
        }

        let attributes = try? fileManager.attributesOfItem(atPath: database.path)
        let dbBytes = (attributes?[.size] as? Int) ?? 0

        if fileManager.fileExists(atPath: paths.covers.path) {
            try copy(paths.covers, to: staged.appendingPathComponent("Covers"))
        }
        if input.includeBooks, fileManager.fileExists(atPath: paths.books.path) {
            try copy(paths.books, to: staged.appendingPathComponent("Books"))
        }

        let manifest = BackupManifest(
            formatVersion: formatVersion,
            appVersion: input.appVersion,
            createdAt: Int(Date().timeIntervalSince1970),
            bookCount: input.bookCount,
            sourceCount: input.sources.count,
            includesBooks: input.includeBooks,
            databaseBytes: dbBytes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staged.appendingPathComponent("manifest.json"))

        let sourcesData = try JSONSerialization.data(
            withJSONObject: input.sources.compactMap { raw -> Any? in
                guard let data = raw.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data)
            },
            options: [.prettyPrinted]
        )
        try sourcesData.write(to: staged.appendingPathComponent("sources.json"))

        try fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        let fileName = "PrivateReader-\(fileStamp()).prbackup"
        let destination = paths.backups.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        var archive = try Archive(url: destination, accessMode: .create)
        try addDirectory(staged, prefix: "", root: staged, to: &archive)
        return destination
    }

    public func latestBackup() -> URL? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: paths.backups,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        return files
            .filter { $0.pathExtension == "prbackup" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }
            .first
    }

    /// `prefix` 由调用方逐层拼出来，不靠字符串裁剪绝对路径。
    /// 沙盒路径在 macOS 上会被解析成 /private/var/...，裁剪很容易把前缀漏掉。
    private func addDirectory(_ directory: URL, prefix: String, root: URL, to archive: inout Archive) throws {
        let items = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let name = prefix.isEmpty ? item.lastPathComponent : prefix + "/" + item.lastPathComponent
            if isDirectory {
                try addDirectory(item, prefix: name, root: root, to: &archive)
            } else {
                try archive.addEntry(with: name, relativeTo: root)
            }
        }
    }

    private func copy(_ source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// 恢复：先解到临时目录校验，全部通过才动现有数据。
public struct BackupImporter {
    private let paths: SandboxPaths
    private let fileManager = FileManager.default

    public init(paths: SandboxPaths) {
        self.paths = paths
    }

    public func inspect(archiveURL: URL) throws -> BackupManifest {
        let staged = try extract(archiveURL)
        defer { try? fileManager.removeItem(at: staged) }
        return try readManifest(in: staged)
    }

    /// 恢复后需要重启 App 才能重新打开数据库。
    @discardableResult
    public func restore(archiveURL: URL) throws -> BackupManifest {
        let staged = try extract(archiveURL)
        defer { try? fileManager.removeItem(at: staged) }

        let manifest = try readManifest(in: staged)
        guard manifest.formatVersion <= BackupManifest.currentFormat else {
            throw BackupError.unsupportedVersion(manifest.formatVersion)
        }
        let db = staged.appendingPathComponent("library.db")
        guard fileManager.fileExists(atPath: db.path) else { throw BackupError.missingDatabase }

        // 现有数据先挪到回滚目录，不动内容
        let rollback = paths.backups.appendingPathComponent("Rollback-\(Int(Date().timeIntervalSince1970))")
        try fileManager.createDirectory(at: rollback, withIntermediateDirectories: true)
        for name in ["library.db", "library.db-wal", "library.db-shm"] {
            let url = paths.root.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.moveItem(at: url, to: rollback.appendingPathComponent(name))
            }
        }

        try copyIfExists(db, to: paths.database)
        for suffix in ["-wal", "-shm"] {
            try copyIfExists(staged.appendingPathComponent("library.db\(suffix)"),
                             to: URL(fileURLWithPath: paths.database.path + suffix))
        }

        if fileManager.fileExists(atPath: staged.appendingPathComponent("Covers").path) {
            try? fileManager.removeItem(at: paths.covers)
            try fileManager.copyItem(at: staged.appendingPathComponent("Covers"), to: paths.covers)
        }
        if fileManager.fileExists(atPath: staged.appendingPathComponent("Books").path) {
            try? fileManager.removeItem(at: paths.books)
            try fileManager.copyItem(at: staged.appendingPathComponent("Books"), to: paths.books)
        }

        return manifest
    }

    // MARK: 内部

    private func extract(_ archiveURL: URL) throws -> URL {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
            throw BackupError.unreadable
        }
        let staged = paths.root.appendingPathComponent("Restore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)

        var fileCount = 0
        for entry in archive {
            let path = entry.path
            guard !path.contains(".."), !path.hasPrefix("/") else {
                throw BackupError.unsafeEntry(path)
            }
            guard entry.type == .file else { continue }
            let destination = staged.appendingPathComponent(path)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destination)
            fileCount += 1
        }
        guard fileCount > 0 else {
            try? fileManager.removeItem(at: staged)
            throw BackupError.empty
        }
        return staged
    }

    private func readManifest(in staged: URL) throws -> BackupManifest {
        let url = staged.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { throw BackupError.missingManifest }
        guard let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else {
            throw BackupError.missingManifest
        }
        return manifest
    }

    private func copyIfExists(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }
}
