import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

/// 一次导入的结果，用来在完成后给一张清单。
struct ImportReport: Identifiable {
    let id = UUID()
    let outcomes: [ImportOutcome]
    let logTail: String

    var successCount: Int { outcomes.filter { $0.isSuccess }.count }
    var failureCount: Int { outcomes.count - successCount }
}

/// 支持导入的扩展名 → UTType。
/// 故意把 `.data` 也放进来：epub / cbz 在系统里没有稳定的内置类型，
/// 只按动态类型过滤会让文件在选择器里变灰、点不动。宁可放宽，交给解析器按后缀判断。
enum ImportTypes {
    static var all: [UTType] {
        var types: [UTType] = [.plainText, .pdf, .data]
        for ext in ["epub", "cbz", "zip"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }
}

/// 导入执行器：把「一堆 URL」变成「书架里的书」。
/// 串行执行，任何一个失败都不影响其余；每一步都写日志，失败也能事后查。
enum ImportRunner {
    static func run(urls: [URL],
                    library: LibraryService,
                    log: ImportLog,
                    paths: SandboxPaths,
                    archiveOriginals: Bool,
                    completion: @escaping (ImportReport) -> Void) {
        let service = ImportService()

        DispatchQueue.global(qos: .userInitiated).async {
            log.append("=== 开始导入 \(urls.count) 个文件 ===")
            var outcomes: [ImportOutcome] = []

            for (index, url) in urls.enumerated() {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let name = url.lastPathComponent
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                log.append("[\(index + 1)/\(urls.count)] \(name)  \(size) 字节  \(url.path)")

                guard FileManager.default.fileExists(atPath: url.path) else {
                    log.append("    失败：文件不存在")
                    outcomes.append(ImportOutcome(fileName: name, content: nil, errorMessage: "文件不存在或已被移动"))
                    continue
                }

                do {
                    let content = try service.parse(url: url)
                    switch content {
                    case .novel(let novel):
                        log.append("    解析成功：小说《\(novel.title)》\(novel.chapters.count) 章")
                    case .comic(let comic):
                        log.append("    解析成功：漫画《\(comic.title)》\(comic.pages.count) 页")
                    }

                    let book = try library.save(content: content, originalURL: url)
                    log.append("    入库成功：\(book.id)")

                    outcomes.append(ImportOutcome(fileName: name, content: content, errorMessage: nil))

                    if archiveOriginals {
                        archive(url: url, paths: paths, log: log)
                    }
                } catch {
                    let message = describe(error)
                    log.append("    失败：\(message)")
                    outcomes.append(ImportOutcome(fileName: name, content: nil, errorMessage: message))
                }
            }

            let success = outcomes.filter { $0.isSuccess }.count
            log.append("=== 结束：成功 \(success) / 失败 \(outcomes.count - success) ===")

            let report = ImportReport(outcomes: outcomes, logTail: tail(of: log))
            DispatchQueue.main.async { completion(report) }
        }
    }

    /// 把错误说成人话。系统错误带上 domain + code，方便我事后定位。
    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        let ns = error as NSError
        return "\(ns.localizedDescription)（\(ns.domain) \(ns.code)）"
    }

    /// 导入成功后把原文件挪进 Import/Done，下次扫描就不会重复导入。
    private static func archive(url: URL, paths: SandboxPaths, log: ImportLog) {
        let fileManager = FileManager.default
        let standardized = url.standardizedFileURL.path
        let rootPath = paths.root.standardizedFileURL.path
        guard standardized.hasPrefix(rootPath) else { return }

        let doneDirectory = paths.root
            .appendingPathComponent("Import", isDirectory: true)
            .appendingPathComponent("Done", isDirectory: true)
        guard !standardized.hasPrefix(doneDirectory.standardizedFileURL.path) else { return }

        try? fileManager.createDirectory(at: doneDirectory, withIntermediateDirectories: true)
        var destination = doneDirectory.appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            destination = doneDirectory.appendingPathComponent("\(base)-\(stamp).\(ext)")
        }
        do {
            try fileManager.moveItem(at: url, to: destination)
            log.append("    原文件已归档：Import/Done/\(destination.lastPathComponent)")
        } catch {
            log.append("    归档失败（不影响已导入的书）：\(error.localizedDescription)")
        }
    }

    private static func tail(of log: ImportLog) -> String {
        let text = log.read()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(40).joined(separator: "\n")
    }
}

/// 导入结果清单。
struct ImportResultSheet: View {
    let report: ImportReport
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            summaryPill("成功 \(report.successCount)", color: Palette.accent)
                            if report.failureCount > 0 {
                                summaryPill("失败 \(report.failureCount)", color: Palette.danger)
                            }
                            Spacer()
                        }
                        .padding(.bottom, 4)

                        ForEach(Array(report.outcomes.enumerated()), id: \.offset) { _, outcome in
                            row(outcome)
                        }

                        if !report.logTail.isEmpty {
                            Button {
                                showLog.toggle()
                            } label: {
                                Text(showLog ? "收起导入日志" : "查看导入日志")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Palette.accent)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 6)

                            if showLog {
                                Text(report.logTail)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Palette.ink3)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Palette.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Palette.line, lineWidth: 1)
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.l)
                }
            }
            .navigationTitle("导入结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func row(_ outcome: ImportOutcome) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: outcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(outcome.isSuccess ? Palette.accent : Palette.danger)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.fileName)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                if let message = outcome.errorMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink3)
                } else if let content = outcome.content {
                    Text(describe(content))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1)
        }
    }

    private func summaryPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    private func describe(_ content: ImportedContent) -> String {
        switch content {
        case .novel(let novel):
            return "小说 · \(novel.chapters.count) 章"
        case .comic(let comic):
            return "漫画 · \(comic.pages.count) 页"
        }
    }
}
