import AppKit

@MainActor
final class InlineTextEditorView: NSView, NSTextViewDelegate {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMetricsChanged: (() -> Void)?

    private(set) var textOrigin: CGPoint
    private(set) var boxWidth: CGFloat
    private(set) var textFontSize: CGFloat
    private(set) var userAdjustedWidth: Bool
    var textColor: NSColor {
        didSet { applyTextStyling() }
    }

    var textString: String {
        textView.string
    }

    private let outerPad: CGFloat = 10.0
    private let handleSize: CGFloat = 8.0
    private let textView: EditorTextView

    private enum DragAction {
        case none
        case moving(startInSuperview: CGPoint, initialOrigin: CGPoint)
        case resizing(handle: BoxResizeHandle, startBoxInSuperview: CGRect, initialFontSize: CGFloat, initialWidth: CGFloat)
    }

    private var dragAction: DragAction = .none

    override var isFlipped: Bool { true }

    init(
        origin: CGPoint,
        initialWidth: CGFloat,
        fontSize: CGFloat,
        color: NSColor,
        initialText: String,
        userAdjustedWidth: Bool
    ) {
        self.textOrigin = origin
        self.boxWidth = max(initialWidth, 60.0)
        self.textFontSize = min(max(fontSize, 10.0), 144.0)
        self.textColor = color
        self.userAdjustedWidth = userAdjustedWidth
        self.textView = EditorTextView(frame: .zero)

        super.init(frame: .zero)

        wantsLayer = true
        configureTextView(initialText: initialText)
        addSubview(textView)
        recalculateFrame()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func focusEditor() {
        window?.makeFirstResponder(textView)
        let len = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: len, length: 0))
    }

    func setFontSize(_ size: CGFloat) {
        textFontSize = min(max(size, 10.0), 144.0)
        applyTextStyling()
        recalculateFrame()
    }

    private func configureTextView(initialText: String) {
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.delegate = self

        textView.onCommitKey = { [weak self] in
            self?.onCommit?()
        }
        textView.onCancelKey = { [weak self] in
            self?.onCancel?()
        }

        textView.string = initialText
        applyTextStyling()
    }

    private func applyTextStyling() {
        let font = NSFont.systemFont(ofSize: textFontSize, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .shadow: shadow
        ]
        textView.typingAttributes = attrs
        textView.insertionPointColor = textColor
        if let storage = textView.textStorage, storage.length > 0 {
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
        }
        needsDisplay = true
    }

    private func recalculateFrame() {
        let width = max(boxWidth, 48.0)
        textView.frame = CGRect(x: outerPad, y: outerPad, width: width, height: 10_000)
        textView.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        if let container = textView.textContainer, let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            let minLineHeight = ceil(textFontSize * 1.35)
            let contentHeight = max(ceil(used.height), minLineHeight)
            textView.frame = CGRect(x: outerPad, y: outerPad, width: width, height: contentHeight)
            frame = CGRect(
                x: textOrigin.x - outerPad,
                y: textOrigin.y - outerPad,
                width: width + outerPad * 2.0,
                height: contentHeight + outerPad * 2.0
            )
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onMetricsChanged?()
    }

    func textDidChange(_ notification: Notification) {
        recalculateFrame()
    }

    private var borderRect: CGRect {
        CGRect(
            x: outerPad,
            y: outerPad,
            width: max(bounds.width - outerPad * 2.0, 20.0),
            height: max(bounds.height - outerPad * 2.0, 16.0)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let box = borderRect

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.fill(box)

        ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(box)
        ctx.setLineDash(phase: 0, lengths: [])

        for handle in BoxResizeHandle.allCases {
            let pt = AnnotationGeometry.handlePoint(for: handle, in: box)
            let r = CGRect(x: pt.x - handleSize / 2, y: pt.y - handleSize / 2, width: handleSize, height: handleSize)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(1.2)
            ctx.fillEllipse(in: r)
            ctx.strokeEllipse(in: r)
        }
        ctx.restoreGState()

        if textView.string.isEmpty {
            let placeholder = "Type & press Enter"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: min(textFontSize, 15.0), weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.50)
            ]
            (placeholder as NSString).draw(at: CGPoint(x: outerPad + 2, y: outerPad + 1), withAttributes: attrs)
        }
    }

    override func resetCursorRects() {
        let box = borderRect
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(textView.frame, cursor: .iBeam)
        for handle in BoxResizeHandle.allCases {
            let pt = AnnotationGeometry.handlePoint(for: handle, in: box)
            let r = CGRect(x: pt.x - 7, y: pt.y - 7, width: 14, height: 14)
            let cursor: NSCursor = switch handle {
            case .left, .right: .resizeLeftRight
            case .top, .bottom: .resizeUpDown
            default: .crosshair
            }
            addCursorRect(r, cursor: cursor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if hitTestHandle(at: local) != nil {
            return self
        }
        if !textView.frame.insetBy(dx: 2, dy: 2).contains(local) {
            return self
        }
        return textView
    }

    override func mouseDown(with event: NSEvent) {
        guard let superview else { return }
        let local = convert(event.locationInWindow, from: nil)
        let ptInSuper = superview.convert(event.locationInWindow, from: nil)

        if let handle = hitTestHandle(at: local) {
            let boxInSuper = CGRect(
                x: textOrigin.x,
                y: textOrigin.y,
                width: borderRect.width,
                height: borderRect.height
            )
            dragAction = .resizing(
                handle: handle,
                startBoxInSuperview: boxInSuper,
                initialFontSize: textFontSize,
                initialWidth: boxWidth
            )
            return
        }

        dragAction = .moving(startInSuperview: ptInSuper, initialOrigin: textOrigin)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let ptInSuper = superview.convert(event.locationInWindow, from: nil)

        switch dragAction {
        case .none:
            break

        case .moving(let start, let initialOrigin):
            textOrigin = CGPoint(
                x: initialOrigin.x + (ptInSuper.x - start.x),
                y: initialOrigin.y + (ptInSuper.y - start.y)
            )
            recalculateFrame()

        case .resizing(let handle, let initialBox, let initialFontSize, let initialWidth):
            let resized = AnnotationGeometry.resizedRect(from: initialBox, handle: handle, to: ptInSuper, minSize: 48.0)
            switch handle {
            case .left, .right:
                userAdjustedWidth = true
                boxWidth = max(resized.width, 48.0)
                textOrigin.x = resized.minX
                textOrigin.y = initialBox.minY

            case .top, .bottom:
                let scale = max(resized.height / max(initialBox.height, 1.0), 0.25)
                textFontSize = min(max(initialFontSize * scale, 10.0), 144.0)
                applyTextStyling()
                recalculateFrame()
                if handle == .top {
                    textOrigin.y = initialBox.maxY - borderRect.height
                } else {
                    textOrigin.y = initialBox.minY
                }

            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                let scaleX = resized.width / max(initialBox.width, 1.0)
                let scaleY = resized.height / max(initialBox.height, 1.0)
                let avgScale = max((scaleX + scaleY) * 0.5, 0.25)
                let nextFont = min(max(initialFontSize * avgScale, 10.0), 144.0)
                let actualScale = nextFont / max(initialFontSize, 1.0)
                textFontSize = nextFont
                boxWidth = max(initialWidth * actualScale, 48.0)
                userAdjustedWidth = true
                applyTextStyling()
                recalculateFrame()

                let anchorsRight = (handle == .topLeft || handle == .bottomLeft)
                let anchorsBottom = (handle == .topLeft || handle == .topRight)
                textOrigin.x = anchorsRight ? (initialBox.maxX - borderRect.width) : initialBox.minX
                textOrigin.y = anchorsBottom ? (initialBox.maxY - borderRect.height) : initialBox.minY
            }
            recalculateFrame()
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragAction = .none
        focusEditor()
    }

    private func hitTestHandle(at localPoint: CGPoint) -> BoxResizeHandle? {
        let box = borderRect
        for handle in BoxResizeHandle.allCases {
            let pt = AnnotationGeometry.handlePoint(for: handle, in: box)
            if hypot(localPoint.x - pt.x, localPoint.y - pt.y) <= 9.0 {
                return handle
            }
        }
        return nil
    }
}

@MainActor
private final class EditorTextView: NSTextView {
    var onCommitKey: (() -> Void)?
    var onCancelKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { // Esc
            onCancelKey?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            if flags.contains(.shift) || flags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onCommitKey?()
            }
            return
        }
        super.keyDown(with: event)
    }
}
