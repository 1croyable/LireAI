import Foundation

struct LireAnswer: Decodable, Identifiable {
    struct Core: Decodable {
        struct Sense: Decodable {
            let partOfSpeech: String?
            let collocations: [String]?
            let usageNote: String?
            let translationsZh: [String]?
            let definitionFr: String?
            let exampleFr: String?
            let exampleZh: String?

            enum CodingKeys: String, CodingKey {
                case partOfSpeech = "part_of_speech"
                case collocations
                case usageNote = "usage_note"
                case translationsZh = "translations_zh"
                case definitionFr = "definition_fr"
                case exampleFr = "example_fr"
                case exampleZh = "example_zh"
            }
        }

        let display: String?
        let lemma: String?
        let partOfSpeech: String?
        let morphology: String?
        let senses: [Sense]?
        let translationsZh: [String]?
        let definitionFr: String?
        let exampleFr: String?
        let exampleZh: String?

        enum CodingKeys: String, CodingKey {
            case display
            case lemma
            case morphology
            case senses

            case partOfSpeech = "part_of_speech"
            case translationsZh = "translations_zh"
            case definitionFr = "definition_fr"
            case exampleFr = "example_fr"
            case exampleZh = "example_zh"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            display = try values.decodeIfPresent(String.self, forKey: .display)
            lemma = try values.decodeIfPresent(String.self, forKey: .lemma)
            partOfSpeech = try values.decodeIfPresent(String.self, forKey: .partOfSpeech)
            if let text = try? values.decode(String.self, forKey: .morphology) {
                morphology = text
            } else if let list = try? values.decode([String].self, forKey: .morphology) {
                morphology = list.joined(separator: "；")
            } else if let fields = try? values.decode([String: String].self, forKey: .morphology) {
                morphology = fields.keys.sorted().map { "\($0)：\(fields[$0]!)" }.joined(separator: "；")
            } else { morphology = nil }
            senses = try values.decodeIfPresent([Sense].self, forKey: .senses)
            translationsZh = try values.decodeIfPresent([String].self, forKey: .translationsZh)
            definitionFr = try values.decodeIfPresent(String.self, forKey: .definitionFr)
            exampleFr = try values.decodeIfPresent(String.self, forKey: .exampleFr)
            exampleZh = try values.decodeIfPresent(String.self, forKey: .exampleZh)
        }

        var dictionaryForm: String {
            let value = (lemma ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n").first ?? ""
            let expression = value.components(separatedBy: " · ").first ?? value
            return expression.replacingOccurrences(
                of: #"\s*[（(](?:n\.\s*[mf]|nom\s|名词|形容词|adjectif|verbe)[^）)]*[）)]\s*$"#,
                with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var displayedSenses: [Sense] {
            if let senses, !senses.isEmpty { return senses }
            return [Sense(
                partOfSpeech: partOfSpeech,
                collocations: nil,
                usageNote: nil,
                translationsZh: translationsZh,
                definitionFr: definitionFr,
                exampleFr: exampleFr,
                exampleZh: exampleZh
            )]
        }
    }

    struct Extra: Decodable, Identifiable {
        let title: String
        let content: String

        var id: String {
            title + content
        }
    }

    struct Block: Decodable, Identifiable {
        let id = UUID()
        let type: String
        let text: String?
        let core: Core?
        let contextNote: String?
        let extras: [Extra]?
        let tags: [String]?

        enum CodingKeys: String, CodingKey {
            case type, text, core, extras, tags
            case contextNote = "context_note"
        }

        var conversationText: String {
            if type == "markdown" { return text ?? "" }
            return LireAnswer(type: "vocabulary", core: core, translation: nil,
                              note: nil, content: nil, contextNote: contextNote,
                              extras: extras).conversationText
        }
    }

    let type: String
    var blocks: [Block]? = nil

    let core: Core?

    let translation: String?
    let note: String?
    let content: String?

    let contextNote: String?
    let extras: [Extra]?

    let id = UUID()

    enum CodingKeys: String, CodingKey {
        case type
        case blocks
        case core
        case translation
        case note
        case content
        case extras

        case contextNote = "context_note"
    }

    var plainText: String {
        if type == "response" { return (blocks ?? []).map(\.conversationText).joined(separator: "\n\n") }
        return translation
        ?? content
        ?? core?.displayedSenses.flatMap { $0.translationsZh ?? [] }.joined(separator: "；")
        ?? core?.translationsZh?.joined(separator: "；")
        ?? ""
    }

    var conversationText: String {
        if type == "response" { return (blocks ?? []).map(\.conversationText).joined(separator: "\n\n") }
        if type == "translation" {
            return [translation, note]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        if type == "vocabulary", let core {
            var parts: [String] = []
            let heading = [core.display, core.lemma, core.partOfSpeech]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !heading.isEmpty { parts.append(heading) }
            if let morphology = core.morphology, !morphology.isEmpty {
                parts.append("词形：\(morphology)")
            }
            for (index, sense) in core.displayedSenses.enumerated() {
                let prefix = core.displayedSenses.count > 1 ? "\(index + 1). " : ""
                if let meanings = sense.translationsZh, !meanings.isEmpty {
                    parts.append(prefix + [sense.partOfSpeech ?? core.partOfSpeech, meanings.joined(separator: "；")].compactMap { $0 }.joined(separator: " · "))
                }
                if let definition = sense.definitionFr, !definition.isEmpty {
                    parts.append("法语解释：\(definition)")
                }
                if let example = sense.exampleFr, !example.isEmpty {
                    parts.append("例句：\(example)")
                }
                if let exampleZh = sense.exampleZh, !exampleZh.isEmpty {
                    parts.append("例句翻译：\(exampleZh)")
                }
                if let collocations = sense.collocations, !collocations.isEmpty {
                    parts.append("搭配：" + collocations.joined(separator: "；"))
                }
                if let usageNote = sense.usageNote, !usageNote.isEmpty { parts.append("补充：" + usageNote) }
            }
            if let contextNote, !contextNote.isEmpty { parts.append("语境：\(contextNote)") }
            for extra in extras ?? [] { parts.append("\(extra.title)：\(extra.content)") }
            return parts.joined(separator: "\n")
        }
        return translation ?? content ?? note ?? plainText
    }

    var displayedBlocks: [Block] {
        if type == "response" { return blocks ?? [] }
        if type == "vocabulary" {
            return [Block(type: "vocabulary", text: nil, core: core,
                          contextNote: contextNote, extras: extras, tags: nil)]
        }
        return [Block(type: "markdown", text: translation ?? content ?? "", core: nil,
                      contextNote: nil, extras: nil, tags: nil)]
    }

    var isValid: Bool {
        if type == "response" {
            guard let blocks, !blocks.isEmpty else { return false }
            return blocks.allSatisfy { block in
                if block.type == "markdown" { return Self.hasText(block.text) }
                return block.type == "vocabulary" && Self.validCore(block.core)
            }
        }
        if type == "vocabulary" { return Self.validCore(core) }
        return Self.hasText(translation ?? content)
    }

    private static func hasText(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private static func validCore(_ core: Core?) -> Bool {
        guard let core, hasText(core.display), hasText(core.lemma),
              !core.displayedSenses.isEmpty else { return false }
        return core.displayedSenses.allSatisfy {
            hasText($0.partOfSpeech ?? core.partOfSpeech) &&
            !($0.translationsZh ?? []).isEmpty &&
            ($0.translationsZh ?? []).allSatisfy { hasText($0) } &&
            hasText($0.definitionFr) && hasText($0.exampleFr) && hasText($0.exampleZh)
        }
    }

    var validationIssue: String {
        for block in displayedBlocks where block.type == "vocabulary" {
            guard let core = block.core else { return "词汇卡缺少 core" }
            if !Self.hasText(core.display) { return "词汇卡缺少 display" }
            if !Self.hasText(core.lemma) { return "词汇卡缺少 lemma" }
            for (index, sense) in core.displayedSenses.enumerated() {
                let required = [("part_of_speech", sense.partOfSpeech ?? core.partOfSpeech),
                                ("definition_fr", sense.definitionFr), ("example_fr", sense.exampleFr),
                                ("example_zh", sense.exampleZh)]
                if let field = required.first(where: { !Self.hasText($0.1) }) {
                    return "词义 \(index + 1) 缺少 \(field.0)"
                }
                if (sense.translationsZh ?? []).isEmpty || !(sense.translationsZh ?? []).allSatisfy({ Self.hasText($0) }) {
                    return "词义 \(index + 1) 缺少 translations_zh"
                }
            }
        }
        return "回答块为空、类型错误或未符合本轮格式"
    }

    func matches(selectionKind: String?, selection: String?) -> Bool {
        guard isValid else { return false }
        let markers = ["SOURCE_TEXT_BEGIN", "SOURCE_TEXT_END", "SOURCE_FRAGMENT_",
                       "LATEST_REQUEST_BEGIN", "WEB_CONTEXT_BEGIN"]
        guard !markers.contains(where: conversationText.contains) else { return false }
        if selectionKind == "lookup" {
            if type == "translation" { return true }
            return type == "vocabulary" && Self.hasText(core?.display)
        }
        if selectionKind == "translation" { return type == "translation" }
        if selectionKind == "vocabulary", let selection {
            return displayedBlocks.contains {
                $0.type == "vocabulary" && $0.core?.display?.trimmingCharacters(in: .whitespacesAndNewlines) == selection
            }
        }
        return type == "response"
    }

    static func decodeJSON(_ text: String, selection: String? = nil) -> LireAnswer? {
        guard let data = text.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let selection {
            if object["type"] as? String == "translation" { object.removeValue(forKey: "note") }
            if object["type"] as? String == "vocabulary", var core = object["core"] as? [String: Any] {
                core["display"] = selection
                object["core"] = core
            }
        }
        guard let normalized = try? JSONSerialization.data(withJSONObject: object),
              let answer = try? JSONDecoder().decode(LireAnswer.self, from: normalized),
              ["translation", "vocabulary", "chat", "response"].contains(answer.type), answer.isValid else { return nil }
        return answer
    }

    static let cardFormatInstructions = """
    A vocabulary object has type="vocabulary", core={display,lemma,morphology,senses}, optional context_note, extras and tags. display and lemma are strings; lemma contains only the dictionary expression, never a part of speech. morphology is optional and contains inflection information only, never a part of speech. Each sense has part_of_speech (French abbreviation: n.f., n.m., adj., adv., v., loc., etc.), translations_zh (array of Chinese meanings for that sense), definition_fr, example_fr, example_zh (strings), optional collocations (array of strings) and usage_note (string). extras, if used, is an array of objects with title and content. No lists or bullets inside field strings. Optional supplements belong to their respective sense when possible and may be omitted. Write explanatory notes (usage_note, context_note and extras prose) in Simplified Chinese; collocations remain in French.
    Common part_of_speech labels include, but are not limited to: n.m. (masculine noun), n.f. (feminine noun), n. (noun), adj. (adjective), adv. (adverb), v. (verb), v.tr. (transitive verb), v.intr. (intransitive verb), v.pron. (pronominal verb), loc. (expression), pron. (pronoun), prép. (preposition), conj. (conjunction), interj. (interjection).
    """

    static let lookupFormatInstructions = """
    Return a single JSON object, no code fences or prose.
    Vocabulary: type="vocabulary" with the card fields below.
    Translation: type="translation", translation=the full Chinese translation. No other content.
    """ + "\n" + cardFormatInstructions

    static let formatInstructions = """
    Return only a JSON object with type="response" and blocks (ordered array).
    Each block is either type="markdown" with text, or a vocabulary object with the card fields below. Use separate cards for independent French expressions. Prose and cards can occur in any order; opening and closing prose are optional. Do not output code fences.
    """ + "\n" + cardFormatInstructions

}
