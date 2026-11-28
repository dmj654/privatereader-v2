import Foundation

/// 把数据库里的 `lastCheckResult` 还原成体检结论。
///
/// 书源管理页离开再回来时，失败、超时、部分可用和正常都应该还能看到；
/// 以前只恢复了前三种，正常/深检通过的源会退回「未检测」。这里集中解析，
/// 让界面和测试共用同一套格式，不再各自拆字符串。
public struct SourceHealthSnapshot: Equatable, Sendable {
    public let status: SourceHealthStatus

    public init?(lastCheckResult: String?) {
        guard let raw = lastCheckResult?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        if raw == "timeout" {
            status = .timeout
            return
        }
        if let message = Self.value(after: "failed: ", in: raw) {
            status = .failed(message)
            return
        }
        if let message = Self.value(after: "partial: ", in: raw) {
            status = .partial(message)
            return
        }
        if let reason = Self.value(after: "skipped: ", in: raw) {
            status = .skipped(reason)
            return
        }

        let parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        // 新格式：okDeep 128ms 5 3 120
        if parts.count == 5, parts[0] == "okDeep",
           let ms = Self.milliseconds(parts[1]),
           let count = Int(parts[2]),
           let checked = Int(parts[3]),
           let chapters = Int(parts[4]) {
            status = .okDeep(milliseconds: ms,
                             sampleCount: count,
                             checkedSamples: max(1, checked),
                             chapterCount: chapters)
            return
        }

        // 1.9.5 旧格式：ok deep 128ms 5 120，只抽查了第一本
        if parts.count == 5, parts[0] == "ok", parts[1] == "deep",
           let ms = Self.milliseconds(parts[2]),
           let count = Int(parts[3]),
           let chapters = Int(parts[4]) {
            status = .okDeep(milliseconds: ms,
                             sampleCount: count,
                             checkedSamples: 1,
                             chapterCount: chapters)
            return
        }

        // 新格式：ok 128ms 5
        if parts.count == 3, parts[0] == "ok",
           let ms = Self.milliseconds(parts[1]),
           let count = Int(parts[2]) {
            status = .ok(milliseconds: ms, sampleCount: count)
            return
        }

        // 更早版本留下的中文短结果，例如「正常 · 0.8s」。
        if let ms = Self.legacyMilliseconds(raw) {
            status = .ok(milliseconds: ms, sampleCount: 0)
            return
        }

        return nil
    }

    private static func value(after prefix: String, in text: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        let value = String(text.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    private static func milliseconds(_ text: String) -> Int? {
        if text.hasSuffix("ms") {
            return Int(text.dropLast(2))
        }
        return Int(text)
    }

    private static func legacyMilliseconds(_ text: String) -> Int? {
        // 「正常 · 0.8s」
        guard text.hasPrefix("正常"), text.hasSuffix("s") else { return nil }
        let digits = String(text.drop { !$0.isNumber && $0 != "." })
        guard let seconds = Double(digits.replacingOccurrences(of: "s", with: "")) else {
            return nil
        }
        return Int(seconds * 1000)
    }
}
