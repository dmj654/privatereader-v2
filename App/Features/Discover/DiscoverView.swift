import SwiftUI
import ReaderCore

/// 发现页。M6 阶段只承担一件事：让书源能被导入、被看到、被管理。
/// 榜单和分类要等源里的 exploreUrl 规则跑通再上，这里先不铺空架子。
struct DiscoverView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var sourceCount = 0
    @State private var enabledCount = 0
    @State private var novelCount = 0
    @State private var comicCount = 0
    @State private var kind: SearchViewModel.Kind = .novel
    @State private var showingImport = false
    @State private var loadError: String?

    @State private var invalidCount = 0
    @State private var isChecking = false
    @State private var checkTask: Task<Void, Never>?
    @State private var checkedCount = 0
    @State private var checkTotal = 0
    @State private var confirmDeleteInvalid = false
    @State private var maintenanceMessage: String?

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    if let loadError {
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("读取书源失败")
                                    .font(Typo.headline)
                                    .foregroundStyle(Palette.danger)
                                Text(loadError)
                                    .font(Typo.micro)
                                    .foregroundStyle(Palette.ink3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if sourceCount == 0 {
                        importGuide
                    } else {
                        kindPicker
                        sourceCard
                        maintenanceCard
                        ExploreSection(kind: kind)
                    }

                    rulesCard
                }
                .padding(.horizontal, Spacing.l)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SourcesView()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                }
                .accessibilityLabel("书源管理")
            }
        }
        .confirmationDialog("删除 \(invalidCount) 条失效书源？", isPresented: $confirmDeleteInvalid, titleVisibility: .visible) {
            Button("删除失效源", role: .destructive) { deleteInvalid() }
        } message: {
            Text("只删当前分类里上次测试明确失败或超时的源，正常的源不动。")
        }
        .sheet(isPresented: $showingImport) {
            SourceImportSheet { _ in reload() }
                .presentationDetents([.medium, .large])
        }
        .onChange(of: kind) { _ in reload() }
        .onAppear(perform: reload)
    }

    private var kindTitle: String { kind == .comic ? "漫画源" : "小说源" }
    private var wantsComic: Bool { kind == .comic }

    // MARK: 块

    private var importGuide: some View {
        Card(padding: 18) {
            VStack(spacing: 14) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 4)

                VStack(spacing: 5) {
                    Text("先导入一份书源")
                        .font(Typo.headline)
                        .foregroundStyle(Palette.ink)
                    Text("书源决定了能搜到哪些站的书。支持 legado 导出的 JSON，一次可以导入几千条。")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.ink3)
                        .multilineTextAlignment(.center)
                }

                Button("导入书源") { showingImport = true }
                    .buttonStyle(PrimaryButtonStyle())

                NavigationLink {
                    SourcesView()
                } label: {
                    Text("先看看书源管理")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.accent)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var kindPicker: some View {
        HStack(spacing: 8) {
            ForEach(SearchViewModel.Kind.allCases) { item in
                let count = item == .novel ? novelCount : comicCount
                Button {
                    kind = item
                } label: {
                    Text("\(item.title) \(count)")
                        .font(.system(size: 12.5, weight: kind == item ? .semibold : .regular))
                        .foregroundStyle(kind == item ? .white : Palette.ink2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(kind == item ? Palette.accent : Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(kind == item ? Color.clear : Palette.line, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sourceCard: some View {
        NavigationLink {
            SourcesView()
        } label: {
            Card {
                HStack(spacing: 14) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 42, height: 42)
                        .background(Palette.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("书源")
                            .font(Typo.headline)
                            .foregroundStyle(Palette.ink)
                        Text("小说 \(novelCount) 条 · 漫画 \(comicCount) 条 · 当前 \(kindTitle) \(kind == .comic ? comicCount : novelCount) 条")
                            .font(Typo.micro)
                            .foregroundStyle(Palette.ink3)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink3)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var maintenanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("书源维护 · \(kindTitle)")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("只测试当前分类的\(kindTitle)，逐个请求搜索接口，5 秒超时；测完可以一键删掉失效源。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
                    .lineSpacing(2)

                HStack(spacing: 9) {
                    Button {
                        toggleCheck()
                    } label: {
                        Text(isChecking
                             ? "停止 \(checkedCount)/\(checkTotal)"
                             : "测试\(kindTitle)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isChecking ? Palette.danger : Palette.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Palette.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(Palette.lineStrong, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)

                    Button {
                        confirmDeleteInvalid = true
                    } label: {
                        Text("删除失效 \(invalidCount)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(invalidCount > 0 ? Palette.danger : Palette.ink3.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Palette.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(Palette.line, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(invalidCount == 0 || isChecking)
                }

                if let maintenanceMessage {
                    Text(maintenanceMessage)
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rulesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("关于书源")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                Text("书源是社区维护的站点解析规则。源站改版会导致规则失效，这时「测一下」会显示超时或失败——关掉它就行，不影响其他源。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 数据

    private func reload() {
        do {
            let all = try env.sources.all()
            sourceCount = all.count
            enabledCount = all.filter(\.enabled).count
            novelCount = all.filter { $0.type != 2 }.count
            comicCount = all.filter { $0.type == 2 }.count
            let invalid = (try? env.sources.invalidSources()) ?? []
            invalidCount = invalid.filter { $0.isComic == wantsComic }.count
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: 维护

    private func toggleCheck() {
        if isChecking {
            checkTask?.cancel()
            checkTask = nil
            isChecking = false
            maintenanceMessage = "已停止检测，已测结果已保存。"
            reload()
            return
        }

        let enabled = ((try? SourceImportService(repo: env.sources).enabledSources()) ?? [])
            .filter { $0.isComic == wantsComic }
        guard !enabled.isEmpty else {
            maintenanceMessage = "当前分类没有启用的\(kindTitle)。"
            return
        }

        isChecking = true
        checkedCount = 0
        checkTotal = enabled.count
        maintenanceMessage = nil

        let repo = env.sources
        let checker = SourceHealthChecker(client: env.sourceClient)

        checkTask = Task {
            await withTaskGroup(of: (String, SourceHealthStatus).self) { group in
                var iterator = enabled.makeIterator()
                let width = min(8, enabled.count)
                for _ in 0..<width {
                    guard let source = iterator.next() else { break }
                    group.addTask { (source.id, await checker.check(source)) }
                }

                while let (id, status) = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    await MainActor.run {
                        try? repo.markChecked(
                            id: id,
                            at: Int(Date().timeIntervalSince1970),
                            result: Self.checkResultText(status)
                        )
                        checkedCount += 1
                    }
                    if let source = iterator.next() {
                        group.addTask { (source.id, await checker.check(source)) }
                    }
                }
            }

            await MainActor.run {
                isChecking = false
                checkTask = nil
                reload()
                if checkedCount >= checkTotal {
                    maintenanceMessage = "检测完成：\(invalidCount) 条失效，可一键删除。"
                }
            }
        }
    }

    private func deleteInvalid() {
        let invalid = ((try? env.sources.invalidSources()) ?? []).filter { $0.isComic == wantsComic }
        guard !invalid.isEmpty else {
            maintenanceMessage = "没有可删除的失效源。"
            return
        }
        try? env.sources.delete(ids: invalid.map(\.id))
        reload()
        maintenanceMessage = "已删除 \(invalid.count) 条失效书源。"
    }

    private static func checkResultText(_ status: SourceHealthStatus) -> String {
        switch status {
        case .ok(let ms, let count): return "ok \(ms)ms \(count)"
        case .timeout: return "timeout"
        case .failed(let message): return "failed: \(message)"
        case .skipped(let reason): return "skipped: \(reason)"
        }
    }
}
