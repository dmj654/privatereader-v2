import Foundation

/// 一句话在整章文本里的位置。`location/length` 是 UTF-16 偏移，和 NSAttributedString 同一坐标系，
/// 所以可以直接用来做高亮。
public struct SpeechSentence: Equatable, Sendable {
    public let text: String
    public let location: Int
    public let length: Int

    public init(text: String, location: Int, length: Int) {
        self.text = text
        self.location = location
        self.length = length
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// 把整章正文切成句子。
///
/// 为什么不按行切：网文正文里一行常常只有几十个字甚至几个字，按行念会碎得像结巴。
/// 按标点切句子，念起来才连贯；同时保留精确偏移，才能做到"念到哪、亮到哪"。
public enum SentenceSplitter {
    /// 句末标点
    private static let terminators: Set<unichar> = [
        0x3002, // 。
        0xFF01, // ！
        0xFF1F, // ？
        0xFF1B, // ；
        0x2026, // …
        0x002E, // .
        0x0021, // !
        0x003F, // ?
        0x003B, // ;
        0x000A, // 换行
        0x000D  // 回车
    ]

    /// 句末标点后可能跟着的收尾符号，要一起算进这一句，否则高亮会短一截。
    private static let closers: Set<unichar> = [
        0x201D, // ”
        0x2019, // ’
        0x300D, // 」
        0x300F, // 』
        0x3009, // 〉
        0x300B, // 》
        0x3011, // 】
        0x0029, // )
        0xFF09  // ）
    ]

    /// 长句的二级切分点：一句话太长会一口气念 28 秒，中间没法暂停也没法跳。
    private static let softBreaks: Set<unichar> = [
        0xFF0C, // ，
        0x3001, // 、
        0x002C, // ,
        0xFF1A, // ：
        0x003A  // :
    ]

    public static func split(_ text: String, maxLength: Int = 110) -> [SpeechSentence] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        var result: [SpeechSentence] = []
        var start = 0
        var index = 0

        while index < ns.length {
            let character = ns.character(at: index)
            guard terminators.contains(character) else {
                index += 1
                continue
            }

            var end = index + 1
            while end < ns.length, closers.contains(ns.character(at: end)) {
                end += 1
            }
            append(ns: ns, from: start, to: end, maxLength: maxLength, into: &result)
            start = end
            index = end
        }

        if start < ns.length {
            append(ns: ns, from: start, to: ns.length, maxLength: maxLength, into: &result)
        }
        return result
    }

    // MARK: 内部

    private static func append(ns: NSString,
                               from start: Int,
                               to end: Int,
                               maxLength: Int,
                               into result: inout [SpeechSentence]) {
        guard end > start else { return }

        // 去掉首尾空白：段首缩进、行尾空行都不该被念出来，也不该被高亮
        var lower = start
        var upper = end
        while lower < upper, isWhitespace(ns.character(at: lower)) { lower += 1 }
        while upper > lower, isWhitespace(ns.character(at: upper - 1)) { upper -= 1 }
        guard upper > lower else { return }

        if upper - lower <= maxLength {
            emit(ns: ns, from: lower, to: upper, into: &result)
            return
        }

        // 太长就按逗号类标点再切；切不动就硬切，保证不会出现"一句念半分钟"
        var chunkStart = lower
        var cursor = lower
        while cursor < upper {
            let character = ns.character(at: cursor)
            if softBreaks.contains(character), cursor - chunkStart >= maxLength / 3 {
                emit(ns: ns, from: chunkStart, to: cursor + 1, into: &result)
                chunkStart = cursor + 1
            } else if cursor - chunkStart >= maxLength {
                emit(ns: ns, from: chunkStart, to: cursor, into: &result)
                chunkStart = cursor
            }
            cursor += 1
        }
        if chunkStart < upper {
            emit(ns: ns, from: chunkStart, to: upper, into: &result)
        }
    }

    private static func emit(ns: NSString, from start: Int, to end: Int, into result: inout [SpeechSentence]) {
        var lower = start
        var upper = end
        while lower < upper, isWhitespace(ns.character(at: lower)) { lower += 1 }
        while upper > lower, isWhitespace(ns.character(at: upper - 1)) { upper -= 1 }
        guard upper > lower else { return }

        let text = ns.substring(with: NSRange(location: lower, length: upper - lower))
        result.append(SpeechSentence(text: text, location: lower, length: upper - lower))
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A
            || character == 0x0D || character == 0x3000
    }
}

/// 朗读队列：只管"当前念第几句、下一句是谁、到头没有"。
/// 不碰音频，因此可以完整单元测试。
public struct SpeechQueue: Equatable {
    public private(set) var sentences: [SpeechSentence]
    public private(set) var index: Int

    public init(sentences: [SpeechSentence], index: Int = 0) {
        self.sentences = sentences
        self.index = sentences.isEmpty ? 0 : min(max(index, 0), sentences.count - 1)
    }

    public var current: SpeechSentence? {
        sentences.indices.contains(index) ? sentences[index] : nil
    }

    public var isAtEnd: Bool {
        sentences.isEmpty || index >= sentences.count - 1
    }

    public var count: Int { sentences.count }

    /// 前进一句。返回是否还有下一句；false 表示本章念完了。
    public mutating func advance() -> Bool {
        guard index + 1 < sentences.count else { return false }
        index += 1
        return true
    }

    public mutating func rewind() -> Bool {
        guard index > 0 else { return false }
        index -= 1
        return true
    }

    public mutating func jump(to target: Int) {
        guard !sentences.isEmpty else { return }
        index = min(max(target, 0), sentences.count - 1)
    }

    /// 找出包含指定位置的那一句，用于"点到哪儿就从哪儿念"。
    public func index(containing location: Int) -> Int? {
        sentences.firstIndex { NSLocationInRange(location, $0.range) }
            ?? sentences.lastIndex { $0.location <= location }
    }
}
