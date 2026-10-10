import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UIKit
import Combine
import WebKit

enum ReaderThemeMode: String, CaseIterable {
    case warm
    case night

    var paperHex: String { self == .warm ? "#F2EFE8" : "#151515" }
    var textHex: String { self == .warm ? "#202124" : "#D8D8D8" }
    var paperColor: UIColor { self == .warm ? UIColor(red: 0.949, green: 0.937, blue: 0.910, alpha: 1) : UIColor(white: 0.082, alpha: 1) }
    var textColor: UIColor { self == .warm ? UIColor(red: 0.125, green: 0.129, blue: 0.141, alpha: 1) : UIColor(white: 0.847, alpha: 1) }
    var readiumTheme: ReadiumNavigator.Theme { self == .warm ? .light : .dark }
}

@MainActor
final class ReaderSession: ObservableObject {
    @Published var chromeVisible = false
    @Published var pageTurnActive = false
    @Published var pendingSelection: PendingSelection?
    @Published var aiConversation: AIReadingConversation?
    @Published var aiSheetPresented = false
    @Published var navigationSheetPresented = false
    @Published var chapters: [ReaderChapterEntry] = []
    @Published var readerReady = false
    @Published var resourcePreparationStarted = false
    @Published var loadingProgress: Double = 0.03
    @Published var position: Int?
    @Published var positionCount: Int?
    @Published var renderedPageNumber: Int?
    @Published var renderedPageCount: Int?
    @Published var error: String?
    @Published var safeAreaInsets: UIEdgeInsets = .zero

    private var chromeDismissTask: Task<Void, Never>?

    func noteInteraction() {
        chromeDismissTask?.cancel()
        guard chromeVisible else { return }
        chromeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.hideChrome()
        }
    }

    func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.22)) {
            chromeVisible.toggle()
        }
        noteInteraction()
    }

    func hideChrome() {
        chromeDismissTask?.cancel()
        guard chromeVisible else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            chromeVisible = false
        }
    }

    func beginLookup(fragments: [String], book: BookRecord) {
        if let conversation = aiConversation, conversation.shouldContinueForLookup {
            conversation.appendLookup(fragments: fragments)
            aiSheetPresented = true
            return
        }
        aiConversation?.cancelOutstandingRequest()
        let conversation = AIReadingConversation(fragments: fragments, bookContext: book.aiMetadataContext, bookID: book.id, bookTitle: book.title)
        aiConversation = conversation
        aiSheetPresented = true
        conversation.startIfNeeded()
    }

    func endLookup() {
        aiConversation?.cancelOutstandingRequest()
        aiConversation = nil
        aiSheetPresented = false
    }
}

@MainActor
final class ReaderHost: UIViewController, EPUBNavigatorDelegate {
    let navigator: EPUBNavigatorViewController
    private static let lookupAction = EditingAction(title: "AI 查找", action: #selector(askAI))
    private static let storeAction = EditingAction(title: "暂存", action: #selector(storeSelection))
    private static let mergeAction = EditingAction(title: "合并查找", action: #selector(mergeSelection))
    
    private let book: BookRecord
    private let publication: Publication
    private let library: LibraryStore
    private let session: ReaderSession
    private var lastLocator: Locator?
    private var pageTurns: PageTurnCoordinator?
    private var indexer: BookLayoutIndexer?
    private var navigatorInstalled = false
    private var lastNavigatorSize: CGSize = .zero
    private var isClosed = false
    private var renderedPageTask: Task<Void, Never>?
    private var fontUpdateTask: Task<Void, Never>?
    private var snapshotRefreshTask: Task<Void, Never>?
    private var readerReadyTask: Task<Void, Never>?
    private var snapshotSaveTask: Task<Void, Never>?
    private var folioRestoreTask: Task<Void, Never>?
    private let titleLabel = UILabel()
    private let folioLabel = UILabel()
    private let folioUnderline = UIView()
    private var folioHiddenForPageTurn = false
    private var currentFontSize: Double
    private var currentTheme: ReaderThemeMode

    init(
        book: BookRecord,
        publication: Publication,
        library: LibraryStore,
        session: ReaderSession,
        fontSize: Double,
        theme: ReaderThemeMode
    ) throws {
        let config = ReaderLayoutProfile.configuration(
            fontSize: fontSize,
            theme: theme,
            editingActions: [Self.lookupAction, Self.storeAction, Self.mergeAction] + EditingAction.defaultActions
        )

        navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: library.savedLocator(for: book),
            config: config
        )

        self.book = book
        self.publication = publication
        self.library = library
        self.session = session
        currentFontSize = fontSize
        currentTheme = theme

        super.init(nibName: nil, bundle: nil)

        navigator.delegate = self
        indexer = try? BookLayoutIndexer(
            publication: publication, initialLocation: library.savedLocator(for: book),
            config: config, title: book.title
        )
        indexer?.countsDidChange = { [weak self] in
            guard let self else { return }
            self.storeCurrentPaginationCounts()
            self.updateRenderedPageNumber()
            self.refreshChapterPageNumbers()
            if self.indexer?.paginationReady == true {
                Task { [weak self] in
                    await self?.pageTurns?.refreshCurrentSnapshot()
                }
            }
        }
        indexer?.paginationProgressDidChange = { [weak session] progress in
            guard let session, !session.readerReady else { return }
            session.loadingProgress = max(session.loadingProgress, 0.22 + min(max(progress, 0), 1) * 0.56)
        }
        indexer?.previewsDidChange = { [weak self] locator, previous, next in
            self?.pageTurns?.setPreviews(for: locator, previous: previous, next: next)
        }
        if session.pendingSelection?.bookID != book.id { session.pendingSelection = nil }

        session.positionCount = book.positionCount
        if book.positionCount == nil {
            Task {
                session.positionCount = try? await publication.positions().get().count
                persist()
            }
        }
        Task { [weak self] in await self?.loadChapters() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use designated initializer")
    }

    private static func preferences(fontSize: Double, theme: ReaderThemeMode) -> EPUBPreferences {
        ReaderLayoutProfile.preferences(fontSize: fontSize, theme: theme)
    }

    private func paginationViewport(_ size: CGSize? = nil) -> CGSize? {
        let viewport = size ?? (lastNavigatorSize == .zero ? view.bounds.size : lastNavigatorSize)
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        return viewport
    }

    private func cachedPaginationCounts(fontSize: Double, size: CGSize? = nil) -> [Int]? {
        guard let viewport = paginationViewport(size) else { return nil }
        return library.paginationCounts(for: book, fontSize: fontSize, viewport: viewport)
    }

    private func storeCurrentPaginationCounts() {
        guard let counts = indexer?.pageCountsSnapshot(),
              let viewport = paginationViewport() else { return }
        library.storePaginationCounts(counts, for: book, fontSize: currentFontSize, viewport: viewport)
    }

    func updateFontSize(_ size: Double) {
        pageTurns?.invalidateCache()
        fontUpdateTask?.cancel()
        fontUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            while pageTurns?.isActive == true || pageTurns?.isSynchronizing == true {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled else { return }
            }
            guard !isClosed, !Task.isCancelled else { return }
            currentFontSize = size
            navigator.submitPreferences(Self.preferences(fontSize: size, theme: currentTheme))
            pageTurns?.refreshAfterReflow()
            session.renderedPageNumber = nil
            session.renderedPageCount = nil
            updateFolioLabel()
            indexer?.reflow(
                preferences: Self.preferences(fontSize: size, theme: currentTheme),
                cachedCounts: cachedPaginationCounts(fontSize: size),
                current: { [weak self] in self?.navigator.currentLocation }
            )
            updateRenderedPageNumber()
        }
    }

    func updateTheme(_ theme: ReaderThemeMode) {
        guard theme != currentTheme else { return }
        let readingLocation = pageTurns?.visibleLocation ?? navigator.currentLocation
        currentTheme = theme

        let preferences = Self.preferences(fontSize: currentFontSize, theme: theme)
        applyThemeColors()
        navigator.submitPreferences(preferences)

        pageTurns?.updatePaperColor(theme.paperColor, textColor: theme.textColor)
        pageTurns?.invalidateCache()
        indexer?.updateAppearance(
            preferences: preferences,
            paper: theme.paperColor,
            text: theme.textColor,
            current: readingLocation
        )

        scheduleSnapshotRefresh()
    }

    private func loadChapters() async {
        guard case .success(let tableOfContents) = await publication.tableOfContents() else { return }
        var flattened: [(link: ReadiumShared.Link, depth: Int)] = []
        func append(_ links: [ReadiumShared.Link], depth: Int) {
            for link in links {
                flattened.append((link, depth))
                append(link.children, depth: depth + 1)
            }
        }
        append(tableOfContents, depth: 0)

        var entries: [ReaderChapterEntry] = []
        for (index, item) in flattened.enumerated() {
            guard !isClosed else { return }
            let title = item.link.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { continue }
            let locator = await publication.locate(item.link) ?? Locator(
                href: item.link.url(),
                mediaType: item.link.mediaType ?? .xhtml,
                locations: .init(progression: 0)
            )
            entries.append(ReaderChapterEntry(
                id: "\(index)-\(item.link.href)",
                title: title,
                depth: item.depth,
                locator: locator,
                page: indexer?.globalPage(for: locator)?.current
            ))
        }
        guard !isClosed else { return }
        session.chapters = entries
    }

    private func refreshChapterPageNumbers() {
        guard !session.chapters.isEmpty else { return }
        session.chapters = session.chapters.map { chapter in
            var updated = chapter
            updated.page = indexer?.globalPage(for: chapter.locator)?.current
            return updated
        }
    }

    func jump(to locator: Locator) async {
        guard !isClosed, pageTurns?.isActive != true else { return }
        session.hideChrome()
        pageTurns?.prepareForNavigation()
        guard await navigator.go(
            to: RenderedPageLocation.navigationLocator(locator),
            options: NavigatorGoOptions(animated: false)
        ) else {
            session.error = "无法跳转到这个章节。"
            return
        }

        var settled: Locator?
        for _ in 0..<60 {
            guard !isClosed, !Task.isCancelled else { return }
            let current = navigator.currentLocation ?? locator
            if await RenderedPageLocation.isPaintReady(
                navigator, at: current, paper: currentTheme.paperColor, text: currentTheme.textColor
            ) {
                settled = current
                break
            }
            try? await Task.sleep(for: .milliseconds(35))
        }
        guard let settled else {
            session.error = "正文仍在加载，请稍后再试。"
            return
        }

        pageTurns?.observedLocation(settled)
        for _ in 0..<20 where pageTurns?.currentSnapshotImage == nil {
            await pageTurns?.refreshCurrentSnapshot()
            if pageTurns?.currentSnapshotImage == nil {
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        commitLocation(settled)
        indexer?.request(for: settled)
        updateRenderedPageNumber()
    }

    func jump(toPage page: Int) async {
        guard let locator = indexer?.locator(forGlobalPage: page) else {
            session.error = "页码仍在计算，请稍后再试。"
            return
        }
        await jump(to: locator)
    }

    private func applyThemeColors() {
        view.backgroundColor = currentTheme.paperColor
        navigator.view.backgroundColor = currentTheme.paperColor
        titleLabel.textColor = currentTheme.textColor.withAlphaComponent(0.48)
        folioLabel.textColor = currentTheme.textColor.withAlphaComponent(0.58)
        folioUnderline.backgroundColor = folioLabel.textColor
    }

    func cancelPageTurn() { pageTurns?.cancel() }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        pageTurns?.releaseMemory()
        indexer?.releaseMemory()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = currentTheme.paperColor

    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.layoutIfNeeded()
        if !navigatorInstalled {
            navigatorInstalled = true
            addChild(navigator)
            navigator.view.backgroundColor = view.backgroundColor
            navigator.view.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(navigator.view, at: 0)
            NSLayoutConstraint.activate([
                navigator.view.topAnchor.constraint(equalTo: view.topAnchor),
                navigator.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                navigator.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                navigator.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            view.layoutIfNeeded()
            navigator.didMove(toParent: self)
            titleLabel.text = book.title
            titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            titleLabel.textColor = currentTheme.textColor.withAlphaComponent(0.48)
            titleLabel.textAlignment = .center
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.isUserInteractionEnabled = false
            navigator.view.addSubview(titleLabel)
            folioLabel.font = .systemFont(ofSize: 15, weight: .regular)
            folioLabel.textColor = currentTheme.textColor.withAlphaComponent(0.58)
            folioLabel.textAlignment = .left
            folioLabel.isUserInteractionEnabled = false
            folioLabel.isHidden = true
            view.addSubview(folioLabel)
            folioUnderline.backgroundColor = folioLabel.textColor
            folioUnderline.isUserInteractionEnabled = false
            folioUnderline.isHidden = true
            view.addSubview(folioUnderline)
            updateTitleFrame()
            indexer?.attach(to: self, behind: navigator.view,
                            safeTop: view.window?.safeAreaInsets.top ?? 0,
                            safeBottom: view.window?.safeAreaInsets.bottom ?? 0)
            pageTurns = PageTurnCoordinator(
                navigator: navigator, container: view,
                didCommit: { [weak self] locator, forward in
                    self?.commitTurnLocation(locator, forward: forward)
                },
                stateChanged: { [weak self] active in self?.setPageTurnActive(active) },
                didFail: { [weak session] message in session?.error = message },
                requestPreviews: { [weak self] locator in self?.indexer?.request(for: locator) },
                pageNumberForLocator: { [weak self] locator in
                    self?.indexer?.globalPage(for: locator)?.current
                },
                snapshotDidChange: { [weak self] image in self?.scheduleStartupSnapshotSave(image) }
            )
            pageTurns?.updatePaperColor(currentTheme.paperColor, textColor: currentTheme.textColor)
            indexer?.setAppearance(paper: currentTheme.paperColor, text: currentTheme.textColor)
            if let locator = navigator.currentLocation { indexer?.request(for: locator) }
            updateRenderedPageNumber()
            markReaderReadyWhenStable()
        }
        updateReaderGeometry()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateReaderGeometry()
        pageTurns?.refreshGesturePriority()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateReaderGeometry()
    }

    private func updateReaderGeometry() {
        guard navigatorInstalled, view.window != nil else { return }
        let proposedSize = view.bounds.size
        guard proposedSize.width > 0, proposedSize.height > 0 else { return }

        let size: CGSize
        if lastNavigatorSize != .zero,
           abs(proposedSize.width - lastNavigatorSize.width) < 0.5,
           abs(proposedSize.height - lastNavigatorSize.height) >= 0.5 {
            size = lastNavigatorSize
            navigator.view.frame = CGRect(origin: .zero, size: size)
        } else {
            size = proposedSize
        }

        let insets = view.window?.safeAreaInsets ?? .zero
        if session.safeAreaInsets != insets { session.safeAreaInsets = insets }
        updateTitleFrame()
        indexer?.updateGeometry(size: size, safeTop: insets.top, safeBottom: insets.bottom)
        if size != lastNavigatorSize {
            lastNavigatorSize = size
            pageTurns?.invalidateCache()
            navigator.view.layoutIfNeeded()
            navigator.viewWillAppear(false)
            pageTurns?.refreshAfterReflow()
            indexer?.reflow(
                preferences: Self.preferences(fontSize: currentFontSize, theme: currentTheme),
                cachedCounts: cachedPaginationCounts(fontSize: currentFontSize, size: size),
                current: { [weak self] in self?.navigator.currentLocation }
            )
            session.renderedPageNumber = nil
            session.renderedPageCount = nil
            updateFolioLabel()
            updateRenderedPageNumber()
        }
    }

    private func updateTitleFrame() {
        let top = view.window?.safeAreaInsets.top ?? 0
        titleLabel.frame = CGRect(x: 64, y: top + 10,
                                  width: max(0, navigator.view.bounds.width - 128), height: 46)
        navigator.view.bringSubviewToFront(titleLabel)
        let bottom = view.window?.safeAreaInsets.bottom ?? 0
        folioLabel.frame = CGRect(x: max(0, navigator.view.bounds.width - 66),
                                  y: max(0, navigator.view.bounds.height - bottom - 42),
                                  width: 56, height: 28)
        let measured = folioLabel.sizeThatFits(
            CGSize(width: folioLabel.bounds.width, height: folioLabel.bounds.height)
        )
        let ruleWidth = min(folioLabel.bounds.width, max(8, ceil(measured.width)))
        folioUnderline.frame = CGRect(x: folioLabel.frame.minX,
                                      y: folioLabel.frame.maxY - 2,
                                      width: ruleWidth, height: 1)
        view.bringSubviewToFront(folioLabel)
        view.bringSubviewToFront(folioUnderline)
    }

    private func setPageTurnActive(_ active: Bool) {
        folioRestoreTask?.cancel()
        session.pageTurnActive = active

        if active {
            folioHiddenForPageTurn = true
            session.hideChrome()
            updateFolioLabel()
            return
        }

        folioHiddenForPageTurn = true
        updateFolioLabel()
        folioRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while pageTurns?.persistenceBlocked == true, !Task.isCancelled, !isClosed {
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled, !isClosed, pageTurns?.isActive != true else { return }
            folioHiddenForPageTurn = false
            updateFolioLabel()
        }
    }

    func chromeVisibilityDidChange() {
        updateFolioLabel(animated: true)
    }

    private func setFolioVisible(_ visible: Bool, animated: Bool) {
        let target: CGFloat = visible ? 1 : 0
        folioLabel.layer.removeAllAnimations()
        folioUnderline.layer.removeAllAnimations()

        if visible {
            folioLabel.isHidden = false
            folioUnderline.isHidden = false
        }

        let changes = { [weak self] in
            self?.folioLabel.alpha = target
            self?.folioUnderline.alpha = target
        }
        let finish: (Bool) -> Void = { [weak self] _ in
            guard let self, !visible, self.folioLabel.alpha == 0 else { return }
            self.folioLabel.isHidden = true
            self.folioUnderline.isHidden = true
        }

        guard animated else {
            changes()
            finish(true)
            return
        }
        UIView.animate(withDuration: visible ? 0.20 : 0.14,
                       delay: 0,
                       options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction],
                       animations: changes, completion: finish)
    }

    private func updateFolioLabel(animated: Bool = false) {
        folioLabel.text = session.renderedPageNumber.map(String.init)
        updateTitleFrame()
        let visible = !session.chromeVisible
            && !folioHiddenForPageTurn
            && session.renderedPageNumber != nil
        setFolioVisible(visible, animated: animated)
    }

    private func scheduleSnapshotRefresh() {
        snapshotRefreshTask?.cancel()
        guard !session.chromeVisible else { return }
        snapshotRefreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, !isClosed,
                  pageTurns?.isActive != true else { return }
            await pageTurns?.refreshCurrentSnapshot()
        }
    }

    private func markReaderReadyWhenStable() {
        readerReadyTask?.cancel()
        readerReadyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var stablePaintSamples = 0

            while !Task.isCancelled, !isClosed {
                let result = await navigator.evaluateJavaScript(
                    "document.readyState === 'complete' && (!document.fonts || document.fonts.status === 'loaded')"
                )
                let domReady: Bool
                if case .success(let ready as Bool) = result {
                    domReady = ready
                } else {
                    domReady = false
                }
                if domReady,
                   let locator = navigator.currentLocation,
                   await RenderedPageLocation.isPaintReady(
                       navigator, at: locator, paper: currentTheme.paperColor, text: currentTheme.textColor
                   ) {
                    stablePaintSamples += 1
                } else {
                    stablePaintSamples = 0
                }

                if stablePaintSamples >= 2 {
                    if !session.resourcePreparationStarted {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            self.session.resourcePreparationStarted = true
                        }
                    }
                    session.loadingProgress = max(session.loadingProgress, 0.20)

                    if let indexer, !(await indexer.waitUntilPaginationReady(for: navigator.currentLocation)) {
                        stablePaintSamples = 0
                        try? await Task.sleep(for: .milliseconds(45))
                        continue
                    }
                    session.loadingProgress = max(session.loadingProgress, 0.80)
                    updateRenderedPageNumber()
                    refreshChapterPageNumbers()

                    if await pageTurns?.prepareInitialResources() == true {
                        session.loadingProgress = max(session.loadingProgress, 0.96)
                        guard !Task.isCancelled, !isClosed else { return }
                        withAnimation(.easeInOut(duration: 0.36)) {
                            self.session.loadingProgress = 1
                            self.session.readerReady = true
                        }
                        return
                    }
                    stablePaintSamples = 0
                }
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }

    func revalidateAfterForeground() {
        guard navigatorInstalled, !isClosed else { return }
        navigator.clearSelection()
        pageTurns?.setSelectionActive(false)
        readerReadyTask?.cancel()
        withAnimation(.easeInOut(duration: 0.16)) {
            session.readerReady = false
            session.resourcePreparationStarted = true
            session.loadingProgress = max(0.82, min(session.loadingProgress, 0.94))
        }
        markReaderReadyWhenStable()
    }

    private func scheduleStartupSnapshotSave(_ image: UIImage, force: Bool = false) {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              force || (!session.chromeVisible && !folioHiddenForPageTurn) else { return }
        snapshotSaveTask?.cancel()
        guard currentTheme == .warm else { return }
        let bookID = book.id
        let fontSize = currentFontSize
        let theme = currentTheme.rawValue
        snapshotSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            await ReaderStartupSnapshotCache.save(
                image,
                bookID: bookID,
                fontSize: fontSize,
                theme: theme,
                size: size,
                scale: image.scale
            )
        }
    }

    @objc
    private func askAI() {
        guard let selected = currentFragment() else { return }
        session.beginLookup(fragments: [selected.text], book: book)
        navigator.clearSelection()
        pageTurns?.setSelectionActive(false)
    }

    private func currentFragment() -> PendingSelection? {
        guard let locator = navigator.currentSelection?.locator,
              let text = locator.text.highlight?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return PendingSelection(text: text, locator: locator, bookID: book.id)
    }

    @objc private func storeSelection() {
        guard session.pendingSelection == nil, let selected = currentFragment() else { return }
        session.pendingSelection = selected
        navigator.clearSelection()
        pageTurns?.setSelectionActive(false)
    }

    @objc private func mergeSelection() {
        guard let pending = session.pendingSelection, let current = currentFragment(),
              let fragments = pending.orderedFragments(with: current) else { return }
        guard fragments.joined(separator: " ").count <= 5000 else {
            session.error = "合并后的选文过长，请缩短当前选文后重试。暂存片段已保留。"
            return
        }
        session.beginLookup(fragments: fragments, book: book)
        session.pendingSelection = nil
        navigator.clearSelection()
        pageTurns?.setSelectionActive(false)
    }

    func persistStartupSnapshot() {
        guard let image = pageTurns?.currentSnapshotImage else { return }
        scheduleStartupSnapshotSave(image, force: true)
    }

    func closeBook() {
        guard !isClosed else { return }
        fontUpdateTask?.cancel()
        renderedPageTask?.cancel()
        snapshotRefreshTask?.cancel()
        readerReadyTask?.cancel()
        folioRestoreTask?.cancel()
        if let image = pageTurns?.currentSnapshotImage {
            scheduleStartupSnapshotSave(image, force: true)
        }
        persist()
        indexer?.close()
        pageTurns?.shutdown()
        session.hideChrome()
        isClosed = true
        navigator.delegate = nil
    }

    func navigator(
        _ navigator: Navigator,
        locationDidChange locator: Locator
    ) {
        guard pageTurns?.isActive != true, pageTurns?.persistenceBlocked != true else { return }
        Task { [weak self] in
            guard let self, !isClosed,
                  await RenderedPageLocation.isPaintReady(self.navigator, at: locator, paper: currentTheme.paperColor, text: currentTheme.textColor),
                  pageTurns?.isActive != true, pageTurns?.persistenceBlocked != true else { return }
            pageTurns?.observedLocation(locator)
            commitLocation(locator)
            indexer?.request(for: locator)
        }
    }

    private func commitLocation(_ locator: Locator) {
        guard !isClosed, lastLocator != locator else { return }
        lastLocator = locator
        session.position = locator.locations.position
        library.update(book, locator: locator, positionCount: session.positionCount)
        updateRenderedPageNumber()
    }

    private func commitTurnLocation(_ locator: Locator, forward: Bool) {
        if let page = session.renderedPageNumber {
            session.renderedPageNumber = max(1, page + (forward ? 1 : -1))
            updateFolioLabel()
        }
        commitLocation(locator)
    }

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        userContentController.addUserScript(WKUserScript(
            source: Self.selectionPageLockScript, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
    }

    static let selectionPageLockScript = """
        (() => {
          if (window.__lireSelectionPageLock) return true;
          const pageX = () => {
            const width = Math.max(1, window.innerWidth);
            return Math.round(window.scrollX / width) * width;
          };
          const hasSelection = () => {
            const selection = window.getSelection();
            return !!selection && selection.rangeCount > 0 && !selection.isCollapsed;
          };
          let stableX = pageX();
          let lockedX = null;
          let touching = false;
          let rootStyle = null;
          const restore = () => {
            if (lockedX !== null && Math.abs(window.scrollX - lockedX) > 0.5) {
              window.scrollTo({ left: lockedX, top: window.scrollY, behavior: 'instant' });
            }
          };
          const syncSelection = () => {
            if (hasSelection()) {
              if (lockedX === null) {
                lockedX = stableX;
                const root = document.scrollingElement;
                if (root) {
                  rootStyle = ['overflow-x', 'overscroll-behavior-x', 'scroll-behavior'].map(name =>
                    [name, root.style.getPropertyValue(name), root.style.getPropertyPriority(name)]);
                  root.style.setProperty('overflow-x', 'hidden', 'important');
                  root.style.setProperty('overscroll-behavior-x', 'none', 'important');
                  root.style.setProperty('scroll-behavior', 'auto', 'important');
                }
              }
              restore();
            } else if (!touching) {
              // A dragged handle can briefly collapse the selection.
              restore();
              lockedX = null;
              const root = document.scrollingElement;
              if (root && rootStyle) {
                rootStyle.forEach(([name, value, priority]) => {
                  if (value) root.style.setProperty(name, value, priority);
                  else root.style.removeProperty(name);
                });
              }
              rootStyle = null;
              stableX = pageX();
            }
          };
          document.addEventListener('touchstart', () => {
            touching = true;
            if (lockedX === null && !hasSelection()) stableX = pageX();
          }, { capture: true, passive: true });
          const endTouch = event => {
            touching = event.touches.length > 0;
            if (!touching) requestAnimationFrame(syncSelection);
          };
          document.addEventListener('touchend', endTouch, { capture: true, passive: true });
          document.addEventListener('touchcancel', endTouch, { capture: true, passive: true });
          document.addEventListener('selectionchange', () => {
            syncSelection();
          }, true);
          window.addEventListener('scroll', event => {
            if (lockedX === null && hasSelection()) syncSelection();
            if (lockedX !== null) {
              if (Math.abs(window.scrollX - lockedX) > 0.5) {
                // Do not let Readium persist a transient half-page position.
                event.stopImmediatePropagation();
                restore();
              }
            } else {
              stableX = pageX();
            }
          }, { capture: true, passive: true });
          window.__lireSelectionPageLock = true;
          return true;
        })()
        """

    /// Derives displayed pages from painted WebKit columns after layout changes.
    private func updateRenderedPageNumber() {
        renderedPageTask?.cancel()
        renderedPageTask = Task { [weak self] in
            guard let self else { return }
            while (pageTurns?.isActive == true || pageTurns?.persistenceBlocked == true) && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, !isClosed else { return }

            if let expected = pageTurns?.visibleLocation ?? navigator.currentLocation {
                var painted = false
                for _ in 0..<60 {
                    guard !Task.isCancelled, !isClosed else { return }
                    if await RenderedPageLocation.isPaintReady(
                        navigator, at: expected,
                        paper: currentTheme.paperColor, text: currentTheme.textColor
                    ) {
                        painted = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(30))
                }
                guard painted else { return }
            }

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
            let expected = pageTurns?.visibleLocation ?? navigator.currentLocation
            let result = await navigator.evaluateJavaScript(script)
            guard !Task.isCancelled, pageTurns?.isActive != true,
                  pageTurns?.persistenceBlocked != true,
                  expected == (pageTurns?.visibleLocation ?? navigator.currentLocation),
                  case .success(let values as [Any]) = result,
                  values.count == 2,
                  let page = values[0] as? NSNumber,
                  let total = values[1] as? NSNumber,
                  total.intValue > 0 else { return }
            guard let href = (pageTurns?.visibleLocation ?? navigator.currentLocation)?.href,
                  let global = indexer?.globalPage(resource: href, localPage: page.intValue) else {
                session.renderedPageNumber = nil
                session.renderedPageCount = nil
                updateFolioLabel()
                return
            }
            session.renderedPageNumber = global.current
            session.renderedPageCount = global.total
            updateFolioLabel()
        }
    }

    func navigator(_ navigator: SelectableNavigator, shouldShowMenuForSelection selection: Selection) -> Bool {
        pageTurns?.setSelectionActive(true)
        if pageTurns?.isActive == true { pageTurns?.cancel(); return false }
        return true
    }

    func navigator(_ navigator: SelectableNavigator, canPerformAction action: EditingAction, for selection: Selection) -> Bool {
        let hasPending = session.pendingSelection?.bookID == book.id
        if action == Self.lookupAction || action == Self.storeAction { return !hasPending }
        if action == Self.mergeAction { return hasPending }
        return true
    }

    func navigator(
        _ navigator: VisualNavigator,
        didTapAt point: CGPoint
    ) {
        if pageTurns?.isSelectionActive == true {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !self.isClosed, self.navigator.currentSelection == nil else { return }
                self.pageTurns?.setSelectionActive(false)
            }
            return
        }
        guard pageTurns?.isActive != true else { return }

        session.toggleChrome()
    }

    func navigator(
        _ navigator: Navigator,
        presentError error: NavigatorError
    ) {
        session.error = String(describing: error)
    }

    func persist() {
        guard !isClosed, pageTurns?.isActive != true else { return }
        if let locator = pageTurns?.visibleLocation ?? navigator.currentLocation ?? lastLocator {
            library.update(
                book,
                locator: locator,
                positionCount: session.positionCount
            )
        }
    }
}

struct ReaderController: UIViewControllerRepresentable {
    let host: ReaderHost

    func makeUIViewController(context: Context) -> ReaderHost {
        host
    }

    func updateUIViewController(
        _ uiViewController: ReaderHost,
        context: Context
    ) {
    }

    static func dismantleUIViewController(_ uiViewController: ReaderHost, coordinator: ()) {
        uiViewController.closeBook()
    }
}

struct ReaderView: View {
    let book: BookRecord
    @ObservedObject var library: LibraryStore
    let close: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var session = ReaderSession()
    @State private var host: ReaderHost?
    @State private var showingFontSize = false
    @State private var showingVocabularyNotes = false
    @State private var startupBookCover: UIImage?
    @State private var pendingNavigation: ReaderNavigationTarget?
    @State private var sceneWasBackgrounded = false
    @AppStorage("readerFontSize") private var fontSize = 1.16
    @AppStorage("readerTheme") private var themeRaw = ReaderThemeMode.warm.rawValue

    private var theme: ReaderThemeMode { ReaderThemeMode(rawValue: themeRaw) ?? .warm }
    private var paper: SwiftUI.Color { SwiftUI.Color(uiColor: theme.paperColor) }
    private var chromeForeground: SwiftUI.Color { SwiftUI.Color(uiColor: theme.textColor) }
    private var chromeBackground: SwiftUI.Color { SwiftUI.Color(uiColor: theme.paperColor) }

    init(book: BookRecord, library: LibraryStore, close: @escaping () -> Void) {
        self.book = book
        self.library = library
        self.close = close
        _startupBookCover = State(
            initialValue: UIImage(contentsOfFile: library.coverURL(for: book).path)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                paper

                if let host {
                    ReaderController(host: host)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if !session.readerReady {
                    ZStack {
                        Color.black

                        if let startupBookCover {
                            Image(uiImage: startupBookCover)
                                .resizable()
                                .scaledToFit()
                                .frame(
                                    maxWidth: min(geometry.size.width * 0.72, 330),
                                    maxHeight: geometry.size.height * 0.64
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .shadow(color: .black.opacity(0.34), radius: 18, y: 10)
                                .offset(y: -geometry.size.height * 0.055)
                        } else {
                            VStack(spacing: 14) {
                                Image(systemName: "book.closed.fill")
                                    .font(.system(size: 44, weight: .regular))
                                Text(book.title)
                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(3)
                            }
                            .foregroundStyle(.white.opacity(0.86))
                            .padding(.horizontal, 42)
                            .offset(y: -geometry.size.height * 0.055)
                        }

                        VStack(spacing: 8) {
                            ProgressView(value: min(max(session.loadingProgress, 0), 1), total: 1)
                                .progressViewStyle(.linear)
                                .tint(.white.opacity(0.82))
                                .frame(width: min(geometry.size.width * 0.52, 220))
                            Text("\(Int((min(max(session.loadingProgress, 0), 1) * 100).rounded()))%")
                                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.48))
                        }
                        .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.80)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .zIndex(15)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity.combined(with: .scale(scale: 1.07))
                    ))
                }

                if session.chromeVisible {
                    VStack(spacing: 0) {
                        HStack {
                            Button {
                                host?.closeBook()
                                close()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(width: 44, height: 44)
                                    .background(chromeBackground, in: Circle())
                                    .overlay(Circle().stroke(chromeForeground.opacity(0.12), lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.09), radius: 6, y: 2)
                                    .frame(width: 68, height: 68)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(chromeForeground)
                            .accessibilityLabel("返回书库")
                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, session.safeAreaInsets.top - 1)

                        Spacer()

                        ZStack {
                            Text({
                                if let position = session.renderedPageNumber, let total = session.renderedPageCount, total > 0 { return "\(position) / \(total) 页" }
                                return "正在计算页码…"
                            }())
                            .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(chromeForeground.opacity(0.62))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            HStack(alignment: .center) {
                                if session.aiConversation != nil {
                                    Button { session.aiSheetPresented = true } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "sparkles")
                                                .font(.system(size: 12, weight: .semibold))
                                            Text("AI")
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        }
                                        .padding(.horizontal, 10)
                                        .frame(height: 38)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(chromeForeground.opacity(0.78))
                                    .background(chromeBackground, in: Capsule())
                                    .overlay(Capsule().stroke(chromeForeground.opacity(0.22), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
                                    .accessibilityLabel("继续 AI 对话")
                                }

                                Spacer()

                                Button { showingFontSize = true } label: {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 18, weight: .semibold))
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(chromeForeground)
                                .background(chromeBackground, in: Circle())
                                .overlay(Circle().stroke(chromeForeground.opacity(0.12), lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.09), radius: 6, y: 2)
                                .padding(.trailing, 3)
                                .accessibilityLabel("阅读设置")
                                .popover(isPresented: $showingFontSize) {
                                    ReaderSettingsPopover(
                                        fontSize: $fontSize,
                                        themeRaw: $themeRaw,
                                        foreground: chromeForeground,
                                        hasPendingSelection: session.pendingSelection != nil,
                                        cancelPendingSelection: { session.pendingSelection = nil },
                                        openNotes: {
                                            showingFontSize = false
                                            session.hideChrome()
                                            Task { @MainActor in
                                                try? await Task.sleep(for: .milliseconds(180))
                                                showingVocabularyNotes = true
                                            }
                                        },
                                        openNavigation: {
                                            showingFontSize = false
                                            session.hideChrome()
                                            Task { @MainActor in
                                                try? await Task.sleep(for: .milliseconds(180))
                                                session.navigationSheetPresented = true
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 24)
                            .frame(height: 44)
                        }
                        .padding(.bottom, session.safeAreaInsets.bottom + 4)
                    }
                    .disabled(session.pageTurnActive)
                    .transition(.opacity)
                    .simultaneousGesture(TapGesture().onEnded { session.noteInteraction() })
                }

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .task(id: book.id) {
                if startupBookCover == nil {
                    startupBookCover = UIImage(contentsOfFile: library.coverURL(for: book).path)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .all)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .statusBarHidden(true)
        .preferredColorScheme(theme == .night ? .dark : .light)
        .sheet(isPresented: $session.aiSheetPresented) {
            if let conversation = session.aiConversation {
                AIReadingSheet(conversation: conversation)
                    .id(conversation.id)
            }
        }
        .sheet(isPresented: $showingVocabularyNotes) {
            VocabularyNotesView(bookID: book.id, bookTitle: book.title)
        }
        .sheet(isPresented: $session.navigationSheetPresented, onDismiss: performPendingNavigation) {
            ReaderNavigationSheet(
                chapters: session.chapters,
                totalPages: session.renderedPageCount,
                currentPage: session.renderedPageNumber,
                selectChapter: { locator in
                    pendingNavigation = .chapter(locator)
                    session.navigationSheetPresented = false
                },
                selectPage: { page in
                    pendingNavigation = .page(page)
                    session.navigationSheetPresented = false
                },
                close: { session.navigationSheetPresented = false }
            )
        }
        .task {
            guard host == nil else {
                return
            }

            do {
                session.loadingProgress = max(session.loadingProgress, 0.05)
                let publication = try await library.open(book)
                session.loadingProgress = max(session.loadingProgress, 0.14)

                host = try ReaderHost(
                    book: book,
                    publication: publication,
                    library: library,
                    session: session,
                    fontSize: fontSize,
                    theme: theme
                )
                session.loadingProgress = max(session.loadingProgress, 0.18)
            } catch {
                session.error = error.localizedDescription
            }
        }
        .onDisappear {
            host?.persistStartupSnapshot()
            host?.persist()
            session.endLookup()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                sceneWasBackgrounded = true
                host?.cancelPageTurn()
                host?.persistStartupSnapshot()
                host?.persist()
            case .inactive:
                host?.cancelPageTurn()
                host?.persistStartupSnapshot()
                host?.persist()
            case .active:
                if sceneWasBackgrounded {
                    sceneWasBackgrounded = false
                    host?.revalidateAfterForeground()
                }
            @unknown default:
                break
            }
        }
        .onChange(of: fontSize) { _, newValue in
            session.noteInteraction()
            host?.updateFontSize(newValue)
        }
        .onChange(of: themeRaw) { _, newValue in
            session.noteInteraction()
            host?.updateTheme(ReaderThemeMode(rawValue: newValue) ?? .warm)
        }
        .onChange(of: session.chromeVisible) { _, visible in
            host?.chromeVisibilityDidChange()
            if !visible { showingFontSize = false }
        }
        .onChange(of: showingFontSize) { oldValue, newValue in
            if oldValue && !newValue { session.hideChrome() }
        }
        .alert(
            "阅读出错",
            isPresented: Binding(
                get: { self.session.error != nil },
                set: { if !$0 { self.session.error = nil } }
            )
        ) {
            Button("好") { self.session.error = nil }
        } message: {
            Text(session.error ?? "")
        }
    }

    private func performPendingNavigation() {
        guard let pendingNavigation else { return }
        self.pendingNavigation = nil
        Task { @MainActor in
            switch pendingNavigation {
            case .chapter(let locator):
                await host?.jump(to: locator)
            case .page(let page):
                await host?.jump(toPage: page)
            }
        }
    }
}
