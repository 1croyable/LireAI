import Foundation

enum FrenchPartOfSpeech {
    static func abbreviation(_ value: String) -> String {
        let parts = value.components(separatedBy: " / ")
        if parts.count > 1 { return parts.map { abbreviation($0) }.joined(separator: " / ") }
        let text = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("n.") || ["adj.", "adv.", "v.", "v.tr.", "v.intr.", "v.pron.", "loc.", "prép.", "pron.", "conj.", "interj."].contains(text) { return text }
        if text.contains("locution") || text.contains("短语") || text.contains("词组") { return "loc." }
        if text.contains("adverbe") || text.contains("副词") { return "adv." }
        if text.contains("adjectif") || text.contains("形容词") { return "adj." }
        if text.contains("verbe") || text.contains("动词") {
            if text.contains("pronominal") || text.contains("代词式") || text.contains("自反") { return "v.pron." }
            if text.contains("intransitif") || text.contains("不及物") { return "v.intr." }
            if text.contains("transitif") || text.contains("及物") { return "v.tr." }
            return "v."
        }
        if text.contains("pronom") || text.contains("代词") { return "pron." }
        if text.contains("préposition") || text.contains("介词") { return "prép." }
        if text.contains("nom") || text.contains("名词") {
            if text.contains("féminin") || text.contains("阴性") { return "n.f." }
            if text.contains("masculin") || text.contains("阳性") { return "n.m." }
            return "n."
        }
        if text.contains("conjonction") || text.contains("连词") { return "conj." }
        if text.contains("interjection") || text.contains("感叹词") { return "interj." }
        return value
    }
}
