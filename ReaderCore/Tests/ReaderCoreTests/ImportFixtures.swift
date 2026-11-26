import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import ReaderCore

/// 测试素材全部现场生成，不依赖二进制文件，CI 可复现。
enum ImportFixtures {
    static var workspace: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Fixture-\(UUID().uuidString)", isDirectory: true)
    }

    static func makeDirectory() throws -> URL {
        let url = workspace
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func resolve(_ directory: URL?) throws -> URL {
        if let directory { return directory }
        return try makeDirectory()
    }

    // MARK: 文本

    static func makeTxt(chapterCount: Int, chapterBody: String = "正文内容。", directory: URL? = nil) throws -> URL {
        let dir = try resolve(directory)
        var text = ""
        for index in 1...chapterCount {
            text += "第\(index)章 标题\(index)\n\(chapterBody)\n\n"
        }
        let url = dir.appendingPathComponent("测试小说.txt")
        try text.data(using: .utf8)!.write(to: url)
        return url
    }

    static func makeGB18030Txt(directory: URL? = nil) throws -> URL {
        let dir = try resolve(directory)
        let text = "第一章 开始\n这是一段中文。\n\n第二章 结束\n又一段中文。\n"
        let url = dir.appendingPathComponent("gbk小说.txt")
        let data = try XCTUnwrapData(text.data(using: TextDecoder.gb18030))
        try data.write(to: url)
        return url
    }

    // MARK: 图片

    static func makeImageData(width: Int = 200, height: Int = 300, color: (CGFloat, CGFloat, CGFloat) = (0.3, 0.4, 0.5)) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        return pngData(from: image)!
    }

    static func pngData(from image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    static func imageSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: EPUB

    static func makeEpub(directory: URL? = nil) throws -> URL {
        let dir = try resolve(directory)
        let source = dir.appendingPathComponent("epub-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        try Data("application/epub+zip".utf8).write(to: source.appendingPathComponent("mimetype"))

        let metaInfo = source.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInfo, withIntermediateDirectories: true)
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try Data(container.utf8).write(to: metaInfo.appendingPathComponent("container.xml"))

        let oebps = source.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)

        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>测试之书</dc:title>
            <dc:creator>某作者</dc:creator>
          </metadata>
          <manifest>
            <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
          </spine>
        </package>
        """
        try Data(opf.utf8).write(to: oebps.appendingPathComponent("content.opf"))

        let chapter1 = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head>
        <body><h1>第一章 启程</h1><p>第一段正文。</p><p>第二段正文。</p></body></html>
        """
        let chapter2 = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>第二章</title></head>
        <body><h1>第二章 归途</h1><p>另一段正文。</p></body></html>
        """
        try Data(chapter1.utf8).write(to: oebps.appendingPathComponent("ch1.xhtml"))
        try Data(chapter2.utf8).write(to: oebps.appendingPathComponent("ch2.xhtml"))
        try makeImageData().write(to: oebps.appendingPathComponent("cover.png"))

        let epubURL = dir.appendingPathComponent("测试之书.epub")
        try FileManager.default.zipItem(at: source, to: epubURL, shouldKeepParent: false)
        return epubURL
    }

    // MARK: CBZ

    static func makeCbz(fileNames: [String] = ["1.png", "2.png", "10.png"], directory: URL? = nil) throws -> URL {
        let dir = try resolve(directory)
        let source = dir.appendingPathComponent("cbz-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        for (index, name) in fileNames.enumerated() {
            let color: (CGFloat, CGFloat, CGFloat) = (CGFloat(index) / 10.0, CGFloat(0.5), CGFloat(0.6))
            try makeImageData(width: 120, height: 160, color: color).write(to: source.appendingPathComponent(name))
        }

        let cbzURL = dir.appendingPathComponent("测试漫画.cbz")
        try FileManager.default.zipItem(at: source, to: cbzURL, shouldKeepParent: false)
        return cbzURL
    }

    // MARK: PDF

    static func makePdf(pageTexts: [String], directory: URL? = nil) throws -> URL {
        let dir = try resolve(directory)
        let url = dir.appendingPathComponent("测试文档.pdf")
        let data = NSMutableData()

        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw ImportError.unreadableFile("pdf consumer")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ImportError.unreadableFile("pdf context")
        }

        for text in pageTexts {
            context.beginPDFPage(nil)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: CTFontCreateWithName("PingFangSC-Regular" as CFString, 18, nil)
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 24, y: 200)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()

        try (data as Data).write(to: url)
        return url
    }
}

private func XCTUnwrapData(_ data: Data?) throws -> Data {
    guard let data else { throw ImportError.unreadableFile("encode") }
    return data
}
