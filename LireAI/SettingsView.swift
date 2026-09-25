import SwiftUI

struct SettingsView: View {
    @State private var key = ""
    @State private var saved = false
    @State private var status = "未配置"
    @State private var testing = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var confirmingSave = false
    @State private var replacingKey = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Mistral API Key") {
                    if saved {
                        Label("Key 已保存", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    SecureField(saved ? "输入新 Key 以替换" : "输入 API Key", text: $key)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack(spacing: 16) {
                        Button(saved ? "保存新 Key" : "保存 Key") {
                            replacingKey = saved
                            confirmingSave = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Spacer()

                        Button("删除 Key", role: .destructive) {
                            confirmingDelete = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(!saved)
                    }
                    .alert(
                        replacingKey ? "确定使用新的 Mistral API Key 替换当前 Key 吗？" : "确定保存这个 Mistral API Key 吗？",
                        isPresented: $confirmingSave
                    ) {
                        Button("取消", role: .cancel) {}
                        Button("保存") {
                            do {
                                try LireKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                                saved = true
                                key = ""
                                status = "测试中…"
                                Task { await testConnection() }
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
                Section("API 状态") {
                    LabeledContent("连接", value: status)
                    Button(testing ? "测试中…" : "测试连接") {
                        Task { await testConnection() }
                    }
                    .disabled(!saved || testing)
                }
                Section("使用说明") {
                    Text("1. 在书库中导入无 DRM 的 EPUB。")
                    Text("2. 打开书籍，长按选中文字，点击“AI 查找”。")
                    Text("3. 在弹出的解释页继续自由提问。")
                }
            }
            .navigationTitle("LireAI")
            .task {
                saved = LireKeychain.load() != nil
                status = saved ? "测试中…" : "未配置"
                if saved { await testConnection() }
            }
            .confirmationDialog("确定删除 Mistral API Key 吗？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    do {
                        try LireKeychain.delete()
                        saved = false
                        key = ""
                        status = "未配置"
                    } catch { self.error = error.localizedDescription }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("提示", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func testConnection() async {
        guard !testing else { return }
        testing = true
        status = "测试中…"
        do {
            guard let savedKey = LireKeychain.load() else { throw LireError.missingKey }
            try await LireClient.testKey(savedKey)
            status = "已连接"
        } catch {
            status = "连接失败"
            self.error = error.localizedDescription
        }
        testing = false
    }
}
