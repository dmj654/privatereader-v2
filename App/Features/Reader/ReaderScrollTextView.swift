import SwiftUI
import UIKit

/// 小说滚动模式：整章放在一个可滚动、可长按选字的 UITextView 里。
///
/// 自动阅读用 CADisplayLink 连续推进 contentOffset；不是按页跳。
/// 同时复用 ReaderTextView 的“复制 / 解释 / 新建净化规则”菜单。
struct ReaderScrollTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let background: UIColor
    let textInsets: UIEdgeInsets
    var autoRunning: Bool
    var pointsPerSecond: CGFloat
    var resetToken: Int
    var onTap: (() -> Void)?
    var onExplain: ((String) -> Void)?
    var onPurify: ((String) -> Void)?
    var onReachBottom: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.textContainerInset = textInsets
        view.textContainer.lineFragmentPadding = 0
        view.backgroundColor = background
        view.delegate = context.coordinator
        view.showsVerticalScrollIndicator = false
        context.coordinator.attach(view)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(view)
        view.backgroundColor = background
        view.textContainerInset = textInsets

        if view.attributedText != attributedText {
            let offset = view.contentOffset
            view.attributedText = attributedText
            if resetToken != context.coordinator.lastResetToken {
                view.setContentOffset(.zero, animated: false)
            } else {
                view.contentOffset = offset
            }
        } else if resetToken != context.coordinator.lastResetToken {
            view.setContentOffset(.zero, animated: false)
        }
        context.coordinator.apply(resetToken: resetToken,
                                  autoRunning: autoRunning,
                                  pointsPerSecond: pointsPerSecond,
                                  onReachBottom: onReachBottom)
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ReaderScrollTextView
        fileprivate var lastResetToken: Int
        private var link: CADisplayLink?
        private var autoRunning = false
        private var pointsPerSecond: CGFloat = 0
        private var didReportBottom = false
        private var hadSelection = false
        private var suppressNextTap = false
        private var onReachBottom: (() -> Void)?

        init(_ parent: ReaderScrollTextView) {
            self.parent = parent
            self.lastResetToken = parent.resetToken
        }

        func apply(resetToken: Int,
                   autoRunning: Bool,
                   pointsPerSecond: CGFloat,
                   onReachBottom: (() -> Void)?) {
            self.autoRunning = autoRunning
            self.pointsPerSecond = max(pointsPerSecond, 0)
            self.onReachBottom = onReachBottom
            if resetToken != lastResetToken {
                lastResetToken = resetToken
                didReportBottom = false
            }
            if autoRunning, pointsPerSecond > 0 {
                start()
            } else {
                stop()
            }
        }

        func attach(_ view: UITextView) {
            linkOwner = view
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        private func start() {
            guard link == nil else { return }
            let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        }

        @objc private func tick(_ displayLink: CADisplayLink) {
            guard autoRunning, let view = linkOwner else { return }
            guard !view.isDragging, !view.isDecelerating else { return }
            // 用户正在长按选字时先别滚，否则选区和菜单会跟着跑。
            guard view.selectedRange.length == 0 else { return }

            let maxOffset = max(view.contentSize.height - view.bounds.height + view.textContainerInset.bottom, 0)
            guard maxOffset > 0 else { return }

            let delta = CGFloat(max(displayLink.targetTimestamp - displayLink.timestamp, 0))
            let next = min(view.contentOffset.y + pointsPerSecond * delta, maxOffset)
            if next >= maxOffset - 0.5 {
                if !didReportBottom {
                    didReportBottom = true
                    onReachBottom?()
                }
            } else {
                didReportBottom = false
                view.contentOffset.y = next
            }
        }

        /// CADisplayLink 的 target 是 self，但滚动视图要由 delegate 回调拿。
        private weak var linkOwner: UITextView?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? UITextView else { return }
            linkOwner = view
            if suppressNextTap {
                suppressNextTap = false
                return
            }
            guard view.selectedRange.length == 0 else { return }
            parent.onTap?()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length > 0 {
                hadSelection = true
            } else if hadSelection {
                hadSelection = false
                suppressNextTap = true
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if let view = scrollView as? UITextView { linkOwner = view }
        }

        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, let onExplain = parent.onExplain, let onPurify = parent.onPurify else {
                return nil
            }
            let text = (textView.text as NSString).substring(with: range)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

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
