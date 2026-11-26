import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ReaderCore

/// 导入书源：粘贴 / 文件 / 剪贴板 / 链接。
///
/// 网友源动辄几千条、几 MB，直接粘进 TextEditor 会卡；
/// 所以默认推荐「从文件导入」，粘贴框只作为小批量补充。
///
/// `category` 决定这个面板是小说入口还是漫画入口：标题、文案、
/// 以及落库时的类型过滤都跟着它走，避免两个入口互相串源。
struct SourceImportSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var category: SourceImportCategory = .novel
    var onImported: (SourceImportSummary) -> Void

    @State private var text = ""
    @State private var isImporting = false
    @State private var summary: SourceImportSummary?
    @State private var errorMessage: String?
    @State private var showingFilePicker = false
    @State private var forceEnable = true
    @State private var indexURL: URL?

    private var title: String { "导入\(category.title)" }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        fileCard
                        pasteCard
                        optionsCard

                        if let summary {
                            resultCard(summary)
                        }

                        if isImporting {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在解析并写入，几千条\(category.title)可能要十几秒…")
                                    .font(Typo.micro)
                                    .foregroundStyle(Palette.ink3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, 14)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        importText()
                    } label: {
                        if isImporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("导入").fontWeight(.semibold)
                        }
                    }
                    .disabled(isImporting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showingFilePicker) {
                // 用 UIKit 的 asCopy 模式：微信/网盘的文件先拷进 App 再读，
                // SwiftUI 的 fileImporter 在这些 provider 上常常点了没反应。
                LegadoDocumentPicker { url in
                    showingFilePicker = false
                    handlePickedURL(url)
                }
            }
            .overlay {
                if isImporting {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView().tint(Palette.accent)
                            Text("正在导入，请稍候…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Palette.ink)
                            Text("几千条\(category.title)需要十几秒")
                                .font(Typo.micro)
                                .foregroundStyle(Palette.ink3)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: Shadow.card, radius: 8, y: 3)
                    }
                }
            }
            .alert("导入失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: 卡片

    private var fileCard: some View {
        Button {
            showingFilePicker = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 42, height: 42)
                    .background(Palette.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("从文件导入")
                        .font(Typo.headline)
                        .foregroundStyle(Palette.ink)
                    Text("支持 legado 的 .json / .txt；漫画入口还支持 Venera 的 index.json（会自动下载并运行里面的 .js 源）")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(14)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var pasteCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("粘贴 JSON 或链接")
                    .font(Typo.headline)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Button("从剪贴板") {
                    if let pasted = UIPasteboard.general.string {
                        text = pasted
                    }
                }
                .font(Typo.micro)
                .foregroundStyle(Palette.accent)
            }

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .padding(8)
                .background(Palette.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("[{\"bookSourceName\":\"…\",\"bookSourceUrl\":\"…\"}]")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.ink3.opacity(0.7))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

            if text.lowercased().hasPrefix("http") {
                Label("将从这个链接下载\(category.title)", systemImage: "link")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.accent)
            }

            Text(category == .comic
                 ? "支持 legado 漫画源 JSON，以及 Venera 的 index.json / 单个 .js 源。Venera 源由 App 内置的 JavaScriptCore 运行。"
                 : "支持 legado 小说源 JSON。漫画源（legado bookSourceType=2 或 Venera index.json）请到「漫画源」入口导入。")
                .font(Typo.micro)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1)
        }
    }

    private var optionsCard: some View {
        Toggle(isOn: $forceEnable) {
            VStack(alignment: .leading, spacing: 2) {
                Text("导入后全部启用")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                Text("关掉则沿用\(category.title)自带的开关状态")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
            }
        }
        .tint(Palette.accent)
        .padding(14)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1)
        }
    }

    private func resultCard(_ summary: SourceImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("导入完成", systemImage: "checkmark.circle.fill")
                .font(Typo.headline)
                .foregroundStyle(Color(hex: 0x4E8A5F))
            Text("新增 \(summary.added) 条，覆盖 \(summary.updated) 条，共 \(summary.total) 条\(category.title)。")
                .font(Typo.caption)
                .foregroundStyle(Palette.ink2)
            if let note = summary.note {
                Text(note)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if summary.total > 0 {
                Text("回到列表可以「测一下全部」；明确失败的源可以关掉，超时的源会保留。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: 动作

    private func handlePickedURL(_ url: URL) {
        do {
            // asCopy 模式下 URL 已在 App 沙盒内，直接读即可
            var data = try Data(contentsOf: url)
            if SourceArchive.looksLikeZip(data) {
                guard let json = SourceArchive.jsonData(from: data) else {
                    errorMessage = "这个压缩包里没有 .json \(category.title)文件。"
                    return
                }
                data = json
            }
            env.importLog.append("已选择文件：\(url.lastPathComponent)，\(data.count) 字节")
            indexURL = nil
            importData(data)
        } catch {
            errorMessage = "读取文件失败：\(error.localizedDescription)"
        }
    }

    private func importText() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.lowercased().hasPrefix("http"),
           let url = URL(string: trimmed) {
            download(url)
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            errorMessage = "文本编码不是 UTF-8"
            return
        }
        importData(data)
    }

    private func download(_ url: URL) {
        isImporting = true
        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                // 不少源站会拒绝没有 UA 的请求
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
                                 + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
                                 forHTTPHeaderField: "User-Agent")
                var (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                if SourceArchive.looksLikeZip(data) {
                    guard let json = SourceArchive.jsonData(from: data) else {
                        throw LegadoParserError.invalidJSON
                    }
                    data = json
                }
                await MainActor.run {
                    isImporting = false
                    indexURL = url
                    importData(data)
                }
            } catch {
                await MainActor.run {
                    errorMessage = "下载失败：\(error.localizedDescription)"
                    isImporting = false
                }
            }
        }
    }

    /// 2500 条源、13MB JSON：解析和写库都放到后台，主线程只负责显示进度。
    private func importData(_ data: Data) {
        // Venera 索引不是 legado JSON：每一项指向一份 JS 脚本，要逐个下载。
        // 放在这里先分流，避免用户看到「格式不对」。
        if VeneraIndexParser.isIndex(data) {
            importVenera(data)
            return
        }

        isImporting = true
        summary = nil
        errorMessage = nil

        let repo = env.sources
        let force = forceEnable
        env.importLog.append("\(category.title)导入开始：\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try SourceImportService(repo: repo).importJSON(
                        data,
                        forceEnabled: force,
                        category: category
                    )
                }.value
                await MainActor.run {
                    isImporting = false
                    summary = result
                    text = ""
                    env.importLog.append("\(category.title)导入完成：新增 \(result.added)，覆盖 \(result.updated)")
                    onImported(result)
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    let message = readable(error)
                    env.importLog.append("\(category.title)导入失败：\(message)")
                    errorMessage = message
                }
            }
        }
    }

    private func importVenera(_ data: Data) {
        isImporting = true
        summary = nil
        errorMessage = nil
        let repo = env.sources
        let force = forceEnable
        let category = self.category
        let base = indexURL
        env.importLog.append("Venera 索引导入开始：\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")

        Task {
            do {
                let service = VeneraImportService(repo: repo)
                let result = try await service.importIndex(
                    data,
                    indexURL: base,
                    forceEnabled: force,
                    category: category
                )
                await MainActor.run {
                    isImporting = false
                    summary = result
                    text = ""
                    env.importLog.append("Venera 导入完成：新增 \(result.added)，覆盖 \(result.updated)，失败 \(result.failed)")
                    onImported(result)
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    let message = readable(error)
                    env.importLog.append("Venera 导入失败：\(message)")
                    errorMessage = message
                }
            }
        }
    }

    private func readable(_ error: Error) -> String {
        if let error = error as? LegadoParserError {
            return error.errorDescription ?? "书源格式不正确"
        }
        return error.localizedDescription
    }
}
