import UIKit

/// 触觉反馈。
/// 只在"确实发生了一件事"的时候用：长按弹面板、加书签、导入完成。
/// 翻页不给震动——高频动作一震就烦。
enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
