import Foundation

enum AIHTTPRetry {
    static func send(_ request: URLRequest, using session: URLSession, retryUnavailable: Bool,
                     wait: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws -> (Data, URLResponse) {
        for attempt in 0...2 {
            try Task.checkCancellation()
            let result = try await session.data(for: request)
            guard retryUnavailable, (result.1 as? HTTPURLResponse)?.statusCode == 503, attempt < 2 else { return result }
            try await wait(pow(2.0, Double(attempt)) + Double.random(in: 0...0.25))
        }
        throw URLError(.badServerResponse)
    }
}
