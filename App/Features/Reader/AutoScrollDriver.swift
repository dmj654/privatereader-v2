import SwiftUI
import UIKit

/// 让 SwiftUI 的 `ScrollView` 真正“自动往下滑”。
///
/// SwiftUI 在 iOS 16 没有拿 scroll offset 的公开接口，`ScrollViewReader`
/// 只能按 id 跳，不能连续滚动。这里放一个 1×1 的桥接视图，沿 superview
/// 找到 SwiftUI 底下的 `UIScrollView`，用 CADisplayLink 每帧推进 offset。
/// 这样条漫和小说滚动模式都是连续滑动，而不是一页一页跳。
struct AutoScrollDriver: UIViewRepresentable {
    var isRunning: Bool
    /// 每秒滚动多少点。设置里按 1...10 档换算后传进来。
    var pointsPerSecond: CGFloat
    /// 换章时递增；driver 会回到顶部。
    var resetToken: Int
    var onReachBottom: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.coordinator = context.coordinator
        context.coordinator.update(isRunning: isRunning,
                                   pointsPerSecond: pointsPerSecond,
                                   resetToken: resetToken,
                                   onReachBottom: onReachBottom)
        return view
    }

    func updateUIView(_ uiView: FinderView, context: Context) {
        uiView.coordinator = context.coordinator
        context.coordinator.update(isRunning: isRunning,
                                   pointsPerSecond: pointsPerSecond,
                                   resetToken: resetToken,
                                   onReachBottom: onReachBottom)
    }

    static func dismantleUIView(_ uiView: FinderView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class FinderView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let coordinator else { return }
            coordinator.attach(scrollView: Self.enclosingScrollView(of: self))
        }

        private static func enclosingScrollView(of view: UIView) -> UIScrollView? {
            var current: UIView? = view
            while let candidate = current {
                if let scroll = candidate as? UIScrollView { return scroll }
                current = candidate.superview
            }
            return nil
        }
    }

    final class Coordinator {
        private weak var scrollView: UIScrollView?
        private var link: CADisplayLink?
        private var isRunning = false
        private var pointsPerSecond: CGFloat = 0
        private var lastResetToken = 0
        private var didReportBottom = false
        private var onReachBottom: (() -> Void)?

        func attach(scrollView: UIScrollView?) {
            guard self.scrollView !== scrollView else { return }
            self.scrollView = scrollView
            guard scrollView != nil else {
                stop()
                return
            }
            startIfNeeded()
        }

        func update(isRunning: Bool,
                    pointsPerSecond: CGFloat,
                    resetToken: Int,
                    onReachBottom: (() -> Void)?) {
            self.isRunning = isRunning
            self.pointsPerSecond = max(pointsPerSecond, 0)
            self.onReachBottom = onReachBottom

            if resetToken != lastResetToken {
                lastResetToken = resetToken
                didReportBottom = false
                scrollView?.setContentOffset(.zero, animated: false)
            }
            startIfNeeded()
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        private func startIfNeeded() {
            guard isRunning, pointsPerSecond > 0, scrollView != nil else {
                stop()
                return
            }
            guard link == nil else { return }
            let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        }

        @objc private func tick(_ displayLink: CADisplayLink) {
            guard isRunning, let scrollView else { return }
            guard !scrollView.isDragging, !scrollView.isDecelerating else { return }

            let maxOffset = max(
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom,
                0
            )
            guard maxOffset > 0 else { return }

            let delta = CGFloat(max(displayLink.targetTimestamp - displayLink.timestamp, 0))
            let next = min(scrollView.contentOffset.y + pointsPerSecond * delta, maxOffset)

            if next >= maxOffset - 0.5 {
                if !didReportBottom {
                    didReportBottom = true
                    onReachBottom?()
                }
            } else {
                didReportBottom = false
                scrollView.contentOffset.y = next
            }
        }
    }
}
