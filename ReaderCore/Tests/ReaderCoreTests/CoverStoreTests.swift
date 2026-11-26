import XCTest
@testable import ReaderCore

final class CoverStoreTests: XCTestCase {
    func testNormalizesToTargetSize() throws {
        let source = ImportFixtures.makeImageData(width: 800, height: 600)
        let jpeg = try XCTUnwrap(CoverStore.normalizedJPEG(from: source))
        XCTAssertEqual(ImportFixtures.imageSize(of: jpeg), CGSize(width: 400, height: 560))
    }

    func testKeepsSmallImageAtTargetSize() throws {
        let source = ImportFixtures.makeImageData(width: 60, height: 90)
        let jpeg = try XCTUnwrap(CoverStore.normalizedJPEG(from: source))
        XCTAssertEqual(ImportFixtures.imageSize(of: jpeg), CGSize(width: 400, height: 560))
    }

    func testInvalidDataReturnsNil() {
        XCTAssertNil(CoverStore.normalizedJPEG(from: Data("not an image".utf8)))
    }

    func testWritesFileAndCreatesDirectory() throws {
        let source = ImportFixtures.makeImageData()
        let dir = try ImportFixtures.makeDirectory()
        let target = dir.appendingPathComponent("Covers/b1.jpg")

        XCTAssertTrue(CoverStore.write(from: source, to: target))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        let written = try Data(contentsOf: target)
        XCTAssertEqual(ImportFixtures.imageSize(of: written), CGSize(width: 400, height: 560))
    }
}
