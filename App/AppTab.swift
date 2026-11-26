import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home, shelf, discover, search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "主页"
        case .shelf: return "书架"
        case .discover: return "发现"
        case .search: return "搜索"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .shelf: return "books.vertical"
        case .discover: return "safari"
        case .search: return "magnifyingglass"
        }
    }
}


/// 让任意页面都能切 Tab（首页空状态的两个引导按钮、发现页的「去搜索」）。
/// 单独抽一个对象，避免把 Binding 一层层往下传。
@MainActor
final class TabRouter: ObservableObject {
    @Published var selection: AppTab = .home
    /// 下钻到内容详情页时隐藏底部 Tab，退出时恢复。
    @Published var hidesTabBar = false
    /// 是否停在内容详情页。搜索页用它避免"收起键盘"把底栏又放出来。
    @Published var detailActive = false
}
