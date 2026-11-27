import Foundation
import SwiftUI

/// 用户自己新建的净化规则。
/// 和书源自带的 `##` 规则分开存，才能做到“只用于本书 / 全局”和“字面 / 正则”。
struct UserPurifierRule: Codable, Identifiable, Equatable {
    enum Scope: String, Codable, CaseIterable, Identifiable {
        case book
        case global

        var id: String { rawValue }
        var title: String { self == .book ? "仅本书" : "全局" }
    }

    var id: UUID = UUID()
    var pattern: String
    var replacement: String = ""
    var isRegex: Bool = false
    var scope: Scope = .book
    var bookId: String?
    var createdAt: Double = Date().timeIntervalSince1970

    /// 转成 Purifier 能吃的 `##pattern##replacement`。
    /// 字面模式先转义正则元字符；替换串里的 `$` 也要转义，否则会被当成捕获组。
    var legadoRule: String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let regex = isRegex ? trimmed : NSRegularExpression.escapedPattern(for: trimmed)
        var escaped = replacement
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
        escaped = escaped.replacingOccurrences(of: "##", with: "\\#\\#")
        return "##\(regex)##\(escaped)"
    }
}

final class PurifierRuleStore: ObservableObject {
    static let shared = PurifierRuleStore()

    @Published private(set) var rules: [UserPurifierRule] = []
    private let storageKey = "reader.userPurifierRules.v1"

    private init() {
        load()
    }

    func rules(for bookId: String) -> [UserPurifierRule] {
        rules.filter { $0.scope == .global || $0.bookId == bookId }
    }

    func legadoRules(for bookId: String) -> [String] {
        rules(for: bookId).compactMap(\.legadoRule)
    }

    func add(_ rule: UserPurifierRule, bookId: String) {
        var value = rule
        value.bookId = rule.scope == .book ? bookId : nil
        rules.append(value)
        persist()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    func removeAll(for bookId: String) {
        rules.removeAll { $0.scope == .book && $0.bookId == bookId }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([UserPurifierRule].self, from: data) else {
            return
        }
        rules = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

/// 从长按选中的文字新建一条净化规则。
struct PurifierRuleEditor: View {
    let selectedText: String
    let bookId: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pattern: String
    @State private var replacement = ""
    @State private var isRegex = false
    @State private var scope: UserPurifierRule.Scope = .book
    @State private var errorMessage: String?

    init(selectedText: String, bookId: String, onSave: @escaping () -> Void) {
        self.selectedText = selectedText
        self.bookId = bookId
        self.onSave = onSave
        _pattern = State(initialValue: selectedText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("匹配文字") {
                    TextField("要净化的文字", text: $pattern, axis: .vertical)
                        .lineLimit(2...6)
                    Toggle("按正则表达式匹配", isOn: $isRegex)
                }

                Section("替换为") {
                    TextField("留空表示直接删除", text: $replacement)
                }

                Section("应用范围") {
                    Picker("应用范围", selection: $scope) {
                        ForEach(UserPurifierRule.Scope.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Text(scope == .global
                         ? "全局规则会应用到所有书的正文。"
                         : "只应用到当前这本书。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink3)
                }
            }
            .navigationTitle("新建净化规则")
            .navigationBarTitleDisplayMode(.inline)
            .alert("正则表达式无效", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isRegex, (try? NSRegularExpression(pattern: trimmed)) == nil {
            errorMessage = "这段正则无法编译，请检查括号、转义和特殊字符。"
            return
        }
        let rule = UserPurifierRule(
            pattern: trimmed,
            replacement: replacement,
            isRegex: isRegex,
            scope: scope,
            bookId: scope == .book ? bookId : nil
        )
        PurifierRuleStore.shared.add(rule, bookId: bookId)
        onSave()
        dismiss()
    }
}
