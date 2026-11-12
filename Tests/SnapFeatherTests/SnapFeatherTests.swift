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
        #expect(reloaded.googleDriveClientID == "test-client.apps.googleusercontent.com")
        #expect(reloaded.googleDriveFolderName == "My Screenshots")
        #expect(reloaded.autoSaveToDriveOnCopy == true)
        #expect(reloaded.autoSaveToDriveOnSave == true)
        #expect(reloaded.makeDriveFilesShareable == true)
        #expect(reloaded.showDriveUploadNotification == false)
    }

    @Test
    func googleDrivePKCEAndMultipartHelpers() {
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
}
