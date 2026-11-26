import SwiftUI
import ReaderCore

struct HomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var router: TabRouter

    @State private var books: [Book] = []
    @State private var progressByBook: [String: ReadingProgress] = [:]
    @State private var stats: ReadingStats = .empty
    @State private var readingBook: Book?

    private var continueBook: Book? {
        books.filter { $0.lastReadAt != nil }
            .max { ($0.lastReadAt ?? 0) < ($1.lastReadAt ?? 0) }
            ?? books.first
    }

    private var updatedBooks: [Book] {
        books.filter { $0.newChapterCount > 0 }
    }

    private var recentBooks: [Book] {
        Array(books.sorted { $0.addedAt > $1.addedAt }.prefix(4))
    }

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if books.isEmpty {
                        emptyState
                    } else {
                        if let continueBook { continueCard(continueBook) }
                        if !updatedBooks.isEmpty { updatesSection }
                        if !recentBooks.isEmpty { recentSection }
                        statsCard
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, 26)
            }
        }
        .navigationBarHidden(true)
        .onAppear(perform: reload)
        .onChange(of: router.selection) { tab in
            if tab == .home { reload() }
        }
        .fullScreenCover(item: $readingBook) { book in
            if book.type == .novel {
                NovelReaderView(book: book, env: env)
                    .environmentObject(env)
            } else if book.origin == .remote {
                OnlineComicView(book: book)
                    .environmentObject(env)
            } else {
                ComicReaderView(book: book)
                    .environmentObject(env)
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Text(dateText)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer()
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 38, height: 38)
                    .background(Palette.surface)
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(Palette.line, lineWidth: 1) }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 14)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: return "早上好"
        case 11..<14: return "中午好"
        case 14..<18: return "下午好"
        case 18..<23: return "晚上好"
        default: return "夜深了"
        }
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 EEEE"
        return formatter.string(from: Date())
    }

    // MARK: 接着读

    private func continueCard(_ book: Book) -> some View {
        Button {
            readingBook = book
        } label: {
            HStack(spacing: 14) {
                BookCoverView(book: book, coverURL: env.library.absoluteCoverURL(for: book))
                    .frame(width: 58, height: 82)

                VStack(alignment: .leading, spacing: 5) {
                    Text("接着读")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    Text(book.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)

                    Text(progressText(book))
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Palette.accent)
                    .clipShape(Circle())
            }
            .padding(14)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            }
            .shadow(color: Shadow.card, radius: Shadow.cardRadius, x: 0, y: Shadow.cardY)
        }
        .buttonStyle(.plain)
    }

    private func progressText(_ book: Book) -> String {
        if let progress = progressByBook[book.id], progress.percent > 0 {
            return "已读 \(Int(progress.percent * 100))% · 第 \(progress.chapterIndex + 1) 章"
        }
        return book.type == .novel ? "还没开始读" : "共 \(book.chapterCount) 章"
    }

    // MARK: 有更新

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("有更新", detail: "\(updatedBooks.count) 本")

            ForEach(updatedBooks.prefix(3)) { book in
                HStack(spacing: 10) {
                    BookCoverView(book: book, coverURL: env.library.absoluteCoverURL(for: book))
                        .frame(width: 32, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text("新增 \(book.newChapterCount) 章")
                            .font(Typo.micro)
                            .foregroundStyle(Palette.accent)
                    }
                    Spacer(minLength: 0)
                    Button("去读") { readingBook = book }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.accent)
                }
                .padding(10)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1)
                }
            }
        }
    }

    // MARK: 最近添加

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("最近添加", detail: nil)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentBooks) { book in
                        Button {
                            readingBook = book
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                BookCoverView(book: book,
                                              coverURL: env.library.absoluteCoverURL(for: book))
                                    .frame(width: 78, height: 108)
                                Text(book.title)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Palette.ink2)
                                    .lineLimit(1)
                                    .frame(width: 78, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: 统计

    private var statsCard: some View {
        NavigationLink {
            StatsView()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionTitle("阅读统计", detail: nil)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink3)
                }

                HStack(alignment: .bottom, spacing: 6) {
                    statItem("本周", StatsService.durationText(stats.weekSeconds))
                    Divider().frame(height: 26)
                    statItem("今天", StatsService.durationText(stats.last7Days.last?.seconds ?? 0))
                    Divider().frame(height: 26)
                    statItem("读完", "\(stats.finishedBooks) 本")
                    Spacer(minLength: 0)
                    miniChart
                }
            }
            .padding(14)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func statItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.ink3)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
        }
    }

    private var miniChart: some View {
        let maxSeconds = max(stats.last7Days.map(\.seconds).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(stats.last7Days.enumerated()), id: \.offset) { _, slice in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(slice.seconds > 0 ? Palette.accent.opacity(0.85) : Palette.line)
                    .frame(width: 5, height: max(3, 26 * CGFloat(slice.seconds) / CGFloat(maxSeconds)))
            }
        }
        .frame(height: 28, alignment: .bottom)
    }

    // MARK: 空状态

    private var emptyState: some View {
        Card(padding: 20) {
            VStack(spacing: 14) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Palette.accent)
                Text("书架还是空的")
                    .font(Typo.headline)
                    .foregroundStyle(Palette.ink)
                Text("导入本地的 txt / epub / pdf / cbz，或者先加一份书源去网上找书。")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    Button("导入本地书") { router.selection = .shelf }
                        .buttonStyle(PrimaryButtonStyle(height: 42))
                    Button("去找书源") { router.selection = .discover }
                        .buttonStyle(SecondaryButtonStyle(height: 42))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(Palette.ink)
            if let detail {
                Text(detail)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
            }
        }
    }

    // MARK: 数据

    private func reload() {
        books = (try? env.books.all()) ?? []
        progressByBook = [:]
        for book in books {
            if let progress = try? env.progress.fetch(bookId: book.id) {
                progressByBook[book.id] = progress
            }
        }
        let service = StatsService(sessions: env.sessions, books: env.books)
        stats = (try? service.stats()) ?? .empty
    }
}
