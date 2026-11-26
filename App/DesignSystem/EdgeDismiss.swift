import SwiftUI

/// 从左边缘右滑关闭当前全屏页。
///
/// 只靠 `simultaneousGesture` 挂在整页上会被 UIScrollView、图片缩放视图吃掉，
/// 漫画里就表现为「边缘右滑没反应」。这里在左边缘单独铺一条 18pt 的透明感应区，
/// 用 `highPriorityGesture` 抢在滚动视图之前接管；阅读器与漫画共用同一套。
struct EdgeDismissModifier: ViewModifier {
    var enabled: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var active = false

    private let edgeWidth: CGFloat = 18

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .offset(x: offset)
                .overlay(alignment: .leading) {
                    edgeStrip(width: proxy.size.width)
                }
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size) { width = $0.width }
        }
    }

    private func edgeStrip(width: CGFloat) -> some View {
        Color.clear
            .frame(width: edgeWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { value in
                        guard enabled else { return }
                        let dx = value.translation.width
                        let horizontal = abs(dx) > abs(value.translation.height)
                        guard active || (dx > 4 && horizontal) else { return }
                        active = true
                        offset = max(0, min(dx, max(width, 1)))
                    }
                    .onEnded { value in
                        guard active else { return }
                        active = false
                        let projected = value.predictedEndTranslation.width
                        if value.translation.width > 80
                            || (value.translation.width > 36 && projected > 180) {
                            withAnimation(.easeOut(duration: 0.18)) { offset = max(width, 1) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { dismiss() }
                        } else {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                offset = 0
                            }
                        }
                    }
            )
    }
}

extension View {
    func edgeDismiss(enabled: Bool = true) -> some View {
        modifier(EdgeDismissModifier(enabled: enabled))
    }
}
