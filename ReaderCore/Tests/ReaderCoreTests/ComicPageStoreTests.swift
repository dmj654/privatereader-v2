import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ReaderCore

final class ComicPageStoreTests: XCTestCase {
    private var root: URL!
    private var paths: SandboxPaths!
    private var store: ComicPageStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicPageStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
        try paths.prepare()
        store = ComicPageStore(paths: paths)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else {
            throw XCTSkip("无法创建测试图片")
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw XCTSkip("无法创建图片写入器")
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func makeBook(id: String = "comic-1") -> Book {
        Book(id: id, type: .comic, origin: .local, title: "测试漫画", chapterCount: 1)
    }

    func testPageURLsAreNaturallySorted() throws {
        let pages = paths.bookDirectory("comic-1").appendingPathComponent("pages", isDirectory: true)
        try writePNG(width: 10, height: 10, to: pages.appendingPathComponent("0010.png"))
        try writePNG(width: 10, height: 10, to: pages.appendingPathComponent("0002.png"))
        try writePNG(width: 10, height: 10, to: pages.appendingPathComponent("0001.png"))
        // 非图片文件要被忽略
        try Data("x".utf8).write(to: pages.appendingPathComponent("readme.txt"))

        let urls = store.pageURLs(for: makeBook())

        XCTAssertEqual(urls.map(\.lastPathComponent), ["0001.png", "0002.png", "0010.png"])
        XCTAssertEqual(store.pageCount(for: makeBook()), 3)
    }

    func testMissingDirectoryYieldsNoPages() {
        XCTAssertEqual(store.pageURLs(for: makeBook(id: "nope")), [])
    }

    func testDownsampleLimitsLongestSide() throws {
        let url = root.appendingPathComponent("big.png")
        try writePNG(width: 400, height: 800, to: url)

        let image = ImageDownsampler.downsample(url: url, maxPixelSize: 200)

        XCTAssertNotNil(image)
        XCTAssertEqual(max(image!.width, image!.height), 200)
        XCTAssertEqual(image!.width, 100)
        XCTAssertEqual(image!.height, 200)
    }

    func testDownsampleWidthKeepsAspectForLongStrip() throws {
        let url = root.appendingPathComponent("strip.png")
        try writePNG(width: 400, height: 1600, to: url)

        let image = ImageDownsampler.downsampleWidth(url: url, targetWidth: 200)

        XCTAssertEqual(image?.width, 200)
        XCTAssertEqual(image?.height, 800, "条漫按宽度缩放，高度必须等比保留")
    }

    func testPixelSizeReadsHeaderWithoutDecoding() throws {
        let url = root.appendingPathComponent("size.png")
        try writePNG(width: 320, height: 480, to: url)

        let size = ImageDownsampler.pixelSize(of: url)

        XCTAssertEqual(size?.width, 320)
        XCTAssertEqual(size?.height, 480)
    }

    func testImageIsCachedAcrossCalls() throws {
        let pages = paths.bookDirectory("comic-1").appendingPathComponent("pages", isDirectory: true)
        try writePNG(width: 100, height: 200, to: pages.appendingPathComponent("0001.png"))

        let options = ComicPageStore.DecodeOptions(maxPixelSize: 100)
        let first = store.image(for: makeBook(), index: 0, options: options)
        let second = store.image(for: makeBook(), index: 0, options: options)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "同一页第二次取图应当命中缓存，不重新解码")
    }

    func testImageReturnsNilForOutOfRangeIndex() throws {
        let pages = paths.bookDirectory("comic-1").appendingPathComponent("pages", isDirectory: true)
        try writePNG(width: 10, height: 10, to: pages.appendingPathComponent("0001.png"))

        XCTAssertNil(store.image(for: makeBook(), index: 3,
                                 options: ComicPageStore.DecodeOptions(maxPixelSize: 100)))
    }

    func testPrefetchDoesNotThrowAndKeepsNeighbours() throws {
        let pages = paths.bookDirectory("comic-1").appendingPathComponent("pages", isDirectory: true)
        for index in 1...5 {
            try writePNG(width: 40, height: 60, to: pages.appendingPathComponent(String(format: "%04d.png", index)))
        }

        let options = ComicPageStore.DecodeOptions(maxPixelSize: 60)
        store.prefetch(for: makeBook(), around: 2, radius: 2, options: options)

        for index in 0...4 {
            XCTAssertNotNil(store.image(for: makeBook(), index: index, options: options))
        }
    }
}
