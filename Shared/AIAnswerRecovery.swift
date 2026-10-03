import Foundation

enum AIAnswerRecovery {
    static func run<Value>(generate: () async throws -> Value?,
                           retryable: (Error) -> Bool,
                           failure: () -> Error) async throws -> Value {
        for attempt in 0...3 {
            try Task.checkCancellation()
            let value: Value?
            do { value = try await generate() }
            catch {
                try Task.checkCancellation()
                guard attempt < 3, retryable(error) else { throw error }
                continue
            }
            try Task.checkCancellation()
            if let value { return value }
            if attempt == 3 { throw failure() }
        }
        throw failure()
    }
}
