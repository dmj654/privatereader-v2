import XCTest
@testable import ReaderCore

final class SentenceSplitterTests: XCTestCase {
    func testSplitsOnChinesePunctuation() {
        let sentences = SentenceSplitter.split("第一句。第二句！第三句？")
        XCTAssertEqual(sentences.count, 3)
        XCTAssertEqual(sentences[0].text, "第一句。")
        XCTAssertEqual(sentences[1].text, "第二句！")
        XCTAssertEqual(sentences[2].text, "第三句？")
    }

    func testLocationsAreContiguousAndInOrder() {
        let text = "　　第一句。第二句！第三句？"
        let sentences = SentenceSplitter.split(text)

        // 段首两个全角空格不该进第一句
        XCTAssertEqual(sentences[0].location, 2)
        XCTAssertEqual(sentences[0].length, 4)

        for pair in zip(sentences, sentences.dropFirst()) {
            XCTAssertLessThan(pair.0.location, pair.1.location, "句子的位置必须递增")
        }

        let ns = text as NSString
        for sentence in sentences {
            let sliced = ns.substring(with: sentence.range)
            XCTAssertEqual(sliced, sentence.text, "偏移必须能切回原句")
        }
    }

    func testClosingQuoteBelongsToTheSentence() {
        let sentences = SentenceSplitter.split("他说：“走吧。”然后离开。")
        XCTAssertEqual(sentences.count, 2)
        XCTAssertEqual(sentences[0].text, "他说：“走吧。”")
        XCTAssertEqual(sentences[1].text, "然后离开。")
    }

    func testNewlineEndsSentence() {
        let sentences = SentenceSplitter.split("第一行\n第二行")
        XCTAssertEqual(sentences.count, 2)
        XCTAssertEqual(sentences[0].text, "第一行")
        XCTAssertEqual(sentences[1].text, "第二行")
    }

    func testNoPunctuationStillReturnsOneSentence() {
        let sentences = SentenceSplitter.split("这句话没有任何标点")
        XCTAssertEqual(sentences.count, 1)
        XCTAssertEqual(sentences[0].text, "这句话没有任何标点")
    }

    func testEmptyInputReturnsNothing() {
        XCTAssertTrue(SentenceSplitter.split("").isEmpty)
        XCTAssertTrue(SentenceSplitter.split("　　\n  \n").isEmpty)
    }

    func testVeryLongSentenceIsSplitAtComma() {
        let clause = String(repeating: "很长的一段话，", count: 40)
        let sentences = SentenceSplitter.split(clause, maxLength: 60)

        XCTAssertGreaterThan(sentences.count, 1, "长句必须被切开，不能一口气念半分钟")
        for sentence in sentences {
            XCTAssertLessThanOrEqual(sentence.length, 80, "切完的句子不该还是超长")
        }
    }

    func testSplitPreservesAllVisibleCharacters() {
        let text = "　　他抬头看了看天。天很蓝，云很白。风停了。"
        let sentences = SentenceSplitter.split(text)
        let joined = sentences.map(\.text).joined()
        XCTAssertEqual(joined, text.trimmingCharacters(in: .whitespacesAndNewlines),
                       "切分不能丢字，否则念出来会跳句")
    }
}

final class SpeechQueueTests: XCTestCase {
    private func makeQueue(_ texts: [String]) -> SpeechQueue {
        var sentences: [SpeechSentence] = []
        var location = 0
        for text in texts {
            sentences.append(SpeechSentence(text: text, location: location, length: (text as NSString).length))
            location += (text as NSString).length
        }
        return SpeechQueue(sentences: sentences)
    }

    func testAdvanceThroughChapter() {
        var queue = makeQueue(["一。", "二。", "三。"])
        XCTAssertEqual(queue.current?.text, "一。")
        XCTAssertTrue(queue.advance())
        XCTAssertEqual(queue.current?.text, "二。")
        XCTAssertTrue(queue.advance())
        XCTAssertEqual(queue.current?.text, "三。")
        XCTAssertFalse(queue.advance(), "最后一句再前进应当报告到头")
        XCTAssertEqual(queue.current?.text, "三。", "到头后不能越界")
    }

    func testIsAtEnd() {
        var queue = makeQueue(["一。", "二。"])
        XCTAssertFalse(queue.isAtEnd)
        _ = queue.advance()
        XCTAssertTrue(queue.isAtEnd)
    }

    func testRewindStopsAtFirst() {
        var queue = makeQueue(["一。", "二。"])
        XCTAssertFalse(queue.rewind())
        _ = queue.advance()
        XCTAssertTrue(queue.rewind())
        XCTAssertEqual(queue.current?.text, "一。")
    }

    func testJumpClampsIntoRange() {
        var queue = makeQueue(["一。", "二。", "三。"])
        queue.jump(to: 99)
        XCTAssertEqual(queue.index, 2)
        queue.jump(to: -5)
        XCTAssertEqual(queue.index, 0)
    }

    func testIndexContainingLocation() {
        // "一。"=2, "二。"=4, "三。"=6
        let queue = makeQueue(["一。", "二。", "三。"])
        XCTAssertEqual(queue.index(containing: 0), 0)
        XCTAssertEqual(queue.index(containing: 2), 1)
        XCTAssertEqual(queue.index(containing: 5), 2)
        // 落在空白处时，回退到前面最近的一句
        XCTAssertEqual(queue.index(containing: 3), 1)
    }

    func testEmptyQueueIsSafe() {
        let queue = SpeechQueue(sentences: [])
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.isAtEnd)
        var mutable = queue
        XCTAssertFalse(mutable.advance())
        mutable.jump(to: 3)
        XCTAssertNil(mutable.current)
    }
}

final class SpeechStartLocatorTests: XCTestCase {
    /// 模拟真实章节：标题 + 换行 + 正文。位置与 attributedBody 的构造完全一致。
    private func chapter(title: String, body: String) -> (sentences: [SpeechSentence], titleLength: Int) {
        let full = title + "\n" + body
        return (SentenceSplitter.split(full), (title as NSString).length)
    }

    func testSkipsChapterTitleWhenStartingFromChapterHead() {
        let (sentences, titleLength) = chapter(
            title: "第七章 雨夜",
            body: "他推开门。风灌了进来。"
        )
        // 第 0 句是标题，第 1 句才是正文第一句
        XCTAssertEqual(sentences[0].text, "第七章 雨夜")

        let start = SpeechStartLocator.startIndex(
            sentences: sentences,
            pageLocation: 0,
            titleLength: titleLength
        )
        XCTAssertEqual(sentences[start].text, "他推开门。", "跳章后应当从正文第一句念，而不是念标题")
    }

    func testLongTitleSplitIntoMultipleSentencesIsFullySkipped() {
        let (sentences, titleLength) = chapter(
            title: "第一章 开始。然后结束。",
            body: "正文来了。"
        )
        let start = SpeechStartLocator.startIndex(
            sentences: sentences,
            pageLocation: 0,
            titleLength: titleLength
        )
        XCTAssertEqual(sentences[start].text, "正文来了。", "标题里带句号被切成多句时也要跳干净")
    }

    func testPageStartingInsideSentenceBeginsMidSentence() {
        let (sentences, titleLength) = chapter(
            title: "第七章 雨夜",
            body: "他推开门。风灌了进来。雨很大。"
        )
        let target = sentences.first { $0.text == "风灌了进来。" }!
        let start = SpeechStartLocator.start(
            sentences: sentences,
            pageLocation: target.location + 2, // 页首落在这句中间
            titleLength: titleLength
        )
        XCTAssertEqual(sentences[start.index].text, "风灌了进来。",
                       "页首把句子切成两半时，要从这半句开口，不能跳到下一句")
        XCTAssertEqual(start.characterOffset, 2, "从句中第 2 个字开始念")
    }

    func testPageStartingExactlyAtSentenceBoundaryUsesThatSentence() {
        let (sentences, titleLength) = chapter(
            title: "第七章 雨夜",
            body: "他推开门。风灌了进来。雨很大。"
        )
        let target = sentences.first { $0.text == "风灌了进来。" }!
        let start = SpeechStartLocator.start(
            sentences: sentences,
            pageLocation: target.location,
            titleLength: titleLength
        )
        XCTAssertEqual(sentences[start.index].text, "风灌了进来。")
        XCTAssertEqual(start.characterOffset, 0)
    }

    func testPageInsideLastSentenceFallsBackToContainingSentence() {
        let sentences = [
            SpeechSentence(text: "前面一句。", location: 0, length: 5),
            SpeechSentence(text: String(repeating: "长", count: 200) + "。", location: 5, length: 201)
        ]
        let start = SpeechStartLocator.start(
            sentences: sentences,
            pageLocation: 120, // 整页都在最后这句中间
            titleLength: 0
        )
        XCTAssertEqual(start.index, 1, "页面上没有任何句子从头开始时，只能念包含页首的那句")
        XCTAssertEqual(start.characterOffset, 115, "从页首对应的字符开口，不重复上一页")
    }

    func testPageLocationInWhitespacePicksNextSentence() {
        let sentences = [
            SpeechSentence(text: "上一句。", location: 0, length: 4),
            SpeechSentence(text: "下一句。", location: 6, length: 4)
        ]
        let start = SpeechStartLocator.start(
            sentences: sentences,
            pageLocation: 5,
            titleLength: 0
        )
        XCTAssertEqual(sentences[start.index].text, "下一句。", "页首落在空白处时应从下一句开始，不重复上一页")
        XCTAssertEqual(start.characterOffset, 0)
    }

    func testTruncatingByOffsetKeepsPageText() {
        // 页首落在句中时，截断后的句子必须正好等于页面上能看到的那半句
        let sentence = SpeechSentence(text: "风灌了进来，他关上门。", location: 100, length: 11)
        let pageLocation = 106
        let offset = pageLocation - sentence.location
        let cut = (sentence.text as NSString).substring(from: offset)
        XCTAssertEqual(cut, "他关上门。")
    }

    func testNoTitleStillWorks() {
        let sentences = [
            SpeechSentence(text: "第一句。", location: 0, length: 4),
            SpeechSentence(text: "第二句。", location: 4, length: 4)
        ]
        let start = SpeechStartLocator.startIndex(sentences: sentences, pageLocation: 0, titleLength: 0)
        XCTAssertEqual(start, 0)
    }

    func testTitleOnlyChapterDoesNotCrash() {
        let sentences = [SpeechSentence(text: "只有标题", location: 0, length: 4)]
        let start = SpeechStartLocator.startIndex(sentences: sentences, pageLocation: 0, titleLength: 4)
        XCTAssertEqual(start, 0, "整章只有标题时不能越界，退回最后一句")
    }

    func testEmptySentencesReturnsZero() {
        XCTAssertEqual(SpeechStartLocator.startIndex(sentences: [], pageLocation: 0, titleLength: 0), 0)
    }
}
