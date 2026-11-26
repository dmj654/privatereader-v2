import Foundation
import CoreText

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 字体家族。只放系统里确定存在的三种，避免选了个名字却回退到系统字体还看不出来。
public enum ReaderFontFamily: String, CaseIterable, Codable, Sendable {
    case system
    case songti
    case kaiti

    public var title: String {
        switch self {
        case .system: return "系统"
        case .songti: return "宋体"
        case .kaiti: return "楷体"
        }
    }

    /// PostScript 名。iOS 上宋体是 STSongti-SC-*，楷体是 STKaiti-SC-*。
    var candidates: [String] {
        switch self {
        case .system:
            return []
        case .songti:
            return ["STSongti-SC-Regular", "Songti SC", "STSong"]
        case .kaiti:
            return ["STKaiti-SC-Regular", "Kaiti SC", "STKaiti"]
        }
    }
}

/// 排版参数 → 富文本属性。用 CTFont 而非 UIFont，保持跨平台可测。
///
/// 必须 Codable：这些参数要跨启动保存。以前只存在 ViewModel 的内存里，
/// 退出阅读器就回默认值，用户每次进来都得重调一遍。
public struct ReaderStyle: Hashable, Sendable, Codable {
    public var fontSize: Double
    public var lineHeightMultiple: Double
    public var paragraphSpacing: Double
    public var letterSpacing: Double
    public var marginHorizontal: Double
    public var marginTop: Double
    public var fontFamily: ReaderFontFamily
    /// 首行缩进两个字。以前是往正文里塞全角空格，同时又设 paragraphStyle 缩进，结果缩了两次。
    public var indentFirstLine: Bool
    public var justified: Bool

    public init(fontSize: Double = 17.5,
                lineHeightMultiple: Double = 1.95,
                paragraphSpacing: Double = 12,
                letterSpacing: Double = 0,
                marginHorizontal: Double = 22,
                marginTop: Double = 12,
                fontFamily: ReaderFontFamily = .system,
                indentFirstLine: Bool = true,
                justified: Bool = false) {
        self.fontSize = fontSize
        self.lineHeightMultiple = lineHeightMultiple
        self.paragraphSpacing = paragraphSpacing
        self.letterSpacing = letterSpacing
        self.marginHorizontal = marginHorizontal
        self.marginTop = marginTop
        self.fontFamily = fontFamily
        self.indentFirstLine = indentFirstLine
        self.justified = justified
    }

    public static let `default` = ReaderStyle()

    // 手写 Codable：缺字段补默认值，而不是整份设置解码失败退回默认。
    // 这样以后加参数（比如新的字重、段首间距）时，老用户已存的设置不会一次性丢光。
    private enum CodingKeys: String, CodingKey {
        case fontSize, lineHeightMultiple, paragraphSpacing, letterSpacing
        case marginHorizontal, marginTop, fontFamily, indentFirstLine, justified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ReaderStyle()
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fallback.fontSize
        lineHeightMultiple = try c.decodeIfPresent(Double.self, forKey: .lineHeightMultiple) ?? fallback.lineHeightMultiple
        paragraphSpacing = try c.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? fallback.paragraphSpacing
        letterSpacing = try c.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? fallback.letterSpacing
        marginHorizontal = try c.decodeIfPresent(Double.self, forKey: .marginHorizontal) ?? fallback.marginHorizontal
        marginTop = try c.decodeIfPresent(Double.self, forKey: .marginTop) ?? fallback.marginTop
        fontFamily = (try? c.decodeIfPresent(ReaderFontFamily.self, forKey: .fontFamily)) ?? fallback.fontFamily
        indentFirstLine = try c.decodeIfPresent(Bool.self, forKey: .indentFirstLine) ?? fallback.indentFirstLine
        justified = try c.decodeIfPresent(Bool.self, forKey: .justified) ?? fallback.justified
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(lineHeightMultiple, forKey: .lineHeightMultiple)
        try c.encode(paragraphSpacing, forKey: .paragraphSpacing)
        try c.encode(letterSpacing, forKey: .letterSpacing)
        try c.encode(marginHorizontal, forKey: .marginHorizontal)
        try c.encode(marginTop, forKey: .marginTop)
        try c.encode(fontFamily, forKey: .fontFamily)
        try c.encode(indentFirstLine, forKey: .indentFirstLine)
        try c.encode(justified, forKey: .justified)
    }

    /// 首行缩进宽度：两个字。
    public var indentWidth: Double {
        indentFirstLine ? fontSize * 2 : 0
    }

    public func attributes(color: CGColor) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = lineHeightMultiple
        paragraphStyle.paragraphSpacing = paragraphSpacing
        paragraphStyle.firstLineHeadIndent = indentWidth
        paragraphStyle.headIndent = 0
        paragraphStyle.alignment = justified ? .justified : .natural

        var result: [NSAttributedString.Key: Any] = [
            .font: font(),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        if abs(letterSpacing) > 0.01 {
            result[.kern] = letterSpacing
        }
        return result
    }

    /// 按家族解析字体；解析不到就退回系统字体，不会变成方框。
    ///
    /// 刻意分平台：
    /// - iOS 用 `UIFont(name:)`，能正确命中 STSongti / STKaiti 这些中文字体。
    /// - macOS 只走 CoreText，**不碰 AppKit**。CI 是无窗口进程，`NSFont` 的字体匹配
    ///   可能阻塞在系统字体服务上——上次 CI 卡了 29 分钟就是这么来的。
    public func font() -> CTFont {
        #if canImport(UIKit)
        for name in fontFamily.candidates {
            if let font = UIFont(name: name, size: fontSize) {
                return font as CTFont
            }
        }
        #else
        if let first = fontFamily.candidates.first {
            let candidate = CTFontCreateWithName(first as CFString, fontSize, nil)
            let resolved = CTFontCopyPostScriptName(candidate) as String
            if !resolved.isEmpty, resolved != "LastResort" {
                return candidate
            }
        }
        #endif

        return CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    }

    /// 正文按段落重组：把连续空行压成一个。
    /// 缩进交给 paragraphStyle，这里不再往正文里塞全角空格——否则会和首行缩进叠加成四格。
    public static func normalizedBody(_ body: String) -> String {
        let lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}
