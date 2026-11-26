import SwiftUI
import UIKit

/// 只读正文渲染。用 UITextView 保证与 CoreText 分页的行宽一致。
struct ReaderTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let background: UIColor

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.backgroundColor = background
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.attributedText = attributedText
        view.backgroundColor = background
    }
}
