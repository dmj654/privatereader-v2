import SwiftUI
import UIKit

/// 只读正文渲染。用 UITextView 保证与 CoreText 分页的行宽一致。
///
/// 这里同时承担三件事：
/// 1. 显示当前页；
/// 2. 长按选中文字，选中后动作交给 SwiftUI 自绘工具栏；
/// 3. 单击九宫格翻页（文字视图自己接点击，不能再盖一层 tapGrid，
///    否则长按永远到不了 UITextView）。
struct ReaderTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let background: UIColor
    let textInsets: UIEdgeInsets
    var isInteractive: Bool = false
    var dismissToken: Int = 0
    var onTapAt: ((CGPoint, CGSize) -> Void)?
    var onSelectionChanged: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ReaderSelectableTextView {
        let view = ReaderSelectableTextView()
        view.isEditable = false
        view.isSelectable = isInteractive
        view.isScrollEnabled = false
        view.textContainerInset = textInsets
        view.textContainer.lineFragmentPadding = 0
        view.backgroundColor = background
        view.delegate = context.coordinator
        view.isUserInteractionEnabled = isInteractive
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)

        if isInteractive {
            let tap = UITapGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleTap(_:)))
            tap.cancelsTouchesInView = false
            view.addGestureRecognizer(tap)
        }
        return view
    }

    func updateUIView(_ view: ReaderSelectableTextView, context: Context) {
        context.coordinator.parent = self
        view.attributedText = attributedText
        view.backgroundColor = background
        view.textContainerInset = textInsets
        view.isSelectable = isInteractive
        view.isUserInteractionEnabled = isInteractive
        if dismissToken != context.coordinator.lastDismissToken {
            context.coordinator.lastDismissToken = dismissToken
            view.selectedRange = NSRange(location: 0, length: 0)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ReaderTextView
        var lastDismissToken = 0
        private var suppressNextTap = false

        init(_ parent: ReaderTextView) {
            self.parent = parent
            self.lastDismissToken = parent.dismissToken
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? UITextView else { return }
            if suppressNextTap {
                suppressNextTap = false
                return
            }
            // 正在选字时，点一下正文只收起选择，不翻页。
            guard view.selectedRange.length == 0 else {
                view.selectedRange = NSRange(location: 0, length: 0)
                parent.onSelectionChanged?("")
                suppressNextTap = true
                return
            }
            parent.onTapAt?(gesture.location(in: view), view.bounds.size)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            if range.length > 0 {
                let text = (textView.text as NSString).substring(with: range)
                parent.onSelectionChanged?(text)
            } else {
                parent.onSelectionChanged?("")
            }
        }

        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            // 动作菜单由 NovelReaderView 自绘；系统菜单一个都不展示。
            guard range.length > 0 else { return nil }
            return UIMenu(children: [])
        }
    }
}

/// 系统长按菜单会带“查询 / 翻译 / 分享”等一长串动作，且样式不可控。
/// 这里关掉原生 action，只保留系统选择手柄，动作交给 SwiftUI 工具栏。
final class ReaderSelectableTextView: UITextView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        // 不注册任何原生编辑菜单。
    }
}
