import Foundation
import Combine

@MainActor
final class VocabularyNotesStore: ObservableObject {
    static let shared = VocabularyNotesStore()
    @Published private(set) var notes: [VocabularyNote] = []
    @Published private(set) var storageError: String?
    private let fileURL: URL
    private var loadBlocked = false

    private struct Archive: Codable {
        let version: Int
        let notes: [VocabularyNote]
    }
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VocabularyNotes/notes-v1.json")
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.fileURL))
            guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            notes = archive.notes.sorted { $0.createdAt > $1.createdAt }
        } catch {
            loadBlocked = true
            storageError = "无法读取本地便签，原文件已保留。\n\(error.localizedDescription)"
        }
    }
    func record(_ answer: LireAnswer, requestID: UUID, bookID: UUID, bookTitle: String, date: Date = Date()) {
        guard !loadBlocked, !notes.contains(where: { $0.requestID == requestID }) else { return }
        let added = VocabularyNote.unique(
            VocabularyNote.extract(from: answer, requestID: requestID, bookID: bookID, bookTitle: bookTitle, date: date),
            excluding: notes)
        guard !added.isEmpty else { return }
        notes.insert(contentsOf: added, at: 0)
        notes.sort { $0.createdAt > $1.createdAt }
        retrySave()
    }
    func retrySave() {
        guard !loadBlocked else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Archive(version: 1, notes: notes))
            try data.write(to: fileURL, options: .atomic)
            storageError = nil
        } catch { storageError = "便签尚未写入设备，请重试保存。\n\(error.localizedDescription)" }
    }
    func today(bookID: UUID, now: Date = Date(), calendar: Calendar = .current) -> [VocabularyNote] {
        notes.filter { $0.bookID == bookID && calendar.isDate($0.createdAt, inSameDayAs: now) }
    }
    func days(calendar: Calendar = .current) -> [Date] {
        Set(notes.map { calendar.startOfDay(for: $0.createdAt) }).sorted(by: >)
    }
    func on(_ day: Date, calendar: Calendar = .current) -> [VocabularyNote] {
        notes.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
    }
    func selectedNotes(days: Set<Date>, calendar: Calendar = .current) -> [VocabularyNote] {
        notes.filter { days.contains(calendar.startOfDay(for: $0.createdAt)) }
    }
    func importPayload(days: Set<Date>, calendar: Calendar = .current) throws -> String {
        try VocabularyNote.importPayload(selectedNotes(days: days, calendar: calendar))
    }
}
