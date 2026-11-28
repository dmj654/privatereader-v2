import XCTest
@testable import ReaderCore

final class SourceHealthSnapshotTests: XCTestCase {

    func testParsesNewOKRecord() throws {
        let snapshot = try XCTUnwrap(SourceHealthSnapshot(lastCheckResult: "ok 128 5"))
        XCTAssertEqual(snapshot.status, .ok(milliseconds: 128, sampleCount: 5))
    }

    func testParsesNewDeepRecord() throws {
        let snapshot = try XCTUnwrap(SourceHealthSnapshot(lastCheckResult: "okDeep 256 8 3 120"))
        XCTAssertEqual(snapshot.status,
                       .okDeep(milliseconds: 256,
                               sampleCount: 8,
                               checkedSamples: 3,
                               chapterCount: 120))
    }

    func testParsesLegacyDeepRecordAsOneSample() throws {
        let snapshot = try XCTUnwrap(SourceHealthSnapshot(lastCheckResult: "ok deep 256ms 8 120"))
        XCTAssertEqual(snapshot.status,
                       .okDeep(milliseconds: 256,
                               sampleCount: 8,
                               checkedSamples: 1,
                               chapterCount: 120))
    }

    func testParsesPartial() throws {
        let snapshot = try XCTUnwrap(SourceHealthSnapshot(lastCheckResult: "partial: 详情打不开：404"))
        XCTAssertEqual(snapshot.status, .partial("详情打不开：404"))
        XCTAssertTrue(snapshot.status.isPartial)
        XCTAssertFalse(snapshot.status.isDefiniteFailure)
    }

    func testParsesFailed() throws {
        let snapshot = try XCTUnwrap(SourceHealthSnapshot(lastCheckResult: "failed: HTTP 404"))
        XCTAssertEqual(snapshot.status, .failed("HTTP 404"))
        XCTAssertTrue(snapshot.status.isDefiniteFailure)
    }

    func testParsesTimeoutAndSkipped() throws {
        XCTAssertEqual(try XCTUnwrap(SourceHealthSnapshot(lastCheckResult: "timeout")).status, .timeout)
        XCTAssertEqual(try XCTUnwrap(SourceHealthSnapshot(lastCheckResult: "skipped: 已关闭")).status,
                       .skipped("已关闭"))
    }

    func testParsesOldChineseOKRecord() throws {
        let snapshot = try XCTUnwrap(SourceHealthSnapshot(lastCheckResult: "正常 · 0.8s"))
        XCTAssertEqual(snapshot.status, .ok(milliseconds: 800, sampleCount: 0))
    }

    func testUnknownOrEmptyRecordIsIgnored() {
        XCTAssertNil(SourceHealthSnapshot(lastCheckResult: nil))
        XCTAssertNil(SourceHealthSnapshot(lastCheckResult: "  "))
        XCTAssertNil(SourceHealthSnapshot(lastCheckResult: "something else"))
        XCTAssertNil(SourceHealthSnapshot(lastCheckResult: "okDeep 1 2 3"))
    }
}
