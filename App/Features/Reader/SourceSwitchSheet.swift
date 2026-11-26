import SwiftUI
import ReaderCore

/// 在线阅读换源。
///
/// 有些源目录不全、正文缺章。这里按书名在启用的源里重新搜一遍，
/// 选中后覆盖同一本书的清单（书 id 不变），进度和书签都还在。
struct SourceSwitchSheet: View {
    let book: Book
    let onSwitched: (Book) -> Void

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SourceSwitchModel

    init(book: Book, onSwitched: @escaping (Book) -> Void) {
        self.book = book
        self.onSwitched = onSwitched
        _model = StateObject(wrappedValue: SourceSwitchModel(book: book))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    list
                }

                if model.isSwitching {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        VStack(spacing: 8) {
                            ProgressView().tint(Palette.accent)
                            Text("正在切换源…")
                                .font(Typo.micro)
                                .foregroundStyle(Palette.ink3)
                        }
                        .padding(18)
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { model.search(env: env) }
            .alert("换源失败", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("当前共 \(book.chapterCount) 章 · 换源后进度保留")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 0)
            if model.isSearching {
                ProgressView().controlSize(.small)
                Text("\(model.finished)/\(model.total)")
                    .font(Typo.micro.monospacedDigit())
                    .foregroundStyle(Palette.ink3)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var list: some View {
        if model.results.isEmpty {
            VStack(spacing: 10) {
                if model.isSearching {
                    ProgressView().tint(Palette.accent)
                    Text("正在各源里找这本书…")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                } else {
                    EmptyStateView(symbol: "arrow.left.arrow.right",
                                   title: "没有找到别的源",
                                   message: "可以在搜索页重新搜这本书，确认其他源是否收录。")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.results, id: \.entry.sourceId) { row in
                    Button {
                        Task {
                            if let updated = await model.switchTo(row, env: env) {
                                onSwitched(updated)
                                dismiss()
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.sourceName)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                Text(row.entry.lastChapter.isEmpty ? "最新章节未知" : row.entry.lastChapter)
                                    .font(Typo.micro)
                                    .foregroundStyle(Palette.ink3)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.ink3)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

@MainActor
final class SourceSwitchModel: ObservableObject {
    struct Row {
        let entry: OnlineBook
        let sourceName: String
    }

    let book: Book
    @Published var results: [Row] = []
    @Published var isSearching = true
    @Published var finished = 0
    @Published var total = 0
    @Published var isSwitching = false
    @Published var errorMessage: String?

    private var sources: [String: SearchTarget] = [:]
    private var seen = Set<String>()
    private var task: Task<Void, Never>?

    init(book: Book) {
        self.book = book
    }

    func search(env: AppEnvironment) {
        guard task == nil else { return }
        task = Task {
            let enabled: [SearchTarget]
            do {
                let repo = env.sources
                enabled = try await Task.detached(priority: .userInitiated) {
                    try SourceImportService(repo: repo).enabledTargets()
                }.value.filter { $0.isComic == (book.type == .comic) }
            } catch {
                isSearching = false
                errorMessage = "读取书源失败：\(error.localizedDescription)"
                return
            }

            for source in enabled { sources[source.id] = source }
            total = enabled.count
            guard !enabled.isEmpty else {
                isSearching = false
                return
            }

            let coordinator = SearchCoordinator(client: env.sourceClient,
                                                venera: env.veneraRuntime)
            for await result in await coordinator.search(sources: enabled, key: book.title) {
                finished += 1
                guard result.errorText == nil else { continue }
                for entry in result.books where matches(entry) {
                    guard seen.insert(entry.sourceId).inserted else { continue }
                    results.append(Row(entry: entry, sourceName: result.source.name))
                }
            }
            isSearching = false
        }
    }

    func switchTo(_ row: Row, env: AppEnvironment) async -> Book? {
        guard let source = sources[row.entry.sourceId] else {
            errorMessage = "这个源已被删除。"
            return nil
        }
        isSwitching = true
        defer { isSwitching = false }

        do {
            let service = OnlineBookService(
                client: env.sourceClient,
                library: OnlineLibrary(paths: env.paths),
                venera: env.veneraRuntime
            )
            let updated: Book
            switch source {
            case .legado(let legado):
                updated = try await service.switchSource(book: book, to: row.entry, source: legado)
            case .venera(let script):
                updated = try await service.switchSourceVenera(
                    book: book, to: row.entry, source: script, runtime: env.veneraRuntime
                )
            }
            try env.books.upsert(updated)
            return updated
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    private func matches(_ entry: OnlineBook) -> Bool {
        let target = normalize(book.title)
        let name = normalize(entry.name)
        return name == target || name.contains(target) || target.contains(name)
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "《", with: "")
            .replacingOccurrences(of: "》", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
