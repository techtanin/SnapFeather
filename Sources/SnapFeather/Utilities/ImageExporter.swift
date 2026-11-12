import AppKit
import CoreGraphics
import CWebP
import UniformTypeIdentifiers

enum ImageExporter {
    @MainActor
    static func renderAnnotatedImage(
        baseImage: CGImage,
        selectionRect: CGRect,
        scale: CGFloat,
        annotations: [AnnotationItem]
    ) -> NSImage? {
        let safeScale = max(scale, 1.0)
        let imageBounds = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        let rawPixelCrop = CGRect(
            x: round(selectionRect.minX * safeScale),
            y: round(selectionRect.minY * safeScale),
            width: round(selectionRect.width * safeScale),
            height: round(selectionRect.height * safeScale)
        )
        let pixelCrop = rawPixelCrop.clamped(to: imageBounds)
        let pixelWidth = Int(pixelCrop.width)
        let pixelHeight = Int(pixelCrop.height)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        guard let cropped = baseImage.cropping(to: pixelCrop) else { return nil }

        let colorSpace = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: safeScale, y: -safeScale)

        let pointOrigin = CGPoint(
            x: pixelCrop.minX / safeScale,
            y: pixelCrop.minY / safeScale
        )
        for item in annotations {
            item.draw(in: ctx, offset: pointOrigin)
        }
        ctx.restoreGState()

        guard let finalCGImage = ctx.makeImage() else { return nil }
        let logicalSize = NSSize(
            width: CGFloat(pixelWidth) / safeScale,
            height: CGFloat(pixelHeight) / safeScale
        )
        return NSImage(cgImage: finalCGImage, size: logicalSize)
    }

    @MainActor
    static func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let pngData = encodedData(for: image, format: .png) {
            pasteboard.setData(pngData, forType: .png)
        }
        if let tiffData = image.tiffRepresentation {
            pasteboard.setData(tiffData, forType: .tiff)
        }
        pasteboard.writeObjects([image])
    }

    @MainActor
    static func encodedData(for image: NSImage, format: ImageFormat) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        switch format {
        case .png:
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = image.size
            return rep.representation(using: .png, properties: [:])
        case .jpeg:
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = image.size
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        case .webp:
            return encodeWebP(cgImage: cgImage, quality: 90.0)
        }
    }

    private static func encodeWebP(cgImage: CGImage, quality: Float) -> Data? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let (stride, strideOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
        let (totalBytes, totalOverflow) = height.multipliedReportingOverflow(by: stride)
        guard !strideOverflow, !totalOverflow, totalBytes > 0 else { return nil }

        let clampedQuality = min(max(quality, 0), 100)
        var rgba = [UInt8](repeating: 0, count: totalBytes)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        let rendered: Bool = rgba.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let ctx = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: stride,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        // Unpremultiply alpha if any semi-transparent pixels exist before WebPEncodeRGBA
        var index = 0
        while index < rgba.count {
            let alpha = rgba[index + 3]
            if alpha > 0 && alpha < 255 {
                let a = Int(alpha)
                rgba[index] = UInt8(min(255, (Int(rgba[index]) * 255) / a))
                rgba[index + 1] = UInt8(min(255, (Int(rgba[index + 1]) * 255) / a))
                rgba[index + 2] = UInt8(min(255, (Int(rgba[index + 2]) * 255) / a))
            }
            index += 4
        }

        var outputPtr: UnsafeMutablePointer<UInt8>?
        let encodedSize = rgba.withUnsafeBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return snapfeather_encode_webp_rgba(
                base,
                Int32(width),
                Int32(height),
                Int32(stride),
                clampedQuality,
                &outputPtr
            )
        }

        guard encodedSize > 0, let outputPtr else { return nil }
        defer { snapfeather_free_webp(outputPtr) }
        return Data(bytes: outputPtr, count: encodedSize)
    }

    @MainActor
    static func defaultFilename(format: ImageFormat, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "SnapFeather_\(formatter.string(from: date)).\(format.fileExtension)"
    }

    @MainActor
    static func write(_ image: NSImage, to url: URL, format: ImageFormat) throws {
        guard let data = encodedData(for: image, format: format) else {
            throw NSError(
                domain: "SnapFeather.ImageExporter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode screenshot image."]
            )
        }
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
final class HUDToast {
    private static var currentWindow: NSWindow?
    private static var dismissTask: Task<Void, Never>?

    static func show(message: String, symbolName: String = "checkmark.circle.fill") {
        dismissTask?.cancel()
        dismissTask = nil
        currentWindow?.orderOut(nil)
        currentWindow?.close()
        currentWindow = nil

        let icon = NSImageView()
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            icon.image = symbol
            icon.contentTintColor = NSColor.systemGreen
        }
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor

        let width = max(240, ceil(label.fittingSize.width) + 64)
        let height: CGFloat = 46

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.minY + 72,
            width: width,
            height: height
        )

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.hasShadow = true

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        window.contentView = container
        window.alphaValue = 0
        window.orderFrontRegardless()
        currentWindow = window

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            window.animator().alphaValue = 1
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, currentWindow === window else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                window.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    window.orderOut(nil)
                    window.close()
                    if currentWindow === window {
                        currentWindow = nil
                    }
                }
            })
        }
    }
}
