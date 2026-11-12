import AppKit
import Carbon
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Sendable {
    case png = "PNG"
    case jpeg = "JPG"
    case webp = "WebP"

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .webp: return "webp"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .webp: return UTType(filenameExtension: "webp") ?? .webP
        }
    }

    var mimeType: String {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        case .webp: return "image/webp"
        }
    }

    static func from(fileExtension ext: String) -> ImageFormat? {
        switch ext.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "webp": return .webp
        default: return nil
        }
    }
}

struct HotKeyShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var displayLabel: String

    static let defaultShortcut = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_2),
        modifiers: UInt32(cmdKey | shiftKey),
        displayLabel: "⌘⇧2"
    )

    static let presets: [HotKeyShortcut] = [
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), displayLabel: "⌘⇧2"),
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey), displayLabel: "⌘⇧S"),
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | shiftKey), displayLabel: "⌥⇧S"),
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | shiftKey), displayLabel: "⌃⇧S"),
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey | cmdKey), displayLabel: "⌥⌘1"),
        HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), displayLabel: "⌥⇧Space")
    ]
}

@MainActor
final class AppPreferences {
    static let shared = AppPreferences()

    private enum Keys {
        static let saveDirectory = "SnapFeather.saveDirectory"
        static let imageFormat = "SnapFeather.imageFormat"
        static let showCrosshairs = "SnapFeather.showCrosshairs"
        static let copyToClipboardOnSave = "SnapFeather.copyToClipboardOnSave"
        static let hotKeyShortcut = "SnapFeather.hotKeyShortcut"
        static let lastColorHex = "SnapFeather.lastColorHex"
        static let strokeWidth = "SnapFeather.strokeWidth"
        static let textFontSize = "SnapFeather.textFontSize"
        static let googleDriveClientID = "SnapFeather.googleDriveClientID"
        static let googleDriveClientSecret = "SnapFeather.googleDriveClientSecret"
        static let googleDriveFolderName = "SnapFeather.googleDriveFolderName"
        static let googleDriveFolderID = "SnapFeather.googleDriveFolderID"
        static let organizeDriveByDate = "SnapFeather.organizeDriveByDate"
        static let autoSaveToDriveOnCopy = "SnapFeather.autoSaveToDriveOnCopy"
        static let autoSaveToDriveOnSave = "SnapFeather.autoSaveToDriveOnSave"
        static let makeDriveFilesShareable = "SnapFeather.makeDriveFilesShareable"
        static let copyShareLinkOnDriveUpload = "SnapFeather.copyShareLinkOnDriveUpload"
        static let showDriveUploadNotification = "SnapFeather.showDriveUploadNotification"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: Keys.saveDirectory) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
        }
        set {
            defaults.set(newValue.path, forKey: Keys.saveDirectory)
        }
    }

    var imageFormat: ImageFormat {
        get {
            guard let raw = defaults.string(forKey: Keys.imageFormat) else {
                return .png
            }
            if raw == "JPEG" {
                return .jpeg
            }
            return ImageFormat(rawValue: raw) ?? .png
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.imageFormat)
        }
    }

    var showCrosshairs: Bool {
        get {
            defaults.object(forKey: Keys.showCrosshairs) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Keys.showCrosshairs)
        }
    }

    var copyToClipboardOnSave: Bool {
        get {
            defaults.object(forKey: Keys.copyToClipboardOnSave) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Keys.copyToClipboardOnSave)
        }
    }

    var hotKeyShortcut: HotKeyShortcut {
        get {
            guard let data = defaults.data(forKey: Keys.hotKeyShortcut),
                  let decoded = try? JSONDecoder().decode(HotKeyShortcut.self, from: data) else {
                return .defaultShortcut
            }
            return decoded
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                defaults.set(encoded, forKey: Keys.hotKeyShortcut)
            }
        }
    }

    var strokeWidth: CGFloat {
        get {
            let value = defaults.double(forKey: Keys.strokeWidth)
            guard value > 0 else { return 3.0 }
            return min(max(CGFloat(value), 1.0), 24.0)
        }
        set {
            let clamped = min(max(newValue, 1.0), 24.0)
            defaults.set(Double(clamped), forKey: Keys.strokeWidth)
        }
    }

    var textFontSize: CGFloat {
        get {
            let value = defaults.double(forKey: Keys.textFontSize)
            guard value > 0 else { return 18.0 }
            return min(max(CGFloat(value), 12.0), 72.0)
        }
        set {
            let clamped = min(max(newValue, 12.0), 72.0)
            defaults.set(Double(clamped), forKey: Keys.textFontSize)
        }
    }

    var googleDriveClientID: String {
        get { defaults.string(forKey: Keys.googleDriveClientID) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.googleDriveClientID) }
    }

    var googleDriveClientSecret: String {
        get {
            // Migrate any legacy plaintext secret from UserDefaults into Keychain
            if let legacy = defaults.string(forKey: Keys.googleDriveClientSecret), !legacy.isEmpty {
                try? KeychainStore.saveClientSecret(legacy)
                defaults.removeObject(forKey: Keys.googleDriveClientSecret)
                return legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return KeychainStore.loadClientSecret()
        }
        set {
            defaults.removeObject(forKey: Keys.googleDriveClientSecret)
            try? KeychainStore.saveClientSecret(newValue)
        }
    }

    var googleDriveFolderName: String {
        get {
            let value = defaults.string(forKey: Keys.googleDriveFolderName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? "SnapFeather Screenshots" : value
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? "SnapFeather Screenshots" : trimmed, forKey: Keys.googleDriveFolderName)
        }
    }

    var googleDriveFolderID: String {
        get { defaults.string(forKey: Keys.googleDriveFolderID) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.googleDriveFolderID) }
    }

    var organizeDriveByDate: Bool {
        get { defaults.object(forKey: Keys.organizeDriveByDate) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.organizeDriveByDate) }
    }

    var autoSaveToDriveOnCopy: Bool {
        get { defaults.object(forKey: Keys.autoSaveToDriveOnCopy) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.autoSaveToDriveOnCopy) }
    }

    var autoSaveToDriveOnSave: Bool {
        get { defaults.object(forKey: Keys.autoSaveToDriveOnSave) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.autoSaveToDriveOnSave) }
    }

    var makeDriveFilesShareable: Bool {
        get { defaults.object(forKey: Keys.makeDriveFilesShareable) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.makeDriveFilesShareable) }
    }

    var copyShareLinkOnDriveUpload: Bool {
        get { defaults.object(forKey: Keys.copyShareLinkOnDriveUpload) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.copyShareLinkOnDriveUpload) }
    }

    var showDriveUploadNotification: Bool {
        get { defaults.object(forKey: Keys.showDriveUploadNotification) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showDriveUploadNotification) }
    }
}
