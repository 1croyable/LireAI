import Foundation

enum FragmentOrder {
    static func pendingFirst(total: (Double?, Double?), positions: (Int?, Int?),
                             sameResource: Bool, progression: (Double?, Double?)) -> Bool {
        if let a = total.0, let b = total.1, a != b { return a < b }
        if let a = positions.0, let b = positions.1, a != b { return a < b }
        if sameResource, let a = progression.0, let b = progression.1, a != b { return a < b }
        return true
    }
}

/// Retains the page boundary without trying to reconstruct French locally.
struct LireSource {
    let fragments: [String]

    init(text: String, fragments: [String]? = nil) {
        self.fragments = (fragments ?? [text]).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    var text: String { fragments.joined(separator: " ") }

    var context: String {
        if fragments.count == 2 {
            return """
            SOURCE_FRAGMENT_1_BEGIN
            \(fragments[0])
            SOURCE_FRAGMENT_1_END

            SOURCE_FRAGMENT_2_BEGIN
            \(fragments[1])
            SOURCE_FRAGMENT_2_END
            """
        }
        return """
        SOURCE_TEXT_BEGIN
        \(text)
        SOURCE_TEXT_END
        """
    }

    var prompt: String {
        let boundary = fragments.count == 2
            ? "The fragments are adjacent in reading order and may split a sentence or word. Do not invent missing text. "
            : ""
        return context + "\n\n" + boundary
            + "New quoted lookup: return one vocabulary card for a standalone French word or fixed expression; for a sentence, clause or passage, return only its complete Chinese translation, without vocabulary cards or discussion. Do not invent missing text or an unidentified dictionary entry."
    }
}
