import UIKit

/// One lightweight persisted bitmap used only to cover EPUB/WebKit startup.
/// It is validated against the exact reader layout and replaced in place.
enum ReaderStartupSnapshotCache {
    private struct Metadata: Codable {
        let fontSize: Double
        let theme: String
        let width: Double
        let height: Double
        let scale: Double
    }

    private static func directory(for bookID: UUID) -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LireAI-StartupPages-v2", isDirectory: true)
        return root.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    static func load(bookID: UUID, fontSize: Double, theme: String, size: CGSize, scale: CGFloat) async -> UIImage? {
        let directory = directory(for: bookID)
        let metadataURL = directory.appendingPathComponent("metadata.json")
        let imageURL = directory.appendingPathComponent("page.jpg")
        let payload = await Task.detached(priority: .userInitiated) { () -> (Data, Data)? in
            guard let metadataData = try? Data(contentsOf: metadataURL), let imageData = try? Data(contentsOf: imageURL) else { return nil }
            return (metadataData, imageData)
        }.value
        guard let (metadataData, imageData) = payload,
              let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData),
              abs(metadata.fontSize - fontSize) < 0.001,
              metadata.theme == theme,
              abs(metadata.width - size.width) < 0.5,
              abs(metadata.height - size.height) < 0.5,
              abs(metadata.scale - scale) < 0.1 else { return nil }
        return UIImage(data: imageData)
    }

    static func save(_ image: UIImage, bookID: UUID, fontSize: Double, theme: String, size: CGSize, scale: CGFloat) async {
        guard let imageData = image.jpegData(compressionQuality: 0.94) else { return }
        let metadata = Metadata(fontSize: fontSize, theme: theme, width: size.width, height: size.height, scale: scale)
        guard let metadataData = try? JSONEncoder().encode(metadata) else { return }
        let directory = directory(for: bookID)
        let imageURL = directory.appendingPathComponent("page.jpg")
        let metadataURL = directory.appendingPathComponent("metadata.json")
        await Task.detached(priority: .utility) {
            do {
                let files = FileManager.default
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                try imageData.write(to: imageURL, options: .atomic)
                try metadataData.write(to: metadataURL, options: .atomic)
            } catch { }
        }.value
    }
}
