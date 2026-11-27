import SwiftUI
import UIKit
import ReaderCore

/// 条漫：长图按宽度铺满，纵向连续滚动。
///
/// 高度在解码前就用图片头里的像素尺寸算好，占位和真实高度一致，
/// 滚动时不会出现"加载完突然跳一下"。
struct StripReader: View {
    let book: Book
    let store: ComicPageStore?
    let pages: [URL]
    let background: Color
    var autoRunning: Bool = false
    var pointsPerSecond: CGFloat = 0
    var resetToken: Int = 0
    var onReachBottom: (() -> Void)?
    let onTap: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    AutoScrollDriver(
                        isRunning: autoRunning,
                        pointsPerSecond: pointsPerSecond,
                        resetToken: resetToken,
                        onReachBottom: onReachBottom
                    )
                    .frame(width: 1, height: 1)

                    ForEach(Array(pages.enumerated()), id: \.offset) { index, url in
                        StripPage(url: url,
                                  index: index,
                                  width: proxy.size.width,
                                  background: background)
                    }

                    Text("— 完 —")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                        .padding(.vertical, 28)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .simultaneousGesture(
                TapGesture().onEnded { onTap() }
            )
        }
    }
}

private struct StripPage: View {
    let url: URL
    let index: Int
    let width: CGFloat
    let background: Color

    @State private var image: CGImage?
    @State private var height: CGFloat = 420

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width)
            } else {
                Rectangle()
                    .fill(background)
                    .frame(width: width, height: height)
                    .overlay {
                        ProgressView().tint(Palette.accent.opacity(0.7))
                    }
            }
        }
        .task(id: index) {
            await load()
        }
    }

    private func load() async {
        // 先用头部信息把占位高度定准，再解码
        if let size = ImageDownsampler.pixelSize(of: url), size.width > 0 {
            let ratio = size.height / size.width
            await MainActor.run {
                height = max(width * ratio, 80)
            }
        }

        let target = Int(width * 2)
        let decoded = await Task.detached(priority: .userInitiated) {
            ImageDownsampler.downsampleWidth(url: url, targetWidth: target)
        }.value

        await MainActor.run {
            image = decoded
        }
    }
}
