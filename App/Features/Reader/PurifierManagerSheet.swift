import SwiftUI

/// 阅读器右上角「净化」进入的管理页：查看、启停和删除自己创建的规则。
struct PurifierManagerSheet: View {
    let bookID: String
    let bookTitle: String
    let isEnabled: Bool
    let onToggle: (Bool) -> Void
    let onChanged: () -> Void

    @ObservedObject private var store = PurifierRuleStore.shared
    @State private var enabled: Bool
    @State private var showEditor = false

    init(bookID: String,
         bookTitle: String,
         isEnabled: Bool,
         onToggle: @escaping (Bool) -> Void,
         onChanged: @escaping () -> Void) {
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.isEnabled = isEnabled
        self.onToggle = onToggle
        self.onChanged = onChanged
        _enabled = State(initialValue: isEnabled)
    }

    private var rules: [UserPurifierRule] {
        store.rules(for: bookID)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $enabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("启用正文净化")
                                .font(.system(size: 15, weight: .medium))
                            Text("关闭后显示源站原文，规则仍然保留")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.ink3)
                        }
                    }
                    .onChange(of: enabled) { value in
                        onToggle(value)
                    }
                } header: {
                    Text("状态")
                }

                Section {
                    if rules.isEmpty {
                        Text("还没有自己创建的净化规则。长按正文选中文字后点「净化」，或者点下面的按钮新建。")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink3)
                            .lineSpacing(3)
                    } else {
                        ForEach(rules) { rule in
                            ruleRow(rule)
                        }
                        .onDelete { offsets in
                            let ids = offsets.compactMap { offset -> UUID? in
                                guard rules.indices.contains(offset) else { return nil }
                                return rules[offset].id
                            }
                            ids.forEach { store.remove(id: $0) }
                            onChanged()
                        }
                    }

                    Button {
                        showEditor = true
                    } label: {
                        Label("新建一条净化规则", systemImage: "plus.circle")
                            .font(.system(size: 14, weight: .medium))
                    }
                } header: {
                    Text("我创建的规则")
                } footer: {
                    Text("「仅本书」只影响《\(bookTitle)》；「全局」会影响所有书的正文。左滑可以删除。")
                        .font(.system(size: 11.5))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("净化管理")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showEditor) {
                PurifierRuleEditor(selectedText: "", bookId: bookID) {
                    onChanged()
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func ruleRow(_ rule: UserPurifierRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rule.pattern)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(3)
            Text(rule.replacement.isEmpty
                 ? "替换为：删除"
                 : "替换为：\(rule.replacement)")
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink2)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(rule.scope.title)
                if rule.isRegex { Text("· 正则") }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 2)
    }
}
