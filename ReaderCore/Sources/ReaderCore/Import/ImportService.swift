import Foundation

/// 按扩展名分派到具体解析器，并把结果统一成 ImportedContent。
public struct ImportService {
    public static let novelExtensions: Set<String> = ["txt", "epub", "pdf"]
    public static let comicExtensions: Set<String> = ["cbz", "zip"]

    public init() {}

    public func parse(url: URL) throws -> ImportedContent {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt":
            return .novel(try TxtParser.parse(url: url))
        case "epub":
            return .novel(try EpubParser.parse(url: url))
        case "pdf":
            #if canImport(PDFKit)
            return .novel(try PdfParser.parse(url: url))
            #else
            throw ImportError.unsupportedFormat(ext)
            #endif
        case "cbz", "zip":
            return .comic(try CbzParser.parse(url: url))
        default:
            throw ImportError.unsupportedFormat(ext)
        }
    }
}

public struct ImportOutcome: Equatable {
    public let fileName: String
    public let content: ImportedContent?
    public let errorMessage: String?

    public var isSuccess: Bool { content != nil }

    public init(fileName: String, content: ImportedContent?, errorMessage: String?) {
        self.fileName = fileName
        self.content = content
        self.errorMessage = errorMessage
    }
}

public struct BatchImporter {
    public let service: ImportService

    public init(service: ImportService = ImportService()) {
        self.service = service
    }

    /// 串行解析，单个失败不影响其余。
    public func importAll(urls: [URL], progress: ((Int, Int) -> Void)? = nil) -> [ImportOutcome] {
        var outcomes: [ImportOutcome] = []
        for (index, url) in urls.enumerated() {
            progress?(index + 1, urls.count)
            do {
                let content = try service.parse(url: url)
                outcomes.append(ImportOutcome(fileName: url.lastPathComponent, content: content, errorMessage: nil))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                outcomes.append(ImportOutcome(fileName: url.lastPathComponent, content: nil, errorMessage: message))
            }
        }
        return outcomes
    }
}
