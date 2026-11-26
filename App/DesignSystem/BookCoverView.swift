import SwiftUI
import UIKit
import ReaderCore

/// 封面缩略图。带一层内存缓存，避免滚动时反复解码。
struct BookCoverView: View {
    let book: Book
    let coverURL: URL?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = CoverImageCache.shared.image(for: book.id, url: coverURL) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [Color(hex: 0xD9E3EC), Color(hex: 0xC3D2E0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    // 书名放全，按封面高度自动缩字号；四行还放不下才截断。
                    VStack(spacing: 5) {
                        Text(book.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .minimumScaleFactor(0.62)

                        if let author = book.author, !author.isEmpty {
                            Text(author)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 10)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        }
    }
}

final class CoverImageCache {
    static let shared = CoverImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 300
    }

    func image(for id: String, url: URL?) -> UIImage? {
        guard let url else { return nil }
        let key = id as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
