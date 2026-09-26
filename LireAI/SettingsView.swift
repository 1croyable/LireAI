import SwiftUI

private enum APIProviderTab: String, CaseIterable, Identifiable {
    case mistral = "Mistral"
    case brave = "Brave Search"

    var id: String { rawValue }
}

struct SettingsView: View {
    @State private var slotIDs: [String] = []
    @State private var activeID = LireKeychain.primaryID
    @State private var provider: APIProviderTab = .mistral

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("API 类型", selection: $provider) {
                        ForEach(APIProviderTab.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if provider == .mistral {
                    ForEach(Array(slotIDs.enumerated()), id: \.element) { index, id in
                        APIKeySlotSection(
                            id: id,
                            number: index + 1,
                            isPrimary: id == LireKeychain.primaryID,
                            isActive: id == activeID,
                            didChange: reloadSlots
                        )
                    }

                    Section {
                        Button {
                            _ = LireKeychain.createSlot()
                            reloadSlots()
                        } label: {
                            Label("添加 Mistral API Key", systemImage: "plus.circle.fill")
                        }
                    }
                } else {
                    BraveAPIKeySection()
                }

                Section("使用说明") {
                    Text("1. 在书库中导入无 DRM 的 EPUB。")
                    Text("2. 打开书籍，长按选中文字，点击“AI 查找”。")
                    Text("3. 在弹出的解释页继续自由提问。")
                    Text("4. Mistral 负责判断和回答，可以保存多个 Key 并手动切换。")
                    Text("5. Brave Search 只在需要联网时执行一次 LLM Context 查询。")
                }
            }
            .navigationTitle("LireAI")
            .task { reloadSlots() }
        }
    }

    private func reloadSlots() {
        slotIDs = LireKeychain.slotIDs
        activeID = LireKeychain.activeID
    }
}

private struct APIKeySlotSection: View {
    let id: String
    let number: Int
    let isPrimary: Bool
    let isActive: Bool
    let didChange: () -> Void

    @State private var key = ""
    @State private var saved = false
    @State private var status = "未配置"
    @State private var testing = false
    @State private var confirmingDelete = false
    @State private var error: String?

    var body: some View {
        Section {
            HStack {
                Label(
                    saved ? "Key 已保存" : "尚未配置",
                    systemImage: saved ? "checkmark.circle.fill" : "key"
                )
                .foregroundStyle(saved ? Color.green : Color.secondary)

                Spacer()

                if isActive, saved {
                    Text("当前使用")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }

            SecureField(saved ? "输入新 Key 以替换" : "输入 API Key", text: $key)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            HStack(spacing: 12) {
                Button(saved ? "保存新 Key" : "保存 Key") { saveKey() }
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(testing ? "测试中…" : "测试连接") {
                    Task { await testConnection() }
                }
                .buttonStyle(.bordered)
                .disabled(!saved || testing)
            }

            LabeledContent("API 状态", value: status)

            if saved, !isActive {
                Button("设为当前使用的 Key") {
                    LireKeychain.setActive(id)
                    didChange()
                }
            }

            if !isPrimary {
                Button("删除此 Key", role: .destructive) {
                    confirmingDelete = true
                }
            }
        } header: {
            Text("Mistral API Key \(number)")
        } footer: {
            if isPrimary {
                Text("第一个 Key 为主 Key，不能删除。")
            }
        }
        .task(id: id) {
            saved = LireKeychain.load(id: id) != nil
            status = saved ? "未测试" : "未配置"
        }
        .confirmationDialog(
            "确定删除这个 Mistral API Key 吗？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteKey() }
            Button("取消", role: .cancel) {}
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )
        ) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func saveKey() {
        do {
            try LireKeychain.save(
                key.trimmingCharacters(in: .whitespacesAndNewlines),
                id: id
            )
            saved = true
            key = ""
            status = "未测试"
            if LireKeychain.load(id: LireKeychain.activeID) == nil {
                LireKeychain.setActive(id)
            }
            didChange()
            Task { await testConnection() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteKey() {
        do {
            try LireKeychain.delete(id: id)
            didChange()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func testConnection() async {
        guard !testing else { return }
        testing = true
        status = "测试中…"
        do {
            guard let savedKey = LireKeychain.load(id: id) else {
                throw LireError.missingKey
            }
            try await LireClient.testKey(savedKey)
            status = "已连接"
        } catch {
            status = "连接失败"
            self.error = error.localizedDescription
        }
        testing = false
    }
}

private struct BraveAPIKeySection: View {
    @State private var key = ""
    @State private var saved = false
    @State private var status = "未配置"
    @State private var testing = false
    @State private var confirmingDelete = false
    @State private var error: String?

    var body: some View {
        Section {
            Label(
                saved ? "Key 已保存" : "尚未配置",
                systemImage: saved ? "checkmark.circle.fill" : "key"
            )
            .foregroundStyle(saved ? Color.green : Color.secondary)

            SecureField(saved ? "输入新 Key 以替换" : "输入 Brave Search API Key", text: $key)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            HStack(spacing: 12) {
                Button(saved ? "保存新 Key" : "保存 Key") { saveKey() }
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(testing ? "测试中…" : "测试连接") {
                    Task { await testConnection() }
                }
                .buttonStyle(.bordered)
                .disabled(!saved || testing)
            }

            LabeledContent("API 状态", value: status)

            if saved {
                Button("删除 Brave Search Key", role: .destructive) {
                    confirmingDelete = true
                }
            }
        } header: {
            Text("Brave Search API Key")
        } footer: {
            Text("使用 Search 套餐的 LLM Context API。测试连接会消耗一次最小查询请求。")
        }
        .task {
            saved = BraveKeychain.load() != nil
            status = saved ? "未测试" : "未配置"
        }
        .confirmationDialog(
            "确定删除 Brave Search API Key 吗？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteKey() }
            Button("取消", role: .cancel) {}
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )
        ) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func saveKey() {
        do {
            try BraveKeychain.save(key)
            key = ""
            saved = true
            status = "未测试"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteKey() {
        do {
            try BraveKeychain.delete()
            key = ""
            saved = false
            status = "未配置"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func testConnection() async {
        guard !testing else { return }
        testing = true
        status = "测试中…"
        do {
            guard let savedKey = BraveKeychain.load() else {
                throw LireError.missingBraveKey
            }
            try await BraveSearchClient.testKey(savedKey)
            status = "已连接"
        } catch {
            status = "连接失败"
            self.error = error.localizedDescription
        }
        testing = false
    }
}
