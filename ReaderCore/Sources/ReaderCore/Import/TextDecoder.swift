import Foundation

/// 中文 txt 的编码兜底：先 UTF-8，再 GB18030，最后 Latin1。
/// 返回解码文本与实际使用的编码名，便于在导入结果里说明。
public enum TextDecoder {
    public struct Result: Equatable {
        public let text: String
        public let encodingName: String
        public let isFallback: Bool
    }

    public static var gb18030: String.Encoding {
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }

    public static func decode(_ data: Data) -> Result? {
        if data.isEmpty { return nil }

        if let text = String(data: data, encoding: .utf8) {
            return Result(text: stripBOM(text), encodingName: "UTF-8", isFallback: false)
        }
        if let text = String(data: data, encoding: gb18030) {
            return Result(text: stripBOM(text), encodingName: "GB18030", isFallback: true)
        }
        if let text = String(data: data, encoding: .utf16) {
            return Result(text: stripBOM(text), encodingName: "UTF-16", isFallback: true)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return Result(text: stripBOM(text), encodingName: "Latin1", isFallback: true)
        }
        return nil
    }

    private static func stripBOM(_ text: String) -> String {
        var result = text
        if result.hasPrefix("\u{FEFF}") {
            result.removeFirst()
        }
        return result
    }
}
