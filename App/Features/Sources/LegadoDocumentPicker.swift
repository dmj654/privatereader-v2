import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 系统文件选择器，asCopy = true。
///
/// SwiftUI 的 `.fileImporter` 在微信 / 网盘这类 File Provider 上会出现
/// 「点文件没反应」：回调根本不触发。用 UIKit 的选择器并要求系统先拷贝一份，
/// 拿到的就是 App 沙盒里的普通文件，读取不再受 provider 权限影响。
struct LegadoDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.json, .plainText, .text, .data, .item],
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
