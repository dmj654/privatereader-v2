import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 封面统一裁成 400×560 的 JPEG，体积可控且网格对齐。
public enum CoverStore {
    public static let targetSize = CGSize(width: 400, height: 560)

    public static func normalizedJPEG(from data: Data,
                                      target: CGSize = targetSize,
                                      quality: CGFloat = 0.82) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height) * 2
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return render(thumbnail, into: target, quality: quality)
    }

    public static func write(from data: Data, to url: URL, quality: CGFloat = 0.82) -> Bool {
        guard let jpeg = normalizedJPEG(from: data, quality: quality) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try jpeg.write(to: url)
            return true
        } catch {
            return false
        }
    }

    static func render(_ image: CGImage, into target: CGSize, quality: CGFloat) -> Data? {
        let width = Int(target.width)
        let height = Int(target.height)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        let bounds = CGRect(x: 0, y: 0, width: target.width, height: target.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)

        let scale = max(target.width / CGFloat(image.width), target.height / CGFloat(image.height))
        let drawWidth = CGFloat(image.width) * scale
        let drawHeight = CGFloat(image.height) * scale
        let rect = CGRect(x: (target.width - drawWidth) / 2,
                          y: (target.height - drawHeight) / 2,
                          width: drawWidth,
                          height: drawHeight)
        context.interpolationQuality = .high
        context.draw(image, in: rect)

        guard let output = context.makeImage() else { return nil }

        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
