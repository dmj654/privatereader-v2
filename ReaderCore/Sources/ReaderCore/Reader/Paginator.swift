import Foundation
import CoreText

/// 用 CoreText 排版分页。纯 CoreText，不依赖 UIKit，因此能在单元测试里验证。
public enum Paginator {
    /// 返回每一页对应的字符范围。保证：连续、无缝、覆盖全文。
    public static func pageRanges(attributedString: NSAttributedString, pageSize: CGSize) -> [NSRange] {
        guard attributedString.length > 0,
              pageSize.width > 1,
              pageSize.height > 1 else { return [] }

        let framesetter = CTFramesetterCreateWithAttributedString(attributedString as CFAttributedString)
        let path = CGPath(rect: CGRect(origin: .zero, size: pageSize), transform: nil)

        var ranges: [NSRange] = []
        var location = 0
        let total = attributedString.length

        while location < total {
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }

            ranges.append(NSRange(location: visible.location, length: visible.length))
            location = visible.location + visible.length
        }

        return ranges
    }

    public static func pageCount(attributedString: NSAttributedString, pageSize: CGSize) -> Int {
        pageRanges(attributedString: attributedString, pageSize: pageSize).count
    }
}
