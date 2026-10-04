import Foundation

struct VocabularyNote: Codable, Identifiable, Equatable {
    let id: UUID
    let requestID: UUID
    let createdAt: Date
    let bookID: UUID
    let bookTitle: String
    let front: String
    let partOfSpeech: String
    let meanings: [String]
    var submittedAt: Date? = nil
    var back: String { [partOfSpeech, meanings.joined(separator: "；")].filter { !$0.isEmpty }.joined(separator: " ") }

    private struct DuplicateKey: Hashable {
        let front: String
        let partOfSpeech: String
        let meanings: [String]
    }
    private var duplicateKey: DuplicateKey {
        let separators = CharacterSet(charactersIn: "；;,，")
        let normalizedMeanings = meanings.flatMap { $0.components(separatedBy: separators) }
            .map(Self.normalize).filter { !$0.isEmpty }
        return DuplicateKey(front: Self.normalize(front),
                            partOfSpeech: Self.normalize(FrenchPartOfSpeech.abbreviation(partOfSpeech)),
                            meanings: Set(normalizedMeanings).sorted())
    }
    nonisolated private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func unique(_ candidates: [VocabularyNote], excluding existing: [VocabularyNote] = []) -> [VocabularyNote] {
        var seen = Set(existing.map(\.duplicateKey))
        return candidates.filter { seen.insert($0.duplicateKey).inserted }
    }
    static func extract(from answer: LireAnswer, requestID: UUID, bookID: UUID,
                        bookTitle: String, date: Date = Date()) -> [VocabularyNote] {
        answer.displayedBlocks.flatMap { block -> [VocabularyNote] in
            guard block.type == "vocabulary", let core = block.core else { return [] }
            let front = core.dictionaryForm
            guard !front.isEmpty else { return [] }
            return core.displayedSenses.compactMap { sense in
                let meanings = (sense.translationsZh ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                guard !meanings.isEmpty else { return nil }
                return VocabularyNote(id: UUID(), requestID: requestID, createdAt: date,
                                      bookID: bookID, bookTitle: bookTitle, front: front,
                                      partOfSpeech: FrenchPartOfSpeech.abbreviation(sense.partOfSpeech ?? core.partOfSpeech ?? ""),
                                      meanings: meanings)
            }
        }
    }
}
