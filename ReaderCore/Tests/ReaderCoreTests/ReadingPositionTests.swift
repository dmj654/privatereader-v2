import XCTest
import GRDB
@testable import ReaderCore

final class ReadingPositionTests: XCTestCase {
    private var database: AppDatabase!
    private var store: ReadingPositionStore!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        store = ReadingPositionStore(repo: ProgressRepository(db: database.writer))
        try BookRepository(db: database.writer)
            .insert(Book(id: "b1", type: .novel, origin: .local, title: "夜航船", chapterCount: 10))
    }

    override func tearDownWithError() throws {
        store = nil
        database = nil
    }

    func testRestoreWithoutRecordReturnsNil() {
        XCTAssertNil(store.restore(bookId: "b1", chapterCount: 10))
    }

    func testRoundTripKeepsChapterAndPage() throws {
        try store.save(bookId: "b1",
                       position: ReadingPosition(chapterIndex: 3, pageIndex: 2),
                       pageCount: 5,
                       chapterCount: 10)

        let restored = try XCTUnwrap(store.restore(bookId: "b1", chapterCount: 10))
        XCTAssertEqual(restored.chapterIndex, 3, "读到第 4 章，回来必须还在第 4 章")
        XCTAssertEqual(restored.pageIndex, 2)
    }

    func testPercentIsComputedAcrossWholeBook() throws {
        let record = try XCTUnwrap(try store.save(bookId: "b1",
                                                  position: ReadingPosition(chapterIndex: 3, pageIndex: 3),
                                                  pageCount: 5,
                                                  chapterCount: 10))
        // 第 4 章（下标 3）读到 3/4 → (3 + 0.75) / 10
        XCTAssertEqual(record.percent, 0.375, accuracy: 0.0001)
    }

    func testRestoreClampsOutOfRangeChapter() throws {
        try store.save(bookId: "b1",
                       position: ReadingPosition(chapterIndex: 99, pageIndex: 0),
                       pageCount: 3,
                       chapterCount: 10)

        let restored = try XCTUnwrap(store.restore(bookId: "b1", chapterCount: 10))
        XCTAssertEqual(restored.chapterIndex, 9)
    }

    func testRestoreReturnsNilWhenNoChapters() {
        try? store.save(bookId: "b1",
                        position: ReadingPosition(chapterIndex: 2, pageIndex: 0),
                        pageCount: 3,
                        chapterCount: 10)
        XCTAssertNil(store.restore(bookId: "b1", chapterCount: 0))
    }

    /// 这条是关键：正文还没解析出来时不能写，否则会把"读到第 4 章"覆盖成第 1 章。
    func testSaveIsNoOpWhenChapterCountIsZero() throws {
        try store.save(bookId: "b1",
                       position: ReadingPosition(chapterIndex: 3, pageIndex: 1),
                       pageCount: 4,
                       chapterCount: 10)

        let result = try store.save(bookId: "b1",
                                    position: ReadingPosition(chapterIndex: 0, pageIndex: 0),
                                    pageCount: 0,
                                    chapterCount: 0)
        XCTAssertNil(result, "章数为 0 时应当拒绝写入")

        let restored = try XCTUnwrap(store.restore(bookId: "b1", chapterCount: 10))
        XCTAssertEqual(restored.chapterIndex, 3, "好的进度不能被空状态覆盖")
    }

    func testSaveClampsNegativeValues() throws {
        let record = try XCTUnwrap(try store.save(bookId: "b1",
                                                  position: ReadingPosition(chapterIndex: -3, pageIndex: -5),
                                                  pageCount: 4,
                                                  chapterCount: 10))
        XCTAssertEqual(record.chapterIndex, 0)
        XCTAssertEqual(record.offset, 0)
    }

    func testVerifyConfirmsWrittenPosition() throws {
        let record = try XCTUnwrap(try store.save(bookId: "b1",
                                                  position: ReadingPosition(chapterIndex: 5, pageIndex: 1),
                                                  pageCount: 6,
                                                  chapterCount: 10))
        XCTAssertTrue(store.verify(bookId: "b1", expecting: record))
    }

    func testVerifyFailsForMissingRecord() {
        let ghost = ReadingProgress(bookId: "nope", chapterIndex: 1, offset: 0, percent: 0.1, updatedAt: 0)
        XCTAssertFalse(store.verify(bookId: "nope", expecting: ghost))
    }

    func testLaterSaveOverwritesEarlier() throws {
        try store.save(bookId: "b1",
                       position: ReadingPosition(chapterIndex: 1, pageIndex: 0),
                       pageCount: 3, chapterCount: 10)
        try store.save(bookId: "b1",
                       position: ReadingPosition(chapterIndex: 7, pageIndex: 2),
                       pageCount: 5, chapterCount: 10)

        let restored = try XCTUnwrap(store.restore(bookId: "b1", chapterCount: 10))
        XCTAssertEqual(restored.chapterIndex, 7)
        XCTAssertEqual(restored.pageIndex, 2)
    }
}
