import Foundation

/// 导入过程的行级日志。
/// 存在的理由：导入在真机上失败时我看不到控制台，只能让日志落盘再取回来。
public struct ImportLog {
    public let url: URL
    public let maximumBytes: Int
    private static let lock = NSLock()

    public init(directory: URL, fileName: String = "import.log", maximumBytes: Int = 128 * 1024) {
        self.url = directory.appendingPathComponent(fileName, isDirectory: false)
        self.maximumBytes = maximumBytes
    }

    public func append(_ message: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)

        trimIfNeeded()
    }

    /// 超过上限就砍掉前半段，保留最近的内容。
    private func trimIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              size > maximumBytes else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let keep = data.suffix(maximumBytes / 2)
        // 从下一个换行开始，避免第一行被截成半句
        if let newline = keep.firstIndex(of: 0x0A) {
            try? Data(keep[keep.index(after: newline)...]).write(to: url)
        } else {
            try? Data(keep).write(to: url)
        }
    }

    public func read() -> String {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
