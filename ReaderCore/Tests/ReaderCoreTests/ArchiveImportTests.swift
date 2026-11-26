import XCTest
@testable import ReaderCore

final class EpubParserTests: XCTestCase {
    func testParsesMetadataAndChapters() throws {
        let url = try ImportFixtures.makeEpub()
        let parsed = try EpubParser.parse(url: url)

        XCTAssertEqual(parsed.title, "测试之书")
        XCTAssertEqual(parsed.author, "某作者")
        XCTAssertEqual(parsed.chapters.count, 2)
        XCTAssertEqual(parsed.chapters[0].title, "第一章 启程")
        XCTAssertTrue(parsed.chapters[0].body.contains("第一段正文"))
        XCTAssertTrue(parsed.chapters[1].body.contains("另一段正文"))
        XCTAssertNotNil(parsed.coverData, "应取出 cover-image")
    }

    func testPlainFileThrows() throws {
        let url = try ImportFixtures.makeTxt(chapterCount: 2)
        XCTAssertThrowsError(try EpubParser.parse(url: url))
    }
}

final class CbzParserTests: XCTestCase {
    func testOrdersPagesNaturally() throws {
        let url = try ImportFixtures.makeCbz()
        let parsed = try CbzParser.parse(url: url)

        XCTAssertEqual(parsed.pages.count, 3)
        XCTAssertEqual(parsed.pages.map { ($0.entryName as NSString).lastPathComponent },
                       ["1.png", "2.png", "10.png"])
        XCTAssertNotNil(parsed.coverData)
    }

    func testExtractsPagesToDiskInOrder() throws {
        let url = try ImportFixtures.makeCbz()
        let target = try ImportFixtures.makeDirectory().appendingPathComponent("pages", isDirectory: true)

        let names = try CbzParser.extractPages(from: url, to: target)

        XCTAssertEqual(names, ["0000.png", "0001.png", "0002.png"])
        for name in names {
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(name).path))
        }

        let firstData = try Data(contentsOf: target.appendingPathComponent("0000.png"))
        XCTAssertEqual(ImportFixtures.imageSize(of: firstData), CGSize(width: 120, height: 160))
    }

    func testEmptyZipThrows() throws {
        let dir = try ImportFixtures.makeDirectory()
        let source = dir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("empty.cbz")
        try FileManager.default.zipItem(at: source, to: zipURL, shouldKeepParent: false)

        XCTAssertThrowsError(try CbzParser.parse(url: zipURL))
    }
}

final class PdfParserTests: XCTestCase {
    func testParsesEachPageAsChapter() throws {
        #if canImport(PDFKit)
        let url = try ImportFixtures.makePdf(pageTexts: ["第一页内容", "第二页内容", "第三页内容"])
        let parsed = try PdfParser.parse(url: url)

        XCTAssertEqual(parsed.chapters.count, 3)
        XCTAssertEqual(parsed.chapters[0].title, "第 1 页")
        XCTAssertTrue(parsed.chapters[0].body.contains("第一页内容"))
        XCTAssertTrue(parsed.chapters[2].body.contains("第三页内容"))
        #else
        throw XCTSkip("当前平台无 PDFKit")
        #endif
    }
}

final class ImportServiceTests: XCTestCase {
    func testDispatchesByExtension() throws {
        let service = ImportService()

        let txt = try ImportFixtures.makeTxt(chapterCount: 2)
        if case .novel(let novel) = try service.parse(url: txt) {
            XCTAssertEqual(novel.chapters.count, 2)
        } else {
            XCTFail("txt 应解析为小说")
        }

        let cbz = try ImportFixtures.makeCbz()
        if case .comic(let comic) = try service.parse(url: cbz) {
            XCTAssertEqual(comic.pages.count, 3)
        } else {
            XCTFail("cbz 应解析为漫画")
        }
    }

    func testUnsupportedExtensionThrows() throws {
        let url = try ImportFixtures.makeDirectory().appendingPathComponent("a.doc")
        try Data("x".utf8).write(to: url)
        XCTAssertThrowsError(try ImportService().parse(url: url)) { error in
            XCTAssertEqual(error as? ImportError, .unsupportedFormat("doc"))
        }
    }

    func testBatchImportKeepsGoingAfterFailure() throws {
        let good = try ImportFixtures.makeTxt(chapterCount: 2)
        let dir = try ImportFixtures.makeDirectory()
        let bad = dir.appendingPathComponent("坏文件.epub")
        try Data("not a zip".utf8).write(to: bad)

        let outcomes = BatchImporter().importAll(urls: [good, bad])

        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes[0].isSuccess)
        XCTAssertFalse(outcomes[1].isSuccess)
        XCTAssertNotNil(outcomes[1].errorMessage)
    }
}
