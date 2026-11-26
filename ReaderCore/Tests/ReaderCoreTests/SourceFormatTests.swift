import XCTest
@testable import ReaderCore

/// 网友分享的书源不止标准数组一种形态。
/// 这些用例来自真机上「导不进去」的几种常见格式。
final class SourceFormatTests: XCTestCase {

    func testGBKEncodedJSONIsTolerated() throws {
        let json = "[{\"bookSourceName\":\"GBK 书源\",\"bookSourceUrl\":\"https://gbk.example\"}]"
        guard let data = json.data(using: TextDecoder.gb18030) else {
            return XCTFail("无法生成 GBK 数据")
        }

        let sources = try LegadoParser.parse(data: data)

        XCTAssertEqual(sources.first?.name, "GBK 书源")
    }

    func testJSONLinesAreTolerated() throws {
        let text = """
        {"bookSourceName":"第一行","bookSourceUrl":"https://one.example"}
        {"bookSourceName":"第二行","bookSourceUrl":"https://two.example"}
        """

        let sources = try LegadoParser.parse(data: Data(text.utf8))

        XCTAssertEqual(sources.map(\.name), ["第一行", "第二行"])
    }

    func testURLKeyedDictionaryIsTolerated() throws {
        let text = """
        {"https://a.example":{"bookSourceName":"A","bookSourceUrl":"https://a.example"},
         "https://b.example":{"bookSourceName":"B","bookSourceUrl":"https://b.example"}}
        """

        let sources = try LegadoParser.parse(data: Data(text.utf8))

        XCTAssertEqual(Set(sources.map(\.name)), ["A", "B"])
    }

    func testUTFF16JSONIsTolerated() throws {
        let json = "[{\"bookSourceName\":\"UTF16 源\",\"bookSourceUrl\":\"https://utf16.example\"}]"
        guard let data = json.data(using: .utf16) else {
            return XCTFail("无法生成 UTF-16 数据")
        }

        let sources = try LegadoParser.parse(data: data)

        XCTAssertEqual(sources.first?.name, "UTF16 源")
    }

    func testZipArchiveExtractsLargestJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceFormatZip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = SandboxPaths(root: root)
        try paths.prepare()
        try Data("db".utf8).write(to: paths.database)

        let source = "{\"bookSourceName\":\"压缩包源\",\"bookSourceUrl\":\"https://zip.example\"}"
        let input = BackupInput(appVersion: "test", bookCount: 0,
                                sources: [source], includeBooks: false)
        let zipURL = try BackupExporter(paths: paths).export(input)
        let data = try Data(contentsOf: zipURL)

        XCTAssertTrue(SourceArchive.looksLikeZip(data))
        let json = try XCTUnwrap(SourceArchive.jsonData(from: data))
        let parsed = try LegadoParser.parse(data: json)
        XCTAssertEqual(parsed.first?.name, "压缩包源")
    }

    func testURLCommentSuffixIsStripped() throws {
        let json = "[{\"bookSourceName\":\"漫画源\",\"bookSourceUrl\":\"https://comic.example##漫画\",\"bookSourceType\":2}]"

        let sources = try LegadoParser.parse(data: Data(json.utf8))

        XCTAssertEqual(sources.first?.url, "https://comic.example")
        XCTAssertEqual(sources.first?.id, "https://comic.example")
        XCTAssertEqual(sources.first?.type, 2)
    }

    func testBOMAndWhitespaceAreTolerated() throws {
        let json = "\n  [{\"bookSourceName\":\"前后空白\",\"bookSourceUrl\":\"https://space.example\"}]\n"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(json.utf8))

        let sources = try LegadoParser.parse(data: data)

        XCTAssertEqual(sources.first?.name, "前后空白")
    }
}
