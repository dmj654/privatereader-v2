import Foundation
import ImageIO
import CoreGraphics

/// 漫画页的取图与下采样。
///
/// 页图在导入时已经解包到 `Books/<id>/pages/`，阅读器只负责按需读一张、缩到屏幕大小。
/// 不缩放直接解码原图，一张 3000×8000 的长图能吃掉 90MB；连读几页就爆内存。
public final class ComicPageStore {
    public struct Page: Equatable, Sendable {
        public let index: Int
        public let url: URL
    }

    private let paths: SandboxPaths
    private let fileManager = FileManager.default
    private let cache = NSCache<NSString, CGImageBox>()

    public init(paths: SandboxPaths) {
        self.paths = paths
        cache.countLimit = 6
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    // MARK: 页面列表

    public func pageURLs(for book: Book) -> [URL] {
        pageURLs(bookId: book.id)
    }

    public func pageURLs(bookId: String) -> [URL] {
        let directory = paths.bookDirectory(bookId).appendingPathComponent("pages", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }

        let images = names.filter { name in
            let ext = (name as NSString).pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "webp", "gif", "heic"].contains(ext)
        }
        return NaturalSort.sorted(images).map { directory.appendingPathComponent($0) }
    }

    public func pageCount(for book: Book) -> Int {
        pageURLs(for: book).count
    }

    // MARK: 取图

    public struct DecodeOptions: Sendable {
        /// 最长边的像素上限。一般传屏幕长边 × 2，放大后仍清晰，又不至于爆内存。
        public var maxPixelSize: Int
        public var cacheKeySuffix: String

        public init(maxPixelSize: Int, cacheKeySuffix: String = "") {
            self.maxPixelSize = maxPixelSize
            self.cacheKeySuffix = cacheKeySuffix
        }
    }

    public func image(for book: Book, index: Int, options: DecodeOptions) -> CGImage? {
        let urls = pageURLs(for: book)
        guard urls.indices.contains(index) else { return nil }

        let key = "\(book.id)-\(index)-\(options.maxPixelSize)-\(options.cacheKeySuffix)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }

        guard let image = ImageDownsampler.downsample(url: urls[index],
                                                      maxPixelSize: options.maxPixelSize) else {
            return nil
        }
        let cost = image.bytesPerRow * image.height
        cache.setObject(CGImageBox(image), forKey: key, cost: cost)
        return image
    }

    /// 预取前后几页：只把解码结果放进缓存，翻页时就不用等 IO。
    public func prefetch(for book: Book, around index: Int, radius: Int = 2, options: DecodeOptions) {
        let count = pageCount(for: book)
        guard count > 0 else { return }
        let lower = max(index - radius, 0)
        let upper = min(index + radius, count - 1)
        guard lower <= upper else { return }

        let urls = pageURLs(for: book)
        for target in lower...upper where target != index {
            let key = "\(book.id)-\(target)-\(options.maxPixelSize)-\(options.cacheKeySuffix)" as NSString
            if cache.object(forKey: key) != nil { continue }
            guard let image = ImageDownsampler.downsample(url: urls[target],
                                                          maxPixelSize: options.maxPixelSize) else { continue }
            cache.setObject(CGImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        }
    }

    public func clearCache() {
        cache.removeAllObjects()
    }

    /// NSCache 只收 class，用它把 CGImage 包一层。
    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
}

public enum ImageDownsampler {
    /// 按最长边下采样。相比 `UIImage(data:)` 全解码，峰值内存能降一个数量级。
    public static func downsample(url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelSize)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 条漫专用：按宽度下采样，高度按比例保留。
    ///
    /// 普通 `downsample` 限制的是最长边，一张 1200×30000 的长图会被压成 74 像素宽，
    /// 完全没法看。这里先算出「宽度缩到 targetWidth 后总高度是多少」，
    /// 再把它当作最长边交给 ImageIO，输出宽度正好落在目标上。
    public static func downsampleWidth(url: URL, targetWidth: Int) -> CGImage? {
        guard let size = pixelSize(of: url), size.width > 0, size.height > 0 else { return nil }
        var width = min(CGFloat(max(targetWidth, 64)), size.width)
        var ratio = width / size.width
        var height = size.height * ratio

        // 超长条漫（高度几万像素）整张解码会吃掉上百 MB。把最长边压到 16000：
        // 宽度会相应变窄，但一屏里仍然能看清，内存不会炸。
        let maxHeight: CGFloat = 16000
        if height > maxHeight {
            height = maxHeight
            ratio = height / size.height
            width = size.width * ratio
        }

        let longest = Int(max(width, height))
        return downsample(url: url, maxPixelSize: longest)
    }

    public static func pixelSize(of url: URL) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}
