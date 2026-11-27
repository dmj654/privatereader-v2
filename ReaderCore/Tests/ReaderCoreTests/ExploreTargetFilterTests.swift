import XCTest
@testable import ReaderCore

final class ExploreTargetFilterTests: XCTestCase {

    private func novelSource(id: String, explore: Bool) -> LegadoSource {
        LegadoSource(
            id: id,
            name: id,
            url: "https://example.com",
            type: 0,
            exploreUrl: explore ? "全部 :: https://example.com/all" : nil,
            ruleExplore: SearchRule(bookList: explore ? "class.item" : "")
        )
    }

    private func comicLegado(id: String, explore: Bool) -> LegadoSource {
        LegadoSource(
            id: id,
            name: id,
            url: "https://example.com",
            type: 2,
            exploreUrl: explore ? "全部 :: https://example.com/all" : nil,
            ruleExplore: SearchRule(bookList: explore ? "class.item" : "")
        )
    }

    private func venera(id: String) -> VeneraSource {
        VeneraSource(id: "venera:\(id)", key: id, name: id, js: "")
    }

    func testNovelTabNeverContainsComicSources() {
        let all: [SearchTarget] = [
            .legado(novelSource(id: "novel", explore: true)),
            .legado(comicLegado(id: "comic-legado", explore: true)),
            .venera(venera(id: "copy_manga"))
        ]

        let filtered = ExploreTargetFilter.filter(all, comic: false)
        XCTAssertEqual(filtered.map(\.id), ["novel"], "小说发现页只能出现小说源")
    }

    func testComicTabNeverContainsNovelSources() {
        let all: [SearchTarget] = [
            .legado(novelSource(id: "novel", explore: true)),
            .legado(comicLegado(id: "comic-legado", explore: true)),
            .venera(venera(id: "copy_manga"))
        ]

        let filtered = ExploreTargetFilter.filter(all, comic: true)
        XCTAssertEqual(Set(filtered.map(\.id)), ["comic-legado", "venera:copy_manga"])
        XCTAssertFalse(filtered.contains { $0.id == "novel" }, "漫画发现页不能出现小说源")
    }

    func testLegadoWithoutExploreRuleIsExcluded() {
        let all: [SearchTarget] = [
            .legado(novelSource(id: "only-search", explore: false)),
            .legado(novelSource(id: "has-explore", explore: true))
        ]

        let filtered = ExploreTargetFilter.filter(all, comic: false)
        XCTAssertEqual(filtered.map(\.id), ["has-explore"])
    }
}
