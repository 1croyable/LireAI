import Combine
import Foundation
import ReadiumShared
import ReadiumStreamer
import UIKit

struct BookRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let author: String
    let identifier: String?
    var locatorJSON: String?
    var progression: Double
    var position: Int?
    var positionCount: Int?

    var aiMetadataContext: String {
        func singleLine(_ value: String) -> String {
            value.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var lines = ["title: \(singleLine(title))"]
        let author = singleLine(author)
        if !author.isEmpty { lines.append("authors: \(author)") }
        if let identifier {
            let identifier = singleLine(identifier)
            if !identifier.isEmpty { lines.append("identifier: \(identifier)") }
        }
        return """
        BOOK_METADATA_BEGIN
        \(lines.joined(separator: "\n"))
        BOOK_METADATA_END
        """
    }
}

@MainActor final class LibraryStore: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var storedBooks: [BookRecord] = []
    private var storedLastBookID: UUID?
    private var changeNotificationScheduled = false

    private struct PaginationCacheFile: Codable {
        var version = 1
        var layouts: [String: [Int]] = [:]
    }
    private var paginationCacheMemory: [UUID: PaginationCacheFile] = [:]
    var books: [BookRecord] { storedBooks }
    var lastBookID: UUID? { storedLastBookID }

    private let files = FileManager.default
    private let client: HTTPClient = DefaultHTTPClient()
    private lazy var retriever = AssetRetriever(httpClient: client)
    private lazy var opener = PublicationOpener(parser: DefaultPublicationParser(
        httpClient: client, assetRetriever: retriever, pdfFactory: DefaultPDFDocumentFactory()
    ))

    private var support: URL {
        files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private var indexURL: URL { support.appendingPathComponent("library.json") }
    private func directory(for id: UUID) -> URL {
        support.appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
    func fileURL(for book: BookRecord) -> URL {
        directory(for: book.id).appendingPathComponent("book.epub")
    }
    func coverURL(for book: BookRecord) -> URL {
        directory(for: book.id).appendingPathComponent("cover.png")
    }
    private func paginationCacheURL(for book: BookRecord) -> URL {
        directory(for: book.id).appendingPathComponent("pagination-v1.json")
    }
    private struct Index: Codable {
        let books: [BookRecord]
        let lastBookID: UUID?
    }
    private func scheduleChangeNotification() {
        guard !changeNotificationScheduled else { return }
        changeNotificationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changeNotificationScheduled = false
            self.objectWillChange.send()
        }
    }
    init() {
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode(Index.self, from: data) {
            storedBooks = index.books.filter { files.fileExists(atPath: fileURL(for: $0).path) }
            storedLastBookID = index.lastBookID
        }
        removeOrphanBookDirectories()
    }

    /// Removes partial import directories left by an interrupted import.
    private func removeOrphanBookDirectories() {
        let booksRoot = support.appendingPathComponent("Books", isDirectory: true)
        guard let directories = try? files.contentsOfDirectory(
            at: booksRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let validIDs = Set(storedBooks.map { $0.id.uuidString })
        for url in directories {
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  !validIDs.contains(url.lastPathComponent) else { continue }
            try? files.removeItem(at: url)
        }
    }
    private func save() {
        do {
            try files.createDirectory(at: support, withIntermediateDirectories: true)
            try JSONEncoder().encode(Index(books: storedBooks, lastBookID: storedLastBookID))
                .write(to: indexURL, options: .atomic)
        } catch { NSLog("LireAI: cannot save library: %@", String(describing: error)) }
    }
    private func publication(at url: URL) async throws -> Publication {
        guard let fileURL = FileURL(url: url) else { throw ReaderError.invalidFile }
        let asset = try await retriever.retrieve(url: fileURL).get()
        let publication = try await opener.open(asset: asset, allowUserInteraction: false).get()
        guard publication.conforms(to: .epub), !publication.isRestricted else { throw ReaderError.invalidFile }
        return publication
    }
    func `import`(
        from source: URL,
        paginationViewport: CGSize? = nil,
        progress: ((Double) -> Void)? = nil,
        prepared: ((BookRecord) -> Void)? = nil
    ) async throws -> BookRecord {
        let allowed = source.startAccessingSecurityScopedResource()
        defer { if allowed { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let dir = directory(for: id)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("book.epub")
        do {
            progress?(0.03)
            try files.copyItem(at: source, to: target)
            progress?(0.08)
            let pub = try await publication(at: target)
            progress?(0.12)
            var book = BookRecord(id: id,
                                  title: pub.metadata.title ?? source.deletingPathExtension().lastPathComponent,
                                  author: pub.metadata.authors.map(\.name).joined(separator: ", "),
                                  identifier: pub.metadata.identifier,
                                  locatorJSON: nil, progression: 0,
                                  position: nil, positionCount: nil)
            if let cover = try? await pub.cover().get()?.pngData() {
                try? cover.write(to: coverURL(for: book), options: .atomic)
            }
            prepared?(book)
            progress?(0.16)

            book.positionCount = try? await pub.positions().get().count
            progress?(0.18)

            if let viewport = paginationViewport,
               viewport.width > 0, viewport.height > 0 {
                do {
                    try await ReaderPaginationPrecomputer.precompute(
                        publication: pub,
                        book: book,
                        library: self,
                        viewport: viewport
                    ) { fraction in
                        progress?(0.18 + min(max(fraction, 0), 1) * 0.80)
                    }
                } catch {
                    NSLog("LireAI: pagination precompute skipped: %@", String(describing: error))
                }
            }

            progress?(0.98)
            var updatedBooks = storedBooks
            updatedBooks.insert(book, at: 0)
            storedBooks = updatedBooks
            storedLastBookID = id
            scheduleChangeNotification()
            save()
            progress?(1)
            return book
        } catch {
            paginationCacheMemory.removeValue(forKey: id)
            try? files.removeItem(at: dir)
            throw error
        }
    }

    private func paginationCacheKey(fontSize: Double, viewport: CGSize) -> String {
        let fontStep = Int((fontSize * 100).rounded())
        let width = Int(viewport.width.rounded())
        let height = Int(viewport.height.rounded())
        return "Iowan-v2|f\(fontStep)|\(width)x\(height)"
    }

    private func loadPaginationCache(for book: BookRecord) -> PaginationCacheFile {
        if let cached = paginationCacheMemory[book.id] { return cached }
        let loaded: PaginationCacheFile
        if let data = try? Data(contentsOf: paginationCacheURL(for: book)),
           let decoded = try? JSONDecoder().decode(PaginationCacheFile.self, from: data),
           decoded.version == 1 {
            loaded = decoded
        } else {
            loaded = PaginationCacheFile()
        }
        paginationCacheMemory[book.id] = loaded
        return loaded
    }

    func paginationCounts(for book: BookRecord, fontSize: Double, viewport: CGSize) -> [Int]? {
        let cache = loadPaginationCache(for: book)
        return cache.layouts[paginationCacheKey(fontSize: fontSize, viewport: viewport)]
    }

    func storePaginationCounts(_ counts: [Int], for book: BookRecord, fontSize: Double, viewport: CGSize) {
        guard !counts.isEmpty, counts.allSatisfy({ $0 > 0 }) else { return }
        var cache = loadPaginationCache(for: book)
        cache.layouts[paginationCacheKey(fontSize: fontSize, viewport: viewport)] = counts
        paginationCacheMemory[book.id] = cache
        do {
            try JSONEncoder().encode(cache).write(to: paginationCacheURL(for: book), options: .atomic)
        } catch {
            NSLog("LireAI: cannot save pagination cache: %@", String(describing: error))
        }
    }

    func open(_ book: BookRecord) async throws -> Publication {
        try await publication(at: fileURL(for: book))
    }
    func select(_ book: BookRecord) {
        storedLastBookID = book.id
        scheduleChangeNotification()
        save()
    }

    func delete(_ book: BookRecord) {
        paginationCacheMemory.removeValue(forKey: book.id)
        try? files.removeItem(at: directory(for: book.id))

        let startupCache = files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LireAI-StartupPages-v2", isDirectory: true)
            .appendingPathComponent(book.id.uuidString, isDirectory: true)
        try? files.removeItem(at: startupCache)

        storedBooks.removeAll { $0.id == book.id }
        if storedLastBookID == book.id {
            storedLastBookID = storedBooks.first?.id
        }
        scheduleChangeNotification()
        save()
    }
    func update(_ book: BookRecord, locator: Locator, positionCount: Int?) {
        guard let index = storedBooks.firstIndex(where: { $0.id == book.id }) else { return }
        var updatedBooks = storedBooks
        var updated = updatedBooks[index]
        updated.locatorJSON = try? locator.jsonString()
        updated.progression = locator.locations.totalProgression ?? updated.progression
        updated.position = locator.locations.position
        if let positionCount { updated.positionCount = positionCount }
        updatedBooks[index] = updated
        storedBooks = updatedBooks
        storedLastBookID = book.id
        scheduleChangeNotification()
        save()
    }
    func savedLocator(for book: BookRecord) -> Locator? {
        guard let data = book.locatorJSON else { return nil }
        return try? Locator(jsonString: data)
    }
    var continueBook: BookRecord? {
        storedBooks.first(where: { $0.id == storedLastBookID }) ?? storedBooks.first
    }
}

enum ReaderError: LocalizedError {
    case invalidFile
    var errorDescription: String? { "无法打开此 EPUB；请确认文件未加密且格式完整。" }
}
