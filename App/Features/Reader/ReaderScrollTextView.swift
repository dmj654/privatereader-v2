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
    var startToken: Int = 0
    var initialProgress: Double = 0
    var onTap: (() -> Void)?
    var onExplain: ((String) -> Void)?
    var onPurify: ((String) -> Void)?
    var onProgress: ((Double) -> Void)?
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
                                  startToken: startToken,
                                  initialProgress: initialProgress,
                                  onReachBottom: onReachBottom)
        if context.coordinator.needsInitialOffset {
            DispatchQueue.main.async {
                context.coordinator.applyInitialOffset()
            }
        }
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
        private var wasRunning = false
        private var lastReportedProgress: Double = -1
        private var lastStartToken = -1
        private var startProgress: Double = 0
        fileprivate var needsInitialOffset = false

        init(_ parent: ReaderScrollTextView) {
            self.parent = parent
            self.lastResetToken = parent.resetToken
        }

        func apply(resetToken: Int,
                   autoRunning: Bool,
                   pointsPerSecond: CGFloat,
                   startToken: Int,
                   initialProgress: Double,
                   onReachBottom: (() -> Void)?) {
            if autoRunning, !wasRunning {
                // 用户在章末停止过自动阅读，重新开启时应先允许触底回调，
                // 否则会停在 maxOffset 无法继续下一章。
                didReportBottom = false
            }
            wasRunning = autoRunning
            if startToken != lastStartToken {
                lastStartToken = startToken
                startProgress = min(max(initialProgress, 0), 1)
                needsInitialOffset = true
            }
            self.autoRunning = autoRunning
            self.pointsPerSecond = max(pointsPerSecond, 0)
            self.onReachBottom = onReachBottom
            if resetToken != lastResetToken {
                lastResetToken = resetToken
                didReportBottom = false
                lastReportedProgress = -1
            }
            if autoRunning, pointsPerSecond > 0 {
                start()
            } else {
                stop()
            }
        }

        func applyInitialOffset() {
            guard needsInitialOffset, let view = linkOwner else { return }
            guard view.text.isEmpty == false, view.contentSize.height > 0 else { return }
            let maxOffset = max(view.contentSize.height - view.bounds.height
                                + view.textContainerInset.bottom, 0)
            guard maxOffset > 0 else {
                needsInitialOffset = false
                return
            }
            view.setContentOffset(CGPoint(x: 0, y: maxOffset * startProgress), animated: false)
            needsInitialOffset = false
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
            if maxOffset <= 0 {
                // 很短的一章一屏就放得下，也要让自动阅读进入下一章；
                // contentSize 为 0 时通常还没布局完成，不要误判。
                guard view.contentSize.height > 0 else { return }
                if !didReportBottom {
                    didReportBottom = true
                    parent.onProgress?(1)
                    onReachBottom?()
                }
                return
            }

            let delta = CGFloat(max(displayLink.targetTimestamp - displayLink.timestamp, 0))
            let next = min(view.contentOffset.y + pointsPerSecond * delta, maxOffset)
            if next >= maxOffset - 0.5 {
                if !didReportBottom {
                    didReportBottom = true
                    parent.onProgress?(1)
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
            let maxOffset = max(scrollView.contentSize.height - scrollView.bounds.height
                                + scrollView.contentInset.bottom, 0)
            let fraction: Double
            if maxOffset > 0 {
                fraction = min(max(Double(scrollView.contentOffset.y / maxOffset), 0), 1)
            } else {
                fraction = 0
            }
            if abs(fraction - lastReportedProgress) > 0.01 || (fraction == 1 && lastReportedProgress != 1) {
                lastReportedProgress = fraction
                parent.onProgress?(fraction)
            }
        }

        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return nil }
            let text = (textView.text as NSString).substring(with: range)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            let filtered = suggestedActions.filter { action in
                let title = action.title
                return title != "拷贝" && title != "Copy" && title != "复制"
            }
            let copy = UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            }
            var extras: [UIMenuElement] = []
            if let onExplain = parent.onExplain {
                extras.append(UIAction(title: "解释", image: UIImage(systemName: "text.magnifyingglass")) { _ in
                    onExplain(text)
                })
            }
            if let onPurify = parent.onPurify {
                extras.append(UIAction(title: "新建净化规则",
                                       image: UIImage(systemName: "eraser.line.dashed")) { _ in
                    onPurify(text)
                })
            }
            return UIMenu(children: [copy] + filtered + extras)
        }
    }
}
