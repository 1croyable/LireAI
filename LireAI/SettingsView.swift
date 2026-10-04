import SwiftUI

private enum APIProviderTab: String, CaseIterable, Identifiable {
    case ai = "API"
    case brave = "Brave Search"
    var id: String { rawValue }
}

struct SettingsView: View {
    @State private var tab: APIProviderTab = .ai
    @State private var provider: AIProvider = AIKeyStore.activeProvider ?? .mistral
    @State private var slotIDs: [String] = []
    @State private var activeProvider: AIProvider?
    @State private var activeID: String?
    @State private var configuredCount = 0
    @State private var model = ""
    @State private var models: [String] = []
    @State private var refreshing = false
    @State private var error: String?
    @AppStorage("LireAI.VocabularyTool.domain") private var vocabularyDomain = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("API 类型", selection: $tab) {
                        ForEach(APIProviderTab.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
                if tab == .ai {
                    Section {
                        Picker("服务商", selection: $provider) {
                            ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                        }
                        LabeledContent("当前使用", value: activeProvider?.title ?? "未设置")
                    }
                    Section {
                        TextField("输入模型 ID，或获取模型目录", text: $model)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onChange(of: model) { _, value in AIKeyStore.setModel(value, for: provider) }
                        if !models.isEmpty {
                            Picker("模型目录", selection: $model) {
                                if !models.contains(model) { Text(model.isEmpty ? "请选择" : model).tag(model) }
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        Button(refreshing ? "获取中…" : "获取模型目录") { Task { await fetchModels() } }
                            .disabled(refreshing || !slotIDs.contains(where: { AIKeyStore.load(provider: provider, id: $0) != nil }))
                    } header: { Text("模型") } footer: {
                        Text(slotIDs.contains(where: { AIKeyStore.load(provider: provider, id: $0) != nil })
                             ? "模型目录不代表免费额度或生成权限；以该 Key 的账户权限与计费规则为准。"
                             : "先保存此服务商的 API Key，再获取模型目录。")
                    }
                    ForEach(Array(slotIDs.enumerated()), id: \.element) { index, id in
                        APIKeySlotSection(provider: provider, id: id, number: index + 1,
                                          isActive: provider == activeProvider && id == activeID,
                                          canSwitch: configuredCount > 1, didChange: reload)
                    }
                    Section {
                        Button { AIKeyStore.createSlot(for: provider); reload() } label: {
                            Label("添加 \(provider.title) API Key", systemImage: "plus.circle.fill")
                        }
                    }
                } else { BraveAPIKeySection() }
                Section {
                    TextField("工具域名（可留空）", text: $vocabularyDomain)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("背单词工具") } footer: {
                    Text("填写背单词工具域名。便签提交时会按需登录，并保存到该工具。")
                }
                Section("使用说明") {
                    Text("选中文字后点击“AI 查找”：词汇显示卡片，句段直接翻译。")
                    Text("在解释页继续提问，可自然讨论并查看相关词汇卡。")
                    Text("各服务商可以保存多个 Key，全局只使用一个。")
                    Text("Brave Search 负责讨论时需要的联网查询。")
                }
            }
            .navigationTitle("LireAI")
            .task { reload(); model = AIKeyStore.model(for: provider) }
            .onChange(of: provider) { _, value in
                models = []
                reload()
                model = AIKeyStore.model(for: value)
            }
            .alert("提示", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func reload() {
        slotIDs = AIKeyStore.slotIDs(for: provider)
        activeProvider = AIKeyStore.activeProvider
        activeID = AIKeyStore.activeID
        configuredCount = AIKeyStore.configuredCount
    }
    private func fetchModels() async {
        let selectedProvider = provider
        guard let id = slotIDs.first(where: { $0 == activeID && provider == activeProvider }) ?? slotIDs.first(where: { AIKeyStore.load(provider: selectedProvider, id: $0) != nil }),
              let key = AIKeyStore.load(provider: selectedProvider, id: id) else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let found = try await AIModelCatalog.fetch(provider: selectedProvider, key: key)
            guard provider == selectedProvider else { return }
            models = found
        } catch { self.error = error.localizedDescription }
    }
}

private struct APIKeySlotSection: View {
    let provider: AIProvider
    let id: String
    let number: Int
    let isActive: Bool
    let canSwitch: Bool
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
                Label(saved ? "Key 已保存" : "尚未配置", systemImage: saved ? "checkmark.circle.fill" : "key")
                    .foregroundStyle(saved ? Color.green : Color.secondary)
                Spacer()
                if isActive, saved { Text("当前使用").font(.caption.weight(.semibold)).foregroundStyle(.blue) }
            }
            SecureField(saved ? "输入新 Key 以替换" : "输入 API Key", text: $key)
                .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
            HStack(spacing: 12) {
                Button(saved ? "保存新 Key" : "保存 Key") { save() }
                    .buttonStyle(.borderedProminent).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(testing ? "测试中…" : "测试连接") { Task { await test() } }
                    .buttonStyle(.bordered).disabled(!saved || testing)
            }
            LabeledContent("API 状态", value: status)
            if saved, !isActive, canSwitch {
                Button("设为当前使用的 Key") { AIKeyStore.setActive(provider: provider, id: id); didChange() }
            }
            Button("删除此 Key", role: .destructive) { confirmingDelete = true }
        } header: { Text("\(provider.title) API Key \(number)") }
        .task(id: id) { saved = AIKeyStore.load(provider: provider, id: id) != nil; status = saved ? "未测试" : "未配置" }
        .confirmationDialog("确定删除这个 API Key 吗？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try AIKeyStore.delete(provider: provider, id: id); didChange() }
                catch { self.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("提示", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func save() {
        do { try AIKeyStore.save(key, provider: provider, id: id); key = ""; saved = true; status = "未测试"; didChange() }
        catch { self.error = error.localizedDescription }
    }
    private func test() async {
        testing = true
        defer { testing = false }
        do {
            guard let key = AIKeyStore.load(provider: provider, id: id) else { throw LireError.missingKey }
            _ = try await AIModelCatalog.fetch(provider: provider, key: key)
            status = "已连接"
        } catch { status = "连接失败"; self.error = error.localizedDescription }
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
