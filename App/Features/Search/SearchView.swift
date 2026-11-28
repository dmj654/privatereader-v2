import SwiftUI
import ReaderCore

struct SearchView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var router: TabRouter
    @StateObject private var model = SearchViewModel()
    @FocusState private var keyboardFocus: Bool
    @State private var showFilters = false
    @State private var restoreTabWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                searchBar
                    .sheet(isPresented: Binding(
                        get: { !model.idSourceOptions.isEmpty },
                        set: { presented in
                            if !presented { model.cancelIDSourcePicker() }
                        }
                    )) {
                        IDSourcePickerSheet(query: model.idPromptQuery ?? model.query,
                                            options: model.idSourceOptions,
                                            onSelect: { source in
                            model.searchUsingID(source: source, env: env)
                        }, onSearchAll: {
                            model.searchAllUsingID(env: env)
                        })
                    }
                kindPicker
                content
                    // 点结果/空白区域收起键盘；搜索框本身不挂这个手势，
                    // 否则点输入框会被立刻取消焦点。
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            if keyboardFocus { keyboardFocus = false }
                        }
                    )
                    .scrollDismissesKeyboard(.immediately)
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: router.selection) { tab in
            if tab == .search {
                // 进搜索页直接弹键盘（用户要求）；离开时收起。
                focusSearchField()
            } else {
                keyboardFocus = false
                restoreTabWork?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) { router.hidesTabBar = false }
            }
        }
        .onAppear {
            // RootTabView 会一次性建好四个 Tab，onAppear 在启动时就会触发；
            // 只有当前确实停在搜索页时才抢焦点，否则启动就会弹键盘。
            if router.selection == .search { focusSearchField() }
        }
        .onChange(of: keyboardFocus) { focused in
            restoreTabWork?.cancel()

            if focused {
                withAnimation(.easeInOut(duration: 0.22)) { router.hidesTabBar = true }
                return
            }

            if router.selection != .search {
                withAnimation(.easeInOut(duration: 0.2)) { router.hidesTabBar = false }
                return
            }

            // 点结果会先收键盘再 push 详情。延迟一点再放底栏，
            // 详情页一旦出现（detailActive）就不要再放。
            let work = DispatchWorkItem {
                guard !keyboardFocus, !router.detailActive else { return }
                withAnimation(.easeInOut(duration: 0.2)) { router.hidesTabBar = false }
            }
            restoreTabWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
        .sheet(isPresented: $showFilters) {
            SearchFilterSheet(model: model)
                .presentationDetents([.height(360)])
        }
        .alert("没有匹配的编号源", isPresented: Binding(
            get: { model.idNoMatch },
            set: { presented in
                if !presented { model.cancelIDNoMatchPrompt() }
            }
        )) {
            Button("搜索全部源") {
                model.searchAllUsingID(env: env)
            }
            Button("取消", role: .cancel) {
                model.cancelIDNoMatchPrompt()
            }
        } message: {
            Text(model.idNoMatchReason)
        }
    }

    /// 等 Tab 切换与键盘宿主都就绪再抢焦点。
    /// 0.05s 只是"刚出现在屏幕上"，TextField 还不是 first responder，
    /// 设 FocusState 会被系统丢掉；0.32s 是一次键盘动画的时间。
    private func focusSearchField() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            guard router.selection == .search else { return }
            keyboardFocus = true
        }
    }

    // MARK: 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.ink3)

                TextField(model.kind == .comic
                          ? "书名、作者或漫画 ID"
                          : "书名或作者",
                          text: $model.query)
                    .accessibilityIdentifier("search.field")
                    .font(.system(size: 15))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($keyboardFocus)
                    .onSubmit {
                        keyboardFocus = false
                        model.search(env: env)
                    }

                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.ink3.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            }

            Button("搜索") {
                keyboardFocus = false
                model.search(env: env)
            }
            .accessibilityIdentifier("search.submit")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(model.query.trimmingCharacters(in: .whitespaces).isEmpty
                             ? Palette.ink3 : Palette.accent)
            .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var kindPicker: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(SearchViewModel.Kind.allCases) { kind in
                    Button {
                        keyboardFocus = false
                        model.setKind(kind, env: env)
                    } label: {
                        Text(kind.title)
                            .font(.system(size: 13, weight: model.kind == kind ? .semibold : .regular))
                            .foregroundStyle(model.kind == kind ? Color.white : Palette.ink2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(model.kind == kind ? Palette.accent : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(kind == .comic ? "search.kind.comic" : "search.kind.novel")
                }
            }
            .padding(3)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            }

            Button {
                showFilters = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.activeFilterCount > 0 ? "\(model.activeFilterCount)" : "筛选")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(model.activeFilterCount > 0 ? .white : Palette.ink2)
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(model.activeFilterCount > 0 ? Palette.accent : Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(model.activeFilterCount > 0 ? Color.clear : Palette.line, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, 8)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let message = model.errorMessage, model.books.isEmpty {
            ScrollView {
                EmptyStateView(symbol: "antenna.radiowaves.left.and.right.slash",
                               title: "暂时搜不了",
                               message: message)
                if !model.history.isEmpty {
                    historySection.padding(.horizontal, Spacing.l)
                }
            }
        } else if model.books.isEmpty && !model.isSearching && model.hasSearched {
            ScrollView {
                VStack(spacing: 0) {
                    EmptyStateView(symbol: "magnifyingglass",
                                   title: "没有搜到「\(model.query)」",
                                   message: "换个关键词，或者去发现页补几个书源。")
                    footer
                }
            }
        } else if model.books.isEmpty && !model.isSearching {
            ScrollView {
                historySection
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, 4)
            }
        } else if model.books.isEmpty && model.isSearching {
            VStack(spacing: 10) {
                ProgressView().tint(Palette.accent)
                Text("正在搜索 \(model.finishedSources)/\(model.totalSources) 个源")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleBooks.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    EmptyStateView(symbol: "line.3.horizontal.decrease.circle",
                                   title: "筛选后没有结果",
                                   message: "去掉一些筛选条件，或者换个关键词。")
                    Button("清除筛选") { model.resetFilters() }
                        .buttonStyle(SecondaryButtonStyle(height: 40))
                        .frame(width: 160)
                }
            }
        } else {
            ScrollView {
                if model.kind == .comic {
                    comicGrid
                } else {
                    LazyVStack(spacing: 9) {
                        ForEach(model.visibleBooks) { book in
                            NavigationLink {
                                MergedOnlineDetailView(book: book)
                            } label: {
                                bookRow(book)
                            }
                            .buttonStyle(.plain)
                        }
                        footer
                    }
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var comicGrid: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ], spacing: 12) {
                ForEach(model.visibleBooks) { book in
                    NavigationLink {
                        MergedOnlineDetailView(book: book)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            OnlineCoverView(url: book.coverUrl, title: book.name)
                                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                            Text(book.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(2)
                            Text("\(book.entries.count) 个源")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Palette.accent)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            footer
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, 4)
        .padding(.bottom, 24)
    }

    private func bookRow(_ book: SearchViewModel.MergedBook) -> some View {
        HStack(alignment: .top, spacing: 11) {
            OnlineCoverView(url: book.coverUrl, title: book.name)
                .frame(width: 46, height: 63)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)

                Text([book.author, book.kindText]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)

                if !book.lastChapter.isEmpty {
                    Text(book.lastChapter)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.ink3.opacity(0.85))
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 9))
                    Text("\(book.entries.count) 个源")
                        .font(.system(size: 10))
                }
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Palette.accentSoft)
                .clipShape(Capsule())
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink3.opacity(0.6))
                .padding(.top, 24)
        }
        .padding(10)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1)
        }
    }

    private var footer: some View {
        Group {
            if model.isSearching {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("已搜 \(model.finishedSources)/\(model.totalSources) 个源")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                }
                .padding(.top, 6)
            } else if model.failedCount > 0 {
                Button {
                    model.retryFailed(env: env)
                } label: {
                    Text("\(model.failedCount) 个源失败 · 点这里重试")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.accent)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            } else if model.books.isEmpty {
                Text("没有搜到「\(model.query)」。换个关键词，或去发现页换个源。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("搜索历史")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                Spacer()
                if !model.history.isEmpty {
                    Button("清空") { model.clearHistory() }
                        .font(Typo.micro)
                        .foregroundStyle(Palette.ink3)
                }
            }

            if model.history.isEmpty {
                Text("搜过的书名会留在这里。结果会按书合并，点进去可以换源。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.ink3)
                    .padding(.top, 2)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(model.history, id: \.self) { keyword in
                        Button {
                            model.selectHistory(keyword, env: env)
                        } label: {
                            Chip(title: keyword)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - 筛选

struct SearchFilterSheet: View {
    @ObservedObject var model: SearchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("精确匹配书名或作者", isOn: $model.filters.exactMatch)
                } header: {
                    Text("精确搜索")
                } footer: {
                    Text("打开后只保留书名或作者与关键词完全一致的结果。")
                }

                Section("结果筛选") {
                    Picker("最少收录源数", selection: $model.filters.minSources) {
                        Text("不限").tag(1)
                        Text("至少 2 个源").tag(2)
                        Text("至少 3 个源").tag(3)
                    }
                }

                Section("排序") {
                    Picker("排序方式", selection: $model.filters.sort) {
                        ForEach(SearchViewModel.SortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("搜索筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清除") { model.resetFilters() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// 简易流式布局，给历史 chips 用。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth,
                      height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 在线封面：先显示占位书名，图到了再换。
struct OnlineCoverView: View {
    let url: String
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0xD9E3EC), Color(hex: 0xC3D2E0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .padding(4)

            if let url = URL(string: url), !url.absoluteString.isEmpty {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        }
    }
}
