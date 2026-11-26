import Foundation

public struct DaySlice: Equatable, Sendable {
    public let day: Int
    public let seconds: Int

    public init(day: Int, seconds: Int) {
        self.day = day
        self.seconds = seconds
    }
}

public struct ReadingStats: Equatable, Sendable {
    public let weekSeconds: Int
    public let monthSeconds: Int
    public let finishedBooks: Int
    public let dailyAverageSeconds: Int
    public let last7Days: [DaySlice]

    public static let empty = ReadingStats(
        weekSeconds: 0, monthSeconds: 0, finishedBooks: 0,
        dailyAverageSeconds: 0, last7Days: []
    )

    public init(weekSeconds: Int,
                monthSeconds: Int,
                finishedBooks: Int,
                dailyAverageSeconds: Int,
                last7Days: [DaySlice]) {
        self.weekSeconds = weekSeconds
        self.monthSeconds = monthSeconds
        self.finishedBooks = finishedBooks
        self.dailyAverageSeconds = dailyAverageSeconds
        self.last7Days = last7Days
    }
}

/// 统计页与首页统计卡的唯一数据来源。
///
/// 口径写死在这里，页面只负责显示：
/// - 本周 = 日历周（周一起），本月 = 日历月；
/// - 日均 = 本周秒数 / 7，不按"有阅读的天数"平均；
/// - 7 日柱状图 = 含今天在内的最近 7 天，缺的天补 0。
public struct StatsService {
    private let sessions: SessionRepository
    private let books: BookRepository
    private var calendar: Calendar

    public init(sessions: SessionRepository,
                books: BookRepository,
                calendar: Calendar = .current) {
        self.sessions = sessions
        self.books = books
        self.calendar = calendar
    }

    public func stats(now: Date = Date()) throws -> ReadingStats {
        let weekStart = startOfWeek(for: now)
        let monthStart = startOfMonth(for: now)
        let end = Int(now.timeIntervalSince1970) + 1

        let weekSeconds = try sessions.totalDuration(
            from: Int(weekStart.timeIntervalSince1970), to: end
        )
        let monthSeconds = try sessions.totalDuration(
            from: Int(monthStart.timeIntervalSince1970), to: end
        )

        let finished = try books.all().filter { $0.status == .finished }.count

        let today = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let raw = try sessions.dailyDurations(
            from: Int(sevenDaysAgo.timeIntervalSince1970), to: end, calendar: calendar
        )
        let bucket = Dictionary(uniqueKeysWithValues: raw.map { ($0.day, $0.seconds) })

        var slices: [DaySlice] = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: sevenDaysAgo) else { continue }
            let key = Int(calendar.startOfDay(for: day).timeIntervalSince1970)
            slices.append(DaySlice(day: key, seconds: bucket[key] ?? 0))
        }

        return ReadingStats(
            weekSeconds: weekSeconds,
            monthSeconds: monthSeconds,
            finishedBooks: finished,
            dailyAverageSeconds: weekSeconds / 7,
            last7Days: slices
        )
    }

    public func startOfWeek(for date: Date) -> Date {
        var calendar = self.calendar
        calendar.firstWeekday = 2   // 周一
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    public func startOfMonth(for date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    /// 秒数转「1 小时 20 分」这种给人看的文本。
    public static func durationText(_ seconds: Int) -> String {
        guard seconds > 0 else { return "0 分钟" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0, minutes > 0 { return "\(hours) 小时 \(minutes) 分" }
        if hours > 0 { return "\(hours) 小时" }
        return "\(max(minutes, 1)) 分钟"
    }
}
