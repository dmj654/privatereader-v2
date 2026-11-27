import SwiftUI
import ReaderCore

struct BookCell: View {
    let book: Book
    let coverURL: URL?
    let progress: Double
    var cachedChapterCount: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                BookCoverView(book: book, coverURL: coverURL)
                    .aspectRatio(3.0 / 4.15, contentMode: .fit)

                if book.newChapterCount > 0 {
                    badge(text: "\(book.newChapterCount)")
                }
            }

            Text(book.title)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .padding(.top, 8)

            HStack(spacing: 4) {
                Text(progressText)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(progress > 0 ? Palette.accent : Palette.ink3.opacity(0.8))
                if let cachedChapterCount, cachedChapterCount > 0 {
                    Text("· 缓存 \(cachedChapterCount) 章")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
            }
            .padding(.top, 5)
        }
    }

    private var progressText: String {
        let percent = Int((max(0, min(1, progress)) * 100).rounded())
        return percent == 0 ? "0%" : "\(percent)%"
    }

    private func badge(text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 17, minHeight: 17)
            .background(Palette.accent)
            .clipShape(Capsule())
            .padding(6)
    }
}
