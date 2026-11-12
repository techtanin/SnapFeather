import AppKit

enum AnnotationTool: String, CaseIterable, Sendable {
    case select
    case pen
    case line
    case arrow
    case rectangle
    case ellipse
    case marker
    case text

    var title: String {
        switch self {
        case .select: return "Select / Move Region or Item (1)"
        case .pen: return "Pen (Freehand)"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .marker: return "Marker (Highlighter)"
        case .text: return "Text"
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .marker: return "highlighter"
        case .text: return "textformat"
        }
    }
}

struct AnnotationColorPreset: Sendable {
    let name: String
    let color: NSColor

    static let palette: [AnnotationColorPreset] = [
        AnnotationColorPreset(name: "Crimson", color: NSColor(calibratedRed: 0.94, green: 0.22, blue: 0.24, alpha: 1.0)),
        AnnotationColorPreset(name: "Orange", color: NSColor(calibratedRed: 0.98, green: 0.52, blue: 0.12, alpha: 1.0)),
        AnnotationColorPreset(name: "Amber", color: NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.15, alpha: 1.0)),
        AnnotationColorPreset(name: "Emerald", color: NSColor(calibratedRed: 0.13, green: 0.77, blue: 0.42, alpha: 1.0)),
        AnnotationColorPreset(name: "Sky", color: NSColor(calibratedRed: 0.14, green: 0.56, blue: 0.98, alpha: 1.0)),
        AnnotationColorPreset(name: "Violet", color: NSColor(calibratedRed: 0.62, green: 0.34, blue: 0.96, alpha: 1.0)),
        AnnotationColorPreset(name: "White", color: .white),
        AnnotationColorPreset(name: "Black", color: .black)
    ]
}

enum AnnotationItem: Sendable {
    case stroke(StrokeAnnotation)
    case shape(ShapeAnnotation)
    case text(TextAnnotation)

    func draw(in context: CGContext, offset: CGPoint = .zero) {
        switch self {
        case .stroke(let stroke):
            stroke.draw(in: context, offset: offset)
        case .shape(let shape):
            shape.draw(in: context, offset: offset)
        case .text(let text):
            text.draw(in: context, offset: offset)
        }
    }

    var boundingBox: CGRect {
        switch self {
        case .stroke(let stroke):
            return stroke.boundingBox
        case .shape(let shape):
            return shape.boundingBox
        case .text(let text):
            return text.boundingBox
        }
    }

    func hitTest(point: CGPoint, tolerance: CGFloat = 10.0) -> Bool {
        switch self {
        case .stroke(let stroke):
            return stroke.hitTest(point: point, tolerance: tolerance)
        case .shape(let shape):
            return shape.hitTest(point: point, tolerance: tolerance)
        case .text(let text):
            return text.hitTest(point: point, tolerance: tolerance)
        }
    }

    func translated(by delta: CGVector) -> AnnotationItem {
        switch self {
        case .stroke(var stroke):
            stroke.points = stroke.points.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
            return .stroke(stroke)
        case .shape(var shape):
            shape.start = CGPoint(x: shape.start.x + delta.dx, y: shape.start.y + delta.dy)
            shape.end = CGPoint(x: shape.end.x + delta.dx, y: shape.end.y + delta.dy)
            return .shape(shape)
        case .text(var text):
            text.origin = CGPoint(x: text.origin.x + delta.dx, y: text.origin.y + delta.dy)
            return .text(text)
        }
    }
}

struct StrokeAnnotation: Sendable {
    enum Kind: Sendable {
        case pen
        case marker
    }

    var kind: Kind
    var points: [CGPoint]
    var color: NSColor
    var lineWidth: CGFloat

    func draw(in context: CGContext, offset: CGPoint = .zero) {
        guard !points.isEmpty else { return }

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if kind == .marker {
            context.setStrokeColor(color.withAlphaComponent(0.38).cgColor)
            context.setLineWidth(max(lineWidth * 4.5, 14.0))
        } else {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(lineWidth)
        }

        let shifted = points.map { CGPoint(x: $0.x - offset.x, y: $0.y - offset.y) }
        if shifted.count == 1 {
            let p = shifted[0]
            let r = (kind == .marker ? max(lineWidth * 2.25, 7.0) : lineWidth / 2.0)
            context.setFillColor(kind == .marker ? color.withAlphaComponent(0.38).cgColor : color.cgColor)
            context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        } else {
            context.beginPath()
            context.move(to: shifted[0])
            for i in 1..<shifted.count {
                let prev = shifted[i - 1]
                let curr = shifted[i]
                let mid = CGPoint(x: (prev.x + curr.x) / 2.0, y: (prev.y + curr.y) / 2.0)
                context.addQuadCurve(to: mid, control: prev)
            }
            if let last = shifted.last {
                context.addLine(to: last)
            }
            context.strokePath()
        }
        context.restoreGState()
    }
}

struct ShapeAnnotation: Sendable {
    enum Kind: Sendable {
        case line
        case arrow
        case rectangle
        case ellipse
    }

    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    var lineWidth: CGFloat

    func draw(in context: CGContext, offset: CGPoint = .zero) {
        let p1 = CGPoint(x: start.x - offset.x, y: start.y - offset.y)
        let p2 = CGPoint(x: end.x - offset.x, y: end.y - offset.y)

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch kind {
        case .line:
            context.beginPath()
            context.move(to: p1)
            context.addLine(to: p2)
            context.strokePath()

        case .arrow:
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let length = hypot(dx, dy)
            guard length > 0.5 else {
                context.restoreGState()
                return
            }

            let headLength = min(max(lineWidth * 4.5, 14.0), length * 0.45)
            let headAngle: CGFloat = .pi / 6.5
            let angle = atan2(dy, dx)

            let shaftEnd = CGPoint(
                x: p2.x - cos(angle) * (headLength * 0.65),
                y: p2.y - sin(angle) * (headLength * 0.65)
            )

            context.beginPath()
            context.move(to: p1)
            context.addLine(to: shaftEnd)
            context.strokePath()

            let leftWing = CGPoint(
                x: p2.x - headLength * cos(angle - headAngle),
                y: p2.y - headLength * sin(angle - headAngle)
            )
            let rightWing = CGPoint(
                x: p2.x - headLength * cos(angle + headAngle),
                y: p2.y - headLength * sin(angle + headAngle)
            )

            context.beginPath()
            context.move(to: p2)
            context.addLine(to: leftWing)
            context.addLine(to: rightWing)
            context.closePath()
            context.fillPath()

        case .rectangle:
            let rect = CGRect.normalized(from: p1, to: p2)
            context.stroke(rect)

        case .ellipse:
            let rect = CGRect.normalized(from: p1, to: p2)
            context.strokeEllipse(in: rect)
        }

        context.restoreGState()
    }
}

struct TextAnnotation: Sendable {
    var origin: CGPoint
    var text: String
    var color: NSColor
    var fontSize: CGFloat

    func draw(in context: CGContext, offset: CGPoint = .zero) {
        guard !text.isEmpty else { return }

        let drawOrigin = CGPoint(x: origin.x - offset.x, y: origin.y - offset.y)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .shadow: shadow
        ]

        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext
        (text as NSString).draw(at: drawOrigin, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension CGRect {
    static func normalized(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    func clamped(to bounds: CGRect) -> CGRect {
        let minX = max(bounds.minX, min(self.minX, bounds.maxX))
        let minY = max(bounds.minY, min(self.minY, bounds.maxY))
        let maxX = max(minX, min(self.maxX, bounds.maxX))
        let maxY = max(minY, min(self.maxY, bounds.maxY))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension StrokeAnnotation {
    private var effectiveStrokeWidth: CGFloat {
        kind == .marker ? max(lineWidth * 4.5, 14.0) : lineWidth
    }

    var boundingBox: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for pt in points.dropFirst() {
            minX = min(minX, pt.x)
            maxX = max(maxX, pt.x)
            minY = min(minY, pt.y)
            maxY = max(maxY, pt.y)
        }
        let pad = effectiveStrokeWidth / 2.0
        return CGRect(x: minX - pad, y: minY - pad, width: (maxX - minX) + pad * 2, height: (maxY - minY) + pad * 2)
    }

    func hitTest(point: CGPoint, tolerance: CGFloat = 10.0) -> Bool {
        let threshold = tolerance + effectiveStrokeWidth / 2.0
        guard boundingBox.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        if points.count == 1 {
            return hypot(point.x - points[0].x, point.y - points[0].y) <= threshold
        }
        for i in 1..<points.count {
            if GeometryHelpers.distanceFromPoint(point, toSegmentStart: points[i - 1], end: points[i]) <= threshold {
                return true
            }
        }
        return false
    }
}

extension ShapeAnnotation {
    var boundingBox: CGRect {
        let pad = max(lineWidth / 2.0, 4.0)
        return CGRect.normalized(from: start, to: end).insetBy(dx: -pad, dy: -pad)
    }

    func hitTest(point: CGPoint, tolerance: CGFloat = 10.0) -> Bool {
        let threshold = tolerance + lineWidth / 2.0
        switch kind {
        case .line, .arrow:
            return GeometryHelpers.distanceFromPoint(point, toSegmentStart: start, end: end) <= threshold
        case .rectangle:
            let rect = CGRect.normalized(from: start, to: end)
            let outer = rect.insetBy(dx: -threshold, dy: -threshold)
            let inner = rect.insetBy(dx: threshold, dy: threshold)
            if inner.width > 0, inner.height > 0 {
                return outer.contains(point) && !inner.contains(point)
            }
            return outer.contains(point)
        case .ellipse:
            let rect = CGRect.normalized(from: start, to: end)
            let rx = rect.width / 2.0
            let ry = rect.height / 2.0
            guard rx > 1, ry > 1 else {
                return rect.insetBy(dx: -threshold, dy: -threshold).contains(point)
            }
            let cx = rect.midX
            let cy = rect.midY
            let dx = point.x - cx
            let dy = point.y - cy
            // Approximate Euclidean distance to ellipse perimeter
            let norm = hypot(dx / rx, dy / ry)
            guard norm > 0.001 else { return false }
            let nearestX = cx + dx / norm
            let nearestY = cy + dy / norm
            return hypot(point.x - nearestX, point.y - nearestY) <= threshold
        }
    }
}

extension TextAnnotation {
    var boundingBox: CGRect {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGRect(origin: origin, size: size)
    }

    func hitTest(point: CGPoint, tolerance: CGFloat = 10.0) -> Bool {
        let pad = max(tolerance * 0.5, 4.0)
        return boundingBox.insetBy(dx: -pad, dy: -pad).contains(point)
    }
}

private enum GeometryHelpers {
    static func distanceFromPoint(_ p: CGPoint, toSegmentStart a: CGPoint, end b: CGPoint) -> CGFloat {
        let vx = b.x - a.x
        let vy = b.y - a.y
        let wx = p.x - a.x
        let wy = p.y - a.y
        let c1 = vx * wx + vy * wy
        if c1 <= 0 {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let c2 = vx * vx + vy * vy
        if c2 <= c1 {
            return hypot(p.x - b.x, p.y - b.y)
        }
        let t = c1 / c2
        let proj = CGPoint(x: a.x + t * vx, y: a.y + t * vy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }
}
