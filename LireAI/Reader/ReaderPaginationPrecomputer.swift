import ReadiumShared
import UIKit

enum ReaderPaginationPrecomputeError: LocalizedError {
    case noWindow

    var errorDescription: String? {
        switch self {
        case .noWindow:
            return "没有可用于分页预计算的活动窗口。"
        }
    }
}

/// Builds the persistent page-count map once, while an EPUB is being imported.
/// The worker navigator is attached almost transparently to the current window:
/// WebKit therefore receives the same portrait viewport as the real reader, but
/// the user only sees the import progress UI above it.
@MainActor
enum ReaderPaginationPrecomputer {
    static func precompute(
        publication: Publication,
        book: BookRecord,
        library: LibraryStore,
        viewport: CGSize,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard let root = activeRootViewController() else {
            throw ReaderPaginationPrecomputeError.noWindow
        }
        guard let firstLink = publication.readingOrder.first else {
            progress(1)
            return
        }

        let firstFont = ReaderLayoutProfile.fontSizes.first ?? 1.16
        let config = ReaderLayoutProfile.configuration(fontSize: firstFont, theme: .warm)
        let firstLocator = Locator(
            href: firstLink.url(),
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: .init(progression: 0)
        )
        let indexer = try BookLayoutIndexer(
            publication: publication,
            initialLocation: firstLocator,
            config: config,
            title: book.title
        )

        let host = UIViewController()
        root.addChild(host)
        host.view.frame = CGRect(origin: .zero, size: viewport)
        host.view.autoresizingMask = []
        host.view.backgroundColor = .clear
        host.view.alpha = 0.001
        host.view.isUserInteractionEnabled = false
        host.view.accessibilityElementsHidden = true
        root.view.insertSubview(host.view, at: 0)
        host.didMove(toParent: root)

        let placeholder = UIView(frame: host.view.bounds)
        placeholder.backgroundColor = .clear
        placeholder.isUserInteractionEnabled = false
        host.view.addSubview(placeholder)

        indexer.attach(
            to: host,
            behind: placeholder,
            safeTop: 0,
            safeBottom: 0
        )
        indexer.setAppearance(paper: ReaderThemeMode.warm.paperColor, text: ReaderThemeMode.warm.textColor)
        indexer.navigator.view.layoutIfNeeded()
        indexer.navigator.viewWillAppear(false)

        defer {
            indexer.close()
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }

        let sizes = ReaderLayoutProfile.fontSizes
        let total = max(1, sizes.count)
        for (index, fontSize) in sizes.enumerated() {
            guard !Task.isCancelled else { return }

            if library.paginationCounts(for: book, fontSize: fontSize, viewport: viewport) != nil {
                progress(Double(index + 1) / Double(total))
                continue
            }

            indexer.paginationProgressDidChange = { localProgress in
                let local = min(max(localProgress, 0), 1)
                progress((Double(index) + local) / Double(total))
            }

            var counts = await indexer.precomputePageCounts(
                preferences: ReaderLayoutProfile.preferences(fontSize: fontSize, theme: .warm),
                current: firstLocator
            )
            if counts == nil, !Task.isCancelled {
                await Task.yield()
                counts = await indexer.precomputePageCounts(
                    preferences: ReaderLayoutProfile.preferences(fontSize: fontSize, theme: .warm),
                    current: firstLocator
                )
            }
            if let counts {
                library.storePaginationCounts(
                    counts,
                    for: book,
                    fontSize: fontSize,
                    viewport: viewport
                )
            }
            progress(Double(index + 1) / Double(total))
        }
        indexer.paginationProgressDidChange = nil
        progress(1)
    }

    private static func activeRootViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        for scene in scenes {
            if let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController {
                return root
            }
            if let root = scene.windows.first(where: { !$0.isHidden })?.rootViewController {
                return root
            }
        }
        return nil
    }
}
