import SwiftUI
import ReaderCore

struct GroupManagerSheet: View {
    let groups: [BookGroup]
    let onChanged: () -> Void

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg.ignoresSafeArea()
                List {
                    Section("新建分组") {
                        HStack {
                            TextField("分组名", text: $newName)
                            Button("添加") {
                                let name = newName.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                _ = try? env.groups.create(name: name)
                                newName = ""
                                onChanged()
                            }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    Section("已有分组") {
                        ForEach(groups) { group in
                            HStack {
                                Text(group.name)
                                Spacer()
                                if group.builtin {
                                    Text("内置").font(Typo.micro).foregroundStyle(Palette.ink3)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                try? env.groups.delete(id: groups[index].id)
                            }
                            onChanged()
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("分组管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
