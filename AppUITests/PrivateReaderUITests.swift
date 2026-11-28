import XCTest

/// 模拟器上的 UI 冒烟测试，不替代真机点按，但至少把「数字编号先弹源选择」
/// 这条链路真实点一遍，避免只靠编译和单元测试。
final class PrivateReaderUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testComicNumberShowsSourcePicker() {
        let app = launch(noIDMatch: false)
        openComicSearch(app, query: "12345")

        XCTAssertTrue(app.staticTexts["选择漫画源"].waitForExistence(timeout: 12),
                      "输入数字后应当弹出编号源选择，而不是直接搜索")
        XCTAssertTrue(app.buttons["id-source-all"].waitForExistence(timeout: 5),
                      "源选择弹窗里要有「所有漫画源都试一下」")
        XCTAssertTrue(app.buttons.matching(identifier: "id-source-option").firstMatch.exists,
                      "应当列出声明了 idMatch 且匹配编号的源")
    }

    func testComicNumberWithoutIDMatchShowsAlert() {
        let app = launch(noIDMatch: true)
        openComicSearch(app, query: "12345")

        let alert = app.alerts["没有匹配的编号源"]
        XCTAssertTrue(alert.waitForExistence(timeout: 12),
                      "没有可匹配的编号源时不能静默回退全源搜索")
        XCTAssertTrue(alert.buttons["搜索全部源"].exists)
        XCTAssertTrue(alert.buttons["取消"].exists)
    }

    private func launch(noIDMatch: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedComicSource"]
        if noIDMatch { app.launchArguments.append("-UITestNoIDMatch") }
        app.launch()
        return app
    }

    private func openComicSearch(_ app: XCUIApplication, query: String) {
        let searchTab = app.buttons["tab.search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 5), "找不到搜索 Tab")
        searchTab.tap()

        let comicKind = app.buttons["search.kind.comic"]
        XCTAssertTrue(comicKind.waitForExistence(timeout: 5), "找不到漫画分类")
        comicKind.tap()

        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "找不到搜索框")
        field.tap()
        field.typeText(query)

        let submit = app.buttons["search.submit"]
        XCTAssertTrue(submit.isEnabled, "输入编号后搜索按钮应当可用")
        submit.tap()
    }
}
