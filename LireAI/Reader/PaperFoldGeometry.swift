import CoreGraphics
import Foundation

/// Fold skeleton shared by the interactive page mesh and its checks.
///
/// `referencePoint` drives the crease. `edgePoint` is the physical point on
/// the sheet's right edge that must stay attached to the finger. Keeping the
/// two separate lets the crease lead the drag without losing finger contact.
struct PaperFoldGeometry {
    let pageSize: CGSize
    let initialY: CGFloat
    let edgePoint: CGPoint
    let referencePoint: CGPoint
    let finger: CGPoint
    let midpoint: CGPoint
    let normal: CGVector
    let distance: CGFloat

    /// The curved arc is about 150% of the dragged span. This deliberately
    /// lifts a broad part of the sheet instead of concentrating the bend in a
    /// narrow strip next to the crease.
    static func curlRadius(for distance: CGFloat) -> CGFloat {
        min(150, max(2, distance * 0.4775))
    }

    /// Places the cylindrical surface so that the original point held on the
    /// right edge still projects exactly to the finger. For a broad curl the
    /// held edge has not quite completed a half turn, so the former πr/2 shift
    /// is no longer sufficient.
    private static func surfaceShift(distance: CGFloat, radius: CGFloat) -> CGFloat {
        let distance = max(0, distance)
        let radius = max(0.001, radius)
        guard distance > 0.001 else { return 0 }
        if radius <= distance / .pi {
            return .pi * radius * 0.5
        }

        let target = distance / radius
        var lower: CGFloat = 0
        var upper: CGFloat = .pi
        for _ in 0..<22 {
            let angle = (lower + upper) * 0.5
            if angle - sin(angle) < target { lower = angle }
            else { upper = angle }
        }
        let angle = (lower + upper) * 0.5
        return radius * angle - distance * 0.5
    }

    /// Applies the single physical page-corner constraint used while the user
    /// is dragging. The visible finite-radius curl sits to the left of the hard
    /// geometric fold, so the hard anchor is intentionally placed farther right
    /// than the desired visible 10% stop. This keeps the rendered lower/upper
    /// contact near that 10% margin without moving the page texture itself.
    static func constrainInteractiveFinger(size: CGSize, initialY: CGFloat,
                                           finger: CGPoint) -> CGPoint {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let y0 = min(height, max(0, initialY))
        var constrained = CGPoint(x: min(width, max(-width, finger.x)),
                                  y: min(height, max(0, finger.y)))
        if width - constrained.x < 1 { constrained.y = y0 }

        let geometrySpineX = width * 0.30

        let verticalDelta = constrained.y - y0
        let anchorY: CGFloat
        if verticalDelta > 0.5 {
            anchorY = 0
        } else if verticalDelta < -0.5 {
            anchorY = height
        } else {
            anchorY = y0 >= height * 0.5 ? height : 0
        }
        let anchor = CGPoint(x: geometrySpineX, y: anchorY)
        let reach = hypot(width - geometrySpineX, y0 - anchorY)
        let dx = constrained.x - anchor.x
        let dy = constrained.y - anchor.y
        let length = hypot(dx, dy)
        if length > reach, length > 0.001 {
            let scale = reach / length
            constrained = CGPoint(x: anchor.x + dx * scale,
                                  y: anchor.y + dy * scale)
        }
        return constrained
    }

    static func make(size: CGSize, initialY: CGFloat, finger: CGPoint,
                     constrainTurnAtSpine: Bool = false) -> PaperFoldGeometry {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let y0 = min(height, max(0, initialY))
        var constrained = CGPoint(x: min(width, max(-width, finger.x)),
                                  y: min(height, max(0, finger.y)))
        if width - constrained.x < 1 { constrained.y = y0 }

        if constrainTurnAtSpine {
            constrained = constrainInteractiveFinger(size: size,
                                                      initialY: y0,
                                                      finger: constrained)
        }

        let referenceX = width
        let dx = constrained.x - referenceX
        let dy = constrained.y - y0
        let distance = hypot(dx, dy)
        let unit = max(distance, 0.001)
        return PaperFoldGeometry(
            pageSize: CGSize(width: width, height: height),
            initialY: y0,
            edgePoint: CGPoint(x: width, y: y0),
            referencePoint: CGPoint(x: referenceX, y: y0),
            finger: constrained,
            midpoint: CGPoint(x: (referenceX + constrained.x) * 0.5,
                              y: (y0 + constrained.y) * 0.5),
            normal: CGVector(dx: dx / unit, dy: dy / unit),
            distance: distance
        )
    }

    func signedDistance(_ point: CGPoint) -> CGFloat {
        (point.x - midpoint.x) * normal.dx + (point.y - midpoint.y) * normal.dy
    }

    func reflected(_ point: CGPoint) -> CGPoint {
        let s = signedDistance(point)
        return CGPoint(x: point.x - 2 * s * normal.dx,
                       y: point.y - 2 * s * normal.dy)
    }

    /// A finite-radius curl consumes `πr` of paper before it becomes flat on
    /// the back. Moving the hard-fold midpoint by half that arc length makes
    /// the original held edge land on the finger without stretching rows or
    /// applying a per-vertex correction.
    func surfaceMidpoint(radius: CGFloat) -> CGPoint {
        let offset = Self.surfaceShift(distance: distance, radius: radius)
        return CGPoint(x: midpoint.x + normal.dx * offset,
                       y: midpoint.y + normal.dy * offset)
    }

    /// Projects one point of the flat page onto one uniform cylindrical paper
    /// surface. A single radius keeps every row coherent and prevents the free
    /// edge from turning into a wave.
    func surfacePoint(_ point: CGPoint, radius: CGFloat) -> (point: CGPoint, height: CGFloat) {
        let curlMidpoint = surfaceMidpoint(radius: radius)
        let s = (point.x - curlMidpoint.x) * normal.dx
            + (point.y - curlMidpoint.y) * normal.dy
        guard s < 0 else { return (point, 0) }

        let localRadius = max(8, radius)
        let distance = -s
        let arcLength = .pi * localRadius
        let normalPosition: CGFloat
        let z: CGFloat
        if distance < arcLength {
            let angle = distance / localRadius
            normalPosition = -localRadius * sin(angle)
            z = localRadius * (1 - cos(angle))
        } else {
            normalPosition = distance - arcLength
            z = 2 * localRadius
        }

        let foot = CGPoint(x: point.x - s * normal.dx,
                           y: point.y - s * normal.dy)
        return (
            CGPoint(x: foot.x + normalPosition * normal.dx,
                    y: foot.y + normalPosition * normal.dy),
            z
        )
    }

    func foldX(atY y: CGFloat) -> CGFloat? {
        guard abs(normal.dx) > 0.0001 else { return nil }
        return midpoint.x - normal.dy / normal.dx * (y - midpoint.y)
    }

    func foldY(atX x: CGFloat) -> CGFloat? {
        guard abs(normal.dy) > 0.0001 else { return nil }
        return midpoint.y - normal.dx / normal.dy * (x - midpoint.x)
    }

}
