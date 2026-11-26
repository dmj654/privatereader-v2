import SwiftUI
import ReaderCore

struct StorageView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var breakdown = StorageBreakdown()
    @State private var cacheList: [StorageService.BookCache] = []
    @State private var confirmClearCache = false
    @State private var confirmClearBackups = false

    private var service: StorageService { StorageService(paths: env.paths) }

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    totalCard
                    cacheCard
                    actionsCard
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, 14)
            }
        }
        .navigationTitle("存储空间")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .confirmationDialog("清空全部章节缓存？", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("清空缓存", role: .destructive) {
                service.clearCache()
                reload()
            }
        } message: {
            Text("只删已下载的在线章节，书、进度和书架都不动。清空后需要联网才能继续读。")
        }
        .confirmationDialog("清空备份文件？", isPresented: $confirmClearBackups, titleVisibility: .visible) {
            Button("清空备份", role: .destructive) {
                service.clearBackups()
                reload()
            }
        } message: {
            Text("只删 App 内生成的备份包。已经导出到「文件」的备份不受影响。")
        }
    }

    private var totalCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("占用")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Text(StorageService.text(breakdown.totalBytes))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Palette.ink)
                }

                bar
                legend
            }
        }
    }

    private var bar: some View {
        GeometryReader { proxy in
            let total = max(breakdown.totalBytes, 1)
            let width = proxy.size.width
            HStack(spacing: 2) {
                segment(breakdown.booksBytes, total: total, width: width, color: Palette.accent)
                segment(breakdown.cacheBytes, total: total, width: width, color: Color(hex: 0x7FA3B8))
                segment(breakdown.coversBytes, total: total, width: width, color: Color(hex: 0xB9CBD9))
                segment(breakdown.backupsBytes, total: total, width: width, color: Color(hex: 0xD8E2EB))
            }
            .frame(width: width, height: 10)
            .clipShape(Capsule())
            .background(Capsule().fill(Palette.line))
        }
        .frame(height: 10)
    }

    private func segment(_ bytes: Int64, total: Int64, width: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: bytes > 0 ? max(2, CGFloat(bytes) / CGFloat(total) * width) : 0)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("书文件", breakdown.booksBytes, Palette.accent)
            legendItem("章节缓存", breakdown.cacheBytes, Color(hex: 0x7FA3B8))
            legendItem("封面", breakdown.coversBytes, Color(hex: 0xB9CBD9))
            legendItem("备份", breakdown.backupsBytes, Color(hex: 0xD8E2EB))
        }
    }

    private func legendItem(_ title: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(title) \(StorageService.text(bytes))")
                .font(.system(size: 9.5))
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
        }
    }

    private var cacheCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("章节缓存")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Text("\(cacheList.count) 本")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                }

                if cacheList.isEmpty {
                    Text("还没有缓存的在线章节。在书的详情页点「缓存全本」可以离线读。")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                        .lineSpacing(2)
                } else {
                    ForEach(cacheList) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.book.title)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                Text("\(item.usage.chapterCount) 章 · \(item.usage.text)")
                                    .font(Typo.micro)
                                    .foregroundStyle(Palette.ink3)
                            }
                            Spacer(minLength: 0)
                            Button("清理") {
                                env.chapterProvider.clearCache(for: item.book)
                                reload()
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Palette.danger)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionsCard: some View {
        VStack(spacing: 10) {
            Button {
                confirmClearCache = true
            } label: {
                Text("清空章节缓存")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)

            Button {
                confirmClearBackups = true
            } label: {
                Text("清空备份文件")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
    }

    private func reload() {
        breakdown = service.breakdown()
        cacheList = service.cacheByBook((try? env.books.all()) ?? [])
    }
}
