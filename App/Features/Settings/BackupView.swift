import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ReaderCore

struct BackupView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var includeBooks = true
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var isImporting = false
    @State private var pendingArchive: URL?
    @State private var pendingManifest: BackupManifest?
    @State private var showRestoreConfirm = false
    @State private var showFilePicker = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var lastBackup: Date?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    statusCard
                    exportCard
                    importCard
                    noteCard
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, 14)
            }
        }
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item, .data, .zip],
            allowsMultipleSelection: false
        ) { result in
            handlePicked(result)
        }
        .confirmationDialog("恢复这份备份？", isPresented: $showRestoreConfirm, titleVisibility: .visible) {
            Button("覆盖并恢复", role: .destructive) { performRestore() }
        } message: {
            if let manifest = pendingManifest {
                Text("备份时间 \(manifest.createdAtText)，\(manifest.bookCount) 本书、\(manifest.sourceCount) 个书源。恢复会覆盖当前数据，现有数据会先移到回滚目录。")
            }
        }
        .alert("备份", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("知道了", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 卡片

    private var statusCard: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 40, height: 40)
                    .background(Palette.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(lastBackupText)
                        .font(Typo.headline)
                        .foregroundStyle(isBackupStale ? Palette.danger : Palette.ink)
                    Text("建议每月备份一次。换机、重装前尤其要备份。")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var exportCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("导出备份")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)

                Text("包含书架、阅读进度、书签、分组、书源和封面。书文件比较大，可以按需勾选。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
                    .lineSpacing(2)

                Toggle(isOn: $includeBooks) {
                    Text("包含书文件（体积大）")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                }
                .tint(Palette.accent)

                Button {
                    export()
                } label: {
                    if isExporting {
                        ProgressView().tint(.white)
                    } else {
                        Text("生成备份")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(height: 44))
                .disabled(isExporting)

                if let exportedURL {
                    ShareLink(item: exportedURL) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                            Text("导出到「文件」")
                        }
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Palette.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var importCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("从备份恢复")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("选择之前导出的 .prbackup 文件。恢复后需要重启 App。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)

                Button {
                    showFilePicker = true
                } label: {
                    Text(isImporting ? "正在读取…" : "选择备份文件")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Palette.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                                .strokeBorder(Palette.lineStrong, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(isImporting)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var noteCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("恢复是怎么做的")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                Text("先解压到临时目录并校验格式版本，全部通过后才替换数据库。现有数据不会被直接删除，而是移到备份目录下的 Rollback 文件夹，确认没问题后可以手动清理。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isBackupStale: Bool {
        guard let lastBackup else { return true }
        let days = Calendar.current.dateComponents([.day], from: lastBackup, to: Date()).day ?? 0
        return days >= 30
    }

    private var lastBackupText: String {
        guard let lastBackup else { return "还没有备份过" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 HH:mm"
        let days = Calendar.current.dateComponents([.day], from: lastBackup, to: Date()).day ?? 0
        if days >= 30 {
            return "上次备份是 \(days) 天前"
        }
        return "上次备份：\(formatter.string(from: lastBackup))"
    }

    // MARK: 动作

    private func export() {
        isExporting = true
        exportedURL = nil

        Task {
            do {
                let sources = (try? env.sources.all().map(\.rawJson)) ?? []
                let count = (try? env.books.count()) ?? 0
                let input = BackupInput(
                    appVersion: version,
                    bookCount: count,
                    sources: sources,
                    includeBooks: includeBooks
                )
                let url = try BackupExporter(paths: env.paths).export(input)
                await MainActor.run {
                    exportedURL = url
                    isExporting = false
                    reload()
                    message = "备份已生成：\(url.lastPathComponent)"
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func handlePicked(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // 拷到沙盒再读：文件 App 的 URL 在回调结束后可能失效
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("restore-\(UUID().uuidString).prbackup")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: url, to: copy)

            isImporting = true
            let manifest = try BackupImporter(paths: env.paths).inspect(archiveURL: copy)
            pendingArchive = copy
            pendingManifest = manifest
            isImporting = false
            showRestoreConfirm = true
        } catch {
            isImporting = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performRestore() {
        guard let pendingArchive else { return }
        isImporting = true

        Task {
            do {
                _ = try BackupImporter(paths: env.paths).restore(archiveURL: pendingArchive)
                await MainActor.run {
                    isImporting = false
                    message = "恢复完成。请从后台完全关闭 App 再重新打开，数据才会生效。"
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func reload() {
        if let url = BackupExporter(paths: env.paths).latestBackup() {
            lastBackup = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        } else {
            lastBackup = nil
        }
    }
}
