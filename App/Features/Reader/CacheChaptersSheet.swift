import SwiftUI
import ReaderCore

/// 从当前章往后缓存指定章数。只缓存正文，不把书加入书架。
struct CacheChaptersSheet: View {
    let book: Book
    let currentChapter: Int
    let chapterCount: Int

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var count: Int
    @State private var isCaching = false
    @State private var resultText: String?
    @State private var errorText: String?
    @State private var cachedCount = 0

    private var available: Int {
        max(chapterCount - currentChapter - 1, 0)
    }

    init(book: Book, currentChapter: Int, chapterCount: Int) {
        self.book = book
        self.currentChapter = currentChapter
        self.chapterCount = chapterCount
        _count = State(initialValue: min(10, max(1, chapterCount - currentChapter - 1)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if available > 0 {
                        Stepper(value: $count, in: 1...available) {
                            Text("缓存后面 \(count) 章")
                                .font(.system(size: 15))
                        }
                        Text("从第 \(currentChapter + 2) 章开始，最多 \(available) 章")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink3)
                    } else {
                        Text("已经是最后一章，没有可缓存的后续章节")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink3)
                    }
                } header: {
                    Text("缓存范围")
                }

                Section {
                    HStack {
                        Text("当前已缓存")
                        Spacer()
                        Text("\(cachedCount) 章")
                            .foregroundStyle(Palette.ink2)
                    }
                    .font(.system(size: 14))

                    if let resultText {
                        Text(resultText)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.accent)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("状态")
                }

                Section {
                    Button {
                        cache()
                    } label: {
                        HStack {
                            Spacer()
                            if isCaching {
                                ProgressView().controlSize(.small)
                            }
                            Text(isCaching ? "缓存中…" : "开始缓存")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                    }
                    .disabled(isCaching || available == 0)
                }
            }
            .navigationTitle("缓存后续章节")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                cachedCount = env.onlineReading.cachedChapterCount(for: book)
            }
        }
    }

    private func cache() {
        guard available > 0, !isCaching else { return }
        isCaching = true
        resultText = nil
        errorText = nil
        let start = currentChapter + 1
        let target = min(count, available)

        Task {
            do {
                let downloaded = try await env.onlineReading.downloadChapters(
                    for: book,
                    from: start,
                    count: target
                )
                await MainActor.run {
                    cachedCount = env.onlineReading.cachedChapterCount(for: book)
                    isCaching = false
                    resultText = downloaded > 0
                        ? "已缓存 \(target) 章，新增 \(downloaded) 章"
                        : "这 \(target) 章之前已经缓存过了"
                }
            } catch {
                await MainActor.run {
                    isCaching = false
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}
