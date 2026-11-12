import AppKit

@MainActor
protocol CaptureSessionDelegate: AnyObject {
    func captureSessionDidCancel()
    func captureSessionDidComplete(with image: NSImage, action: CaptureCompletionAction)
}

enum CaptureCompletionAction: Sendable {
    case copy
    case quickSave
    case saveAs
    case uploadToDrive
    case print
}

@MainActor
final class CaptureSessionCoordinator: CaptureSessionDelegate {
    private var windows: [CaptureOverlayWindow] = []
    private var activeWindow: CaptureOverlayWindow?
    private let onFinish: @MainActor () -> Void

    init(snapshots: [ScreenSnapshot], onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
        for snapshot in snapshots {
            let win = CaptureOverlayWindow(snapshot: snapshot, coordinator: self)
            windows.append(win)
        }
    }

    func start() {
        NSApp.activate(ignoringOtherApps: true)
        for win in windows {
            win.makeKeyAndOrderFront(nil)
        }
        if let mouseWindow = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? windows.first {
            mouseWindow.makeKey()
            activeWindow = mouseWindow
        }
    }

    func notifySelectionStarted(in sourceWindow: CaptureOverlayWindow) {
        activeWindow = sourceWindow
        for win in windows where win !== sourceWindow {
            win.clearSelectionFromPeer()
        }
    }

    func captureSessionDidCancel() {
        closeAll()
    }

    func captureSessionDidComplete(with image: NSImage, action: CaptureCompletionAction) {
        switch action {
        case .copy:
            ImageExporter.copyToClipboard(image)
            closeAll()
            let prefs = AppPreferences.shared
            if prefs.autoSaveToDriveOnCopy {
                if GoogleDriveService.shared.isAuthorized {
                    HUDToast.show(message: "Copied • Saving to Drive...")
                    let filename = ImageExporter.defaultFilename(format: prefs.imageFormat)
                    uploadToGoogleDrive(image: image, format: prefs.imageFormat, filename: filename, copyShareLink: false)
                } else {
                    HUDToast.show(message: "Copied (Drive not authorized)")
                }
            } else {
                HUDToast.show(message: "Copied to clipboard")
            }

        case .quickSave:
            let prefs = AppPreferences.shared
            let folder = prefs.saveDirectory
            let filename = ImageExporter.defaultFilename(format: prefs.imageFormat)
            let targetURL = folder.appendingPathComponent(filename)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try ImageExporter.write(image, to: targetURL, format: prefs.imageFormat)
                if prefs.copyToClipboardOnSave {
                    ImageExporter.copyToClipboard(image)
                }
                closeAll()
                HUDToast.show(message: "Saved \(filename)")
                if prefs.autoSaveToDriveOnSave && GoogleDriveService.shared.isAuthorized {
                    uploadToGoogleDrive(image: image, format: prefs.imageFormat, filename: filename, copyShareLink: false)
                }
            } catch {
                presentSaveError(error)
            }

        case .saveAs:
            let prefs = AppPreferences.shared
            // Temporarily hide overlay windows so the native save panel is frontmost
            windows.forEach { $0.orderOut(nil) }

            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.directoryURL = prefs.saveDirectory
            panel.nameFieldStringValue = ImageExporter.defaultFilename(format: prefs.imageFormat)
            panel.allowedContentTypes = [prefs.imageFormat.contentType]

            let accessory = SavePanelFormatAccessory(panel: panel, initialFormat: prefs.imageFormat)
            panel.accessoryView = accessory.view

            let response = panel.runModal()
            if response == .OK, let url = panel.url {
                let resolvedFormat = ImageFormat.from(fileExtension: url.pathExtension) ?? accessory.selectedFormat
                do {
                    try ImageExporter.write(image, to: url, format: resolvedFormat)
                    if prefs.copyToClipboardOnSave {
                        ImageExporter.copyToClipboard(image)
                    }
                    closeAll()
                    HUDToast.show(message: "Saved \(url.lastPathComponent)")
                    if prefs.autoSaveToDriveOnSave && GoogleDriveService.shared.isAuthorized {
                        uploadToGoogleDrive(image: image, format: resolvedFormat, filename: url.lastPathComponent, copyShareLink: false)
                    }
                } catch {
                    closeAll()
                    presentSaveError(error)
                }
            } else {
                // Restore overlay if user cancelled Save dialog
                windows.forEach { $0.makeKeyAndOrderFront(nil) }
                activeWindow?.makeKey()
            }

        case .uploadToDrive:
            let prefs = AppPreferences.shared
            guard GoogleDriveService.shared.isAuthorized else {
                closeAll()
                NotificationCenter.default.post(name: .snapFeatherOpenDrivePreferences, object: nil)
                return
            }
            closeAll()
            HUDToast.show(message: "Uploading to Google Drive...", symbolName: "icloud.and.arrow.up.fill")
            let filename = ImageExporter.defaultFilename(format: prefs.imageFormat)
            uploadToGoogleDrive(
                image: image,
                format: prefs.imageFormat,
                filename: filename,
                copyShareLink: prefs.makeDriveFilesShareable
            )

        case .print:
            windows.forEach { $0.orderOut(nil) }
            let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
            imageView.image = image
            let printOp = NSPrintOperation(view: imageView)
            printOp.showsPrintPanel = true
            printOp.run()
            closeAll()
        }
    }

    private func closeAll() {
        for win in windows {
            win.orderOut(nil)
            win.close()
        }
        windows.removeAll()
        onFinish()
    }

    private func presentSaveError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Save Screenshot"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func uploadToGoogleDrive(
        image: NSImage,
        format: ImageFormat,
        filename: String,
        copyShareLink: Bool
    ) {
        Task { @MainActor in
            do {
                let result = try await GoogleDriveService.shared.uploadScreenshot(
                    image: image,
                    format: format,
                    filename: filename
                )
                Diagnostics.log("Uploaded \(result.name) to Google Drive (id=\(result.fileId))")
                if copyShareLink, let link = result.webViewLink {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(link, forType: .string)
                    HUDToast.show(message: "Uploaded & link copied")
                } else if AppPreferences.shared.showDriveUploadNotification {
                    HUDToast.show(message: "Saved to Google Drive", symbolName: "icloud.and.arrow.up.fill")
                }
            } catch {
                Diagnostics.log("Google Drive upload error: \(error.localizedDescription)")
                HUDToast.show(message: "Drive upload failed", symbolName: "exclamationmark.icloud.fill")
            }
        }
    }
}

extension Notification.Name {
    static let snapFeatherOpenDrivePreferences = Notification.Name("SnapFeather.openDrivePreferences")
}

@MainActor
final class CaptureOverlayWindow: NSWindow {
    private let canvasView: CaptureCanvasView

    init(snapshot: ScreenSnapshot, coordinator: CaptureSessionCoordinator) {
        let frame = snapshot.screen.frame
        self.canvasView = CaptureCanvasView(
            frame: NSRect(origin: .zero, size: frame.size),
            snapshot: snapshot,
            coordinator: coordinator
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.setFrame(frame, display: false)

        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isOpaque = true
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true
        self.isReleasedWhenClosed = false
        self.contentView = canvasView
        self.makeFirstResponder(canvasView)
        canvasView.ownerWindow = self
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func clearSelectionFromPeer() {
        canvasView.clearSelection()
    }
}

private enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight
}

private enum DragMode {
    case none
    case creatingSelection(anchor: CGPoint)
    case movingSelection(startPoint: CGPoint, initialRect: CGRect)
    case movingAnnotation(index: Int, startPoint: CGPoint, originalItem: AnnotationItem)
    case resizingSelection(handle: ResizeHandle, initialRect: CGRect)
    case drawingAnnotation
}

@MainActor
final class CaptureCanvasView: NSView, FloatingToolbarsDelegate, NSTextFieldDelegate {
    weak var ownerWindow: CaptureOverlayWindow?
    private weak var coordinator: CaptureSessionCoordinator?

    private let snapshot: ScreenSnapshot
    private let backgroundImage: NSImage

    private var selectionRect: CGRect? {
        didSet { updateToolbarsLayout() }
    }
    private var hoverPoint: CGPoint?
    private var dragMode: DragMode = .none

    private var activeTool: AnnotationTool = .select
    private var activeColor: NSColor = AnnotationColorPreset.palette[0].color
    private var activeLineWidth: CGFloat = AppPreferences.shared.strokeWidth
    private var activeTextFontSize: CGFloat = AppPreferences.shared.textFontSize

    private var sizeIndicatorText: String?
    private var sizeIndicatorTask: Task<Void, Never>?

    private var annotations: [AnnotationItem] = []
    private var inProgressItem: AnnotationItem?
    private var selectedAnnotationIndex: Int?

    private let verticalToolbar = VerticalAnnotationToolbar()
    private let horizontalToolbar = HorizontalActionToolbar()
    private var activeTextField: NSTextField?
    private var activeTextOrigin: CGPoint = .zero

    private let handleSize: CGFloat = 8.0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame frameRect: NSRect, snapshot: ScreenSnapshot, coordinator: CaptureSessionCoordinator) {
        self.snapshot = snapshot
        self.coordinator = coordinator
        self.backgroundImage = NSImage(cgImage: snapshot.cgImage, size: frameRect.size)
        super.init(frame: frameRect)

        verticalToolbar.delegate = self
        horizontalToolbar.delegate = self
        verticalToolbar.isHidden = true
        horizontalToolbar.isHidden = true

        addSubview(verticalToolbar)
        addSubview(horizontalToolbar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
    }

    func clearSelection() {
        commitActiveTextField()
        selectionRect = nil
        annotations.removeAll()
        inProgressItem = nil
        selectedAnnotationIndex = nil
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        backgroundImage.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if let sel = selectionRect, sel.width > 1, sel.height > 1 {
            // Dim everything outside selection using even-odd fill
            ctx.saveGState()
            ctx.beginPath()
            ctx.addRect(bounds)
            ctx.addRect(sel)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.52).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()

            // Clip and draw annotations inside selection
            ctx.saveGState()
            ctx.clip(to: sel)
            for item in annotations {
                item.draw(in: ctx)
            }
            inProgressItem?.draw(in: ctx)
            if let idx = selectedAnnotationIndex, annotations.indices.contains(idx) {
                drawAnnotationSelectionHighlight(for: annotations[idx], in: ctx)
            }
            ctx.restoreGState()

            // Selection border
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(sel)

            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.setLineWidth(1.0)
            ctx.stroke(sel)
            ctx.restoreGState()

            // 8 resize handles
            for handle in ResizeHandle.allCases {
                let hr = handleRect(for: handle, in: sel)
                ctx.saveGState()
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                ctx.setLineWidth(1.0)
                ctx.fillEllipse(in: hr)
                ctx.strokeEllipse(in: hr)
                ctx.restoreGState()
            }

            drawDimensionBadge(for: sel)

            if let pt = hoverPoint, sel.contains(pt), activeTool != .select, activeTool != .text {
                switch dragMode {
                case .none, .drawingAnnotation:
                    drawCursorBrushPreview(at: pt, in: ctx)
                default:
                    break
                }
            }

            if let sizeText = sizeIndicatorText {
                drawSizeIndicatorBadge(text: sizeText, near: hoverPoint ?? CGPoint(x: sel.midX, y: sel.midY))
            }
        } else {
            // Full screen dim before selection
            ctx.saveGState()
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.fill(bounds)
            ctx.restoreGState()

            if AppPreferences.shared.showCrosshairs, let pt = hoverPoint {
                drawCrosshairs(at: pt, in: ctx)
            }
            drawHintBanner()
        }
    }

    private func drawCrosshairs(at point: CGPoint, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: [5, 5])

        ctx.beginPath()
        ctx.move(to: CGPoint(x: point.x, y: 0))
        ctx.addLine(to: CGPoint(x: point.x, y: bounds.height))
        ctx.move(to: CGPoint(x: 0, y: point.y))
        ctx.addLine(to: CGPoint(x: bounds.width, y: point.y))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawHintBanner() {
        let text = "Drag to select region  •  Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pillRect = CGRect(
            x: (bounds.width - size.width - 28) / 2,
            y: 36,
            width: size.width + 28,
            height: size.height + 14
        )
        let path = NSBezierPath(roundedRect: pillRect, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()

        (text as NSString).draw(
            at: CGPoint(x: pillRect.minX + 14, y: pillRect.minY + 7),
            withAttributes: attrs
        )
    }

    private func drawAnnotationSelectionHighlight(for item: AnnotationItem, in ctx: CGContext) {
        let box = item.boundingBox.insetBy(dx: -5, dy: -5)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(box)
        ctx.setLineDash(phase: 0, lengths: [])

        let dot: CGFloat = 5
        let corners = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY),
            CGPoint(x: box.maxX, y: box.maxY)
        ]
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.systemCyan.cgColor)
        ctx.setLineWidth(1.0)
        for corner in corners {
            let r = CGRect(x: corner.x - dot / 2, y: corner.y - dot / 2, width: dot, height: dot)
            ctx.fill(r)
            ctx.stroke(r)
        }
        ctx.restoreGState()
    }

    private func drawDimensionBadge(for sel: CGRect) {
        let pxW = Int(round(sel.width * snapshot.backingScaleFactor))
        let pxH = Int(round(sel.height * snapshot.backingScaleFactor))
        let label = "\(Int(round(sel.width))) × \(Int(round(sel.height)))  (\(pxW)×\(pxH)px)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let badgeW = textSize.width + 16
        let badgeH = textSize.height + 8

        var badgeY = sel.minY - badgeH - 6
        if badgeY < 6 {
            badgeY = sel.minY + 6
        }
        let badgeX = min(max(sel.minX, 6), bounds.width - badgeW - 6)
        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)

        let path = NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.78).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        (label as NSString).draw(
            at: CGPoint(x: badgeRect.minX + 8, y: badgeRect.minY + 4),
            withAttributes: attrs
        )
    }

    private func drawCursorBrushPreview(at point: CGPoint, in ctx: CGContext) {
        let diameter: CGFloat = activeTool == .marker
            ? max(activeLineWidth * 4.5, 14.0)
            : max(activeLineWidth, 2.0)
        let radius = diameter / 2.0
        let circleRect = CGRect(x: point.x - radius, y: point.y - radius, width: diameter, height: diameter)

        ctx.saveGState()
        let fillAlpha: CGFloat = activeTool == .marker ? 0.30 : 0.20
        ctx.setFillColor(activeColor.withAlphaComponent(fillAlpha).cgColor)
        ctx.fillEllipse(in: circleRect)

        // Outer dark halo + inner crisp color/white ring for high contrast on any background
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        ctx.setLineWidth(2.0)
        ctx.strokeEllipse(in: circleRect)

        ctx.setStrokeColor(activeColor == .black ? NSColor.white.cgColor : activeColor.cgColor)
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: circleRect)
        ctx.restoreGState()
    }

    private func drawSizeIndicatorBadge(text: String, near point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let badgeW = size.width + 16
        let badgeH = size.height + 8
        let x = min(max(point.x + 18, 8), bounds.width - badgeW - 8)
        let y = min(max(point.y - badgeH - 12, 8), bounds.height - badgeH - 8)
        let rect = CGRect(x: x, y: y, width: badgeW, height: badgeH)

        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.80).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        path.lineWidth = 1
        path.stroke()

        (text as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 4), withAttributes: attrs)
    }

    // MARK: - Mouse Events

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoverPoint = pt
        updateCursor(at: pt)
        if selectionRect == nil || (activeTool != .select && activeTool != .text) {
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let hasOption = event.modifierFlags.contains(.option)
        let isDrawingOrText = selectionRect != nil && (activeTool != .select || activeTextField != nil)
        guard hasOption || isDrawingOrText else {
            super.scrollWheel(with: event)
            return
        }

        let rawDelta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY * 0.08
            : event.scrollingDeltaY * 0.65
        guard abs(rawDelta) > 0.01 else { return }
        adjustActiveSize(by: rawDelta)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        if let tf = activeTextField, !tf.frame.contains(pt) {
            commitActiveTextField()
        }

        if let sel = selectionRect {
            if let handle = hitTestHandle(at: pt, in: sel) {
                dragMode = .resizingSelection(handle: handle, initialRect: sel)
                return
            }

            if sel.contains(pt) {
                switch activeTool {
                case .select:
                    if let hitIndex = hitTestAnnotationIndex(at: pt) {
                        selectedAnnotationIndex = hitIndex
                        dragMode = .movingAnnotation(
                            index: hitIndex,
                            startPoint: pt,
                            originalItem: annotations[hitIndex]
                        )
                        NSCursor.closedHand.set()
                    } else {
                        selectedAnnotationIndex = nil
                        dragMode = .movingSelection(startPoint: pt, initialRect: sel)
                    }
                case .pen:
                    dragMode = .drawingAnnotation
                    inProgressItem = .stroke(StrokeAnnotation(
                        kind: .pen,
                        points: [pt],
                        color: activeColor,
                        lineWidth: activeLineWidth
                    ))
                case .marker:
                    dragMode = .drawingAnnotation
                    inProgressItem = .stroke(StrokeAnnotation(
                        kind: .marker,
                        points: [pt],
                        color: activeColor,
                        lineWidth: activeLineWidth
                    ))
                case .line, .arrow, .rectangle, .ellipse:
                    dragMode = .drawingAnnotation
                    let kind: ShapeAnnotation.Kind = switch activeTool {
                    case .line: .line
                    case .arrow: .arrow
                    case .rectangle: .rectangle
                    default: .ellipse
                    }
                    inProgressItem = .shape(ShapeAnnotation(
                        kind: kind,
                        start: pt,
                        end: pt,
                        color: activeColor,
                        lineWidth: activeLineWidth
                    ))
                case .text:
                    beginInlineTextInput(at: pt, within: sel)
                }
                needsDisplay = true
                return
            }
        }

        // Start a fresh selection
        if let ownerWindow {
            coordinator?.notifySelectionStarted(in: ownerWindow)
        }
        annotations.removeAll()
        inProgressItem = nil
        selectedAnnotationIndex = nil
        verticalToolbar.isHidden = true
        horizontalToolbar.isHidden = true
        dragMode = .creatingSelection(anchor: pt)
        selectionRect = CGRect(origin: pt, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil).clamped(to: bounds)
        hoverPoint = pt

        switch dragMode {
        case .none:
            break

        case .creatingSelection(let anchor):
            selectionRect = CGRect.normalized(from: anchor, to: pt)
            needsDisplay = true

        case .movingSelection(let startPoint, let initialRect):
            let dx = pt.x - startPoint.x
            let dy = pt.y - startPoint.y
            var moved = initialRect.offsetBy(dx: dx, dy: dy)
            moved.origin.x = min(max(moved.origin.x, 0), bounds.width - moved.width)
            moved.origin.y = min(max(moved.origin.y, 0), bounds.height - moved.height)
            selectionRect = moved
            needsDisplay = true

        case .movingAnnotation(let index, let startPoint, let originalItem):
            guard annotations.indices.contains(index) else { return }
            let delta = CGVector(dx: pt.x - startPoint.x, dy: pt.y - startPoint.y)
            annotations[index] = originalItem.translated(by: delta)
            needsDisplay = true

        case .resizingSelection(let handle, let initialRect):
            selectionRect = resizedRect(from: initialRect, handle: handle, to: pt).clamped(to: bounds)
            needsDisplay = true

        case .drawingAnnotation:
            guard var current = inProgressItem else { return }
            switch current {
            case .stroke(var stroke):
                if let last = stroke.points.last {
                    if hypot(pt.x - last.x, pt.y - last.y) >= 1.2 {
                        stroke.points.append(pt)
                    }
                } else {
                    stroke.points.append(pt)
                }
                current = .stroke(stroke)
            case .shape(var shape):
                shape.end = pt
                current = .shape(shape)
            case .text:
                break
            }
            inProgressItem = current
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .creatingSelection:
            if let sel = selectionRect, (sel.width < 6 || sel.height < 6) {
                selectionRect = nil
            }
        case .drawingAnnotation:
            if let item = inProgressItem {
                annotations.append(item)
                inProgressItem = nil
            }
        default:
            break
        }
        dragMode = .none
        updateToolbarsLayout()
        updateCursor(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    // MARK: - Keyboard Shortcuts

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53 { // Esc
            if activeTextField != nil {
                activeTextField?.removeFromSuperview()
                activeTextField = nil
                window?.makeFirstResponder(self)
                return
            }
            coordinator?.captureSessionDidCancel()
            return
        }

        if activeTextField != nil {
            super.keyDown(with: event)
            return
        }

        if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "c":
                toolbarsDidClickCopy()
                return
            case "s":
                toolbarsDidClickSaveAs()
                return
            case "z":
                toolbarsDidClickUndo()
                return
            case "p":
                toolbarsDidClickPrint()
                return
            default:
                break
            }
        }

        if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            if selectionRect != nil {
                toolbarsDidClickCopy()
                return
            }
        }

        if let idx = selectedAnnotationIndex, annotations.indices.contains(idx) {
            if event.keyCode == 51 || event.keyCode == 117 { // Delete / Forward Delete
                annotations.remove(at: idx)
                selectedAnnotationIndex = nil
                needsDisplay = true
                return
            }

            let step: CGFloat = flags.contains(.shift) ? 10.0 : 1.0
            switch event.keyCode {
            case 123: // Left
                annotations[idx] = annotations[idx].translated(by: CGVector(dx: -step, dy: 0))
                needsDisplay = true
                return
            case 124: // Right
                annotations[idx] = annotations[idx].translated(by: CGVector(dx: step, dy: 0))
                needsDisplay = true
                return
            case 125: // Down (flipped coordinates)
                annotations[idx] = annotations[idx].translated(by: CGVector(dx: 0, dy: step))
                needsDisplay = true
                return
            case 126: // Up (flipped coordinates)
                annotations[idx] = annotations[idx].translated(by: CGVector(dx: 0, dy: -step))
                needsDisplay = true
                return
            default:
                break
            }
        }

        if flags.isEmpty, let chars = event.charactersIgnoringModifiers {
            if chars == "[" || chars == "-" {
                adjustActiveSize(by: -1.0)
                return
            }
            if chars == "]" || chars == "=" || chars == "+" {
                adjustActiveSize(by: 1.0)
                return
            }

            let tools = AnnotationTool.allCases
            if let digit = Int(chars), digit >= 1, digit <= tools.count {
                let chosen = tools[digit - 1]
                activeTool = chosen
                verticalToolbar.selectedTool = chosen
                if chosen != .select {
                    selectedAnnotationIndex = nil
                }
                needsDisplay = true
                return
            }
        }

        super.keyDown(with: event)
    }

    // MARK: - Inline Text

    private func beginInlineTextInput(at point: CGPoint, within sel: CGRect) {
        commitActiveTextField()

        let fieldWidth = max(140, min(280, sel.maxX - point.x - 8))
        let fieldHeight = max(28, ceil(activeTextFontSize * 1.45) + 8)
        let fieldY = min(max(point.y - 4, 4), bounds.height - fieldHeight - 4)
        let field = NSTextField(frame: NSRect(x: point.x, y: fieldY, width: fieldWidth, height: fieldHeight))
        field.font = NSFont.systemFont(ofSize: round(activeTextFontSize), weight: .semibold)
        field.textColor = activeColor
        field.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        field.isBordered = true
        field.isBezeled = true
        field.focusRingType = .none
        field.placeholderString = "Type & press Enter"
        field.delegate = self

        addSubview(field)
        window?.makeFirstResponder(field)
        activeTextField = field
        activeTextOrigin = point
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitActiveTextField()
    }

    private func commitActiveTextField() {
        guard let field = activeTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .newlines)
        let fontSize = field.font?.pointSize ?? 16
        field.removeFromSuperview()
        activeTextField = nil
        window?.makeFirstResponder(self)

        if !text.isEmpty {
            annotations.append(.text(TextAnnotation(
                origin: activeTextOrigin,
                text: text,
                color: activeColor,
                fontSize: fontSize
            )))
            needsDisplay = true
        }
    }

    // MARK: - Resize Handle Math

    private func handleRect(for handle: ResizeHandle, in sel: CGRect) -> CGRect {
        let pt: CGPoint = switch handle {
        case .topLeft: CGPoint(x: sel.minX, y: sel.minY)
        case .top: CGPoint(x: sel.midX, y: sel.minY)
        case .topRight: CGPoint(x: sel.maxX, y: sel.minY)
        case .left: CGPoint(x: sel.minX, y: sel.midY)
        case .right: CGPoint(x: sel.maxX, y: sel.midY)
        case .bottomLeft: CGPoint(x: sel.minX, y: sel.maxY)
        case .bottom: CGPoint(x: sel.midX, y: sel.maxY)
        case .bottomRight: CGPoint(x: sel.maxX, y: sel.maxY)
        }
        return CGRect(
            x: pt.x - handleSize / 2,
            y: pt.y - handleSize / 2,
            width: handleSize,
            height: handleSize
        )
    }

    private func hitTestHandle(at point: CGPoint, in sel: CGRect) -> ResizeHandle? {
        for handle in ResizeHandle.allCases {
            let expanded = handleRect(for: handle, in: sel).insetBy(dx: -5, dy: -5)
            if expanded.contains(point) {
                return handle
            }
        }
        return nil
    }

    private func resizedRect(from initial: CGRect, handle: ResizeHandle, to pt: CGPoint) -> CGRect {
        var minX = initial.minX
        var maxX = initial.maxX
        var minY = initial.minY
        var maxY = initial.maxY

        switch handle {
        case .topLeft:
            minX = min(pt.x, maxX - 10)
            minY = min(pt.y, maxY - 10)
        case .top:
            minY = min(pt.y, maxY - 10)
        case .topRight:
            maxX = max(pt.x, minX + 10)
            minY = min(pt.y, maxY - 10)
        case .left:
            minX = min(pt.x, maxX - 10)
        case .right:
            maxX = max(pt.x, minX + 10)
        case .bottomLeft:
            minX = min(pt.x, maxX - 10)
            maxY = max(pt.y, minY + 10)
        case .bottom:
            maxY = max(pt.y, minY + 10)
        case .bottomRight:
            maxX = max(pt.x, minX + 10)
            maxY = max(pt.y, minY + 10)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func hitTestAnnotationIndex(at point: CGPoint) -> Int? {
        for index in annotations.indices.reversed() {
            if annotations[index].hitTest(point: point) {
                return index
            }
        }
        return nil
    }

    private func updateCursor(at point: CGPoint) {
        guard let sel = selectionRect else {
            NSCursor.crosshair.set()
            return
        }
        if let handle = hitTestHandle(at: point, in: sel) {
            switch handle {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
            return
        }
        if sel.contains(point) {
            if activeTool == .select {
                if hitTestAnnotationIndex(at: point) != nil {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.openHand.set()
                }
            } else if activeTool == .text {
                NSCursor.iBeam.set()
            } else {
                NSCursor.crosshair.set()
            }
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: - Toolbar Positioning

    private func updateToolbarsLayout() {
        guard let sel = selectionRect, sel.width >= 10, sel.height >= 10 else {
            verticalToolbar.isHidden = true
            horizontalToolbar.isHidden = true
            return
        }
        if case .creatingSelection = dragMode {
            verticalToolbar.isHidden = true
            horizontalToolbar.isHidden = true
            return
        }

        verticalToolbar.isHidden = false
        horizontalToolbar.isHidden = false

        let margin: CGFloat = 8
        let vSize = verticalToolbar.frame.size
        let hSize = horizontalToolbar.frame.size

        // Horizontal toolbar below bottom-right, or above top-right, or inside bottom-right
        var hX = sel.maxX - hSize.width
        hX = min(max(hX, margin), bounds.width - hSize.width - margin)
        var hY = sel.maxY + margin
        if hY + hSize.height > bounds.height - margin {
            if sel.minY - hSize.height - margin >= margin {
                hY = sel.minY - hSize.height - margin
            } else {
                hY = sel.maxY - hSize.height - margin
            }
        }
        horizontalToolbar.setFrameOrigin(CGPoint(x: hX, y: hY))

        // Vertical toolbar outside right edge, or outside left edge, or inside right edge
        var vX = sel.maxX + margin
        if vX + vSize.width > bounds.width - margin {
            if sel.minX - vSize.width - margin >= margin {
                vX = sel.minX - vSize.width - margin
            } else {
                vX = sel.maxX - vSize.width - margin
            }
        }
        var vY = sel.maxY - vSize.height
        vY = min(max(vY, margin), bounds.height - vSize.height - margin)
        verticalToolbar.setFrameOrigin(CGPoint(x: vX, y: vY))
    }

    // MARK: - FloatingToolbarsDelegate

    func toolbarsDidSelectTool(_ tool: AnnotationTool) {
        commitActiveTextField()
        activeTool = tool
        if tool != .select {
            selectedAnnotationIndex = nil
            needsDisplay = true
        }
    }

    func toolbarsDidSelectColor(_ color: NSColor) {
        activeColor = color
        activeTextField?.textColor = color
    }

    func toolbarsDidSelectLineWidth(_ width: CGFloat) {
        activeLineWidth = min(max(width, 1.0), 24.0)
        AppPreferences.shared.strokeWidth = activeLineWidth
        needsDisplay = true
    }

    func toolbarsDidSelectTextFontSize(_ size: CGFloat) {
        activeTextFontSize = min(max(size, 12.0), 72.0)
        AppPreferences.shared.textFontSize = activeTextFontSize
        updateActiveTextFieldFont()
        needsDisplay = true
    }

    private func adjustActiveSize(by delta: CGFloat) {
        if activeTool == .text || activeTextField != nil {
            activeTextFontSize = min(max(activeTextFontSize + delta * 1.5, 12.0), 72.0)
            let displayFontSize = round(activeTextFontSize)
            AppPreferences.shared.textFontSize = displayFontSize
            verticalToolbar.selectedTextFontSize = displayFontSize
            updateActiveTextFieldFont()
            showSizeIndicator("Text: \(Int(displayFontSize)) pt")
        } else {
            activeLineWidth = min(max(activeLineWidth + delta * 0.5, 1.0), 24.0)
            let roundedDisplay = (round(activeLineWidth * 2.0) / 2.0)
            AppPreferences.shared.strokeWidth = activeLineWidth
            verticalToolbar.selectedLineWidth = activeLineWidth
            if activeTool == .marker {
                let markerPx = Int(round(max(activeLineWidth * 4.5, 14.0)))
                showSizeIndicator("Marker: \(markerPx) px")
            } else {
                showSizeIndicator(String(format: "Brush: %.1f pt", roundedDisplay))
            }
        }
        needsDisplay = true
    }

    private func updateActiveTextFieldFont() {
        guard let field = activeTextField else { return }
        let roundedSize = round(activeTextFontSize)
        field.font = NSFont.systemFont(ofSize: roundedSize, weight: .semibold)
        var frame = field.frame
        frame.size.height = max(28, ceil(roundedSize * 1.45) + 8)
        field.frame = frame
    }

    private func showSizeIndicator(_ text: String) {
        sizeIndicatorText = text
        sizeIndicatorTask?.cancel()
        sizeIndicatorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled, let self else { return }
            self.sizeIndicatorText = nil
            self.needsDisplay = true
        }
    }

    func toolbarsDidClickUndo() {
        commitActiveTextField()
        if !annotations.isEmpty {
            annotations.removeLast()
            if let idx = selectedAnnotationIndex, idx >= annotations.count {
                selectedAnnotationIndex = nil
            }
            needsDisplay = true
        }
    }

    func toolbarsDidClickClear() {
        commitActiveTextField()
        annotations.removeAll()
        selectedAnnotationIndex = nil
        needsDisplay = true
    }

    func toolbarsDidClickCopy() {
        finishCapture(action: .copy)
    }

    func toolbarsDidClickQuickSave() {
        finishCapture(action: .quickSave)
    }

    func toolbarsDidClickSaveAs() {
        finishCapture(action: .saveAs)
    }

    func toolbarsDidClickUploadToDrive() {
        finishCapture(action: .uploadToDrive)
    }

    func toolbarsDidClickPrint() {
        finishCapture(action: .print)
    }

    func toolbarsDidClickShare(from anchorView: NSView) {
        commitActiveTextField()
        guard let image = exportSelectedImage() else { return }
        let picker = NSSharingServicePicker(items: [image])
        picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    func toolbarsDidClickClose() {
        coordinator?.captureSessionDidCancel()
    }

    private func exportSelectedImage() -> NSImage? {
        guard let sel = selectionRect, sel.width >= 2, sel.height >= 2 else { return nil }
        return ImageExporter.renderAnnotatedImage(
            baseImage: snapshot.cgImage,
            selectionRect: sel,
            scale: snapshot.backingScaleFactor,
            annotations: annotations
        )
    }

    private func finishCapture(action: CaptureCompletionAction) {
        commitActiveTextField()
        guard let image = exportSelectedImage() else { return }
        coordinator?.captureSessionDidComplete(with: image, action: action)
    }
}

private extension CGPoint {
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(x, rect.minX), rect.maxX),
            y: min(max(y, rect.minY), rect.maxY)
        )
    }
}

@MainActor
private final class SavePanelFormatAccessory: NSObject {
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 42))

    var selectedFormat: ImageFormat {
        let idx = popup.indexOfSelectedItem
        return ImageFormat.allCases.indices.contains(idx) ? ImageFormat.allCases[idx] : .png
    }

    init(panel: NSSavePanel, initialFormat: ImageFormat) {
        self.panel = panel
        super.init()

        let label = NSTextField(labelWithString: "Format:")
        label.font = NSFont.systemFont(ofSize: 13)

        for fmt in ImageFormat.allCases {
            popup.addItem(withTitle: "\(fmt.rawValue) (.\(fmt.fileExtension))")
        }
        if let idx = ImageFormat.allCases.firstIndex(of: initialFormat) {
            popup.selectItem(at: idx)
        }
        popup.target = self
        popup.action = #selector(formatChanged)

        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    @objc private func formatChanged() {
        let fmt = selectedFormat
        panel?.allowedContentTypes = [fmt.contentType]
        if let currentName = panel?.nameFieldStringValue, !currentName.isEmpty {
            let base = URL(fileURLWithPath: currentName).deletingPathExtension().lastPathComponent
            panel?.nameFieldStringValue = "\(base).\(fmt.fileExtension)"
        }
    }
}
