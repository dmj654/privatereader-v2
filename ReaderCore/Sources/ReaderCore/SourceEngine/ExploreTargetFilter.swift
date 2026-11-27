import Foundation

/// 发现页筛选：小说只拿小说源，漫画只拿漫画源；legado 还必须有真正的
/// `exploreUrl + ruleExplore`，否则点进去只会是一片空白。
/// 单独抽出来是为了能单测，避免「小说页混进漫画源」这种回归。
public enum ExploreTargetFilter {
    public static func filter(_ targets: [SearchTarget], comic: Bool) -> [SearchTarget] {
        targets.filter { target in
            guard target.isComic == comic else { return false }
            switch target {
            case .legado(let source):
                return !(source.exploreUrl ?? "").isEmpty
                    && !source.ruleExplore.bookList.isEmpty
            case .venera:
                return true
            }
        }
    }
}
