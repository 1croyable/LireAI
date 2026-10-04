import ReadiumNavigator
import ReadiumShared
import UIKit

struct PagePreview {
    let locator: Locator
    let image: UIImage
    var pageNumber: Int? = nil
}

@MainActor
final class BookLayoutIndexer {
    let navigator: EPUBNavigatorViewController
    private let publication: Publication
    private var positions: [[Locator]]?
    private let readingOrder: [Link]
    private let title: String
    private let titleLabel = UILabel()
    private var capturePaperColor = UIColor(red: 0.949, green: 0.937, blue: 0.910, alpha: 1)
    private var captureTextColor = UIColor(red: 0.125, green: 0.129, blue: 0.141, alpha: 1)
    private var counts: [Int?]
    private var job: Task<Void, Never>?
    private var pendingPreferences: EPUBPreferences?
    private var requestedLocation: Locator?
    private var renderedLocation: Locator?
    private var generation = 0
    private var closed = false
    private let previewDepth = 4
    private var preferForward = true
    private var pages: [String: PagePreview] = [:]
    private var recency: [String] = []
    private var nextKeys: [String: String] = [:]
    private var previousKeys: [String: String] = [:]
    private let imageBudget = 128 * 1024 * 1024
    private struct ArchivedPage {
        let locator: Locator
        let url: URL
        let pageNumber: Int?
        let write: Task<Int?, Never>
    }
    private var archiveDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LireAI-Pages-" + UUID().uuidString)
    private var archive: [String: ArchivedPage] = [:]
    private var archiveOrder: [String] = []
    private var archiveSizes: [String: Int] = [:]
    private let archiveBudget = 256 * 1024 * 1024
    var countsDidChange: (() -> Void)?
    var paginationProgressDidChange: ((Double) -> Void)?
    var previewsDidChange: ((Locator, [PagePreview], [PagePreview]) -> Void)?

    var paginationReady: Bool {
        !counts.isEmpty && counts.allSatisfy { ($0 ?? 0) > 0 }
    }

    init(publication: Publication, initialLocation: Locator?, config: EPUBNavigatorViewController.Configuration, title: String) throws {
        var workerConfig = config
        workerConfig.editingActions = []
        navigator = try EPUBNavigatorViewController(publication: publication, initialLocation: initialLocation, config: workerConfig)
        self.publication = publication
        readingOrder = publication.readingOrder
        counts = Array(repeating: nil, count: publication.readingOrder.count)
        self.title = title
    }

    func attach(to parent: UIViewController, behind visible: UIView,
                safeTop: CGFloat, safeBottom: CGFloat) {
        parent.addChild(navigator)
        navigator.view.frame = visible.frame
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        navigator.view.isUserInteractionEnabled = false
        parent.view.insertSubview(navigator.view, belowSubview: visible)
        navigator.didMove(toParent: parent)
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = UIColor.black.withAlphaComponent(0.42)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isUserInteractionEnabled = false
        navigator.view.addSubview(titleLabel)
        updateGeometry(size: visible.bounds.size, safeTop: safeTop, safeBottom: safeBottom)
    }

    func updateGeometry(size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) {
        navigator.view.frame = CGRect(origin: .zero, size: size)
        titleLabel.frame = CGRect(x: 64, y: safeTop + 10, width: max(0, size.width - 128), height: 46)
        navigator.view.bringSubviewToFront(titleLabel)
    }

    func setAppearance(paper: UIColor, text: UIColor) {
        capturePaperColor = paper
        captureTextColor = text
        navigator.view.backgroundColor = paper
        titleLabel.textColor = text.withAlphaComponent(0.48)
    }

    func updateAppearance(preferences: EPUBPreferences, paper: UIColor, text: UIColor,
                          current: Locator?) {
        clearPages()
        setAppearance(paper: paper, text: text)
        generation += 1
        let revision = generation
        let previous = job
        previous?.cancel()
        let origin = current ?? requestedLocation ?? navigator.currentLocation
        requestedLocation = origin

        job = Task { [self] in
            await previous?.value
            guard !closed, revision == generation, !Task.isCancelled else { return }

            navigator.submitPreferences(preferences)
            guard !closed, revision == generation, !Task.isCancelled else { return }

            await processRequests(revision: revision)
            if revision == generation { job = nil }
        }
    }

    func globalPage(resource: AnyURL, localPage: Int) -> (current: Int, total: Int)? {
        guard let index = readingOrder.firstIndex(where: { $0.url().isEquivalentTo(resource) }), counts.allSatisfy({ $0 != nil }) else { return nil }
        let known = counts.compactMap { $0 }
        let prefix = known.prefix(index).reduce(0, +)
        return (prefix + min(max(1, localPage), known[index]), known.reduce(0, +))
    }

    func globalPage(for locator: Locator) -> (current: Int, total: Int)? {
        guard let index = readingOrder.firstIndex(where: { $0.url().isEquivalentTo(locator.href) }),
              counts.indices.contains(index), let count = counts[index], count > 0 else { return nil }
        let progression = min(0.999_999, max(0, locator.locations.progression ?? 0))
        let localPage = min(count, Int(floor(progression * Double(count))) + 1)
        return globalPage(resource: locator.href, localPage: localPage)
    }

    func locator(forGlobalPage page: Int) -> Locator? {
        guard page > 0, counts.allSatisfy({ $0 != nil }) else { return nil }
        let known = counts.compactMap { $0 }
        guard page <= known.reduce(0, +) else { return nil }
        var remaining = page
        for (index, count) in known.enumerated() {
            if remaining <= count {
                let progression = Double(remaining - 1) / Double(max(count, 1))
                let link = readingOrder[index]
                return Locator(
                    href: link.url(),
                    mediaType: link.mediaType ?? .xhtml,
                    locations: .init(progression: progression)
                )
            }
            remaining -= count
        }
        return nil
    }

    func request(for current: Locator) {
        func cachedChain(_ links: [String: String]) -> [PagePreview] {
            var chain: [PagePreview] = []
            var key = pageKey(current)
            for _ in 0..<previewDepth {
                guard let next = links[key], let page = pages[next] else { break }
                chain.append(page)
                key = next
            }
            return chain
        }
        let previous = cachedChain(previousKeys)
        let next = cachedChain(nextKeys)
        if !previous.isEmpty || !next.isEmpty { previewsDidChange?(current, previous, next) }
        if let requestedLocation, samePage(requestedLocation, current), job != nil { return }
        if let previous = requestedLocation {
            if let a = previous.locations.totalProgression, let b = current.locations.totalProgression, a != b {
                preferForward = b > a
            } else if previous.href.isEquivalentTo(current.href),
                      let a = previous.locations.progression, let b = current.locations.progression, a != b {
                preferForward = b > a
            }
        }
        requestedLocation = current
        if job == nil { enqueue(current: { current }, preferences: nil) }
    }

    func reflow(
        preferences: EPUBPreferences,
        cachedCounts: [Int]? = nil,
        current: @escaping () -> Locator?
    ) {
        job?.cancel()
        clearPages()
        let restoredCounts: Bool
        if let cachedCounts,
           cachedCounts.count == readingOrder.count,
           cachedCounts.allSatisfy({ $0 > 0 }) {
            counts = cachedCounts.map(Optional.some)
            restoredCounts = true
        } else {
            counts = Array(repeating: nil, count: readingOrder.count)
            restoredCounts = false
            countsDidChange?()
        }
        pendingPreferences = preferences
        requestedLocation = current()
        enqueue(
            current: current,
            preferences: preferences,
            notifyRestoredCounts: restoredCounts
        )
    }

    private func enqueue(
        current: @escaping () -> Locator?,
        preferences: EPUBPreferences?,
        notifyRestoredCounts: Bool = false
    ) {
        guard !closed else { return }
        generation += 1
        let revision = generation
        let previous = job
        previous?.cancel()
        job = Task { [self] in
            await previous?.value
            guard !closed, revision == generation, !Task.isCancelled else { return }
            if let settings = pendingPreferences ?? preferences {
                navigator.submitPreferences(settings)
                pendingPreferences = nil
                if !Task.isCancelled, let reflowed = current() { requestedLocation = reflowed }
            }
            guard !closed, revision == generation, !Task.isCancelled else { return }
            if notifyRestoredCounts {
                paginationProgressDidChange?(1)
                countsDidChange?()
            }
            await processRequests(revision: revision)
            if revision == generation { job = nil }
        }
    }

    /// Import-time exact pagination pass. This deliberately skips neighbor
    /// snapshots and only measures each spine item's stable WebKit column count.
    /// A dedicated indexer instance is used by the importer, so cancelling its
    /// normal worker cannot interfere with the visible reader.
    func precomputePageCounts(
        preferences: EPUBPreferences,
        current: Locator?
    ) async -> [Int]? {
        let previous = job
        previous?.cancel()
        await previous?.value
        guard !closed, !Task.isCancelled else { return nil }

        clearPages()
        generation += 1
        let revision = generation
        counts = Array(repeating: nil, count: readingOrder.count)
        pendingPreferences = nil
        requestedLocation = current
        renderedLocation = nil

        navigator.submitPreferences(preferences)
        await Task.yield()
        guard !closed, revision == generation, !Task.isCancelled else { return nil }
        await measureBook(revision: revision)
        guard !closed, revision == generation, !Task.isCancelled else { return nil }
        return pageCountsSnapshot()
    }

    func pageCountsSnapshot() -> [Int]? {
        guard paginationReady else { return nil }
        let snapshot = counts.compactMap { $0 }
        guard snapshot.count == readingOrder.count else { return nil }
        return snapshot
    }

    private func processRequests(revision: Int) async {
        while !closed, !Task.isCancelled, revision == generation, let origin = requestedLocation {
            if !paginationReady {
                await measureBook(revision: revision)
            }
            guard !closed, !Task.isCancelled, revision == generation else { return }
            if let latest = requestedLocation, !samePage(latest, origin) { continue }

            await renderNeighbors(of: origin, revision: revision)
            guard !closed, !Task.isCancelled, revision == generation else { return }
            if let latest = requestedLocation, !samePage(latest, origin) { continue }
            return
        }
    }

    /// Startup/reflow barrier used by ReaderHost. It does not add another
    /// pagination pass; it simply waits for the single worker above to finish
    /// the exact scroll-width counts before the reader is unlocked.
    func waitUntilPaginationReady(for current: Locator?) async -> Bool {
        if paginationReady { return true }
        if let current {
            requestedLocation = current
            if job == nil { enqueue(current: { current }, preferences: nil) }
        }
        while !closed, !Task.isCancelled {
            if paginationReady { return true }
            if job == nil, let origin = requestedLocation ?? navigator.currentLocation {
                enqueue(current: { origin }, preferences: nil)
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }

    private func pageKey(_ locator: Locator) -> String {
        locator.href.string + "#" + String(format: "%.5f", locator.locations.progression ?? 0)
    }

    func releaseMemory() {
        pages.removeAll()
        recency.removeAll()
    }

    func clearPages() {
        let oldDirectory = archiveDirectory
        archive.values.forEach { $0.write.cancel() }
        archive.removeAll()
        archiveOrder.removeAll()
        archiveSizes.removeAll()
        archiveDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LireAI-Pages-" + UUID().uuidString)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: oldDirectory) }
        renderedLocation = nil
        pages.removeAll()
        recency.removeAll()
        nextKeys.removeAll()
        previousKeys.removeAll()
    }

    private func remember(_ page: PagePreview, from origin: Locator, forward: Bool) {
        let key = pageKey(page.locator)
        let source = pageKey(origin)
        pages[key] = page
        archivePage(page, key: key)
        recency.removeAll { $0 == key }
        recency.append(key)
        if forward { nextKeys[source] = key; previousKeys[key] = source }
        else { previousKeys[source] = key; nextKeys[key] = source }
        func cost(_ preview: PagePreview) -> Int {
            guard let image = preview.image.cgImage else { return 0 }
            return image.bytesPerRow * image.height
        }
        var bytes = pages.values.reduce(0) { $0 + cost($1) }
        while bytes > imageBudget, recency.count > 1 {
            let oldest = recency.removeFirst()
            if let removed = pages.removeValue(forKey: oldest) { bytes -= cost(removed) }
        }
    }

    private func archivePage(_ page: PagePreview, key: String) {
        guard archive[key] == nil else { return }
        let directory = archiveDirectory
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        let image = page.image
        let write = Task.detached(priority: .utility) { () -> Int? in
            guard !Task.isCancelled, let data = image.pngData(), !Task.isCancelled else { return nil }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard !Task.isCancelled else { return nil }
                try data.write(to: url, options: .atomic)
                return data.count
            } catch { return nil }
        }
        archive[key] = ArchivedPage(locator: page.locator, url: url, pageNumber: page.pageNumber, write: write)
        archiveOrder.append(key)
        Task { [weak self] in
            guard let bytes = await write.value, let self,
                  !closed, archive[key]?.url == url else { return }
            archiveSizes[key] = bytes
            var total = archiveSizes.values.reduce(0, +)
            while total > archiveBudget, let oldest = archiveOrder.first {
                archiveOrder.removeFirst()
                total -= archiveSizes.removeValue(forKey: oldest) ?? 0
                if let removed = archive.removeValue(forKey: oldest) {
                    removed.write.cancel()
                    Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: removed.url) }
                }
            }
        }
    }

    private func neighbor(of origin: Locator, forward: Bool) async -> PagePreview? {
        let source = pageKey(origin)
        if let key = (forward ? nextKeys : previousKeys)[source], let page = pages[key] {
            recency.removeAll { $0 == key }
            recency.append(key)
            return page
        }
        if let key = (forward ? nextKeys : previousKeys)[source], let saved = archive[key],
           await saved.write.value != nil, !Task.isCancelled {
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: saved.url.path)?.preparingForDisplay()
            }.value
            if let image, !Task.isCancelled {
                archiveOrder.removeAll { $0 == key }
                archiveOrder.append(key)
                let page = PagePreview(locator: saved.locator, image: image, pageNumber: saved.pageNumber)
                remember(page, from: origin, forward: forward)
                return page
            }
        }
        guard !Task.isCancelled, await navigate(to: origin), !Task.isCancelled,
              let page = await advance(forward: forward), !Task.isCancelled else { return nil }
        remember(page, from: origin, forward: forward)
        return page
    }

    private func renderNeighbors(of origin: Locator, revision: Int) async {
        var previous: [PagePreview] = []
        var next: [PagePreview] = []
        var exhaustedPrevious = false
        var exhaustedNext = false
        let order = [preferForward, !preferForward]
            + Array(repeating: preferForward, count: previewDepth - 1)
            + Array(repeating: !preferForward, count: previewDepth - 1)
        for forward in order {
            guard !closed, !Task.isCancelled, revision == generation else { return }
            if let latest = requestedLocation, !samePage(latest, origin) { return }
            if forward ? exhaustedNext : exhaustedPrevious { continue }
            let last = forward ? next.last?.locator : previous.last?.locator
            if let page = await neighbor(of: last ?? origin, forward: forward) {
                guard !Task.isCancelled, revision == generation else { return }
                if forward { next.append(page) } else { previous.append(page) }
                previewsDidChange?(origin, previous, next)
            } else {
                if forward { exhaustedNext = true } else { exhaustedPrevious = true }
            }
        }
    }

    private func advance(forward: Bool) async -> PagePreview? {
        guard !Task.isCancelled, let origin = renderedLocation,
              let currentLayout = await layout(),
              let resource = readingOrder.firstIndex(where: { $0.url().isEquivalentTo(origin.href) }) else { return nil }
        let column = currentLayout.page - 1 + (forward ? 1 : -1)
        var target: Locator
        if column >= 0 && column < currentLayout.total {
            target = Locator(href: origin.href, mediaType: origin.mediaType,
                             locations: .init(progression: Double(column) / Double(currentLayout.total)))
        } else {
            let adjacent = resource + (forward ? 1 : -1)
            guard readingOrder.indices.contains(adjacent) else { return nil }
            target = Locator(href: readingOrder[adjacent].url(), mediaType: origin.mediaType,
                             locations: .init(progression: 0))
            guard await navigate(to: target), !Task.isCancelled else { return nil }
            if !forward {
                guard let previousLayout = await layout() else { return nil }
                target = Locator(href: target.href, mediaType: target.mediaType,
                                 locations: .init(progression: Double(previousLayout.total - 1) / Double(previousLayout.total)))
            }
        }
        guard !Task.isCancelled, await navigate(to: target), !Task.isCancelled,
              let captured = await capture(at: target) else { return nil }
        let bookmark = await bookmark(for: target)
        guard !Task.isCancelled else { return nil }
        return PagePreview(locator: bookmark, image: captured.image, pageNumber: captured.pageNumber)
    }

    private func bookmark(for page: Locator) async -> Locator {
        if positions == nil { positions = try? await publication.positionsByReadingOrder().get() }
        guard let positions,
              let index = readingOrder.firstIndex(where: { $0.url().isEquivalentTo(page.href) }),
              positions.indices.contains(index), !positions[index].isEmpty,
              let progression = page.locations.progression else { return page }
        let group = positions[index]
        let nearest = min(group.count - 1, max(0, Int(ceil(progression * Double(group.count - 1)))))
        let lower = group.first?.locations.totalProgression ?? 0
        let upper = positions.indices.contains(index + 1)
            ? (positions[index + 1].first?.locations.totalProgression ?? 1) : 1
        guard group[nearest].href.isEquivalentTo(page.href) else { return page }
        return group[nearest].copy(locations: {
            $0.progression = progression
            $0.totalProgression = lower + (upper - lower) * progression
        })
    }

    private func navigate(to locator: Locator) async -> Bool {
        if let current = renderedLocation, samePage(current, locator),
           await RenderedPageLocation.isPaintReady(navigator, at: locator, paper: capturePaperColor, text: captureTextColor) { return true }
        guard !Task.isCancelled,
              await navigator.go(to: RenderedPageLocation.navigationLocator(locator),
                                 options: NavigatorGoOptions(animated: false)),
              await ready(at: locator) else { return false }
        renderedLocation = locator
        return true
    }

    private func measureBook(revision: Int) async {
        let totalResources = max(1, readingOrder.count)
        var completed = counts.filter { ($0 ?? 0) > 0 }.count
        paginationProgressDidChange?(Double(completed) / Double(totalResources))

        for (index, link) in readingOrder.enumerated() where counts[index] == nil {
            guard !closed, revision == generation, !Task.isCancelled else { return }
            let locator = Locator(
                href: link.url(),
                mediaType: link.mediaType ?? .xhtml,
                locations: .init(progression: 0)
            )

            var count = await quickPageCount(at: locator)

            if count == nil, await navigate(to: locator), let layout = await layout() {
                count = layout.total
            }

            if let count, count > 0 {
                counts[index] = count
                completed += 1
                paginationProgressDidChange?(Double(completed) / Double(totalResources))
            }
            await Task.yield()
        }

        if !Task.isCancelled, revision == generation, paginationReady {
            paginationProgressDidChange?(1)
            countsDidChange?()
        }
    }

    private func quickPageCount(at locator: Locator) async -> Int? {
        guard !Task.isCancelled,
              await navigator.go(
                to: RenderedPageLocation.navigationLocator(locator),
                options: NavigatorGoOptions(animated: false)
              ) else { return nil }

        var lastTotal: Int?
        var stableSamples = 0
        for _ in 0..<55 {
            guard !Task.isCancelled, !closed else { return nil }
            let result = await navigator.evaluateJavaScript(
                """
                (() => {
                  const root = document.scrollingElement;
                  const width = window.innerWidth;
                  const href = window.readium?.link?.href || '';
                  const ready = document.readyState === 'complete'
                    && (!document.fonts || document.fonts.status === 'loaded');
                  if (!root || width <= 0) return [href, ready, 0];
                  const total = Math.max(1, Math.ceil((root.scrollWidth - 1) / width));
                  return [href, ready, total];
                })()
                """
            )

            if case .success(let values as [Any]) = result, values.count == 3,
               let ready = values[1] as? Bool, ready,
               let totalNumber = values[2] as? NSNumber, totalNumber.intValue > 0 {
                let hrefMatches: Bool
                if let href = values[0] as? String, !href.isEmpty, let url = AnyURL(string: href) {
                    hrefMatches = url.isEquivalentTo(locator.href)
                } else {
                    hrefMatches = navigator.currentLocation?.href.isEquivalentTo(locator.href) == true
                }

                if hrefMatches {
                    let total = totalNumber.intValue
                    if total == lastTotal {
                        stableSamples += 1
                    } else {
                        lastTotal = total
                        stableSamples = 1
                    }
                    if stableSamples >= 2 {
                        renderedLocation = locator
                        return total
                    }
                } else {
                    stableSamples = 0
                    lastTotal = nil
                }
            }
            try? await Task.sleep(for: .milliseconds(22))
        }
        return nil
    }

    private func ready(at locator: Locator) async -> Bool {
        var stableSamples = 0
        for _ in 0..<60 {
            guard !Task.isCancelled, !closed else { return false }
            try? await Task.sleep(for: .milliseconds(30))
            if await RenderedPageLocation.isPaintReady(navigator, at: locator, paper: capturePaperColor, text: captureTextColor) {
                stableSamples += 1
                if stableSamples >= 2 { navigator.view.layoutIfNeeded(); return true }
            } else { stableSamples = 0 }
        }
        return false
    }

    private func samePage(_ lhs: Locator, _ rhs: Locator) -> Bool {
        guard lhs.href.isEquivalentTo(rhs.href) else { return false }
        if let a = lhs.locations.progression, let b = rhs.locations.progression { return abs(a - b) < 0.0001 }
        return lhs.locations.position == rhs.locations.position
    }

    private func layout() async -> (page: Int, total: Int)? {
        let script = """
        (() => {
          const root = document.scrollingElement;
          const width = window.innerWidth;
          if (!root || width <= 0) return null;
          const total = Math.max(1, Math.ceil((root.scrollWidth - 1) / width));
          const page = Math.min(total, Math.max(1, Math.round(Math.abs(window.scrollX) / width) + 1));
          return [page, total];
        })()
        """
        let result = await navigator.evaluateJavaScript(script)
        guard case .success(let values as [Any]) = result, values.count == 2, let page = values[0] as? NSNumber, let total = values[1] as? NSNumber else { return nil }
        return (page.intValue, total.intValue)
    }

    private func capture(at locator: Locator) async -> PagePreview? {
        for _ in 0..<16 {
            guard !Task.isCancelled, !closed else { return nil }
            let expectsVisibleContent = await RenderedPageLocation.hasVisiblePageContent(navigator)
            let expectsVisibleText = await RenderedPageLocation.hasVisiblePageText(navigator)
            let number = globalPage(for: locator)?.current
            if let image = await RenderedPageLocation.snapshot(
                navigator,
                at: locator,
                paper: capturePaperColor,
                afterScreenUpdates: true,
                pageNumber: number,
                folioColor: captureTextColor.withAlphaComponent(0.58),
                safeBottom: navigator.view.window?.safeAreaInsets.bottom
            ) {
                if (!expectsVisibleContent || RenderedPageLocation.hasVisibleInk(image, paper: capturePaperColor))
                    && (!expectsVisibleText || RenderedPageLocation.hasVisibleInk(
                        image, paper: capturePaperColor, minimumContrast: 250
                    )) {
                    return PagePreview(locator: locator, image: image, pageNumber: number)
                }
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return nil
    }

    func close() {
        closed = true
        clearPages()
        generation += 1
        job?.cancel()
        navigator.view.removeFromSuperview()
        navigator.removeFromParent()
    }
}
