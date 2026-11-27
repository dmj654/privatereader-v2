import SwiftUI
import UIKit

/// 只读正文渲染。用 UITextView 保证与 CoreText 分页的行宽一致。
///
/// 这里同时承担三件事：
/// 1. 显示当前页；
/// 2. 长按选中文字，给出复制 / 解释 / 新建净化规则；
/// 3. 单击九宫格翻页（文字视图自己接点击，不能再盖一层 tapGrid，
///    否则长按永远到不了 UITextView）。
struct ReaderTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let background: UIColor
    let textInsets: UIEdgeInsets
    var isInteractive: Bool = false
    var onTapAt: ((CGPoint, CGSize) -> Void)?
    var onExplain: ((String) -> Void)?
    var onPurify: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
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

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.attributedText = attributedText
        view.backgroundColor = background
        view.textContainerInset = textInsets
        view.isSelectable = isInteractive
        view.isUserInteractionEnabled = isInteractive
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ReaderTextView
        private var hadSelection = false
        private var suppressNextTap = false

        init(_ parent: ReaderTextView) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? UITextView else { return }
            if suppressNextTap {
                suppressNextTap = false
                return
            }
            // 用户正在选字时，第一下点击只用来收起选择菜单，不翻页。
            guard view.selectedRange.length == 0 else { return }
            parent.onTapAt?(gesture.location(in: view), view.bounds.size)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length > 0 {
                hadSelection = true
            } else if hadSelection {
                hadSelection = false
                suppressNextTap = true
            }
        }

        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, let onExplain = parent.onExplain, let onPurify = parent.onPurify else {
                return nil
            }
            let text = (textView.text as NSString).substring(with: range)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            // 系统菜单自带“拷贝”；加一条中文“复制”会在不同系统语言下重复。
            // 只保留除系统拷贝外真正有价值的动作，再追加解释/净化。
            let filtered = suggestedActions.filter { action in
                let title = action.title
                return title != "拷贝" && title != "Copy" && title != "复制"
            }

            let copy = UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            }
            let explain = UIAction(title: "解释", image: UIImage(systemName: "text.magnifyingglass")) { _ in
                onExplain(text)
            }
            let purify = UIAction(title: "新建净化规则",
                                  image: UIImage(systemName: "eraser.line.dashed")) { _ in
                onPurify(text)
            }
            return UIMenu(children: [copy] + filtered + [explain, purify])
        }
    }
}
