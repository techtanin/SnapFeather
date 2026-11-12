import AppKit
import Testing
@testable import SnapFeather

@MainActor
struct SnapFeatherTests {
    @Test
    func rectNormalizationAndClamping() {
        let rect = CGRect.normalized(from: CGPoint(x: 200, y: 300), to: CGPoint(x: 50, y: 120))
        #expect(rect == CGRect(x: 50, y: 120, width: 150, height: 180))

        let clamped = CGRect(x: -20, y: -10, width: 500, height: 500)
            .clamped(to: CGRect(x: 0, y: 0, width: 300, height: 250))
        #expect(clamped == CGRect(x: 0, y: 0, width: 300, height: 250))
    }

    @Test
    func annotatedImageExportMatchesRetinaScale() throws {
        let width = 400
        let height = 300
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let baseCG = try #require(ctx.makeImage())

        let annotations: [AnnotationItem] = [
            .shape(ShapeAnnotation(
                kind: .arrow,
                start: CGPoint(x: 20, y: 20),
                end: CGPoint(x: 90, y: 80),
                color: .red,
                lineWidth: 3
            )),
            .text(TextAnnotation(
                origin: CGPoint(x: 30, y: 40),
                text: "Hello M4",
                color: .white,
                fontSize: 14
            ))
        ]

        let exported = try #require(ImageExporter.renderAnnotatedImage(
            baseImage: baseCG,
            selectionRect: CGRect(x: 10, y: 10, width: 100, height: 80),
            scale: 2.0,
            annotations: annotations
        ))

        #expect(exported.size == NSSize(width: 100, height: 80))
        let outCG = try #require(exported.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(outCG.width == 200)
        #expect(outCG.height == 160)

        let pngData = try #require(ImageExporter.encodedData(for: exported, format: .png))
        #expect(!pngData.isEmpty)

        let jpgData = try #require(ImageExporter.encodedData(for: exported, format: .jpeg))
        #expect(!jpgData.isEmpty)

        let webpData = try #require(ImageExporter.encodedData(for: exported, format: .webp))
        #expect(webpData.count > 12)
        // WebP RIFF header ("RIFF....WEBP")
        #expect(String(data: webpData.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: webpData.subdata(in: 8..<12), encoding: .ascii) == "WEBP")
    }

    @Test
    func preferencesPersistenceRoundTrip() {
        let suiteName = "SnapFeatherTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.copyShareLinkOnDriveUpload == true)
        #expect(prefs.organizeDriveByDate == true)
        prefs.imageFormat = .webp
        prefs.showCrosshairs = false
        prefs.copyToClipboardOnSave = false
        prefs.strokeWidth = 6.0
        prefs.textFontSize = 26.0
        prefs.hotKeyShortcut = HotKeyShortcut.presets[1]
        prefs.googleDriveClientID = "test-client.apps.googleusercontent.com"
        prefs.googleDriveFolderName = "My Screenshots"
        prefs.autoSaveToDriveOnCopy = true
        prefs.autoSaveToDriveOnSave = true
        prefs.copyShareLinkOnDriveUpload = false
        prefs.organizeDriveByDate = false
        prefs.makeDriveFilesShareable = true
        prefs.showDriveUploadNotification = false

        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.imageFormat == .webp)
        #expect(reloaded.showCrosshairs == false)
        #expect(reloaded.copyToClipboardOnSave == false)
        #expect(reloaded.strokeWidth == 6.0)
        #expect(reloaded.textFontSize == 26.0)

        reloaded.strokeWidth = 100.0
        reloaded.textFontSize = 200.0
        #expect(reloaded.strokeWidth == 24.0)
        #expect(reloaded.textFontSize == 72.0)

        #expect(reloaded.hotKeyShortcut == HotKeyShortcut.presets[1])
        #expect(HotKeyShortcut.presets.contains(where: { $0.displayLabel == "⌘⇧S" }))
        #expect(reloaded.googleDriveClientID == "test-client.apps.googleusercontent.com")
        #expect(reloaded.googleDriveFolderName == "My Screenshots")
        #expect(reloaded.autoSaveToDriveOnCopy == true)
        #expect(reloaded.autoSaveToDriveOnSave == true)
        #expect(reloaded.copyShareLinkOnDriveUpload == false)
        #expect(reloaded.organizeDriveByDate == false)
        #expect(reloaded.makeDriveFilesShareable == true)
        #expect(reloaded.showDriveUploadNotification == false)
    }

    @Test
    func googleDrivePKCEAndMultipartHelpers() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let sampleDate = Date(timeIntervalSince1970: 1_773_014_400) // 2026-03-09 00:00:00 UTC
        let dateParts = GoogleDriveService.dateFolderComponents(for: sampleDate, calendar: cal)
        #expect(dateParts.year == "2026")
        #expect(dateParts.month == "March")
        #expect(dateParts.day == "09")
        #expect(
            GoogleDriveService.resolvedShareURL(fileId: "abc123", webViewLink: nil)
                == "https://drive.google.com/file/d/abc123/view"
        )
        #expect(
            GoogleDriveService.resolvedShareURL(fileId: "abc123", webViewLink: "https://drive.google.com/file/d/abc123/view?usp=drivesdk")
                == "https://drive.google.com/file/d/abc123/view?usp=drivesdk"
        )
        let encoded = GoogleDriveService.base64URLEncode(Data([0xFB, 0xFF, 0x3F]))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))

        let metadata = Data("{\"name\":\"shot.webp\"}".utf8)
        let payload = Data([0x52, 0x49, 0x46, 0x46])
        let body = GoogleDriveService.buildMultipartBody(
            metadata: metadata,
            imageData: payload,
            mimeType: "image/webp",
            boundary: "TestBoundary"
        )
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("--TestBoundary\r\nContent-Type: application/json"))
        #expect(text.contains("Content-Type: image/webp"))
        #expect(text.contains("--TestBoundary--\r\n"))

        let escapedHTML = LoopbackOAuthServer.escapeHTML("<script>alert('xss' & \"1\")</script>")
        #expect(escapedHTML == "&lt;script&gt;alert(&#39;xss&#39; &amp; &quot;1&quot;)&lt;/script&gt;")

        let escapedQuery = GoogleDriveService.escapeDriveQueryValue("Team's \\Folder")
        #expect(escapedQuery == "Team\\'s \\\\Folder")
    }

    @Test
    func overlayWindowInitializesWithoutTrapping() throws {
        guard let screen = NSScreen.screens.first else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try #require(ctx.makeImage())
        let snapshot = ScreenSnapshot(
            screen: screen,
            displayID: CGMainDisplayID(),
            cgImage: cgImage,
            backingScaleFactor: screen.backingScaleFactor
        )
        let coordinator = CaptureSessionCoordinator(snapshots: [snapshot]) {}
        _ = coordinator

        HUDToast.show(message: "First toast")
        HUDToast.show(message: "Second toast replacing first")
    }

    @Test
    func annotationHitTestAndTranslation() {
        let arrow = AnnotationItem.shape(ShapeAnnotation(
            kind: .arrow,
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 110, y: 10),
            color: .red,
            lineWidth: 3
        ))
        #expect(arrow.hitTest(point: CGPoint(x: 60, y: 14)))
        #expect(!arrow.hitTest(point: CGPoint(x: 60, y: 40)))

        let movedArrow = arrow.translated(by: CGVector(dx: 25, dy: 30))
        #expect(movedArrow.hitTest(point: CGPoint(x: 85, y: 40)))
        #expect(!movedArrow.hitTest(point: CGPoint(x: 60, y: 10)))

        let stroke = AnnotationItem.stroke(StrokeAnnotation(
            kind: .pen,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50)],
            color: .green,
            lineWidth: 4
        ))
        #expect(stroke.hitTest(point: CGPoint(x: 25, y: 26)))
        let movedStroke = stroke.translated(by: CGVector(dx: 100, dy: 0))
        #expect(movedStroke.hitTest(point: CGPoint(x: 125, y: 25)))
    }

    @Test
    func resizingExistingShapesStrokesAndTextBoxes() throws {
        // 1. Rectangle & Ellipse resize
        let rectItem = AnnotationItem.shape(ShapeAnnotation(
            kind: .rectangle,
            start: CGPoint(x: 20, y: 20),
            end: CGPoint(x: 120, y: 80),
            color: .red,
            lineWidth: 3
        ))
        let resizedRect = rectItem.resized(using: .box(.bottomRight), to: CGPoint(x: 220, y: 180))
        if case .shape(let shape) = resizedRect {
            #expect(shape.start == CGPoint(x: 20, y: 20))
            #expect(shape.end == CGPoint(x: 220, y: 180))
        } else {
            Issue.record("Expected resized shape")
        }

        // 2. Arrow endpoint resize
        let arrowItem = AnnotationItem.shape(ShapeAnnotation(
            kind: .arrow,
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 100, y: 50),
            color: .blue,
            lineWidth: 3
        ))
        let movedTip = arrowItem.resized(using: .endpointEnd, to: CGPoint(x: 180, y: 90))
        if case .shape(let arrow) = movedTip {
            #expect(arrow.start == CGPoint(x: 10, y: 10))
            #expect(arrow.end == CGPoint(x: 180, y: 90))
        } else {
            Issue.record("Expected resized arrow")
        }

        // 3. Freehand stroke path resize scales points proportionally
        let strokeItem = AnnotationItem.stroke(StrokeAnnotation(
            kind: .pen,
            points: [CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 100)],
            color: .green,
            lineWidth: 4
        ))
        let originalBox = strokeItem.boundingBox
        let stretchedStroke = strokeItem.resized(
            using: .box(.bottomRight),
            to: CGPoint(x: originalBox.maxX + 50, y: originalBox.maxY + 50)
        )
        #expect(abs(stretchedStroke.boundingBox.width - (originalBox.width + 50)) < 1.0)
        #expect(abs(stretchedStroke.boundingBox.height - (originalBox.height + 50)) < 1.0)

        // 4. Text box width resize wraps text and grows height
        let textItem = AnnotationItem.text(TextAnnotation(
            origin: CGPoint(x: 40, y: 40),
            text: "Hello SnapFeather resizable wrapped text box",
            color: .white,
            fontSize: 18,
            maxWidth: nil
        ))
        let initialBox = textItem.boundingBox
        let narrowText = textItem.resized(using: .box(.right), to: CGPoint(x: 140, y: initialBox.midY))
        if case .text(let wrapped) = narrowText {
            #expect(wrapped.maxWidth == 100)
            #expect(wrapped.fontSize == 18)
            #expect(narrowText.boundingBox.height > initialBox.height)
        } else {
            Issue.record("Expected wrapped text annotation")
        }

        // 5. Text box corner resize scales font size
        let scaledText = textItem.resized(
            using: .box(.bottomRight),
            to: CGPoint(x: initialBox.minX + initialBox.width * 2.0, y: initialBox.minY + initialBox.height * 2.0)
        )
        if case .text(let bigText) = scaledText {
            #expect(bigText.fontSize > 30)
            #expect(bigText.origin == CGPoint(x: 40, y: 40))
        } else {
            Issue.record("Expected scaled text annotation")
        }

        // 6. Straight line snapping at 0°, 45°, and 90° increments
        let start = CGPoint(x: 100, y: 100)
        let almostHorizontal = AnnotationGeometry.snappedLineEnd(from: start, to: CGPoint(x: 220, y: 108))
        #expect(abs(almostHorizontal.y - 100) < 0.01)
        #expect(almostHorizontal.x > 200)

        let almostVertical = AnnotationGeometry.snappedLineEnd(from: start, to: CGPoint(x: 106, y: 240))
        #expect(abs(almostVertical.x - 100) < 0.01)
        #expect(almostVertical.y > 220)

        let almostDiagonal = AnnotationGeometry.snappedLineEnd(from: start, to: CGPoint(x: 205, y: 195))
        #expect(abs((almostDiagonal.x - 100) - (almostDiagonal.y - 100)) < 0.01)
    }

    @Test
    func annotationHistoryUndoAndRedoFlow() {
        var history = AnnotationHistory()
        var items: [AnnotationItem] = []

        #expect(history.canUndo == false)
        #expect(history.canRedo == false)

        // Step 1: Add rectangle
        let rect = AnnotationItem.shape(ShapeAnnotation(
            kind: .rectangle,
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 80, y: 60),
            color: .red,
            lineWidth: 3
        ))
        history.recordBeforeMutation(current: items)
        items.append(rect)

        // Step 2: Resize rectangle
        let resized = rect.resized(using: .box(.bottomRight), to: CGPoint(x: 140, y: 120))
        history.recordBeforeMutation(current: items)
        items[0] = resized

        // Step 3: Clear all
        history.recordBeforeMutation(current: items)
        items.removeAll()
        #expect(items.isEmpty)
        #expect(history.canUndo == true)

        // Undo Clear -> back to resized rect
        items = history.undo(current: items)!
        #expect(items == [resized])
        #expect(history.canRedo == true)

        // Undo Resize -> back to original rect
        items = history.undo(current: items)!
        #expect(items == [rect])

        // Redo -> back to resized rect
        items = history.redo(current: items)!
        #expect(items == [resized])
        #expect(history.canRedo == true)

        // New edit clears redo stack
        history.recordBeforeMutation(current: items)
        items.append(.text(TextAnnotation(origin: .zero, text: "Hi", color: .white, fontSize: 16)))
        #expect(history.canRedo == false)
    }
}
