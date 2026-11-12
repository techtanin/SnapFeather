import AppKit
import CoreGraphics
import ScreenCaptureKit

struct ScreenSnapshot: @unchecked Sendable {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let cgImage: CGImage
    let backingScaleFactor: CGFloat
}

enum ScreenCaptureError: LocalizedError {
    case permissionPromptedBySystem
    case permissionDenied
    case noDisplaysFound
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionPromptedBySystem, .permissionDenied:
            return "Screen Recording permission is required to capture screenshots."
        case .noDisplaysFound:
            return "No active displays could be found."
        case .captureFailed(let reason):
            return "Failed to capture screen: \(reason)"
        }
    }
}

@MainActor
final class ScreenCaptureService {
    static let shared = ScreenCaptureService()

    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestPermissionIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func captureAllScreens() async throws -> [ScreenSnapshot] {
        Diagnostics.log("captureAllScreens preflight=\(hasPermission()) screens=\(NSScreen.screens.count)")

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            Diagnostics.log("SCShareableContent returned displays=\(content.displays.count)")
        } catch let error as NSError {
            Diagnostics.log("SCShareableContent error domain=\(error.domain) code=\(error.code) desc=\(error.localizedDescription)")
            if isPermissionError(error) {
                throw classifyPermissionError()
            }
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }

        let scDisplaysByID = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        var snapshots: [ScreenSnapshot] = []

        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            guard let scDisplay = scDisplaysByID[displayID] else {
                continue
            }

            let scale = max(screen.backingScaleFactor, 1.0)
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            config.scalesToFit = false
            config.captureResolution = .best

            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                snapshots.append(
                    ScreenSnapshot(
                        screen: screen,
                        displayID: displayID,
                        cgImage: image,
                        backingScaleFactor: scale
                    )
                )
            } catch let error as NSError {
                Diagnostics.log("SCScreenshotManager.captureImage error domain=\(error.domain) code=\(error.code) desc=\(error.localizedDescription)")
                if isPermissionError(error) {
                    throw classifyPermissionError()
                }
                throw ScreenCaptureError.captureFailed(error.localizedDescription)
            }
        }

        guard !snapshots.isEmpty else {
            throw ScreenCaptureError.noDisplaysFound
        }

        return snapshots
    }

    private func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == SCStreamErrorDomain && error.code == SCStreamError.userDeclined.rawValue {
            return true
        }
        return !hasPermission() && error.localizedDescription.localizedCaseInsensitiveContains("declined")
    }

    private func classifyPermissionError() -> ScreenCaptureError {
        let key = "SnapFeather.lastSystemPromptStamp"
        let stamp = currentBinaryStamp()
        let previous = UserDefaults.standard.double(forKey: key)
        if abs(previous - stamp) > 0.001 {
            UserDefaults.standard.set(stamp, forKey: key)
            return .permissionPromptedBySystem
        }
        return .permissionDenied
    }

    private func currentBinaryStamp() -> TimeInterval {
        guard let exeURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: exeURL.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return 0
        }
        return modDate.timeIntervalSince1970
    }
}
