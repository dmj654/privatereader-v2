import SwiftUI
import ReaderCore

/// 发现页：只负责找书和找漫画。
/// 导入、开关、测试、删除这些书源维护动作统一放在 `SourcesView`，不在发现页占位置。
struct DiscoverView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var novelCount = 0
    @State private var comicCount = 0
    @State private var kind: SearchViewModel.Kind = .novel
    @State private var showingImport = false
    @State private var loadError: String?

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

                    kindPicker

                    if currentKindCount == 0 {
                        importGuide
                    } else if kind == .comic {
                        ExploreSection(kind: .comic)
                            .id("comic-explore")
                    } else {
                        NovelDiscoverSection()
                            .id("novel-discover")
                    }
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
        .sheet(isPresented: $showingImport) {
            SourceImportSheet(category: kind == .comic ? .comic : .novel) { _ in reload() }
                .presentationDetents([.medium, .large])
        }
        .onChange(of: kind) { _ in reload() }
        .onAppear(perform: reload)
    }

    private var kindTitle: String { kind == .comic ? "漫画源" : "小说源" }
    private var currentKindCount: Int { kind == .comic ? comicCount : novelCount }

    // MARK: 块

    private var importGuide: some View {
        Card(padding: 18) {
            VStack(spacing: 14) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 4)

                VStack(spacing: 5) {
                    Text("先导入一份\(kindTitle)")
                        .font(Typo.headline)
                        .foregroundStyle(Palette.ink)
                    Text(kind == .comic
                         ? "漫画源决定能搜到哪些在线漫画。支持 legado 导出的 JSON，一次可以导入几千条。"
                         : "书源决定能搜到哪些站的书。支持 legado 导出的 JSON，一次可以导入几千条。")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.ink3)
                        .multilineTextAlignment(.center)
                }

                Button("导入\(kindTitle)") { showingImport = true }
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

    // MARK: 数据

    private func reload() {
        do {
            let all = try env.sources.all()
            novelCount = all.filter { $0.type != 2 }.count
            comicCount = all.filter { $0.type == 2 }.count
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
