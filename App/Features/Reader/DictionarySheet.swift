import SwiftUI
import UIKit

/// 长按“解释”打开的词典页。用系统词典，不伪造解释内容。
struct DictionarySheet: View {
    let term: String
    @Environment(\.dismiss) private var dismiss

    private var hasDefinition: Bool {
        UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: term)
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasDefinition {
                    DictionaryController(term: term)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Palette.ink3)
                        Text("系统词典没有收录这个词")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text("「\(term)」\n可以复制后在系统词典或其他词典里查询。")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink3)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                }
            }
            .navigationTitle("解释")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct DictionaryController: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}
