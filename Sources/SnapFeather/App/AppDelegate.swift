import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var takeScreenshotMenuItem: NSMenuItem?
    private var activeCoordinator: CaptureSessionCoordinator?
    private var isStartingCapture = false
    private var preferencesController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.log("Launched from \(Bundle.main.bundlePath) preflight=\(ScreenCaptureService.shared.hasPermission())")
        NSApp.setActivationPolicy(.accessory)
        setupMenuBarItem()
        registerGlobalHotKey(AppPreferences.shared.hotKeyShortcut)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openGoogleDrivePreferences),
            name: .snapFeatherOpenDrivePreferences,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeyManager.shared.unregister()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapFeather")
            symbol?.isTemplate = true
            button.image = symbol
            button.toolTip = "SnapFeather (\(AppPreferences.shared.hotKeyShortcut.displayLabel))"
        }

        let menu = NSMenu()
        let takeItem = NSMenuItem(
            title: "Take Screenshot (\(AppPreferences.shared.hotKeyShortcut.displayLabel))",
            action: #selector(startRegionCapture),
            keyEquivalent: ""
        )
        takeItem.target = self
        menu.addItem(takeItem)
        self.takeScreenshotMenuItem = takeItem

        let fullScreenItem = NSMenuItem(
            title: "Capture Full Screen to Clipboard",
            action: #selector(captureFullScreenToClipboard),
            keyEquivalent: ""
        )
        fullScreenItem.target = self
        menu.addItem(fullScreenItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(
            title: "Preferences...",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        let driveItem = NSMenuItem(
            title: "Google Drive Settings...",
            action: #selector(openGoogleDrivePreferences),
            keyEquivalent: ""
        )
        driveItem.target = self
        menu.addItem(driveItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit SnapFeather",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    private func registerGlobalHotKey(_ shortcut: HotKeyShortcut) {
        GlobalHotKeyManager.shared.register(shortcut: shortcut) { [weak self] in
            self?.startRegionCapture()
        }
        takeScreenshotMenuItem?.title = "Take Screenshot (\(shortcut.displayLabel))"
        statusItem?.button?.toolTip = "SnapFeather (\(shortcut.displayLabel))"
    }

    @objc func startRegionCapture() {
        Diagnostics.log("startRegionCapture triggered activeCoordinator=\(activeCoordinator != nil) isStarting=\(isStartingCapture)")
        if let active = activeCoordinator {
            // Re-pressing hotkey cancels the active overlay cleanly
            active.captureSessionDidCancel()
            return
        }
        guard !isStartingCapture else { return }
        isStartingCapture = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isStartingCapture = false }
            do {
                let snapshots = try await ScreenCaptureService.shared.captureAllScreens()
                guard self.activeCoordinator == nil else { return }
                Diagnostics.log("Captured \(snapshots.count) snapshots; starting overlay")
                let coordinator = CaptureSessionCoordinator(snapshots: snapshots) { [weak self] in
                    self?.activeCoordinator = nil
                }
                self.activeCoordinator = coordinator
                coordinator.start()
            } catch ScreenCaptureError.permissionPromptedBySystem {
                Diagnostics.log("System permission prompt displayed; skipping duplicate alert")
            } catch ScreenCaptureError.permissionDenied {
                Diagnostics.log("Presenting permissionDenied alert")
                presentPermissionAlert()
            } catch {
                Diagnostics.log("Presenting capture error alert: \(error.localizedDescription)")
                presentErrorAlert(title: "Capture Failed", message: error.localizedDescription)
            }
        }
    }

    @objc private func captureFullScreenToClipboard() {
        guard !isStartingCapture, activeCoordinator == nil else { return }
        isStartingCapture = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isStartingCapture = false }
            do {
                let snapshots = try await ScreenCaptureService.shared.captureAllScreens()
                let target = snapshots.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? snapshots.first
                guard let target else { return }
                let image = NSImage(cgImage: target.cgImage, size: target.screen.frame.size)
                ImageExporter.copyToClipboard(image)
                let prefs = AppPreferences.shared
                if prefs.autoSaveToDriveOnCopy && GoogleDriveService.shared.isAuthorized {
                    HUDToast.show(message: "Copied • Saving to Drive...")
                    let filename = ImageExporter.defaultFilename(format: prefs.imageFormat)
                    Task { @MainActor in
                        do {
                            let res = try await GoogleDriveService.shared.uploadScreenshot(
                                image: image,
                                format: prefs.imageFormat,
                                filename: filename
                            )
                            Diagnostics.log("Uploaded full screen \(res.name) to Drive (id=\(res.fileId))")
                            if prefs.showDriveUploadNotification {
                                HUDToast.show(message: "Saved to Google Drive", symbolName: "icloud.and.arrow.up.fill")
                            }
                        } catch {
                            Diagnostics.log("Full screen Drive upload failed: \(error.localizedDescription)")
                            HUDToast.show(message: "Drive upload failed", symbolName: "exclamationmark.icloud.fill")
                        }
                    }
                } else {
                    HUDToast.show(message: "Full screen copied")
                }
            } catch ScreenCaptureError.permissionPromptedBySystem {
                Diagnostics.log("System permission prompt displayed during full-screen capture")
            } catch ScreenCaptureError.permissionDenied {
                presentPermissionAlert()
            } catch {
                presentErrorAlert(title: "Capture Failed", message: error.localizedDescription)
            }
        }
    }

    @objc private func openPreferences() {
        ensurePreferencesController()
        preferencesController?.refreshPermissionStatus()
        NSApp.activate(ignoringOtherApps: true)
        preferencesController?.showWindow(nil)
        preferencesController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openGoogleDrivePreferences() {
        ensurePreferencesController()
        preferencesController?.selectGoogleDriveTab()
        preferencesController?.refreshPermissionStatus()
        NSApp.activate(ignoringOtherApps: true)
        preferencesController?.showWindow(nil)
        preferencesController?.window?.makeKeyAndOrderFront(nil)
    }

    private func ensurePreferencesController() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController { [weak self] newShortcut in
                self?.registerGlobalHotKey(newShortcut)
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func presentPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
        Enable SnapFeather in System Settings > Privacy & Security > Screen & System Audio Recording, then click Relaunch App.

        Tip: If SnapFeather isn't listed yet, click (+) to add it. If it already appears enabled from an earlier build, remove it with (−) and re-add it.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch App")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            ScreenCaptureService.shared.openScreenRecordingSettings()
        } else if response == .alertSecondButtonReturn {
            relaunchApp()
        }
    }

    private func relaunchApp() {
        GlobalHotKeyManager.shared.unregister()
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    private func presentErrorAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
