import Foundation

enum AIModelFilter {
    static func supportsTextChat(_ model: [String: Any]) -> Bool {
        guard let identifier = model["id"] as? String else { return false }
        if let capabilities = model["capabilities"] as? [String: Any],
           let chat = capabilities["completion_chat"] as? Bool, !chat { return false }
        let architecture = model["architecture"] as? [String: Any]
        if let output = (architecture?["output_modalities"] ?? model["output_modalities"]) as? [String] {
            let types = Set(output.map { $0.lowercased() })
            if !types.contains("text") || !types.isDisjoint(with: ["image", "audio", "video", "embeddings"]) { return false }
        }
        let id = identifier.lowercased()
        let nonChat = ["embedding", "embed-", "-embed", "whisper", "transcrib", "translat-", "-tts", "speech",
                       "audio", "image", "imagen", "dall-e", "video", "veo-", "rerank", "moderation", "ocr", "-live", "realtime"]
        return !nonChat.contains(where: id.contains)
    }
}
