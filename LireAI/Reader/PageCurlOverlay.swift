import UIKit

/// The only page-turn renderer. If Metal or either snapshot is unavailable,
/// the gesture is rejected rather than falling back to a horizontal slide.
@MainActor
final class PageCurlOverlay: UIView {
    enum Direction { case forward, backward }

    private let direction: Direction
    private let metalView: PageCurlMetalView
    private var entryLink: CADisplayLink?
    private var entryStart: CFTimeInterval = 0
    private var entryFrom = CGPoint.zero
    private var entryTarget = CGPoint.zero
    private var initialY: CGFloat = 0
    private var finger = CGPoint.zero
    private var hasEntered = false
    private var displayLink: CADisplayLink?
    private var animationStart: CFTimeInterval = 0
    private var animationDuration: CFTimeInterval = 0
    private var animationFrom = CGPoint.zero
    private var animationCompleted = false
    private var completion: (() -> Void)?
    private(set) var progress: CGFloat = 0

    init?(current: UIImage, target: UIImage, direction: Direction, frame: CGRect,
          metalView metal: PageCurlMetalView) {
        self.direction = direction
        metalView = metal
        super.init(frame: frame)
        backgroundColor = metal.backgroundColor ?? .clear
        isOpaque = true
        clipsToBounds = true
        isAccessibilityElement = false
        metal.removeFromSuperview()
        metal.frame = bounds
        metal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(metal)
        guard metal.prepare(current: current, target: target,
                            forward: direction == .forward) else { return nil }
        finger = CGPoint(x: entryRestingX, y: 0)
        render(finger)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use snapshot initializer") }

    private var entryRestingX: CGFloat { direction == .forward ? bounds.width : -bounds.width }
    private var cancelRestingX: CGFloat { direction == .forward ? bounds.width : -bounds.width }

    func replaceDestination(_ image: UIImage) {
        metalView.replaceDestination(image, forward: direction == .forward)
    }

    func setPaperColor(_ color: UIColor) {
        backgroundColor = color
        metalView.setPaperColor(color)
    }

    func setInitialTouchY(_ y: CGFloat) {
        initialY = min(bounds.height, max(0, y))
        finger = CGPoint(x: entryRestingX, y: initialY)
        render(finger)
    }

    private func interactiveProgress(forX x: CGFloat) -> CGFloat {
        let width = max(bounds.width, 1)
        let raw = direction == .forward ? 1 - x / width : x / width
        return min(1, max(0, raw))
    }

    private func render(_ point: CGPoint, constrainTurnAtSpine: Bool = false) {
        finger = point
        progress = interactiveProgress(forX: point.x)
        metalView.update(finger: point, initialY: initialY,
                         forward: direction == .forward, opacity: 1,
                         constrainTurnAtSpine: constrainTurnAtSpine)
    }

    func track(finger point: CGPoint) {
        var targetPoint = CGPoint(
            x: min(bounds.width, max(0, point.x)),
            y: point.y
        )

        targetPoint = PaperFoldGeometry.constrainInteractiveFinger(
            size: bounds.size, initialY: initialY, finger: targetPoint
        )

        if hasEntered {
            render(targetPoint)
        } else {
            entryTarget = targetPoint
            if entryLink == nil {
                entryFrom = finger
                entryStart = CACurrentMediaTime()
                let link = CADisplayLink(target: self, selector: #selector(tickEntry(_:)))
                link.add(to: .main, forMode: .common)
                entryLink = link
            }
        }
    }

    @objc private func tickEntry(_ link: CADisplayLink) {
        let t = min(1, max(0, (link.timestamp - entryStart) / 0.14))
        let eased = 1 - pow(1 - t, 3)
        let point = CGPoint(
            x: entryFrom.x + (entryTarget.x - entryFrom.x) * CGFloat(eased),
            y: entryFrom.y + (entryTarget.y - entryFrom.y) * CGFloat(eased)
        )
        render(point)
        if t >= 1 {
            link.invalidate()
            entryLink = nil
            hasEntered = true
        }
    }

    func finish(completed: Bool) async {
        await withCheckedContinuation { continuation in
            entryLink?.invalidate()
            entryLink = nil
            hasEntered = true
            displayLink?.invalidate()
            animationFrom = finger
            animationCompleted = completed
            animationStart = CACurrentMediaTime()

            if UIAccessibility.isReduceMotionEnabled {
                animationDuration = 0.01
            } else if completed {
                animationDuration = direction == .forward ? 0.34 : 0.29
            } else {
                let targetX = cancelRestingX
                let remaining = abs(targetX - animationFrom.x) / max(bounds.width, 1)
                animationDuration = max(0.18, 0.20 + Double(remaining) * 0.12)
            }

            completion = { continuation.resume() }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func quadraticBezier(from p0: CGPoint, control p1: CGPoint,
                                 to p2: CGPoint, t: CGFloat) -> CGPoint {
        let oneMinus = 1 - t
        return CGPoint(
            x: oneMinus * oneMinus * p0.x + 2 * oneMinus * t * p1.x + t * t * p2.x,
            y: oneMinus * oneMinus * p0.y + 2 * oneMinus * t * p1.y + t * t * p2.y
        )
    }

    @objc private func tick(_ link: CADisplayLink) {
        let raw = min(1, max(0, (link.timestamp - animationStart) / animationDuration))
        let t = CGFloat(1 - pow(1 - raw, 2))
        let width = max(bounds.width, 1)

        if animationCompleted && direction == .forward {
            let exitX = -width
            let x = animationFrom.x + (exitX - animationFrom.x) * t
            let alignRaw = min(1, raw / 0.55)
            let align = CGFloat(1 - pow(1 - alignRaw, 3))
            let y = animationFrom.y + (initialY - animationFrom.y) * align
            render(CGPoint(x: x, y: y), constrainTurnAtSpine: false)
        } else if animationCompleted && direction == .backward {
            let destination = CGPoint(x: width, y: initialY)
            let guide = CGPoint(x: animationFrom.x + (width - animationFrom.x) * 0.58,
                                y: initialY)
            render(quadraticBezier(from: animationFrom, control: guide,
                                   to: destination, t: t))
        } else {
            let destination = CGPoint(x: cancelRestingX, y: initialY)
            let guide = CGPoint(x: animationFrom.x + (destination.x - animationFrom.x) * 0.55,
                                y: initialY)
            render(quadraticBezier(from: animationFrom, control: guide,
                                   to: destination, t: t))
        }

        if raw >= 1 {
            link.invalidate()
            displayLink = nil
            let callback = completion
            completion = nil
            callback?()
        }
    }
}
