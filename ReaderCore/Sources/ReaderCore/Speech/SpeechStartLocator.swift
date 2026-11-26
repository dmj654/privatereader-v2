import Foundation

/// "从这一页开始听"的起点：第几句，以及是否要从这句中间开口。
public struct SpeechStart: Equatable {
    public let index: Int
    /// 句子内偏移（UTF-16）。页首把一句话切成两半时，这里大于 0——
    /// 朗读应当从页首这半句开始，而不是退回上一页，也不是跳到下一句。
    public let characterOffset: Int

    public init(index: Int, characterOffset: Int) {
        self.index = index
        self.characterOffset = characterOffset
    }
}

/// 决定"从这一页开始听，第一句该是哪一句、从哪个字开口"。
///
/// 这里有三件事必须同时满足，缺一个用户就会觉得"听的和看的不是一回事"：
/// 1. 章标题排在正文前面，但它不是正文——不该从"第三章 XXX"开始念；
/// 2. 分页会把一句话切成两半，页首落在句子中间时，要从**页首这半句**开口，
///    既不能倒回上一页念（听感错位），也不能跳到下一句（漏掉眼前这半句）；
/// 3. 页首落在空白处时，落到下一句。
///
/// 上一版为了"绝不倒回上一页"，做成了"从这一页开始的第一个完整句念"，
/// 结果页首那半句被整段跳过——用户看着眼前有字，耳朵却从第二句开始。现在改为截断开口。
public enum SpeechStartLocator {

    public static func start(sentences: [SpeechSentence],
                             pageLocation: Int,
                             titleLength: Int,
                             skipTitle: Bool = true) -> SpeechStart {
        guard !sentences.isEmpty else { return SpeechStart(index: 0, characterOffset: 0) }

        var index: Int
        var offset = 0

        if let hit = sentences.firstIndex(where: { NSLocationInRange(pageLocation, $0.range) }) {
            index = hit
            // 页首在这句中间：从句中开口
            offset = max(0, pageLocation - sentences[hit].location)
        } else if let next = sentences.firstIndex(where: { $0.location > pageLocation }) {
            // 页首在两句之间的空白里：从下一句开头念
            index = next
        } else {
            // 页首在最后一句之后：只能念最后一句（极端情况）
            index = sentences.count - 1
            offset = max(0, pageLocation - sentences[index].location)
        }

        if skipTitle, titleLength > 0, sentences[index].location < titleLength {
            // 页首落在标题里（章首）：整段标题跳过，从正文第一句开头念
            index = sentences.firstIndex { $0.location >= titleLength } ?? sentences.count - 1
            offset = 0
        }

        return SpeechStart(index: index, characterOffset: offset)
    }

    /// 兼容只需要句子下标的调用。
    public static func startIndex(sentences: [SpeechSentence],
                                  pageLocation: Int,
                                  titleLength: Int,
                                  skipTitle: Bool = true) -> Int {
        start(sentences: sentences,
              pageLocation: pageLocation,
              titleLength: titleLength,
              skipTitle: skipTitle).index
    }
}
