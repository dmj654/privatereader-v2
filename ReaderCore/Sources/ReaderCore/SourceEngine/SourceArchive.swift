import Foundation
import ZIPFoundation

/// 有些分享包是 zip，里面放一份 json。
/// 直接选 zip 也应该能导入，不用用户先去解压。
public enum SourceArchive {
    /// 从压缩包数据里取最大的那份 .json —— 合集通常就是最大的那个。
    public static func jsonData(from archiveData: Data) -> Data? {
        // ZIPFoundation 的 Archive 以 URL 打开最稳；压缩包只在导入时读一次，
        // 落一份临时文件再删掉，代价可以忽略。
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-import-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (try? archiveData.write(to: temp)) != nil,
              let archive = try? Archive(url: temp, accessMode: .read) else { return nil }

        let marker = Data("bookSourceName".utf8)
        var bestSource: Data?
        var bestAny: Data?

        for entry in archive {
            guard entry.type == .file,
                  entry.path.lowercased().hasSuffix(".json"),
                  entry.uncompressedSize > 0 else { continue }
            var data = Data()
            guard (try? archive.extract(entry) { chunk in
                data.append(chunk)
            }) != nil else { continue }

            if data.count > (bestAny?.count ?? 0) { bestAny = data }
            // 包里可能还有 manifest / 说明.json，优先挑真的含书源字段的那份
            if data.range(of: marker) != nil,
               data.count > (bestSource?.count ?? 0) {
                bestSource = data
            }
        }
        return bestSource ?? bestAny
    }

    public static func looksLikeZip(_ data: Data) -> Bool {
        data.starts(with: [0x50, 0x4B])   // "PK"
    }
}
