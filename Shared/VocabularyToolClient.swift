import Foundation
import Security

struct VocabularyExportCard: Codable, Equatable {
    let front: String
    let back: String
    let type: VocabularyExportType
}

enum VocabularyExportType: String, Codable, CaseIterable, Identifiable {
    case active, passive
    var id: String { rawValue }
}

enum VocabularyToolError: LocalizedError {
    case invalidDomain, loginRequired, credentials, invalidCards, invalidResponse
    case server(String)
    var errorDescription: String? {
        switch self {
        case .invalidDomain: "请先在设置中填写有效的背单词工具域名。"
        case .loginRequired: "请登录背单词工具后提交。"
        case .credentials: "用户名或密码不正确，请重新输入。"
        case .invalidCards: "请选择 1–1000 张便签，正面须为 1–255 个字符，背面不能为空。"
        case .invalidResponse: "服务返回的结果无法确认，请检查工具域名和接口配置。"
        case .server(let text): text
        }
    }
}

private final class VocabularyToolRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
protocol VocabularyTokenStorage {
    func load(for domain: String) throws -> String?
    func save(_ token: String, for domain: String) throws
    func remove(for domain: String) throws
}

@MainActor
private final class VocabularyTokenKeychain: VocabularyTokenStorage {
    private func query(_ domain: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "LireAI.VocabularyTool.session",
         kSecAttrAccount as String: domain,
         kSecAttrSynchronizable as String: false]
    }
    func load(for domain: String) throws -> String? {
        var request = query(domain)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            try remove(for: domain)
            return nil
        }
        return token
    }
    func save(_ token: String, for domain: String) throws {
        var request = query(domain)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            request.merge(attributes) { _, new in new }
            try check(SecItemAdd(request as CFDictionary, nil))
        } else { try check(status) }
    }
    func remove(for domain: String) throws {
        let status = SecItemDelete(query(domain) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw VocabularyToolError.server("无法访问设备上的登录凭据，请稍后重试（\(status)）。")
        }
    }
}

@MainActor
final class VocabularyToolClient {
    static let shared = VocabularyToolClient()
    private let session: URLSession
    private let tokenStorage: any VocabularyTokenStorage

    init(session: URLSession? = nil, tokenStorage: (any VocabularyTokenStorage)? = nil) {
        self.tokenStorage = tokenStorage ?? VocabularyTokenKeychain()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = session ?? URLSession(configuration: configuration, delegate: VocabularyToolRedirects(), delegateQueue: nil)
    }
    static func baseURL(_ domain: String) throws -> URL {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VocabularyToolError.invalidDomain }
        let input = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: input),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw VocabularyToolError.invalidDomain }
        if components.path.isEmpty || components.path == "/" { components.path = "/api" }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw VocabularyToolError.invalidDomain }
        return url
    }
    func login(domain: String, username: String, password: String) async throws {
        let base = try Self.baseURL(domain)
        let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password, "return_token": true])
        let (data, status) = try await post(base.appendingPathComponent("user/login"), body: body)
        if status == 401 { try tokenStorage.remove(for: base.absoluteString); throw VocabularyToolError.credentials }
        try check(status, data: data)
        struct Login: Decodable { let token: String }
        guard let response = try? JSONDecoder().decode(Login.self, from: data), !response.token.isEmpty else {
            throw VocabularyToolError.invalidResponse
        }
        try tokenStorage.save(response.token, for: base.absoluteString)
    }
    func submit(domain: String, cards: [VocabularyExportCard]) async throws -> Int {
        let base = try Self.baseURL(domain)
        guard (1...1000).contains(cards.count), cards.allSatisfy({
            let front = $0.front.trimmingCharacters(in: .whitespacesAndNewlines)
            return !front.isEmpty && front.utf16.count <= 255 && !$0.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { throw VocabularyToolError.invalidCards }
        guard let token = try tokenStorage.load(for: base.absoluteString) else { throw VocabularyToolError.loginRequired }
        let body = try JSONEncoder().encode(cards)
        let (data, status) = try await post(base.appendingPathComponent("notes/import"), body: body, token: token)
        if status == 401 || status == 403 {
            try tokenStorage.remove(for: base.absoluteString)
            throw VocabularyToolError.loginRequired
        }
        try check(status, data: data)
        struct Imported: Decodable { let id: Int; let word_count: Int }
        guard let imported = try? JSONDecoder().decode(Imported.self, from: data), imported.id > 0,
              imported.word_count > 0, imported.word_count <= cards.count else {
            throw VocabularyToolError.invalidResponse
        }
        return imported.word_count
    }
    private func post(_ url: URL, body: Data, token: String? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VocabularyToolError.invalidResponse }
        return (data, http.statusCode)
    }
    private func check(_ status: Int, data: Data) throws {
        guard (200...299).contains(status) else {
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = root?["error"] as? String ?? root?["message"] as? String
            let message = status == 404 ? "未找到接口，请检查工具域名及 /api 路由配置。" : "背单词工具请求失败（HTTP \(status)）。"
            throw VocabularyToolError.server(message + (detail.map { "\n" + $0 } ?? ""))
        }
    }
}
