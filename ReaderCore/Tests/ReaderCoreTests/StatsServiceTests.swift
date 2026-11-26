import XCTest
import GRDB
@testable import ReaderCore

final class StatsServiceTests: XCTestCase {
    private var database: AppDatabase!
    private var sessions: SessionRepository!
    private var books: BookRepository!
    private var calendar: Calendar!
    private var now: Date!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        sessions = SessionRepository(db: database.writer)
        books = BookRepository(db: database.writer)

        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2

        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 25
        components.hour = 12
        now = calendar.date(from: components)!
    }

    override func tearDownWithError() throws {
        database = nil
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    private func ensureBook(_ id: String = "b1") throws {
        guard (try? books.fetch(id: id)) == nil else { return }
        try books.insert(Book(id: id, type: .novel, origin: .local, title: id))
    }

    private func addSession(_ date: Date, seconds: Int, bookId: String = "b1") throws {
        try ensureBook(bookId)
        try sessions.record(ReadingSession(
            bookId: bookId,
            startedAt: Int(date.timeIntervalSince1970),
            durationSec: seconds
        ))
    }

    private func addBook(id: String, status: BookStatus) throws {
        try books.insert(Book(id: id, type: .novel, origin: .local,
                              title: id, status: status))
    }

    func testWeekMonthAndAverageUseCalendarBoundaries() throws {
        try addSession(date(2026, 11, 24), seconds: 600)   // 本周
        try addSession(date(2026, 11, 25, 9), seconds: 300) // 本周
        try addSession(date(2026, 11, 20), seconds: 900)   // 上周，但近 7 天
        try addSession(date(2026, 11, 1), seconds: 1200)   // 本月，非本周
        try addSession(date(2026, 10, 31), seconds: 1000)  // 上月

        let service = StatsService(sessions: sessions, books: books, calendar: calendar)
        let stats = try service.stats(now: now)

        XCTAssertEqual(stats.weekSeconds, 900, "本周从周一（11/23）算起")
        XCTAssertEqual(stats.monthSeconds, 3000, "本月从 11/1 算起：600+300+900+1200")
        XCTAssertEqual(stats.dailyAverageSeconds, 128, "900 / 7 向下取整")
    }

    func testLastSevenDaysFillsMissingDaysWithZero() throws {
        try addSession(date(2026, 11, 25, 9), seconds: 300)
        try addSession(date(2026, 11, 20), seconds: 900)

        let service = StatsService(sessions: sessions, books: books, calendar: calendar)
        let stats = try service.stats(now: now)

        XCTAssertEqual(stats.last7Days.count, 7)
        XCTAssertEqual(stats.last7Days.first?.day,
                       Int(calendar.startOfDay(for: date(2026, 11, 19)).timeIntervalSince1970))
        XCTAssertEqual(stats.last7Days.last?.seconds, 300)
        XCTAssertEqual(stats.last7Days[1].seconds, 900, "11/20 那一格")
        XCTAssertEqual(stats.last7Days[2].seconds, 0, "没有阅读的天要补 0")
    }

    func testFinishedBooksOnlyCountsFinishedStatus() throws {
        try addBook(id: "a", status: .finished)
        try addBook(id: "b", status: .finished)
        try addBook(id: "c", status: .reading)

        let service = StatsService(sessions: sessions, books: books, calendar: calendar)
        let stats = try service.stats(now: now)

        XCTAssertEqual(stats.finishedBooks, 2)
    }

    func testEmptyDatabaseYieldsZeros() throws {
        let service = StatsService(sessions: sessions, books: books, calendar: calendar)
        let stats = try service.stats(now: now)

        XCTAssertEqual(stats.weekSeconds, 0)
        XCTAssertEqual(stats.monthSeconds, 0)
        XCTAssertEqual(stats.finishedBooks, 0)
        XCTAssertEqual(stats.last7Days.map(\.seconds), Array(repeating: 0, count: 7))
    }

    func testDurationText() {
        XCTAssertEqual(StatsService.durationText(0), "0 分钟")
        XCTAssertEqual(StatsService.durationText(30), "1 分钟", "不足一分钟也别显示 0")
        XCTAssertEqual(StatsService.durationText(600), "10 分钟")
        XCTAssertEqual(StatsService.durationText(3600), "1 小时")
        XCTAssertEqual(StatsService.durationText(4800), "1 小时 20 分")
    }
}
