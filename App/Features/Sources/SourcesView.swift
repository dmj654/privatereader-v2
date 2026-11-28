import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

/// 书源管理：列表、开关、体检、删除、导入。
///
/// 2500 条源不可能一条条手点，所以「测一下全部」是主操作；
/// 列表默认按「启用 → 名称」排，关掉的沉在下面。
struct SourcesView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var sources: [BookSource] = []
    @State private var health: [String: SourceHealthStatus] = [:]
    @State private var checking: Set<String> = []
    @State private var isCheckingAll = false
    @State private var showingImport = false
    @State private var errorMessage: String?
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteFailed = false
    @State private var searchText = ""
    @State private var kindFilter: SourceKind = .novel
    @State private var filter: HealthFilter = .all
    @State private var checkedCount = 0
    @State private var activeBatchTotal = 0
    @State private var checkTask: Task<Void, Never>?
    @State private var selectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var confirmDeleteSelected = false
    @State private var confirmDeepCheckAll = false

    private var kindSources: [BookSource] {
        sources.filter { kindFilter.matches($0.type) }
    }
    private var enabledCount: Int { kindSources.filter(\.enabled).count }
    private var novelTotal: Int { sources.filter { $0.type != 2 }.count }
    private var comicTotal: Int { sources.filter { $0.type == 2 }.count }

    enum SourceKind: String, CaseIterable, Identifiable {
        case novel, comic

        var id: String { rawValue }
        var title: String { self == .novel ? "小说源" : "漫画源" }

        func matches(_ type: Int) -> Bool {
            self == .comic ? type == 2 : type != 2
        }
    }

    enum HealthFilter: String, CaseIterable, Identifiable {
        case all, ok, partial, failed, disabled

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .ok: return "正常"
            case .partial: return "部分可用"
            case .failed: return "失败"
            case .disabled: return "已关闭"
            }
        }
    }

    private var summaryDetail: String {
        var parts = ["启用 \(enabledCount) 条", "共 \(kindSources.count) 条"]
        let ok = kindSources.filter { $0.enabled && health[$0.id]?.isHealthy == true }.count
        let failed = kindSources.filter { $0.enabled && health[$0.id]?.isDefiniteFailure == true }.count
        let timedOut = kindSources.filter { $0.enabled && health[$0.id]?.isTimeout == true }.count
        let partial = kindSources.filter { $0.enabled && health[$0.id]?.isPartial == true }.count
        if ok > 0 { parts.append("正常 \(ok) 条") }
        if failed > 0 { parts.append("失败 \(failed) 条") }
        if timedOut > 0 { parts.append("超时 \(timedOut) 条") }
        if partial > 0 { parts.append("部分可用 \(partial) 条") }
        return parts.joined(separator: " · ")
    }

    private var filteredSources: [BookSource] {
        sources.filter { source in
            guard kindFilter.matches(source.type) else { return false }
            let text = searchText.trimmingCharacters(in: .whitespaces)
            let matchesText = text.isEmpty
                || source.name.localizedCaseInsensitiveContains(text)
                || source.id.localizedCaseInsensitiveContains(text)

            guard matchesText else { return false }
            switch filter {
            case .all:
                return true
            case .disabled:
                return !source.enabled
            case .ok:
                return health[source.id]?.isHealthy == true
            case .partial:
                guard source.enabled else { return false }
                return health[source.id]?.isPartial == true
            case .failed:
                guard source.enabled else { return false }
                return health[source.id]?.isDefiniteFailure == true
            }
        }
    }

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            list
        }
        .navigationTitle(kindFilter.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selectionMode {
                    Button("完成") { exitSelection() }
                        .font(.system(size: 13.5, weight: .medium))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selectionMode {
                    Button(selectedIDs.count == filteredSources.count && !filteredSources.isEmpty ? "取消全选" : "全选") {
                        toggleSelectAll()
                    }
                    .font(.system(size: 13.5, weight: .medium))
                } else {
                    Button {
                        showingImport = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel("导入\(kindFilter.title)")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !sources.isEmpty { bottomBar }
        }
        .sheet(isPresented: $showingImport) {
            SourceImportSheet(category: kindFilter == .comic ? .comic : .novel) { summary in
                reload()
                if summary.total > 0 {
                    errorMessage = nil
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("删除全部\(kindFilter.title)？", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("删除全部\(kindFilter.title)", role: .destructive) { deleteAll() }
        } message: {
            Text("只删当前这一类的 \(kindSources.count) 条源，书架里的书不受影响。")
        }
        .confirmationDialog("删除 \(failedSources.count) 条明确失败的\(kindFilter.title)？", isPresented: $confirmDeleteFailed, titleVisibility: .visible) {
            Button("删除失败源", role: .destructive) { deleteFailed() }
        } message: {
            Text("只删当前这一类里明确失败的源（404、解析错误、脚本报错）。超时的源会保留，可以稍后再测。")
        }
        .confirmationDialog("删除选中的 \(selectedIDs.count) 条\(kindFilter.title)？", isPresented: $confirmDeleteSelected, titleVisibility: .visible) {
            Button("删除选中项", role: .destructive) { deleteSelected() }
        } message: {
            Text("只删当前分类里勾选的源，书架里的书不受影响。")
        }
        .confirmationDialog("深度检测全部\(kindFilter.title)？", isPresented: $confirmDeepCheckAll, titleVisibility: .visible) {
            Button("开始深度检测") { checkAllDeep() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会对当前分类里启用的 \(enabledCount) 条源逐条检查搜索、前 3 本书的详情和目录。源多时可能要几十分钟，检测中可从菜单点「停止检测」。")
        }
        .onAppear(perform: reload)
    }

    // MARK: 列表

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                kindPicker

                if kindSources.isEmpty {
                    emptyState
                } else {
                    summaryCard
                    maintenanceHint
                    filterBar

                    if filteredSources.isEmpty {
                        Text(searchText.isEmpty ? "这个筛选下没有\(kindFilter.title)" : "没有匹配「\(searchText)」的\(kindFilter.title)")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.ink3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(filteredSources) { source in
                            row(source)
                        }
                    }
                }

                Text("\(kindFilter.title)共 \(kindSources.count) 条 · 启用 \(enabledCount) 条 · 当前显示 \(filteredSources.count) 条")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
                    .padding(.top, 4)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
    }

    private var kindPicker: some View {
        HStack(spacing: 8) {
            ForEach(SourceKind.allCases) { kind in
                let count = sources.filter { kind.matches($0.type) }.count
                Button {
                    kindFilter = kind
                    if selectionMode { selectedIDs.removeAll() }
                } label: {
                    Text("\(kind.title) \(count)")
                        .font(.system(size: 12.5, weight: kindFilter == kind ? .semibold : .regular))
                        .foregroundStyle(kindFilter == kind ? .white : Palette.ink2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(kindFilter == kind ? Palette.accent : Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(kindFilter == kind ? Color.clear : Palette.line, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink3)
                TextField("搜名称或网址", text: $searchText)
                    .font(.system(size: 13.5))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink3.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            }

            HStack(spacing: 7) {
                ForEach(HealthFilter.allCases) { item in
                    Button {
                        filter = item
                    } label: {
                        Chip(title: item.title, isOn: filter == item)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(kindFilter.title) \(kindSources.count) 条")
                    .font(Typo.headline)
                    .foregroundStyle(Palette.ink)
                Text(summaryDetail)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 0)
            Menu {
                if isCheckingAll {
                    Button("停止检测") { checkAll() }
                } else {
                    Button("测一下启用的\(kindFilter.title)") { checkAll() }
                    Button("深度检测全部\(kindFilter.title)（慢）") { confirmDeepCheckAll = true }
                        .disabled(enabledCount == 0)
                }
                Button("批量管理（勾选后测试 / 开关 / 删除）") { enterSelection() }
                Button("禁用全部失败的\(kindFilter.title)") { disableFailed() }
                    .disabled(failedSources.isEmpty)
                Button("删除全部失败的\(kindFilter.title)", role: .destructive) { confirmDeleteFailed = true }
                    .disabled(failedSources.isEmpty)
                Divider()
                Button("删除全部\(kindFilter.title)", role: .destructive) { confirmDeleteAll = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 34, height: 34)
                    .background(Palette.surfaceAlt)
                    .clipShape(Circle())
            }
        }
        .padding(14)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1)
        }
    }

    private var maintenanceHint: some View {
        Text("「测一下全部」只做搜索，速度较快。「深度检测全部（慢）」会对每本源打开前 3 本书的详情和目录，源多时要几十分钟，可随时停止。单源「测一下」和「测所选」也会抽查前 3 本：搜索正常但详情/目录坏掉的源会标成「部分可用」，不会自动删除。")
            .font(Typo.micro)
            .foregroundStyle(Palette.ink3)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func row(_ source: BookSource) -> some View {
        let status = health[source.id]
        let isChecking = checking.contains(source.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if selectionMode {
                    Button {
                        toggleSelection(source.id)
                    } label: {
                        Image(systemName: selectedIDs.contains(source.id)
                              ? "checkmark.circle.fill"
                              : "circle")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(selectedIDs.contains(source.id) ? Palette.accent : Palette.ink3)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(source.id)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.ink3.opacity(0.85))
                        .lineLimit(1)
                }

                if source.type == 2 {
                    Text("漫画")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Palette.accentDeep)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Palette.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Spacer(minLength: 6)

                Toggle("", isOn: Binding(
                    get: { source.enabled },
                    set: { setEnabled(source, $0) }
                ))
                .labelsHidden()
                .tint(Palette.accent)
                .scaleEffect(0.86)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(status, id: source.id, enabled: source.enabled))
                    .frame(width: 5, height: 5)

                Text(statusText(status, id: source.id, enabled: source.enabled, checking: isChecking))
                    .font(Typo.micro)
                    .foregroundStyle(status == nil ? Palette.ink3 : Palette.ink2)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button {
                    check(source)
                } label: {
                    Text(isChecking ? "检测中" : "测一下")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isChecking ? Palette.ink3 : Palette.accent)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Palette.accentSoft.opacity(isChecking ? 0.5 : 1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isChecking)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1)
        }
        .opacity(source.enabled ? 1 : 0.62)
        .contextMenu {
            Button(source.enabled ? "关闭" : "启用") { setEnabled(source, !source.enabled) }
            Button("测一下") { check(source) }
            Button("删除", role: .destructive) { delete(source) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            EmptyStateView(
                symbol: "tray.and.arrow.down",
                title: "还没有\(kindFilter.title)",
                message: kindFilter == .comic
                    ? "导入 legado 格式的漫画源 JSON，就能搜索和阅读在线漫画。"
                    : "导入 legado 格式的书源 JSON，就能搜索和阅读网文。"
            )
            Button("导入\(kindFilter.title)") { showingImport = true }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 44)
        }
        .padding(.top, 36)
        .padding(.bottom, 20)
    }

    private var bottomBar: some View {
        Group {
            if selectionMode {
                selectionBar
            } else {
                normalBar
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.line).frame(height: 0.5)
        }
    }

    private var normalBar: some View {
        HStack(spacing: 10) {
            Button {
                checkAll()
            } label: {
                Text(isCheckingAll ? "停止检测 \(checkedCount)/\(activeBatchTotal)" : "测一下全部")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                            .strokeBorder(Palette.lineStrong, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .disabled(kindSources.isEmpty)

            Button {
                showingImport = true
            } label: {
                Text("导入")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 96)
                    .frame(height: 44)
                    .background(Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text(selectedIDs.isEmpty ? "未选择" : "已选 \(selectedIDs.count) 条")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("\(kindFilter.title) · 共 \(kindSources.count) 条")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.ink3)
            }
            .frame(width: 96, alignment: .leading)

            Button {
                checkSelected()
            } label: {
                Text(isCheckingAll ? "\(checkedCount)/\(activeBatchTotal)" : "测所选")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(selectedIDs.isEmpty ? Palette.ink3 : Palette.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Palette.accentSoft.opacity(selectedIDs.isEmpty ? 0.4 : 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(selectedIDs.isEmpty || isCheckingAll)

            Menu {
                Button("启用所选") { setEnabledSelected(true) }
                    .disabled(selectedIDs.isEmpty)
                Button("关闭所选") { setEnabledSelected(false) }
                    .disabled(selectedIDs.isEmpty)
                Divider()
                Button("删除所选", role: .destructive) { confirmDeleteSelected = true }
                    .disabled(selectedIDs.isEmpty)
            } label: {
                Text("批量操作")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 92, height: 40)
                    .background(Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    // MARK: 状态

    private func statusText(_ status: SourceHealthStatus?,
                            id: String,
                            enabled: Bool,
                            checking: Bool) -> String {
        if checking { return "正在请求源站…" }
        guard let status else {
            guard enabled else { return "已关闭" }
            return "未检测"
        }
        switch status {
        case .ok(let ms, let count):
            return "正常 · \(ms)ms · \(count) 条结果"
        case .okDeep(let ms, let count, let checked, let chapters):
            return "正常 · \(ms)ms · \(count) 条结果 · 抽查 \(checked) 本详情/目录通过 · 共 \(chapters) 章"
        case .partial(let message):
            return "部分可用 · \(message)"
        case .timeout:
            return "超时 · 首轮和加长重试都没响应（不是失效，可稍后再测）"
        case .failed(let message):
            return "失败 · \(message)"
        case .skipped(let reason):
            return reason
        }
    }

    private func statusColor(_ status: SourceHealthStatus?, id: String, enabled: Bool) -> Color {
        guard enabled else { return Palette.ink3.opacity(0.5) }
        guard let status else { return Palette.ink3.opacity(0.6) }
        switch status {
        case .ok, .okDeep: return Color(hex: 0x4E8A5F)
        case .partial: return Color(hex: 0xC08A3E)
        case .timeout: return Color(hex: 0xC08A3E)
        case .failed: return Palette.danger
        case .skipped: return Palette.ink3.opacity(0.6)
        }
    }

    // MARK: 动作

    private func reload() {
        do {
            let all = try env.sources.all()
            sources = all.sorted { lhs, rhs in
                if lhs.enabled != rhs.enabled { return lhs.enabled && !rhs.enabled }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

            // 上次体检的结论都从数据库恢复；本次内存里的新结果优先。
            let liveIDs = Set(all.map(\.id))
            health = health.filter { liveIDs.contains($0.key) }
            for source in all where health[source.id] == nil {
                if let snapshot = SourceHealthSnapshot(lastCheckResult: source.lastCheckResult) {
                    health[source.id] = snapshot.status
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setEnabled(_ source: BookSource, _ enabled: Bool) {
        do {
            try env.sources.setEnabled(id: source.id, enabled: enabled)
            if var updated = sources.first(where: { $0.id == source.id }) {
                updated.enabled = enabled
                if let index = sources.firstIndex(where: { $0.id == source.id }) {
                    sources[index] = updated
                }
            }
            // 开关改了顺序也要跟着变
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ source: BookSource) {
        do {
            try env.sources.delete(id: source.id)
            health[source.id] = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteAll() {
        do {
            try env.sources.delete(ids: kindSources.map(\.id))
            health = [:]
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func enterSelection() {
        selectionMode = true
        selectedIDs.removeAll()
    }

    private func exitSelection() {
        selectionMode = false
        selectedIDs.removeAll()
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func toggleSelectAll() {
        let visible = Set(filteredSources.map(\.id))
        if visible.isSubset(of: selectedIDs) {
            selectedIDs.subtract(visible)
        } else {
            selectedIDs.formUnion(visible)
        }
    }

    private func setEnabledSelected(_ enabled: Bool) {
        let ids = kindSources.filter { selectedIDs.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        do {
            for id in ids {
                try env.sources.setEnabled(id: id, enabled: enabled)
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelected() {
        let ids = kindSources.filter { selectedIDs.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        do {
            try env.sources.delete(ids: ids)
            ids.forEach { health[$0] = nil }
            selectedIDs.subtract(ids)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func check(_ source: BookSource) {
        guard !checking.contains(source.id) else { return }
        checking.insert(source.id)

        Task {
            let service = SourceImportService(repo: env.sources)
            let target = service.target(from: source)
            let checker = SourceHealthChecker(client: env.sourceClient, venera: env.veneraRuntime)
            let status: SourceHealthStatus
            switch target {
            case .legado(let executable):
                status = await checker.check(executable, retryTimeout: 20, deep: true)
            case .venera(let script):
                status = await checker.check(script, retryTimeout: 45, deep: true)
            case nil:
                status = .failed("书源解析失败，建议重新导入")
            }
            await MainActor.run {
                health[source.id] = status
                checking.remove(source.id)
                record(status, for: source)
            }
        }
    }

    private func checkAll() {
        startBatch(kindSources.filter(\.enabled), deep: false)
    }

    /// 全部深度检测走同一个批量任务，保留进度和“再点一次停止”。
    /// 和快速检测分开，避免用户误把几十分钟的深检当成普通体检。
    private func checkAllDeep() {
        startBatch(kindSources.filter(\.enabled), deep: true)
    }

    private func checkSelected() {
        let targets = kindSources.filter { selectedIDs.contains($0.id) }
        startBatch(targets, deep: true)
    }

    private func startBatch(_ targets: [BookSource], deep: Bool = false) {
        // 检测中再点 = 停止
        if isCheckingAll {
            checkTask?.cancel()
            checkTask = nil
            isCheckingAll = false
            checking.removeAll()
            checkedCount = 0
            activeBatchTotal = 0
            return
        }

        guard !targets.isEmpty else { return }

        isCheckingAll = true
        checkedCount = 0
        activeBatchTotal = targets.count
        checking = Set(targets.map(\.id))

        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        let service = SourceImportService(repo: env.sources)
        let checker = SourceHealthChecker(client: env.sourceClient, venera: env.veneraRuntime)

        checkTask = Task {
            await withTaskGroup(of: (String, SourceHealthStatus?).self) { group in
                var iterator = targets.makeIterator()
                // Venera 的 JS 运行时很重，漫画源同时开 8 个会互相拖到超时；降到 4 路。
                let width = min(kindFilter == .comic ? 4 : 8, targets.count)

                for _ in 0..<width {
                    guard let source = iterator.next() else { break }
                    group.addTask {
                        guard let target = service.target(from: source) else {
                            return (source.id, nil)
                        }
                        switch target {
                        case .legado(let executable):
                            return (source.id, await checker.check(executable, retryTimeout: 20, deep: deep))
                        case .venera(let script):
                            return (source.id, await checker.check(script, retryTimeout: 45, deep: deep))
                        }
                    }
                }

                while let (id, status) = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    await MainActor.run {
                        if let status {
                            health[id] = status
                            if let source = byID[id] { record(status, for: source) }
                        }
                        checking.remove(id)
                        checkedCount += 1
                    }
                    if let source = iterator.next() {
                        group.addTask {
                            guard let target = service.target(from: source) else {
                                return (source.id, nil)
                            }
                            switch target {
                            case .legado(let executable):
                                return (source.id, await checker.check(executable, retryTimeout: 20, deep: deep))
                            case .venera(let script):
                                return (source.id, await checker.check(script, retryTimeout: 45, deep: deep))
                            }
                        }
                    }
                }
            }

            await MainActor.run {
                isCheckingAll = false
                checkTask = nil
                // 取消时不要弹汇总
                guard checkedCount >= targets.count else { return }

                var ok = 0, failed = 0, timedOut = 0, partial = 0
                for source in targets {
                    switch health[source.id] {
                    case .ok, .okDeep: ok += 1
                    case .partial: partial += 1
                    case .failed: failed += 1
                    case .timeout: timedOut += 1
                    case .skipped, .none: break
                    }
                }
                if failed > 0 {
                    errorMessage = "检测完成：\(ok) 条正常，\(partial) 条部分可用（详情/目录异常），\(failed) 条明确失败，\(timedOut) 条超时（已保留，可稍后再测）。可以点右上角菜单关闭或删除明确失败的源。"
                } else if timedOut > 0 || partial > 0 {
                    errorMessage = "检测完成：没有明确失败；\(ok) 条正常，\(partial) 条部分可用（详情/目录异常），\(timedOut) 条超时（已自动重试仍无响应，保留着，不会删除）。"
                }
            }
        }
    }

    /// 明确失败、且仍然启用的源。超时不算失败，不能一键删除。
    private var failedSources: [BookSource] {
        kindSources.filter { source in
            guard source.enabled else { return false }
            return health[source.id]?.isDefiniteFailure == true
        }
    }

    private func disableFailed() {
        for source in failedSources {
            try? env.sources.setEnabled(id: source.id, enabled: false)
        }
        reload()
    }

    private func deleteFailed() {
        for source in failedSources {
            try? env.sources.delete(id: source.id)
            health[source.id] = nil
        }
        reload()
    }

    /// 把体检结果写回库，下次进来还能看到上次的结论。
    private func record(_ status: SourceHealthStatus, for source: BookSource) {
        let text: String
        switch status {
        case .ok(let ms, let count):
            text = "ok \(ms) \(count)"
        case .okDeep(let ms, let count, let checked, let chapters):
            text = "okDeep \(ms) \(count) \(checked) \(chapters)"
        case .partial(let message):
            text = "partial: \(message)"
        case .timeout:
            text = "timeout"
        case .failed(let message):
            text = "failed: \(message)"
        case .skipped(let reason):
            text = "skipped: \(reason)"
        }
        try? env.sources.markChecked(
            id: source.id,
            at: Int(Date().timeIntervalSince1970),
            result: text
        )
    }
}
