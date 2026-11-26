import XCTest
import GRDB
@testable import ReaderCore

final class RepositoryTests: XCTestCase {
    private var database: AppDatabase!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
    }

    override func tearDownWithError() throws {
        database = nil
    }

    private func makeBook(id: String = "b1", title: String = "夜航船") -> Book {
        Book(id: id, type: .novel, origin: .local, title: title)
    }

    func testBookInsertAndFetchRoundTrip() throws {
        let repo = BookRepository(db: database.writer)
        var book = makeBook()
        book.author = "张岱"
        book.chapterCount = 214
        try repo.insert(book)

        let fetched = try XCTUnwrap(try repo.fetch(id: "b1"))
        XCTAssertEqual(fetched.title, "夜航船")
        XCTAssertEqual(fetched.author, "张岱")
        XCTAssertEqual(fetched.chapterCount, 214)
        XCTAssertEqual(fetched.groupId, BookGroup.builtinReadingID)
        XCTAssertEqual(fetched.status, .reading)
    }

    func testBooksOrderedByLastReadThenAdded() throws {
        let repo = BookRepository(db: database.writer)
        try repo.insert(Book(id: "a", type: .novel, origin: .local, title: "A", addedAt: 100))
        try repo.insert(Book(id: "b", type: .novel, origin: .local, title: "B", addedAt: 200))
        try repo.insert(Book(id: "c", type: .novel, origin: .local, title: "C", addedAt: 150, lastReadAt: 300))

        let books = try repo.all()
        XCTAssertEqual(books.map(\.id), ["c", "b", "a"])
    }

    func testDeleteBookCascadesChildren() throws {
        let books = BookRepository(db: database.writer)
        try books.insert(makeBook())

        try ProgressRepository(db: database.writer)
            .save(ReadingProgress(bookId: "b1", chapterIndex: 3, offset: 10, percent: 0.2, updatedAt: 1))
        try BookmarkRepository(db: database.writer)
            .add(Bookmark(bookId: "b1", chapterIndex: 3, offset: 10, excerpt: "摘录"))
        try SessionRepository(db: database.writer)
            .record(ReadingSession(bookId: "b1", startedAt: 1, durationSec: 60))
        try CacheRepository(db: database.writer)
            .upsert(ChapterCache(bookId: "b1", chapterIndex: 3, kind: .text, localPath: "/tmp/x", sizeBytes: 100))

        try books.delete(id: "b1")

        XCTAssertNil(try ProgressRepository(db: database.writer).fetch(bookId: "b1"))
        XCTAssertEqual(try BookmarkRepository(db: database.writer).count(bookId: "b1"), 0)
        XCTAssertEqual(try SessionRepository(db: database.writer).totalDuration(from: 0, to: 999), 0)
        XCTAssertEqual(try CacheRepository(db: database.writer).totalBytes(), 0)
    }

    func testDeleteCustomGroupMovesBooksToReading() throws {
        let groups = GroupRepository(db: database.writer)
        let books = BookRepository(db: database.writer)

        let custom = try groups.create(name: "想读")
        try books.insert(Book(id: "x", type: .novel, origin: .local, title: "X", groupId: custom.id))
        XCTAssertEqual(try books.books(inGroup: custom.id).count, 1)

        try groups.delete(id: custom.id)

        let moved = try XCTUnwrap(try books.fetch(id: "x"))
        XCTAssertEqual(moved.groupId, BookGroup.builtinReadingID)
        XCTAssertEqual(try groups.all().count, 3)
    }

    func testBuiltinGroupCannotBeDeleted() throws {
        let groups = GroupRepository(db: database.writer)
        try groups.delete(id: BookGroup.builtinReadingID)
        XCTAssertEqual(try groups.all().count, 3)
    }

    func testProgressSaveOverwrites() throws {
        let repo = ProgressRepository(db: database.writer)
        try BookRepository(db: database.writer).insert(makeBook())
        try repo.save(ReadingProgress(bookId: "b1", chapterIndex: 1, offset: 0, percent: 0.1, updatedAt: 1))
        try repo.save(ReadingProgress(bookId: "b1", chapterIndex: 5, offset: 88, percent: 0.5, updatedAt: 2))

        let progress = try XCTUnwrap(try repo.fetch(bookId: "b1"))
        XCTAssertEqual(progress.chapterIndex, 5)
        XCTAssertEqual(progress.offset, 88)
        XCTAssertEqual(progress.percent, 0.5, accuracy: 0.0001)
    }

    func testSourceUpsertReplacesById() throws {
        let repo = SourceRepository(db: database.writer)
        try repo.upsertAll([BookSource(id: "s1", name: "星空", rawJson: "{}")])
        try repo.upsertAll([BookSource(id: "s1", name: "星空二号", rawJson: "{\"a\":1}")])

        XCTAssertEqual(try repo.count(), 1)
        XCTAssertEqual(try repo.all().first?.name, "星空二号")
    }

    func testEnabledSourcesFilter() throws {
        let repo = SourceRepository(db: database.writer)
        try repo.upsertAll([
            BookSource(id: "s1", name: "A", rawJson: "{}"),
            BookSource(id: "s2", name: "B", rawJson: "{}")
        ])
        try repo.setEnabled(id: "s2", enabled: false)

        XCTAssertEqual(try repo.enabled().map(\.id), ["s1"])
        XCTAssertEqual(try repo.count(), 2)
    }

    func testSessionTotalDurationInRange() throws {
        let repo = SessionRepository(db: database.writer)
        try BookRepository(db: database.writer).insert(makeBook())
        try repo.record(ReadingSession(bookId: "b1", startedAt: 100, durationSec: 60))
        try repo.record(ReadingSession(bookId: "b1", startedAt: 200, durationSec: 90))
        try repo.record(ReadingSession(bookId: "b1", startedAt: 900, durationSec: 30))

        XCTAssertEqual(try repo.totalDuration(from: 0, to: 500), 150)
        XCTAssertEqual(try repo.totalDuration(from: 0, to: 1000), 180)
    }

    func testDailyDurationsBucketsByDay() throws {
        let repo = SessionRepository(db: database.writer)
        try BookRepository(db: database.writer).insert(makeBook())

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day1 = 1_700_000_000
        let day1Later = day1 + 3600
        let day2 = day1 + 86_400

        try repo.record(ReadingSession(bookId: "b1", startedAt: day1, durationSec: 60))
        try repo.record(ReadingSession(bookId: "b1", startedAt: day1Later, durationSec: 40))
        try repo.record(ReadingSession(bookId: "b1", startedAt: day2, durationSec: 20))

        let buckets = try repo.dailyDurations(from: 0, to: day2 + 100, calendar: calendar)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets.first?.seconds, 100)
        XCTAssertEqual(buckets.last?.seconds, 20)
    }

    func testCacheTotalBytesAndDelete() throws {
        let repo = CacheRepository(db: database.writer)
        try BookRepository(db: database.writer).insert(makeBook())
        try repo.upsert(ChapterCache(bookId: "b1", chapterIndex: 0, kind: .text, localPath: "/a", sizeBytes: 1000))
        try repo.upsert(ChapterCache(bookId: "b1", chapterIndex: 1, kind: .images, localPath: "/b", sizeBytes: 2500))

        XCTAssertEqual(try repo.totalBytes(), 3500)
        XCTAssertEqual(try repo.list(bookId: "b1").count, 2)

        try repo.delete(bookId: "b1")
        XCTAssertEqual(try repo.totalBytes(), 0)
    }

    func testCacheUpsertReplacesSameChapter() throws {
        let repo = CacheRepository(db: database.writer)
        try BookRepository(db: database.writer).insert(makeBook())
        try repo.upsert(ChapterCache(bookId: "b1", chapterIndex: 0, kind: .text, localPath: "/old", sizeBytes: 10))
        try repo.upsert(ChapterCache(bookId: "b1", chapterIndex: 0, kind: .text, localPath: "/new", sizeBytes: 20))

        let list = try repo.list(bookId: "b1")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.localPath, "/new")
        XCTAssertEqual(list.first?.sizeBytes, 20)
    }

    func testSearchHistoryKeepsLatestTwenty() throws {
        let repo = SearchHistoryRepository(db: database.writer)
        for index in 0..<25 {
            try repo.record(keyword: "k\(index)")
        }
        let recent = try repo.recent()
        XCTAssertEqual(recent.count, 20)
    }

    func testSearchHistoryIgnoresBlankKeyword() throws {
        let repo = SearchHistoryRepository(db: database.writer)
        try repo.record(keyword: "   ")
        XCTAssertEqual(try repo.recent().count, 0)
    }
}
