import UIKit
import ReaderCore

/// 没有源站封面的在线书，生成一张可辨识的本地封面。
///
/// 三个已交付小说源的 `coverUrl` 规则本来就是空的；只画一个灰底占位会让
/// 书架看起来像“没封面”。这里用书名和作者生成固定卡片，写入正常封面路径，
/// 这样书架、详情、缓存和离线都不依赖源站图片。
enum GeneratedCoverStore {
    static func write(title: String, author: String?, bookID: String, paths: SandboxPaths) -> String? {
        let size = CGSize(width: 400, height: 560)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            draw(title: title, author: author, in: context.cgContext, size: size)
        }
        guard let data = image.jpegData(compressionQuality: 0.86) else { return nil }
        do {
            try FileManager.default.createDirectory(at: paths.covers, withIntermediateDirectories: true)
            try data.write(to: paths.coverFile(bookID), options: .atomic)
            return "Covers/\(bookID).jpg"
        } catch {
            return nil
        }
    }

    private static func draw(title: String, author: String?, in context: CGContext, size: CGSize) {
        let seed = stableHash(title)
        let hue = CGFloat((seed % 360)) / 360
        let deep = UIColor(hue: hue, saturation: 0.55, brightness: 0.34, alpha: 1)
        let mid = UIColor(hue: hue + 0.045 > 1 ? hue - 0.955 : hue + 0.045,
                          saturation: 0.62, brightness: 0.58, alpha: 1)
        let light = UIColor(hue: hue + 0.09 > 1 ? hue - 0.91 : hue + 0.09,
                            saturation: 0.45, brightness: 0.78, alpha: 1)

        let colors = [deep.cgColor, mid.cgColor, light.cgColor] as CFArray
        let locations: [CGFloat] = [0, 0.56, 1]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors,
                                     locations: locations) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 30, y: size.height),
                                       end: CGPoint(x: size.width - 20, y: 70),
                                       options: [])
        }

        // 顶部留出一条低对比度的光带，避免整张图看起来像纯色块。
        context.setFillColor(UIColor.white.withAlphaComponent(0.10).cgColor)
        context.fill(CGRect(x: 0, y: 120, width: size.width, height: 1))
        context.fill(CGRect(x: 0, y: 124, width: size.width, height: 1))

        context.setFillColor(UIColor.white.withAlphaComponent(0.16).cgColor)
        let circle = CGRect(x: size.width - 132, y: -86, width: 260, height: 260)
        context.fillEllipse(in: circle)
        context.setFillColor(UIColor.white.withAlphaComponent(0.08).cgColor)
        context.fillEllipse(in: circle.insetBy(dx: 22, dy: 22))

        let titleRect = CGRect(x: 34, y: 150, width: size.width - 68, height: 224)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .left
        titleStyle.lineBreakMode = .byWordWrapping
        titleStyle.lineSpacing = 5
        let titleFontSize: CGFloat = title.count > 16 ? 28 : (title.count > 10 ? 34 : 40)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: titleFontSize, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: titleStyle
        ]
        (title as NSString).draw(with: titleRect,
                                 options: [.usesLineFragmentOrigin, .usesFontLeading],
                                 attributes: titleAttributes,
                                 context: nil)

        let ruleY: CGFloat = 406
        context.setFillColor(UIColor.white.withAlphaComponent(0.55).cgColor)
        context.fill(CGRect(x: 36, y: ruleY, width: 46, height: 2))

        let authorText = (author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? author! : "私阅读 · 在线书源"
        let authorStyle = NSMutableParagraphStyle()
        authorStyle.alignment = .left
        authorStyle.lineBreakMode = .byTruncatingTail
        let authorAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.88),
            .paragraphStyle: authorStyle
        ]
        (authorText as NSString).draw(with: CGRect(x: 36, y: ruleY + 20,
                                                  width: size.width - 72, height: 28),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading],
                                      attributes: authorAttributes,
                                      context: nil)

        let markerStyle = NSMutableParagraphStyle()
        markerStyle.alignment = .right
        let markerAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.58),
            .paragraphStyle: markerStyle,
            .kern: 1.2
        ]
        ("PRIVATE READER" as NSString).draw(with: CGRect(x: 36, y: 500,
                                                         width: size.width - 72, height: 20),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                                            attributes: markerAttributes,
                                            context: nil)
    }

    private static func stableHash(_ text: String) -> Int {
        var hash = 5381
        for scalar in text.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return abs(hash)
    }
}
