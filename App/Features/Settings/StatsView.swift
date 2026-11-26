import SwiftUI
import ReaderCore

struct StatsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var stats: ReadingStats = .empty

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    summaryGrid
                    chartCard
                    Text("统计口径：本周从周一起算；日均 = 本周总时长 / 7。")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("阅读统计")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            statTile("本周", StatsService.durationText(stats.weekSeconds), "本周累计阅读")
            statTile("本月", StatsService.durationText(stats.monthSeconds), "本月累计阅读")
            statTile("日均", StatsService.durationText(stats.dailyAverageSeconds), "按本周折算")
            statTile("读完", "\(stats.finishedBooks) 本", "书架里标记为读完")
        }
    }

    private func statTile(_ title: String, _ value: String, _ detail: String) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink3)
                Text(value)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.ink3.opacity(0.8))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chartCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("最近 7 天")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Text("合计 \(StatsService.durationText(stats.last7Days.reduce(0) { $0 + $1.seconds }))")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                }

                let maxSeconds = max(stats.last7Days.map(\.seconds).max() ?? 0, 1)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(stats.last7Days.enumerated()), id: \.offset) { _, slice in
                        VStack(spacing: 6) {
                            Text(slice.seconds > 0 ? shortDuration(slice.seconds) : "")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.ink3)
                                .frame(height: 12)

                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(slice.seconds > 0 ? Palette.accent : Palette.line)
                                .frame(height: max(6, 110 * CGFloat(slice.seconds) / CGFloat(maxSeconds)))

                            Text(weekday(slice.day))
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.ink3)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 150, alignment: .bottom)
            }
        }
    }

    private func shortDuration(_ seconds: Int) -> String {
        if seconds >= 3600 { return String(format: "%.1fh", Double(seconds) / 3600) }
        return "\(max(seconds / 60, 1))m"
    }

    private func weekday(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EE"
        return formatter.string(from: date).replacingOccurrences(of: "周", with: "")
    }

    private func reload() {
        let service = StatsService(sessions: env.sessions, books: env.books)
        stats = (try? service.stats()) ?? .empty
    }
}
