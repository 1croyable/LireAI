import Foundation
import Security

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case groq, mistral, openai, deepseek
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mistral: "Mistral"
        case .deepseek: "DeepSeek"
        case .openai: "OpenAI"
        case .groq: "Groq"
        }
    }
    var baseURL: URL {
        let value: String
        switch self {
        case .mistral: value = "https://api.mistral.ai/v1/"
        case .deepseek: value = "https://api.deepseek.com/"
        case .openai: value = "https://api.openai.com/v1/"
        case .groq: value = "https://api.groq.com/openai/v1/"
        }
        return URL(string: value)!
    }
    var defaultModel: String { self == .mistral ? "ministral-14b-2512" : "" }
}

struct AIConnection {
    let provider: AIProvider
    let slotID: String
    let key: String
    let model: String
}

enum AIKeyStore {
    private static let defaults = UserDefaults.standard
    private static func slotsKey(_ provider: AIProvider) -> String { "LireAI.API.slots.\(provider.rawValue)" }
    static func slotIDs(for provider: AIProvider) -> [String] {
        migrateMistral()
        return defaults.stringArray(forKey: slotsKey(provider)) ?? []
    }
    private static func migrateMistral() {
        guard !defaults.bool(forKey: "LireAI.API.migrated") else { return }
        let oldSlots = ["primary"] + (defaults.stringArray(forKey: "LireAI.MistralKeySlots") ?? []).filter { $0 != "primary" }
        let slots = oldSlots.filter { load(provider: .mistral, id: $0) != nil || $0 != "primary" }
        defaults.set(slots, forKey: slotsKey(.mistral))
        let oldActive = defaults.string(forKey: "LireAI.ActiveMistralKeySlot") ?? "primary"
        if let active = slots.first(where: { $0 == oldActive && load(provider: .mistral, id: $0) != nil })
            ?? slots.first(where: { load(provider: .mistral, id: $0) != nil }) {
            defaults.set(AIProvider.mistral.rawValue, forKey: "LireAI.API.activeProvider")
            defaults.set(active, forKey: "LireAI.API.activeSlot")
        }
        defaults.set(true, forKey: "LireAI.API.migrated")
    }
    static var activeProvider: AIProvider? {
        migrateMistral()
        return defaults.string(forKey: "LireAI.API.activeProvider").flatMap(AIProvider.init(rawValue:))
    }
    static var activeID: String? { migrateMistral(); return defaults.string(forKey: "LireAI.API.activeSlot") }
    static func model(for provider: AIProvider) -> String {
        defaults.string(forKey: "LireAI.API.model.\(provider.rawValue)") ?? provider.defaultModel
    }
    static func setModel(_ model: String, for provider: AIProvider) {
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "LireAI.API.model.\(provider.rawValue)")
    }
    @discardableResult static func createSlot(for provider: AIProvider) -> String {
        let id = UUID().uuidString
        defaults.set(slotIDs(for: provider) + [id], forKey: slotsKey(provider))
        return id
    }
    static func setActive(provider: AIProvider, id: String) {
        guard slotIDs(for: provider).contains(id), load(provider: provider, id: id) != nil else { return }
        defaults.set(provider.rawValue, forKey: "LireAI.API.activeProvider")
        defaults.set(id, forKey: "LireAI.API.activeSlot")
    }
    static var configuredCount: Int {
        AIProvider.allCases.reduce(0) { total, provider in
            total + slotIDs(for: provider).filter { load(provider: provider, id: $0) != nil }.count
        }
    }
    static func connection() throws -> AIConnection {
        guard let provider = activeProvider, let id = activeID,
              let key = load(provider: provider, id: id) else { throw LireError.missingKey }
        let model = model(for: provider)
        guard !model.isEmpty else { throw LireError.server("请先在设置中选择 \(provider.title) 的模型。") }
        return AIConnection(provider: provider, slotID: id, key: key, model: model)
    }
    private static func query(provider: AIProvider, id: String) -> [String: Any] {
        let service = provider == .mistral ? "LireAI.Mistral" : "LireAI.API.\(provider.rawValue)"
        let account = provider == .mistral ? (id == "primary" ? "mistral-api-key" : "mistral-api-key.\(id)") : id
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account]
    }
    static func load(provider: AIProvider, id: String) -> String? {
        var request = query(provider: provider, id: id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String, provider: AIProvider, id: String) throws {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw LireError.missingKey }
        var request = query(provider: provider, id: id)
        let data = Data(cleaned.utf8)
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(request as CFDictionary, nil)
            guard result == errSecSuccess else { throw LireError.keychain(result) }
        } else if status != errSecSuccess { throw LireError.keychain(status) }
        if activeProvider == nil || configuredCount == 1 { setActive(provider: provider, id: id) }
    }
    static func delete(provider: AIProvider, id: String) throws {
        let wasActive = activeProvider == provider && activeID == id
        let status = SecItemDelete(query(provider: provider, id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LireError.keychain(status) }
        defaults.set(slotIDs(for: provider).filter { $0 != id }, forKey: slotsKey(provider))
        if wasActive {
            defaults.removeObject(forKey: "LireAI.API.activeProvider")
            defaults.removeObject(forKey: "LireAI.API.activeSlot")
            for candidate in AIProvider.allCases {
                if let fallback = slotIDs(for: candidate).first(where: { load(provider: candidate, id: $0) != nil }) {
                    setActive(provider: candidate, id: fallback)
                    break
                }
            }
        }
    }
}

struct AIModelCatalog {
    static func fetch(provider: AIProvider, key: String) async throws -> [String] {
        var request = URLRequest(url: provider.baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LireError.server("\(provider.title) 连接失败，请检查 Key 和账户权限。")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]] else { throw LireError.invalidResponse }
        return models.filter { AIModelFilter.supportsTextChat($0) }.compactMap { $0["id"] as? String }.sorted()
    }
}
