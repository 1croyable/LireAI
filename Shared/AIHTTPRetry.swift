import Foundation

enum AIHTTPRetry {
    static func send(_ request: URLRequest, using session: URLSession, retryUnavailable: Bool,
                     retryGroqErrors: Bool = false,
                     reduceOversizedRequest: ((URLRequest) -> URLRequest?)? = nil,
                     wait: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws -> (Data, URLResponse) {
        let retries = retryGroqErrors ? 3 : (retryUnavailable ? 2 : 0)
        var currentRequest = request
        for attempt in 0...retries {
            try Task.checkCancellation()
            let result = try await session.data(for: currentRequest)
            guard attempt < retries, let response = result.1 as? HTTPURLResponse else { return result }
            let status = response.statusCode
            if status == 413, let smaller = reduceOversizedRequest?(currentRequest),
               let oldBody = currentRequest.httpBody, let newBody = smaller.httpBody,
               newBody.count < oldBody.count {
                currentRequest = smaller
                continue
            }
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

/// Only shortens retrieved evidence; quoted text, conversation and the current question stay intact.
enum AIWebContext {
    static func bounded(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        let suffix = "\n[Search evidence shortened to fit the request.]"
        guard limit >= suffix.utf8.count else { return "" }
        let budget = max(0, limit - suffix.utf8.count)
        var prefix = ""
        var size = 0
        for character in text {
            let bytes = String(character).utf8.count
            guard size + bytes <= budget else { break }
            prefix.append(character)
            size += bytes
        }
        return prefix + suffix
    }

    static func compactRequest(_ request: URLRequest) -> URLRequest? {
        guard let body = request.httpBody,
              var payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              var messages = payload["messages"] as? [[String: String]] else { return nil }
        var changed = false
        for index in messages.indices where messages[index]["role"] == "user" {
            guard let content = messages[index]["content"],
                  let start = content.range(of: "\nWEB_CONTEXT_BEGIN\n"),
                  let end = content.range(of: "\nWEB_CONTEXT_END", range: start.upperBound..<content.endIndex) else { continue }
            let evidence = String(content[start.upperBound..<end.lowerBound])
            let budget = max(512, evidence.utf8.count / 2)
            guard budget < evidence.utf8.count else { continue }
            messages[index]["content"] = String(content[..<start.upperBound])
                + bounded(evidence, toUTF8Bytes: budget) + content[end.lowerBound...]
            changed = true
        }
        guard changed else { return nil }
        payload["messages"] = messages
        guard let data = try? JSONSerialization.data(withJSONObject: payload), data.count < body.count else { return nil }
        var compact = request
        compact.httpBody = data
        return compact
    }
}
