import MetalKit
import ReadiumNavigator
import ReadiumShared
import UIKit
import WebKit

@MainActor
enum ReaderPageDecoration {
    /// Draw the folio directly into a page bitmap so it behaves like ink on
    /// paper during the Metal curl (front, fold and mirrored back side).
    static func addingFolio(to image: UIImage, pageNumber: Int, safeBottom: CGFloat,
                            paper: UIColor, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(at: .zero)
            paper.setFill()
            context.fill(CGRect(x: max(0, image.size.width - 68),
                                y: max(0, image.size.height - safeBottom - 44),
                                width: 60, height: 34))
            drawFolio(pageNumber: pageNumber, in: context, size: image.size,
                      safeBottom: safeBottom, color: color)
        }
    }

    static func drawFolio(
        pageNumber: Int,
        in context: UIGraphicsImageRendererContext,
        size: CGSize,
        safeBottom: CGFloat,
        color: UIColor
    ) {
        let text = String(pageNumber) as NSString
        let font = UIFont.systemFont(ofSize: 15, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]

        let frame = CGRect(
            x: max(0, size.width - 66),
            y: max(0, size.height - safeBottom - 42),
            width: 56,
            height: 28
        )
        let textFrame = CGRect(
            x: frame.minX,
            y: frame.minY + max(0, (frame.height - font.lineHeight) / 2),
            width: frame.width,
            height: font.lineHeight
        )
        text.draw(in: textFrame, withAttributes: attributes)
        let measured = text.size(withAttributes: attributes)
        let ruleWidth = min(frame.width, max(8, ceil(measured.width)))
        context.cgContext.setFillColor(color.cgColor)
        context.cgContext.fill(CGRect(
            x: frame.minX,
            y: frame.maxY - 2,
            width: ruleWidth,
            height: 1
        ))
    }
}

/// Readium's locators contain text/element anchors for durable bookmarks.
/// A bitmap page needs its exact column instead; anchors may start on an
/// earlier column and must not override progression during page navigation.
@MainActor
enum RenderedPageLocation {
    static func navigationLocator(_ locator: Locator) -> Locator {
        guard let progression = locator.locations.progression else { return locator }
        return Locator(href: locator.href, mediaType: locator.mediaType,
                       title: locator.title,
                       locations: .init(progression: min(1, progression + 0.0000001)))
    }

    static func snapshot(_ navigator: EPUBNavigatorViewController, at locator: Locator? = nil,
                         paper: UIColor, afterScreenUpdates: Bool = false,
                         pageNumber: Int? = nil, folioColor: UIColor? = nil,
                         safeBottom: CGFloat? = nil) async -> UIImage? {
        let view = navigator.view!
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return nil }

        var candidates: [(web: WKWebView, frame: CGRect)] = []
        func visit(_ child: UIView) {
            guard !child.isHidden, child.alpha >= 0.999,
                  (child.layer.presentation()?.opacity ?? Float(child.alpha)) >= 0.999 else { return }
            if let web = child as? WKWebView {
                let frame = web.convert(web.bounds, to: view)
                if frame.intersects(view.bounds), web.window != nil { candidates.append((web, frame)) }
            } else {
                child.subviews.forEach(visit)
            }
        }
        visit(view)
        guard !candidates.isEmpty else { return nil }

        var evaluated: [(web: WKWebView, frame: CGRect, href: Bool, page: Bool, area: CGFloat)] = []
        for candidate in candidates {
            let intersection = candidate.frame.intersection(view.bounds)
            let area = max(0, intersection.width) * max(0, intersection.height)
            var hrefMatches = locator == nil
            var pageMatches = locator == nil

            if let locator {
                let script = """
                (() => {
                  const root = document.scrollingElement;
                  const width = Math.max(1, window.innerWidth);
                  const total = root ? Math.max(1, Math.ceil((root.scrollWidth - 1) / width)) : 1;
                  const page = root ? Math.min(total, Math.max(1, Math.round(Math.abs(window.scrollX) / width) + 1)) : 1;
                  return [window.readium?.link?.href || '', page, total];
                })()
                """
                if let raw = try? await candidate.web.evaluateJavaScript(script),
                   let values = raw as? [Any], values.count == 3,
                   let page = values[1] as? NSNumber, let total = values[2] as? NSNumber {
                    if let href = values[0] as? String, !href.isEmpty, let url = AnyURL(string: href) {
                        hrefMatches = url.isEquivalentTo(locator.href)
                    }
                    if let progression = locator.locations.progression {
                        let expected = min(total.intValue,
                                           max(1, Int(floor(progression * total.doubleValue + 0.000001)) + 1))
                        pageMatches = page.intValue == expected
                    } else {
                        pageMatches = true
                    }
                }
            }
            evaluated.append((candidate.web, candidate.frame, hrefMatches, pageMatches, area))
        }

        let hrefPool = evaluated.filter { $0.href }
        let firstPool = hrefPool.isEmpty ? evaluated : hrefPool
        let pagePool = firstPool.filter { $0.page }
        let finalPool = pagePool.isEmpty ? firstPool : pagePool
        guard let selected = finalPool.max(by: { $0.area < $1.area }) else { return nil }

        let config = WKSnapshotConfiguration()
        config.rect = selected.web.bounds
        config.afterScreenUpdates = afterScreenUpdates
        guard let content = try? await selected.web.takeSnapshot(configuration: config),
              !Task.isCancelled else { return nil }
        // A load/reflow may start while WebKit is taking the snapshot.
        var ancestor: UIView? = selected.web
        while let child = ancestor {
            guard !child.isHidden, child.alpha >= 0.999,
                  (child.layer.presentation()?.opacity ?? Float(child.alpha)) >= 0.999 else { return nil }
            if child === view { break }
            ancestor = child.superview
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.screen.scale ?? 3
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            paper.setFill()
            context.fill(view.bounds)
            content.draw(in: selected.frame)
            for label in view.subviews.compactMap({ $0 as? UILabel }) where !label.isHidden {
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: label.frame.minX, y: label.frame.minY)
                label.layer.render(in: context.cgContext)
                context.cgContext.restoreGState()
            }
            if let pageNumber, let folioColor {
                ReaderPageDecoration.drawFolio(
                    pageNumber: pageNumber,
                    in: context,
                    size: view.bounds.size,
                    safeBottom: safeBottom ?? view.window?.safeAreaInsets.bottom ?? 0,
                    color: folioColor
                )
            }
        }
    }

    /// Returns whether the currently visible WebKit column contains actual EPUB
    /// content. This lets us reject a compositor snapshot which is only the
    /// paper colour without trapping a genuinely blank publisher page forever.
    static func hasVisiblePageContent(_ navigator: EPUBNavigatorViewController) async -> Bool {
        let result = await navigator.evaluateJavaScript("""
        (() => {
          const vw = Math.max(1, window.innerWidth);
          const vh = Math.max(1, window.innerHeight);
          const intersects = (r) => r && r.width > 0.5 && r.height > 0.5
            && r.right > 0 && r.left < vw && r.bottom > 0 && r.top < vh;

          const body = document.body;
          if (!body) return false;
          const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
          let node;
          while ((node = walker.nextNode())) {
            if (!node.nodeValue || !node.nodeValue.trim()) continue;
            const range = document.createRange();
            range.selectNodeContents(node);
            for (const rect of range.getClientRects()) {
              if (intersects(rect)) return true;
            }
          }
          for (const element of document.querySelectorAll('img,svg,canvas,video,object,iframe')) {
            if (intersects(element.getBoundingClientRect())) return true;
          }
          return false;
        })()
        """)
        if case .success(let visible as Bool) = result { return visible }
        return true
    }

    /// Fast visual sanity check for the live page bitmap. The test samples only
    /// the reading area (not the native title/folio labels) and needs just a few
    /// non-paper pixels to accept a sparse chapter/title page.
    static func hasVisibleInk(_ image: UIImage, paper: UIColor, minimumContrast: Int = 72,
                              textColor: UIColor? = nil) -> Bool {
        guard let source = image.cgImage else { return false }
        var pr: CGFloat = 0, pg: CGFloat = 0, pb: CGFloat = 0, pa: CGFloat = 0
        guard paper.getRed(&pr, green: &pg, blue: &pb, alpha: &pa) else { return true }

        var expectedInk: (Int, Int, Int)?
        if let textColor {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if textColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
                expectedInk = (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
            }
        }
        // Coarse downsampling can make normal text look grey.
        let scale = min(1, min(512.0 / Double(source.width), 1024.0 / Double(source.height)))
        let width = expectedInk == nil ? 72 : max(1, Int(Double(source.width) * scale))
        let height = expectedInk == nil ? 112 : max(1, Int(Double(source.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        context.interpolationQuality = expectedInk == nil ? .low : .none
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        let paperR = Int((pr * 255).rounded())
        let paperG = Int((pg * 255).rounded())
        let paperB = Int((pb * 255).rounded())
        let minY = Int(Double(height) * 0.16)
        let maxY = Int(Double(height) * 0.86)
        let minX = Int(Double(width) * 0.06)
        let maxX = Int(Double(width) * 0.94)
        var changed = 0
        var sampled = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = (y * width + x) * 4
                let delta = abs(Int(pixels[offset]) - paperR)
                    + abs(Int(pixels[offset + 1]) - paperG)
                    + abs(Int(pixels[offset + 2]) - paperB)
                sampled += 1
                let matchesInk = expectedInk.map { ink in
                    abs(Int(pixels[offset]) - ink.0) <= 24
                        && abs(Int(pixels[offset + 1]) - ink.1) <= 24
                        && abs(Int(pixels[offset + 2]) - ink.2) <= 24
                } ?? true
                if delta > minimumContrast && matchesInk {
                    changed += 1
                    if expectedInk != nil, changed >= 6 { return true }
                }
            }
        }
        return changed >= (expectedInk == nil ? max(6, sampled / 1200) : 6)
    }

    static func hasVisiblePageText(_ navigator: EPUBNavigatorViewController) async -> Bool {
        let result = await navigator.evaluateJavaScript("""
        (() => {
          const width = window.innerWidth;
          const height = window.innerHeight;
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          let node;
          while ((node = walker.nextNode())) {
            if (!node.nodeValue || !node.nodeValue.trim()) continue;
            const range = document.createRange();
            range.selectNodeContents(node);
            for (const rect of range.getClientRects()) {
              if (rect.width > 0.5 && rect.height > 0.5 && rect.right > 0
                  && rect.left < width && rect.bottom > 0 && rect.top < height) return true;
            }
          }
          return false;
        })()
        """)
        if case .success(let visible as Bool) = result { return visible }
        return false
    }

    static func isPaintReady(_ navigator: EPUBNavigatorViewController, at locator: Locator, paper: UIColor? = nil, text: UIColor? = nil) async -> Bool {
        let result = await navigator.evaluateJavaScript("""
        (() => {
          const root = document.scrollingElement;
          const width = window.innerWidth;
          if (!root || width <= 0 || document.readyState !== 'complete'
              || (document.fonts && document.fonts.status !== 'loaded')) return null;
          const total = Math.max(1, Math.ceil((root.scrollWidth - 1) / width));
          const page = Math.min(total, Math.max(1, Math.round(Math.abs(window.scrollX) / width) + 1));
          const body = getComputedStyle(document.body);
          const rootStyle = getComputedStyle(document.documentElement);
          const background = (body.backgroundColor === 'rgba(0, 0, 0, 0)' || body.backgroundColor === 'transparent')
            ? rootStyle.backgroundColor : body.backgroundColor;
          return [page, total, window.readium?.link?.href || '', background, body.color];
        })()
        """)
        guard case .success(let values as [Any]) = result, values.count == 5,
              let page = values[0] as? NSNumber, let total = values[1] as? NSNumber else { return false }
        if let href = values[2] as? String, !href.isEmpty,
           let url = AnyURL(string: href), !url.isEquivalentTo(locator.href) { return false }
        func matches(_ actual: Any, _ expected: UIColor?) -> Bool {
            guard let expected else { return true }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard expected.getRed(&r, green: &g, blue: &b, alpha: &a), let actual = actual as? String else { return false }
            let rgb = "rgb(\(Int((r * 255).rounded())),\(Int((g * 255).rounded())),\(Int((b * 255).rounded())))"
            return actual.replacingOccurrences(of: " ", with: "") == rgb
        }
        guard matches(values[3], paper), matches(values[4], text) else { return false }
        guard let progression = locator.locations.progression else { return true }
        let expected = min(total.intValue, max(1, Int(floor(progression * total.doubleValue + 0.000001)) + 1))
        return page.intValue == expected
    }
}

@MainActor
final class PageTurnCoordinator: NSObject, UIGestureRecognizerDelegate {
    private struct PageSnapshot {
        let locator: Locator
        let image: UIImage
        let size: CGSize
        var pageNumber: Int? = nil
    }

    private struct PageCache {
        var previous: [PageSnapshot] = []
        var current: PageSnapshot?
        var next: [PageSnapshot] = []
    }

    private weak var container: UIView?
    private let navigator: EPUBNavigatorViewController
    private let didCommit: (Locator, Bool) -> Void
    private let stateChanged: (Bool) -> Void
    private let didFail: (String) -> Void
    private let requestPreviews: (Locator) -> Void
    private let pageNumberForLocator: (Locator) -> Int?
    private let snapshotDidChange: (UIImage) -> Void
    private var cache = PageCache()
    private var captureLocation: Locator?
    private var cacheGeneration = 0
    private var capturingCurrent = false
    private let settledCover = UIImageView()
    private var synchronizationTask: Task<Void, Never>?
    private var synchronizationRevision = 0
    var visibleLocation: Locator? { cache.current?.locator }
    var isSynchronizing: Bool { synchronizationTask != nil }
    private var renderer: PageCurlMetalView?
    private var paperColor = UIColor(red: 0.949, green: 0.937, blue: 0.910, alpha: 1)
    private var inkColor = UIColor(red: 0.125, green: 0.129, blue: 0.141, alpha: 1)
    private var preloadTask: Task<Void, Never>?
    private var turnPan: UIPanGestureRecognizer!
    private var overlay: PageCurlOverlay?
    private var destination: PageSnapshot?
    private var origin: PageSnapshot?
    private var forward = true
    private var finishRequested: Bool?
    private var finishing = false
    private var closed = false
    private var selectionActive = false
    private var panTouchBeganAt: TimeInterval = 0
    private var discardCacheAfterTurn = false
    private(set) var isActive = false
    var persistenceBlocked: Bool { isSynchronizing || !settledCover.isHidden }
    var currentSnapshotImage: UIImage? { cache.current?.image }
    var isSelectionActive: Bool { selectionActive || navigator.currentSelection != nil }

    init(navigator: EPUBNavigatorViewController, container: UIView, didCommit: @escaping (Locator, Bool) -> Void,
         stateChanged: @escaping (Bool) -> Void, didFail: @escaping (String) -> Void,
         requestPreviews: @escaping (Locator) -> Void,
         pageNumberForLocator: @escaping (Locator) -> Int? = { _ in nil },
         snapshotDidChange: @escaping (UIImage) -> Void = { _ in }) {
        self.navigator = navigator
        self.container = container
        self.didCommit = didCommit
        self.stateChanged = stateChanged
        self.didFail = didFail
        self.requestPreviews = requestPreviews
        self.pageNumberForLocator = pageNumberForLocator
        self.snapshotDidChange = snapshotDidChange
        super.init()
        settledCover.frame = container.bounds
        settledCover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        settledCover.contentMode = .scaleToFill
        settledCover.isUserInteractionEnabled = true
        settledCover.isHidden = true
        container.addSubview(settledCover)
        renderer = PageCurlMetalView(curlFrame: container.bounds)
        renderer?.setPaperColor(paperColor)
        renderer?.warmUp(scale: container.window?.screen.scale ?? container.traitCollection.displayScale)
        turnPan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        turnPan.delegate = self
        turnPan.cancelsTouchesInView = true
        turnPan.delaysTouchesBegan = false
        turnPan.maximumNumberOfTouches = 1
        container.addGestureRecognizer(turnPan)
        refreshGesturePriority()
    }

    func refreshGesturePriority() {
        func visit(_ view: UIView) {
            if let scroll = view as? UIScrollView {
                // Selection handles can auto-scroll ancestor containers without a pan.
                scroll.isScrollEnabled = false
                scroll.bounces = false
                scroll.alwaysBounceHorizontal = false
                scroll.alwaysBounceVertical = false
                scroll.panGestureRecognizer.isEnabled = false
            }
            view.subviews.forEach(visit)
        }
        visit(navigator.view)
    }

    func setSelectionActive(_ active: Bool) {
        selectionActive = active
        refreshGesturePriority()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === turnPan { panTouchBeganAt = touch.timestamp }
        return !closed
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if navigator.currentSelection == nil { selectionActive = false }
        // Reserve held touches for selection before Readium reports it.
        if gestureRecognizer === turnPan, ProcessInfo.processInfo.systemUptime - panTouchBeganAt >= 0.35 {
            return false
        }
        guard !closed, !isActive, !selectionActive, navigator.currentSelection == nil,
              let locator = cache.current?.locator ?? navigator.currentLocation,
              let pan = gestureRecognizer as? UIPanGestureRecognizer, let container else { return false }
        let velocity = pan.velocity(in: container)
        let translation = pan.translation(in: container)
        let horizontal = abs(translation.x) >= 8 ? translation : velocity
        guard abs(horizontal.x) > abs(horizontal.y) * 0.6,
              (abs(translation.x) >= 8 || abs(velocity.x) > 60) else { return false }
        let neighbor = horizontal.x < 0 ? cache.next.first : cache.previous.first
        guard let current = cache.current, current.size == container.bounds.size,
              samePage(current.locator, locator), neighbor != nil else {
            requestPreviews(locator)
            return false
        }
        return true
    }

    @objc private func handle(_ pan: UIPanGestureRecognizer) {
        guard let container else { return }
        let translation = pan.translation(in: container)
        let isForward = pan.state == .began
            ? (abs(translation.x) >= 8 ? translation.x : pan.velocity(in: container).x) < 0
            : forward
        let sign: CGFloat = isForward ? -1 : 1
        let amount = min(1, max(0, translation.x * sign / max(container.bounds.width, 1)))
        switch pan.state {
        case .began:
            let startY = pan.location(in: container).y - pan.translation(in: container).y
            begin(forward: isForward, initialY: startY)
            overlay?.track(finger: pan.location(in: container))
        case .changed:
            guard isActive, !finishing else { return }
            if selectionActive || navigator.currentSelection != nil { cancel(); return }
            overlay?.track(finger: pan.location(in: container))
        case .ended:
            guard isActive else { return }
            let releaseVelocity = pan.velocity(in: container).x * sign
            finishRequested = amount >= 0.30
                || (amount > 0.06 && releaseVelocity > 450)
            finishTurn()
        case .cancelled, .failed:
            cancel()
        default:
            break
        }
    }

    private func begin(forward: Bool, initialY: CGFloat) {
        guard !isActive, !closed, let container, let locator = cache.current?.locator ?? navigator.currentLocation,
              let preview = (forward ? cache.next.first : cache.previous.first) else { return }
        guard let current = cache.current, current.size == container.bounds.size,
              samePage(current.locator, locator) else { requestPreviews(locator); return }
        let page = pageWithFolio(current)
        let target = pageWithFolio(preview)
        let image = page.image
        if renderer == nil {
            renderer = PageCurlMetalView(curlFrame: container.bounds)
            renderer?.setPaperColor(paperColor)
            renderer?.warmUp(scale: container.window?.screen.scale ?? container.traitCollection.displayScale)
        }
        guard let renderer,
              let curl = PageCurlOverlay(current: image, target: target.image,
                                         direction: forward ? .forward : .backward,
                                         frame: container.bounds, metalView: renderer) else {
            didFail("翻页动画暂时无法加载，请再试一次。")
            return
        }
        origin = page
        destination = target
        cache.current = page
        self.forward = forward
        finishRequested = nil
        finishing = false
        discardCacheAfterTurn = false
        isActive = true
        container.addSubview(curl)
        overlay = curl
        curl.setPaperColor(paperColor)
        curl.setInitialTouchY(initialY)
        renderer.draw()
        stateChanged(true)
    }

    private func pageWithFolio(_ page: PageSnapshot) -> PageSnapshot {
        guard let number = pageNumberForLocator(page.locator), page.pageNumber != number else { return page }
        let image = ReaderPageDecoration.addingFolio(
            to: page.image, pageNumber: number,
            safeBottom: container?.window?.safeAreaInsets.bottom ?? 0,
            paper: paperColor, color: inkColor.withAlphaComponent(0.58))
        return PageSnapshot(locator: page.locator, image: image, size: page.size, pageNumber: number)
    }

    private func settledLocation(restoring expected: Locator) async -> Locator? {
        var stableSamples = 0
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(30))
            guard !closed, !Task.isCancelled else { return nil }
            if await RenderedPageLocation.isPaintReady(navigator, at: expected, paper: paperColor, text: inkColor) {
                stableSamples += 1
                if stableSamples >= 2 { navigator.view.layoutIfNeeded(); return expected }
            } else { stableSamples = 0 }
        }
        return nil
    }

    private func samePage(_ lhs: Locator, _ rhs: Locator) -> Bool {
        guard lhs.href.isEquivalentTo(rhs.href) else { return false }
        if let a = lhs.locations.progression, let b = rhs.locations.progression { return abs(a - b) < 0.0001 }
        return lhs.locations.position == rhs.locations.position
    }

    private func capture(at locator: Locator) async -> (image: UIImage, pageNumber: Int?)? {
        let number = pageNumberForLocator(locator)
        guard let image = await RenderedPageLocation.snapshot(
            navigator,
            at: locator,
            paper: paperColor,
            afterScreenUpdates: true,
            pageNumber: number,
            folioColor: inkColor.withAlphaComponent(0.58),
            safeBottom: container?.window?.safeAreaInsets.bottom
        ) else { return nil }
        return (image, number)
    }

    private func finishTurn() {
        guard !finishing, let shouldCommit = finishRequested, let overlay,
              let destination else { return }
        finishing = true
        Task { [self] in
            await overlay.finish(completed: shouldCommit && !closed)
            guard shouldCommit, finishRequested != false, !closed else {
                removeOverlay()
                return
            }
            settledCover.image = destination.image
            settledCover.isHidden = false
            commitCache(destination, forward: forward)
            didCommit(destination.locator, forward)
            synchronizeNavigator()
            removeOverlay()
            requestPreviews(destination.locator)
        }
    }

    private func synchronizeNavigator() {
        synchronizationRevision += 1
        guard synchronizationTask == nil else { return }
        synchronizationTask = Task { [weak self] in
            guard let self else { return }
            defer { synchronizationTask = nil }
            while !closed, !Task.isCancelled, let destination = cache.current {
                let revision = synchronizationRevision
                let moved = await navigator.go(to: RenderedPageLocation.navigationLocator(destination.locator),
                                               options: NavigatorGoOptions(animated: false))
                let ready = moved ? await settledLocation(restoring: destination.locator) : nil
                guard !closed, !Task.isCancelled else { return }
                if revision != synchronizationRevision { continue }
                guard ready != nil else {
                    didFail("正文仍在加载，请稍后再试。")
                    return
                }
                refreshGesturePriority()
                settledCover.isHidden = true
                settledCover.image = nil
                return
            }
        }
    }

    private func commitCache(_ page: PageSnapshot, forward: Bool) {
        if forward {
            if let current = cache.current { cache.previous.insert(current, at: 0) }
            cache.previous = Array(cache.previous.prefix(4))
            cache.current = page
            cache.next.removeAll { samePage($0.locator, page.locator) }
        } else {
            if let current = cache.current { cache.next.insert(current, at: 0) }
            cache.next = Array(cache.next.prefix(4))
            cache.current = page
            cache.previous.removeAll { samePage($0.locator, page.locator) }
        }
        snapshotDidChange(page.image)
    }

    private func removeOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
        origin = nil
        destination = nil
        finishRequested = nil
        finishing = false
        isActive = false
        if discardCacheAfterTurn { cache = PageCache() }
        stateChanged(false)
        refreshGesturePriority()
    }

    func setPreviews(for locator: Locator, previous: [PagePreview], next: [PagePreview]) {
        guard !closed, let container else { return }
        let size = container.bounds.size
        let previousPages = previous.map { PageSnapshot(locator: $0.locator, image: $0.image, size: size, pageNumber: $0.pageNumber) }
        let nextPages = next.map { PageSnapshot(locator: $0.locator, image: $0.image, size: size, pageNumber: $0.pageNumber) }
        if isActive, let origin, samePage(origin.locator, locator) {
            cache.current = origin
            cache.previous = mergePreviews(previousPages, with: cache.previous)
            cache.next = mergePreviews(nextPages, with: cache.next)
            return
        }
        guard let current = cache.current?.locator ?? captureLocation ?? navigator.currentLocation, samePage(current, locator) else { return }
        if cache.current?.size != size || cache.current.map({ samePage($0.locator, current) }) != true {
            Task { [weak self] in
                guard let self else { return }
                await refreshCurrentSnapshot()
                guard cache.current != nil else { return }
                setPreviews(for: locator, previous: previous, next: next)
            }
            return
        }
        cache.previous = mergePreviews(previousPages, with: cache.previous)
        cache.next = mergePreviews(nextPages, with: cache.next)
        preloadNearbyPages()
    }

    private func preloadNearbyPages() {
        preloadTask?.cancel()
        if renderer == nil, let container {
            renderer = PageCurlMetalView(curlFrame: container.bounds)
            renderer?.setPaperColor(paperColor)
            renderer?.warmUp(scale: container.window?.screen.scale ?? container.traitCollection.displayScale)
        }
        guard let renderer else { return }
        let images = [cache.current?.image, cache.next.first?.image, cache.previous.first?.image]
            .compactMap { $0 }
        preloadTask = Task { [weak self] in
            for image in images {
                await Task.yield()
                guard let self, !Task.isCancelled, !self.closed else { return }
                renderer.preload([image])
            }
        }
    }

    func updatePaperColor(_ color: UIColor, textColor: UIColor) {
        paperColor = color
        inkColor = textColor
        renderer?.setPaperColor(color)
        overlay?.setPaperColor(color)
    }

    private func mergePreviews(_ incoming: [PageSnapshot], with existing: [PageSnapshot]) -> [PageSnapshot] {
        var result = incoming
        for page in existing where !result.contains(where: { samePage($0.locator, page.locator) }) {
            result.append(page)
        }
        return Array(result.prefix(4))
    }

    func cancel() {
        guard isActive else { return }
        finishRequested = false
        finishTurn()
    }

    func releaseMemory() {
        preloadTask?.cancel()
        cache.previous = Array(cache.previous.prefix(1))
        cache.next = Array(cache.next.prefix(1))
        renderer?.purgeTextureCache()
    }

    func invalidateCache() {
        captureLocation = cache.current?.locator ?? captureLocation ?? navigator.currentLocation
        cacheGeneration += 1
        preloadTask?.cancel()
        synchronizationRevision += 1
        synchronizationTask?.cancel()
        settledCover.isHidden = true
        settledCover.image = nil
        cache = PageCache()
        renderer?.purgeTextureCache()
        discardCacheAfterTurn = true
        cancel()
    }

    func prepareForNavigation() {
        if isActive { cancel() }
        captureLocation = nil
        cacheGeneration += 1
        preloadTask?.cancel()
        synchronizationRevision += 1
        synchronizationTask?.cancel()
        synchronizationTask = nil
        settledCover.isHidden = true
        settledCover.image = nil
        cache = PageCache()
        renderer?.purgeTextureCache()
    }

    func refreshAfterReflow() {
        captureLocation = nil
        cacheGeneration += 1
        preloadTask?.cancel()
        synchronizationRevision += 1
        synchronizationTask?.cancel()
        settledCover.isHidden = true
        settledCover.image = nil
        cache = PageCache()
        renderer?.purgeTextureCache()
    }

    @discardableResult
    func refreshCurrentSnapshot() async -> Bool {
        guard !capturingCurrent else { return cache.current != nil }
        let generation = cacheGeneration
        capturingCurrent = true
        defer {
            capturingCurrent = false
            if generation != cacheGeneration, !closed, cache.current == nil {
                Task { [weak self] in await self?.refreshCurrentSnapshot() }
            }
        }
        guard !isActive, !persistenceBlocked, !closed, navigator.currentSelection == nil, let container,
              let locator = captureLocation ?? navigator.currentLocation else { return false }

        var stablePaintSamples = 0
        for _ in 0..<100 {
            guard generation == cacheGeneration, !Task.isCancelled,
                  !isActive, !persistenceBlocked, !closed else { return false }
            if await RenderedPageLocation.isPaintReady(
                navigator, at: locator, paper: paperColor, text: inkColor
            ) {
                stablePaintSamples += 1
            } else {
                stablePaintSamples = 0
            }

            if stablePaintSamples >= 2 {
                try? await Task.sleep(for: .milliseconds(24))
                guard generation == cacheGeneration, !Task.isCancelled,
                      !isActive, !persistenceBlocked, !closed else { return false }
                let expectsVisibleContent = await RenderedPageLocation.hasVisiblePageContent(navigator)
                let expectsVisibleText = await RenderedPageLocation.hasVisiblePageText(navigator)
                guard let captured = await capture(at: locator), generation == cacheGeneration,
                      navigator.currentSelection == nil, !isActive, !Task.isCancelled else { return false }
                let image = captured.image

                if (expectsVisibleContent && !RenderedPageLocation.hasVisibleInk(image, paper: paperColor))
                    || (expectsVisibleText && !RenderedPageLocation.hasVisibleInk(
                        image, paper: paperColor, textColor: inkColor
                    )) {
                    stablePaintSamples = 0
                    try? await Task.sleep(for: .milliseconds(45))
                    continue
                }

                cache.current = PageSnapshot(locator: locator, image: image, size: container.bounds.size,
                                             pageNumber: captured.pageNumber)
                captureLocation = nil
                snapshotDidChange(image)
                preloadNearbyPages()
                requestPreviews(locator)
                return true
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return false
    }

    /// Cold-open/foreground gate. It intentionally leaves the normal rolling
    /// cache policy untouched; it only refuses to unlock the reader until the
    /// visible page has a verified bitmap and the immediately useful textures
    /// have been uploaded once.
    func prepareInitialResources() async -> Bool {
        guard !closed, !isActive, !persistenceBlocked, let locator = navigator.currentLocation else {
            return false
        }

        cacheGeneration += 1
        preloadTask?.cancel()
        cache = PageCache()
        captureLocation = locator
        renderer?.purgeTextureCache()

        guard await refreshCurrentSnapshot(),
              let current = cache.current,
              samePage(current.locator, locator) else { return false }

        requestPreviews(locator)
        for _ in 0..<60 {
            guard !closed, !Task.isCancelled else { return false }
            if !cache.previous.isEmpty || !cache.next.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        if renderer == nil, let container {
            renderer = PageCurlMetalView(curlFrame: container.bounds)
            renderer?.setPaperColor(paperColor)
        }
        guard let renderer, let container else { return false }
        renderer.warmUp(scale: container.window?.screen.scale ?? container.traitCollection.displayScale)
        let images = [cache.current?.image, cache.next.first?.image, cache.previous.first?.image]
            .compactMap { $0 }
        renderer.preload(images)
        return cache.current != nil
    }

    func observedLocation(_ locator: Locator) {
        guard !isActive, !persistenceBlocked else { return }
        let needsRefresh: Bool
        if let current = cache.current, !samePage(current.locator, locator) {
            cache = PageCache()
            needsRefresh = true
        } else {
            needsRefresh = cache.current == nil
        }
        captureLocation = locator
        refreshGesturePriority()
        if needsRefresh {
            Task { [weak self] in _ = await self?.refreshCurrentSnapshot() }
        }
    }

    func shutdown() {
        closed = true
        synchronizationTask?.cancel()
        settledCover.removeFromSuperview()
        preloadTask?.cancel()
        cancel()
        synchronizationRevision += 1
        synchronizationTask?.cancel()
        settledCover.isHidden = true
        settledCover.image = nil
        cache = PageCache()
        renderer?.purgeTextureCache()
        turnPan.isEnabled = false
        container?.removeGestureRecognizer(turnPan)
    }
}
