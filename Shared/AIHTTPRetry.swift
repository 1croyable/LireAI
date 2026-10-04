import Foundation

enum AIHTTPRetry {
    static func send(_ request: URLRequest, using session: URLSession, retryUnavailable: Bool,
                     retryGroqErrors: Bool = false,
                     wait: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws -> (Data, URLResponse) {
        let retries = retryGroqErrors ? 3 : (retryUnavailable ? 2 : 0)
        for attempt in 0...retries {
            try Task.checkCancellation()
            let result = try await session.data(for: request)
            guard attempt < retries, let response = result.1 as? HTTPURLResponse else { return result }
            let status = response.statusCode
            let recoverable = retryGroqErrors
                ? [429, 500, 502, 503].contains(status) || (status == 400 && generatedJSONFailure(result.0))
                : retryUnavailable && status == 503
            guard recoverable else { return result }
            let delay = pow(2.0, Double(attempt)) + Double.random(in: 0...0.25)
            let retryAfter = retryDelay(response) ?? 0
            guard retryAfter <= 60 else { return result }
            try await wait(max(delay, retryAfter))
        }
        throw URLError(.badServerResponse)
    }

    private static func generatedJSONFailure(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return false }
        if error["code"] as? String == "json_validate_failed" { return true }
        let message = (error["message"] as? String ?? "").lowercased()
        return message.contains("failed to generate json") || message.contains("generated json does not match")
    }

    private static func retryDelay(_ response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
