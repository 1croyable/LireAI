import Foundation
import Security

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case gemini, groq, openrouter, mistral
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mistral: "Mistral"
        case .groq: "Groq"
        case .openrouter: "OpenRouter"
        case .gemini: "Gemini"
        }
    }
    var baseURL: URL {
        let value: String
        switch self {
        case .mistral: value = "https://api.mistral.ai/v1/"
        case .groq: value = "https://api.groq.com/openai/v1/"
        case .openrouter: value = "https://openrouter.ai/api/v1/"
        case .gemini: value = "https://generativelanguage.googleapis.com/v1beta/openai/"
        }
        return URL(string: value)!
    }
    var defaultModel: String {
        switch self {
        case .mistral: "ministral-14b-2512"
        case .openrouter: "nvidia/nemotron-3-super-120b-a12b:free"
        case .gemini: "gemini-3.8-flash"
        default: ""
        }
    }
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
        migrate()
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
    private static func migrate() {
        migrateMistral()
        migrateRemovedProviders(in: defaults, removeKeys: { name in
            let status = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "LireAI.API.\(name)"
            ] as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }, keyExists: { provider, id in load(provider: provider, id: id) != nil })
    }
    static func migrateRemovedProviders(in defaults: UserDefaults, removeKeys: (String) -> Bool,
                                        keyExists: (AIProvider, String) -> Bool) {
        guard !defaults.bool(forKey: "LireAI.API.removedProvidersMigrated") else { return }
        var keysRemoved = true
        for name in ["openai", "deepseek"] {
            let removed = removeKeys(name)
            keysRemoved = keysRemoved && removed
            defaults.removeObject(forKey: "LireAI.API.slots.\(name)")
            defaults.removeObject(forKey: "LireAI.API.model.\(name)")
        }
        if let name = defaults.string(forKey: "LireAI.API.activeProvider"),
           AIProvider(rawValue: name) == nil {
            defaults.removeObject(forKey: "LireAI.API.activeProvider")
            defaults.removeObject(forKey: "LireAI.API.activeSlot")
            for provider in AIProvider.allCases {
                let ids = defaults.stringArray(forKey: slotsKey(provider)) ?? []
                if let id = ids.first(where: { keyExists(provider, $0) }) {
                    defaults.set(provider.rawValue, forKey: "LireAI.API.activeProvider")
                    defaults.set(id, forKey: "LireAI.API.activeSlot")
                    break
                }
            }
        }
        // Retry cleanup if Keychain is temporarily unavailable.
        if keysRemoved { defaults.set(true, forKey: "LireAI.API.removedProvidersMigrated") }
    }
    static var activeProvider: AIProvider? {
        migrate()
        return defaults.string(forKey: "LireAI.API.activeProvider").flatMap(AIProvider.init(rawValue:))
    }
    static var activeID: String? { migrate(); return defaults.string(forKey: "LireAI.API.activeSlot") }
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
    static let openRouterCandidates = [
        "nvidia/nemotron-3-super-120b-a12b:free",
        "openai/gpt-oss-120b:free",
        "nvidia/nemotron-3-ultra-550b-a55b:free"
    ]

    static func fetch(provider: AIProvider, key: String, session: URLSession = .shared) async throws -> [String] {
        // The public model catalog cannot validate a Key.
        if provider == .openrouter {
            var keyRequest = URLRequest(url: provider.baseURL.appendingPathComponent("key"))
            keyRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            keyRequest.timeoutInterval = 30
            let (data, response) = try await session.data(for: keyRequest)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw LireError.server("OpenRouter 连接失败，请检查 Key 和账户权限。")
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["data"] is [String: Any] else { throw LireError.invalidResponse }
        }
        var request = URLRequest(url: provider.baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LireError.server("\(provider.title) 连接失败，请检查 Key 和账户权限。")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]] else { throw LireError.invalidResponse }
        let textModels = models.filter { AIModelFilter.supportsTextChat($0) }
        if provider == .openrouter {
            let freeIDs = Set(textModels.compactMap { model -> String? in
                guard let pricing = model["pricing"] as? [String: Any],
                      isZero(pricing["prompt"]), isZero(pricing["completion"]) else { return nil }
                return model["id"] as? String
            })
            return openRouterCandidates.filter { freeIDs.contains($0) }
        }
        return textModels.compactMap { $0["id"] as? String }.sorted()
    }

    private static func isZero(_ value: Any?) -> Bool {
        if let text = value as? String { return Decimal(string: text) == 0 }
        if let number = value as? NSNumber { return number.decimalValue == 0 }
        return false
    }
}
