import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let onShortcutChanged: @MainActor (HotKeyShortcut) -> Void

    private let tabView = NSTabView()

    // General tab
    private let shortcutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folderLabel = NSTextField(labelWithString: "")
    private let crosshairsCheckbox = NSButton(checkboxWithTitle: "Show full-screen crosshair guides while selecting", target: nil, action: nil)
    private let copyOnSaveCheckbox = NSButton(checkboxWithTitle: "Also copy screenshot to clipboard after saving", target: nil, action: nil)
    private let permissionStatusLabel = NSTextField(labelWithString: "")

    // Google Drive tab
    private var isAuthorizing = false
    private let driveStatusLabel = NSTextField(labelWithString: "")
    private let authorizeButton = NSButton(title: "Authorize Google Drive", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    private let authSpinner = NSProgressIndicator()
    private let clientIDField = NSTextField(string: "")
    private let clientSecretField = NSSecureTextField(string: "")
    private let driveFolderNameField = NSTextField(string: "")
    private let driveFolderIDField = NSTextField(string: "")
    private let autoSaveOnCopyCheckbox = NSButton(checkboxWithTitle: "Auto-save to Google Drive after copying image", target: nil, action: nil)
    private let autoSaveOnSaveCheckbox = NSButton(checkboxWithTitle: "Auto-save to Google Drive after saving locally", target: nil, action: nil)
    private let shareableCheckbox = NSButton(checkboxWithTitle: "Make uploaded files shareable (Anyone with link)", target: nil, action: nil)
    private let driveToastCheckbox = NSButton(checkboxWithTitle: "Show notification toast after Drive upload", target: nil, action: nil)

    init(onShortcutChanged: @escaping @MainActor (HotKeyShortcut) -> Void) {
        self.onShortcutChanged = onShortcutChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SnapFeather Preferences"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        setupUI()
        loadValues()
    }

    func windowWillClose(_ notification: Notification) {
        persistDriveTextFields()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func selectGoogleDriveTab() {
        tabView.selectTabViewItem(withIdentifier: "gdrive")
    }

    func refreshPermissionStatus() {
        let granted = ScreenCaptureService.shared.hasPermission()
        permissionStatusLabel.stringValue = granted
            ? "Screen Recording: Granted"
            : "Screen Recording: Permission Needed"
        permissionStatusLabel.textColor = granted ? .systemGreen : .systemOrange
        refreshDriveStatus()
    }

    private func refreshDriveStatus() {
        if GoogleDriveService.shared.isAuthorized {
            let email = GoogleDriveService.shared.connectedEmail ?? "Authorized Account"
            driveStatusLabel.stringValue = "Connected: \(email)"
            driveStatusLabel.textColor = .systemGreen
            authorizeButton.title = "Re-authorize"
            disconnectButton.isEnabled = true
        } else {
            driveStatusLabel.stringValue = "Not connected"
            driveStatusLabel.textColor = .secondaryLabelColor
            authorizeButton.title = "Authorize Google Drive"
            disconnectButton.isEnabled = false
        }
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])

        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "General"
        generalItem.view = buildGeneralTabView()
        tabView.addTabViewItem(generalItem)

        let driveItem = NSTabViewItem(identifier: "gdrive")
        driveItem.label = "Google Drive"
        driveItem.view = buildGoogleDriveTabView()
        tabView.addTabViewItem(driveItem)
    }

    private func buildGeneralTabView() -> NSView {
        let container = NSView()
        let grid = NSGridView(views: [])
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        shortcutPopup.target = self
        shortcutPopup.action = #selector(shortcutChanged)
        for preset in HotKeyShortcut.presets {
            shortcutPopup.addItem(withTitle: preset.displayLabel)
        }

        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        for fmt in ImageFormat.allCases {
            formatPopup.addItem(withTitle: "\(fmt.rawValue) (.\(fmt.fileExtension))")
        }

        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.maximumNumberOfLines = 1
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chooseFolderBtn = NSButton(title: "Choose...", target: self, action: #selector(chooseFolder))
        let folderRow = NSStackView(views: [folderLabel, chooseFolderBtn])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8

        crosshairsCheckbox.target = self
        crosshairsCheckbox.action = #selector(crosshairsToggled)

        copyOnSaveCheckbox.target = self
        copyOnSaveCheckbox.action = #selector(copyOnSaveToggled)

        let openSettingsBtn = NSButton(title: "Open System Settings", target: self, action: #selector(openPrivacySettings))
        let permRow = NSStackView(views: [permissionStatusLabel, openSettingsBtn])
        permRow.orientation = .horizontal
        permRow.spacing = 10

        grid.addRow(with: [makeRowLabel("Capture Hotkey:"), shortcutPopup])
        grid.addRow(with: [makeRowLabel("Image Format:"), formatPopup])
        grid.addRow(with: [makeRowLabel("Save Folder:"), folderRow])
        grid.addRow(with: [makeRowLabel("Overlay:"), crosshairsCheckbox])
        grid.addRow(with: [makeRowLabel("Clipboard:"), copyOnSaveCheckbox])
        grid.addRow(with: [makeRowLabel("Permissions:"), permRow])

        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -18)
        ])
        return container
    }

    private func buildGoogleDriveTabView() -> NSView {
        let container = NSView()
        let grid = NSGridView(views: [])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        authorizeButton.bezelStyle = .rounded
        authorizeButton.target = self
        authorizeButton.action = #selector(authorizeGoogleDrive)

        disconnectButton.bezelStyle = .rounded
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectGoogleDrive)

        let helpButton = NSButton(title: "Setup Guide", target: self, action: #selector(showDriveSetupGuide))
        helpButton.bezelStyle = .rounded

        authSpinner.style = .spinning
        authSpinner.controlSize = .small
        authSpinner.isDisplayedWhenStopped = false

        let authRow = NSStackView(views: [authorizeButton, disconnectButton, helpButton, authSpinner])
        authRow.orientation = .horizontal
        authRow.spacing = 8

        clientIDField.placeholderString = "xxxxxxxxxxxx.apps.googleusercontent.com"
        clientIDField.delegate = self
        clientIDField.target = self
        clientIDField.action = #selector(driveFieldsChanged)
        clientIDField.translatesAutoresizingMaskIntoConstraints = false
        clientIDField.widthAnchor.constraint(equalToConstant: 320).isActive = true

        clientSecretField.placeholderString = "Optional (if provided by Desktop OAuth client)"
        clientSecretField.delegate = self
        clientSecretField.target = self
        clientSecretField.action = #selector(driveFieldsChanged)
        clientSecretField.translatesAutoresizingMaskIntoConstraints = false
        clientSecretField.widthAnchor.constraint(equalToConstant: 320).isActive = true

        driveFolderNameField.placeholderString = "SnapFeather Screenshots"
        driveFolderNameField.delegate = self
        driveFolderNameField.target = self
        driveFolderNameField.action = #selector(driveFolderNameChanged)
        driveFolderNameField.translatesAutoresizingMaskIntoConstraints = false
        driveFolderNameField.widthAnchor.constraint(equalToConstant: 320).isActive = true

        driveFolderIDField.placeholderString = "Auto-resolved (or paste existing Drive Folder ID)"
        driveFolderIDField.delegate = self
        driveFolderIDField.target = self
        driveFolderIDField.action = #selector(driveFieldsChanged)
        driveFolderIDField.translatesAutoresizingMaskIntoConstraints = false
        driveFolderIDField.widthAnchor.constraint(equalToConstant: 320).isActive = true

        autoSaveOnCopyCheckbox.target = self
        autoSaveOnCopyCheckbox.action = #selector(driveCheckboxesChanged)

        autoSaveOnSaveCheckbox.target = self
        autoSaveOnSaveCheckbox.action = #selector(driveCheckboxesChanged)

        shareableCheckbox.target = self
        shareableCheckbox.action = #selector(driveCheckboxesChanged)

        driveToastCheckbox.target = self
        driveToastCheckbox.action = #selector(driveCheckboxesChanged)

        let optionsStack = NSStackView(views: [
            autoSaveOnCopyCheckbox,
            autoSaveOnSaveCheckbox,
            shareableCheckbox,
            driveToastCheckbox
        ])
        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 6

        grid.addRow(with: [makeRowLabel("Account:"), driveStatusLabel])
        grid.addRow(with: [makeRowLabel(""), authRow])
        grid.addRow(with: [makeRowLabel("OAuth Client ID:"), clientIDField])
        grid.addRow(with: [makeRowLabel("Client Secret:"), clientSecretField])
        grid.addRow(with: [makeRowLabel("Drive Folder:"), driveFolderNameField])
        grid.addRow(with: [makeRowLabel("Folder ID:"), driveFolderIDField])
        grid.addRow(with: [makeRowLabel("Auto-Upload:"), optionsStack])

        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -18)
        ])
        return container
    }

    private func makeRowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.alignment = .right
        return label
    }

    private func loadValues() {
        let prefs = AppPreferences.shared
        if let idx = HotKeyShortcut.presets.firstIndex(of: prefs.hotKeyShortcut) {
            shortcutPopup.selectItem(at: idx)
        }
        if let fmtIdx = ImageFormat.allCases.firstIndex(of: prefs.imageFormat) {
            formatPopup.selectItem(at: fmtIdx)
        }
        folderLabel.stringValue = prefs.saveDirectory.path
        crosshairsCheckbox.state = prefs.showCrosshairs ? .on : .off
        copyOnSaveCheckbox.state = prefs.copyToClipboardOnSave ? .on : .off

        clientIDField.stringValue = prefs.googleDriveClientID
        clientSecretField.stringValue = prefs.googleDriveClientSecret
        driveFolderNameField.stringValue = prefs.googleDriveFolderName
        driveFolderIDField.stringValue = prefs.googleDriveFolderID
        autoSaveOnCopyCheckbox.state = prefs.autoSaveToDriveOnCopy ? .on : .off
        autoSaveOnSaveCheckbox.state = prefs.autoSaveToDriveOnSave ? .on : .off
        shareableCheckbox.state = prefs.makeDriveFilesShareable ? .on : .off
        driveToastCheckbox.state = prefs.showDriveUploadNotification ? .on : .off

        refreshPermissionStatus()
    }

    private func persistDriveTextFields() {
        let prefs = AppPreferences.shared
        let newClientID = clientIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefs.googleDriveClientID != newClientID {
            prefs.googleDriveClientID = newClientID
        }
        let newSecret = clientSecretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefs.googleDriveClientSecret != newSecret {
            prefs.googleDriveClientSecret = newSecret
        }
        let previousFolderName = prefs.googleDriveFolderName
        prefs.googleDriveFolderName = driveFolderNameField.stringValue
        let typedFolderID = driveFolderIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefs.googleDriveFolderName != previousFolderName && typedFolderID == prefs.googleDriveFolderID {
            prefs.googleDriveFolderID = ""
            driveFolderIDField.stringValue = ""
        } else if prefs.googleDriveFolderID != typedFolderID {
            prefs.googleDriveFolderID = typedFolderID
        }
    }

    // MARK: - Actions

    @objc private func shortcutChanged() {
        let idx = shortcutPopup.indexOfSelectedItem
        guard HotKeyShortcut.presets.indices.contains(idx) else { return }
        let selected = HotKeyShortcut.presets[idx]
        AppPreferences.shared.hotKeyShortcut = selected
        onShortcutChanged(selected)
    }

    @objc private func formatChanged() {
        let idx = formatPopup.indexOfSelectedItem
        guard ImageFormat.allCases.indices.contains(idx) else { return }
        AppPreferences.shared.imageFormat = ImageFormat.allCases[idx]
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = AppPreferences.shared.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            AppPreferences.shared.saveDirectory = url
            folderLabel.stringValue = url.path
        }
    }

    @objc private func crosshairsToggled() {
        AppPreferences.shared.showCrosshairs = (crosshairsCheckbox.state == .on)
    }

    @objc private func copyOnSaveToggled() {
        AppPreferences.shared.copyToClipboardOnSave = (copyOnSaveCheckbox.state == .on)
    }

    @objc private func openPrivacySettings() {
        ScreenCaptureService.shared.openScreenRecordingSettings()
    }

    @objc private func driveFieldsChanged() {
        persistDriveTextFields()
    }

    @objc private func driveFolderNameChanged() {
        let prefs = AppPreferences.shared
        let oldName = prefs.googleDriveFolderName
        prefs.googleDriveFolderName = driveFolderNameField.stringValue
        if prefs.googleDriveFolderName != oldName {
            prefs.googleDriveFolderID = ""
            driveFolderIDField.stringValue = ""
        }
    }

    @objc private func driveCheckboxesChanged() {
        let prefs = AppPreferences.shared
        prefs.autoSaveToDriveOnCopy = (autoSaveOnCopyCheckbox.state == .on)
        prefs.autoSaveToDriveOnSave = (autoSaveOnSaveCheckbox.state == .on)
        prefs.makeDriveFilesShareable = (shareableCheckbox.state == .on)
        prefs.showDriveUploadNotification = (driveToastCheckbox.state == .on)
    }

    func controlTextDidChange(_ obj: Notification) {
        persistDriveTextFields()
    }

    @objc private func authorizeGoogleDrive() {
        if isAuthorizing {
            GoogleDriveService.shared.cancelPendingAuthorization()
            return
        }

        persistDriveTextFields()
        let clientID = AppPreferences.shared.googleDriveClientID
        let clientSecret = AppPreferences.shared.googleDriveClientSecret

        isAuthorizing = true
        authorizeButton.title = "Cancel Auth"
        authSpinner.startAnimation(nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isAuthorizing = false
                self.authSpinner.stopAnimation(nil)
                self.refreshDriveStatus()
            }
            do {
                _ = try await GoogleDriveService.shared.authorize(
                    clientID: clientID,
                    clientSecret: clientSecret
                )
                HUDToast.show(message: "Google Drive connected")
            } catch LoopbackOAuthError.cancelled {
                HUDToast.show(message: "Google Drive auth cancelled", symbolName: "xmark.circle.fill")
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Google Drive Authorization Failed"
                alert.informativeText = error.localizedDescription
                if let win = self.window {
                    _ = await alert.beginSheetModal(for: win)
                } else {
                    alert.runModal()
                }
            }
        }
    }

    @objc private func disconnectGoogleDrive() {
        GoogleDriveService.shared.disconnect()
        driveFolderIDField.stringValue = ""
        refreshDriveStatus()
    }

    @objc private func showDriveSetupGuide() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Google Drive OAuth Setup"
        alert.informativeText = """
        1. Open Google Cloud Console (console.cloud.google.com) and enable the Google Drive API.
        2. Go to Google Auth Platform / Credentials > Create Credentials > OAuth client ID.
        3. Choose Application type: Desktop app.
        4. Paste the Client ID (and Client Secret if shown) into SnapFeather, then click Authorize Google Drive.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Cloud Console")
        if let win = self.window {
            alert.beginSheetModal(for: win) { response in
                if response == .alertSecondButtonReturn,
                   let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else if alert.runModal() == .alertSecondButtonReturn,
                  let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
            NSWorkspace.shared.open(url)
        }
    }
}
