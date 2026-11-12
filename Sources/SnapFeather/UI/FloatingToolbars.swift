import AppKit

@MainActor
protocol FloatingToolbarsDelegate: AnyObject {
    func toolbarsDidSelectTool(_ tool: AnnotationTool)
    func toolbarsDidSelectColor(_ color: NSColor)
    func toolbarsDidSelectLineWidth(_ width: CGFloat)
    func toolbarsDidSelectTextFontSize(_ size: CGFloat)
    func toolbarsDidClickUndo()
    func toolbarsDidClickClear()
    func toolbarsDidClickCopy()
    func toolbarsDidClickQuickSave()
    func toolbarsDidClickSaveAs()
    func toolbarsDidClickUploadToDrive()
    func toolbarsDidClickPrint()
    func toolbarsDidClickShare(from anchorView: NSView)
    func toolbarsDidClickClose()
}

@MainActor
class ToolbarIconButton: NSButton {
    var isToolActive: Bool = false {
        didSet { updateAppearance() }
    }

    var customAccentColor: NSColor? {
        didSet { updateAppearance() }
    }

    private var isHovered: Bool = false
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 6
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    private func updateAppearance() {
        if isToolActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
            contentTintColor = .white
        } else if isHovered {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
            contentTintColor = customAccentColor ?? .white
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = customAccentColor ?? NSColor.white.withAlphaComponent(0.9)
        }
    }
}

@MainActor
class FloatingToolbarPanel: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        appearance = NSAppearance(named: .darkAqua)
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class VerticalAnnotationToolbar: FloatingToolbarPanel {
    weak var delegate: FloatingToolbarsDelegate?

    private var toolButtons: [AnnotationTool: ToolbarIconButton] = [:]
    private let colorButton = ToolbarIconButton(frame: .zero)
    private let colorPopover = NSPopover()

    var selectedTool: AnnotationTool = .pen {
        didSet { updateActiveStates() }
    }

    var selectedColor: NSColor = AnnotationColorPreset.palette[0].color {
        didSet { updateColorSwatch() }
    }

    var selectedLineWidth: CGFloat = AppPreferences.shared.strokeWidth
    var selectedTextFontSize: CGFloat = AppPreferences.shared.textFontSize

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 392))
        setupButtons()
        updateActiveStates()
        updateColorSwatch()
    }

    private func setupButtons() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for tool in AnnotationTool.allCases {
            let btn = makeIconButton(symbol: tool.symbolName, tooltip: tool.title) { [weak self] in
                guard let self else { return }
                self.selectedTool = tool
                self.delegate?.toolbarsDidSelectTool(tool)
            }
            toolButtons[tool] = btn
            stack.addArrangedSubview(btn)
        }

        stack.addArrangedSubview(makeDivider())

        colorButton.translatesAutoresizingMaskIntoConstraints = false
        colorButton.toolTip = "Color & Stroke Width"
        colorButton.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Color")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        colorButton.target = self
        colorButton.action = #selector(openColorPopover(_:))
        NSLayoutConstraint.activate([
            colorButton.widthAnchor.constraint(equalToConstant: 28),
            colorButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        stack.addArrangedSubview(colorButton)

        let undoBtn = makeIconButton(symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)") { [weak self] in
            self?.delegate?.toolbarsDidClickUndo()
        }
        stack.addArrangedSubview(undoBtn)

        let clearBtn = makeIconButton(symbol: "trash", tooltip: "Clear All Annotations") { [weak self] in
            self?.delegate?.toolbarsDidClickClear()
        }
        stack.addArrangedSubview(clearBtn)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        layoutSubtreeIfNeeded()
        setFrameSize(stack.fittingSize)
    }

    private func makeDivider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 22),
            line.heightAnchor.constraint(equalToConstant: 1)
        ])
        return line
    }

    private func makeIconButton(symbol: String, tooltip: String, action: @escaping @MainActor () -> Void) -> ToolbarIconButton {
        let btn = ActionIconButton(actionHandler: action)
        btn.toolTip = tooltip
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium))
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 28),
            btn.heightAnchor.constraint(equalToConstant: 28)
        ])
        return btn
    }

    private func updateActiveStates() {
        for (tool, btn) in toolButtons {
            btn.isToolActive = (tool == selectedTool)
        }
    }

    private func updateColorSwatch() {
        colorButton.customAccentColor = selectedColor
        colorButton.contentTintColor = selectedColor
    }

    @objc private func openColorPopover(_ sender: NSButton) {
        if colorPopover.isShown {
            colorPopover.close()
            return
        }
        let vc = ColorWidthPopoverViewController(
            selectedColor: selectedColor,
            selectedWidth: selectedLineWidth,
            selectedFontSize: selectedTextFontSize,
            onSelectColor: { [weak self] newColor in
                self?.selectedColor = newColor
                self?.delegate?.toolbarsDidSelectColor(newColor)
            },
            onSelectWidth: { [weak self] newWidth in
                self?.selectedLineWidth = newWidth
                self?.delegate?.toolbarsDidSelectLineWidth(newWidth)
            },
            onSelectFontSize: { [weak self] newSize in
                self?.selectedTextFontSize = newSize
                self?.delegate?.toolbarsDidSelectTextFontSize(newSize)
            }
        )
        colorPopover.contentViewController = vc
        colorPopover.behavior = .transient
        colorPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minX)
    }
}

@MainActor
final class HorizontalActionToolbar: FloatingToolbarPanel {
    weak var delegate: FloatingToolbarsDelegate?
    private var shareButton: ToolbarIconButton?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 38))
        setupButtons()
    }

    private func setupButtons() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let copyBtn = makeActionButton(symbol: "doc.on.doc", title: "Copy", tooltip: "Copy to Clipboard (⌘C)") { [weak self] in
            self?.delegate?.toolbarsDidClickCopy()
        }
        stack.addArrangedSubview(copyBtn)

        let quickSaveBtn = makeIconButton(symbol: "square.and.arrow.down.on.square", tooltip: "Quick Save to Folder") { [weak self] in
            self?.delegate?.toolbarsDidClickQuickSave()
        }
        stack.addArrangedSubview(quickSaveBtn)

        let saveAsBtn = makeIconButton(symbol: "square.and.arrow.down", tooltip: "Save As... (⌘S)") { [weak self] in
            self?.delegate?.toolbarsDidClickSaveAs()
        }
        stack.addArrangedSubview(saveAsBtn)

        let driveBtn = makeIconButton(symbol: "icloud.and.arrow.up", tooltip: "Upload to Google Drive") { [weak self] in
            self?.delegate?.toolbarsDidClickUploadToDrive()
        }
        stack.addArrangedSubview(driveBtn)

        let printBtn = makeIconButton(symbol: "printer", tooltip: "Print (⌘P)") { [weak self] in
            self?.delegate?.toolbarsDidClickPrint()
        }
        stack.addArrangedSubview(printBtn)

        let shareBtn = makeIconButton(symbol: "square.and.arrow.up", tooltip: "Share") { [weak self] in
            guard let self, let btn = self.shareButton else { return }
            self.delegate?.toolbarsDidClickShare(from: btn)
        }
        self.shareButton = shareBtn
        stack.addArrangedSubview(shareBtn)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 20)
        ])
        stack.addArrangedSubview(divider)

        let closeBtn = makeIconButton(symbol: "xmark", tooltip: "Cancel (Esc)") { [weak self] in
            self?.delegate?.toolbarsDidClickClose()
        }
        closeBtn.customAccentColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)
        stack.addArrangedSubview(closeBtn)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        layoutSubtreeIfNeeded()
        setFrameSize(stack.fittingSize)
    }

    private func makeActionButton(symbol: String, title: String, tooltip: String, action: @escaping @MainActor () -> Void) -> NSButton {
        let btn = ActionPillButton(title: title, symbol: symbol, actionHandler: action)
        btn.toolTip = tooltip
        return btn
    }

    private func makeIconButton(symbol: String, tooltip: String, action: @escaping @MainActor () -> Void) -> ToolbarIconButton {
        let btn = ActionIconButton(actionHandler: action)
        btn.toolTip = tooltip
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium))
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 28),
            btn.heightAnchor.constraint(equalToConstant: 28)
        ])
        return btn
    }
}

@MainActor
private final class ActionIconButton: ToolbarIconButton {
    private let actionHandler: @MainActor () -> Void

    init(actionHandler: @escaping @MainActor () -> Void) {
        self.actionHandler = actionHandler
        super.init(frame: .zero)
        target = self
        action = #selector(didTap)
    }

    @objc private func didTap() {
        actionHandler()
    }
}

@MainActor
private final class ActionPillButton: NSButton {
    private let actionHandler: @MainActor () -> Void
    private var trackingAreaRef: NSTrackingArea?

    init(title: String, symbol: String, actionHandler: @escaping @MainActor () -> Void) {
        self.actionHandler = actionHandler
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor
        focusRingType = .none

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14)
        ])

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center

        let contentStack = NSStackView(views: [iconView, label])
        contentStack.orientation = .horizontal
        contentStack.spacing = 5
        contentStack.alignment = .centerY
        contentStack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentStack)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])

        target = self
        action = #selector(didTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor
    }

    @objc private func didTap() {
        actionHandler()
    }
}

@MainActor
private final class ColorWidthPopoverViewController: NSViewController {
    private var selectedColor: NSColor
    private var selectedWidth: CGFloat
    private var selectedFontSize: CGFloat
    private let onSelectColor: @MainActor (NSColor) -> Void
    private let onSelectWidth: @MainActor (CGFloat) -> Void
    private let onSelectFontSize: @MainActor (CGFloat) -> Void

    private var swatchButtons: [SwatchButton] = []
    private var widthButtons: [(CGFloat, SizePillButton)] = []
    private var fontButtons: [(CGFloat, SizePillButton)] = []

    private let widthValueLabel = NSTextField(labelWithString: "")
    private let widthSlider = NSSlider(value: 3.0, minValue: 1.0, maxValue: 24.0, target: nil, action: nil)
    private let brushPreviewDot = NSView()
    private var brushPreviewWidthConstraint: NSLayoutConstraint?
    private var brushPreviewHeightConstraint: NSLayoutConstraint?

    private let fontValueLabel = NSTextField(labelWithString: "")
    private let fontSlider = NSSlider(value: 18.0, minValue: 12.0, maxValue: 72.0, target: nil, action: nil)

    init(
        selectedColor: NSColor,
        selectedWidth: CGFloat,
        selectedFontSize: CGFloat,
        onSelectColor: @escaping @MainActor (NSColor) -> Void,
        onSelectWidth: @escaping @MainActor (CGFloat) -> Void,
        onSelectFontSize: @escaping @MainActor (CGFloat) -> Void
    ) {
        self.selectedColor = selectedColor
        self.selectedWidth = selectedWidth
        self.selectedFontSize = selectedFontSize
        self.onSelectColor = onSelectColor
        self.onSelectWidth = onSelectWidth
        self.onSelectFontSize = onSelectFontSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 268, height: 264))

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.spacing = 10
        mainStack.alignment = .leading
        mainStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        let colorLabel = makeSectionLabel("Color")
        mainStack.addArrangedSubview(colorLabel)

        let swatchRow = NSStackView()
        swatchRow.orientation = .horizontal
        swatchRow.spacing = 7
        for preset in AnnotationColorPreset.palette {
            let swatch = SwatchButton(color: preset.color, isSelected: Self.colorsMatch(preset.color, selectedColor)) { [weak self] color in
                guard let self else { return }
                self.selectedColor = color
                self.onSelectColor(color)
                self.refreshUI()
            }
            swatch.toolTip = preset.name
            swatchButtons.append(swatch)
            swatchRow.addArrangedSubview(swatch)
        }
        mainStack.addArrangedSubview(swatchRow)

        mainStack.addArrangedSubview(makeSeparator())

        // Brush Size section
        let brushHeader = NSStackView()
        brushHeader.orientation = .horizontal
        brushHeader.alignment = .centerY
        brushHeader.spacing = 8
        brushHeader.translatesAutoresizingMaskIntoConstraints = false

        let brushTitle = makeSectionLabel("Brush Size")
        widthValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        widthValueLabel.textColor = .labelColor

        let previewBox = NSView()
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewBox.widthAnchor.constraint(equalToConstant: 24),
            previewBox.heightAnchor.constraint(equalToConstant: 24)
        ])

        brushPreviewDot.wantsLayer = true
        brushPreviewDot.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(brushPreviewDot)
        let wC = brushPreviewDot.widthAnchor.constraint(equalToConstant: selectedWidth)
        let hC = brushPreviewDot.heightAnchor.constraint(equalToConstant: selectedWidth)
        brushPreviewWidthConstraint = wC
        brushPreviewHeightConstraint = hC
        NSLayoutConstraint.activate([
            brushPreviewDot.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            brushPreviewDot.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
            wC,
            hC
        ])

        let spacer1 = NSView()
        spacer1.setContentHuggingPriority(.defaultLow, for: .horizontal)
        brushHeader.addArrangedSubview(brushTitle)
        brushHeader.addArrangedSubview(spacer1)
        brushHeader.addArrangedSubview(previewBox)
        brushHeader.addArrangedSubview(widthValueLabel)
        mainStack.addArrangedSubview(brushHeader)
        brushHeader.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -28).isActive = true

        widthSlider.isContinuous = true
        widthSlider.controlSize = .small
        widthSlider.doubleValue = Double(selectedWidth)
        widthSlider.target = self
        widthSlider.action = #selector(widthSliderChanged)
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        mainStack.addArrangedSubview(widthSlider)

        let widthRow = NSStackView()
        widthRow.orientation = .horizontal
        widthRow.spacing = 6
        for (title, w) in [("2 pt", CGFloat(2)), ("4 pt", CGFloat(4)), ("8 pt", CGFloat(8)), ("14 pt", CGFloat(14))] {
            let pill = SizePillButton(title: title, isSelected: false) { [weak self] in
                guard let self else { return }
                self.selectedWidth = w
                self.onSelectWidth(w)
                self.refreshUI()
            }
            widthButtons.append((w, pill))
            widthRow.addArrangedSubview(pill)
        }
        mainStack.addArrangedSubview(widthRow)

        mainStack.addArrangedSubview(makeSeparator())

        // Text Font Size section
        let fontHeader = NSStackView()
        fontHeader.orientation = .horizontal
        fontHeader.alignment = .centerY
        fontHeader.spacing = 8
        fontHeader.translatesAutoresizingMaskIntoConstraints = false

        let fontTitle = makeSectionLabel("Text Font Size")
        fontValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        fontValueLabel.textColor = .labelColor

        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fontHeader.addArrangedSubview(fontTitle)
        fontHeader.addArrangedSubview(spacer2)
        fontHeader.addArrangedSubview(fontValueLabel)
        mainStack.addArrangedSubview(fontHeader)
        fontHeader.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -28).isActive = true

        fontSlider.isContinuous = true
        fontSlider.controlSize = .small
        fontSlider.doubleValue = Double(selectedFontSize)
        fontSlider.target = self
        fontSlider.action = #selector(fontSliderChanged)
        fontSlider.translatesAutoresizingMaskIntoConstraints = false
        fontSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        mainStack.addArrangedSubview(fontSlider)

        let fontRow = NSStackView()
        fontRow.orientation = .horizontal
        fontRow.spacing = 6
        for (title, s) in [("14 pt", CGFloat(14)), ("18 pt", CGFloat(18)), ("28 pt", CGFloat(28)), ("42 pt", CGFloat(42))] {
            let pill = SizePillButton(title: title, isSelected: false) { [weak self] in
                guard let self else { return }
                self.selectedFontSize = s
                self.onSelectFontSize(s)
                self.refreshUI()
            }
            fontButtons.append((s, pill))
            fontRow.addArrangedSubview(pill)
        }
        mainStack.addArrangedSubview(fontRow)

        let tipLabel = NSTextField(labelWithString: "Tip: Hold ⌥ + Scroll (or [ / ]) to resize anytime")
        tipLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        tipLabel.textColor = .tertiaryLabelColor
        mainStack.addArrangedSubview(tipLabel)

        root.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: root.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])

        self.view = root
        refreshUI()
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeSeparator() -> NSView {
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 240),
            sep.heightAnchor.constraint(equalToConstant: 1)
        ])
        return sep
    }

    private func refreshUI() {
        for swatch in swatchButtons {
            swatch.isSelectedSwatch = Self.colorsMatch(swatch.swatchColor, selectedColor)
        }

        widthSlider.doubleValue = Double(selectedWidth)
        widthValueLabel.stringValue = String(format: "%.1f pt", selectedWidth)

        let dotSize = min(max(selectedWidth, 2.0), 22.0)
        brushPreviewWidthConstraint?.constant = dotSize
        brushPreviewHeightConstraint?.constant = dotSize
        brushPreviewDot.layer?.cornerRadius = dotSize / 2.0
        brushPreviewDot.layer?.backgroundColor = selectedColor.cgColor
        brushPreviewDot.layer?.borderWidth = 1
        brushPreviewDot.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor

        for (w, btn) in widthButtons {
            btn.isSelectedOption = abs(selectedWidth - w) < 0.6
        }

        fontSlider.doubleValue = Double(selectedFontSize)
        fontValueLabel.stringValue = "\(Int(round(selectedFontSize))) pt"
        for (s, btn) in fontButtons {
            btn.isSelectedOption = abs(selectedFontSize - s) < 1.0
        }
    }

    @objc private func widthSliderChanged() {
        let stepped = (round(widthSlider.doubleValue * 2.0) / 2.0)
        selectedWidth = CGFloat(stepped)
        onSelectWidth(selectedWidth)
        refreshUI()
    }

    @objc private func fontSliderChanged() {
        let rounded = round(fontSlider.doubleValue)
        selectedFontSize = CGFloat(rounded)
        onSelectFontSize(selectedFontSize)
        refreshUI()
    }

    private static func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let c1 = a.usingColorSpace(.sRGB), let c2 = b.usingColorSpace(.sRGB) else {
            return a == b
        }
        return abs(c1.redComponent - c2.redComponent) < 0.02
            && abs(c1.greenComponent - c2.greenComponent) < 0.02
            && abs(c1.blueComponent - c2.blueComponent) < 0.02
    }
}

@MainActor
private final class SwatchButton: NSButton {
    let swatchColor: NSColor
    private let onPick: @MainActor (NSColor) -> Void
    private let checkmarkView = NSImageView()

    var isSelectedSwatch: Bool = false {
        didSet { updateAppearance() }
    }

    init(color: NSColor, isSelected: Bool, onPick: @escaping @MainActor (NSColor) -> Void) {
        self.swatchColor = color
        self.isSelectedSwatch = isSelected
        self.onPick = onPick
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = color.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22)
        ])

        checkmarkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        checkmarkView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkmarkView)
        NSLayoutConstraint.activate([
            checkmarkView.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkmarkView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        target = self
        action = #selector(didTap)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateAppearance() {
        checkmarkView.isHidden = !isSelectedSwatch
        if let srgb = swatchColor.usingColorSpace(.sRGB) {
            let luminance = 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
            checkmarkView.contentTintColor = luminance > 0.7 ? .black : .white
        } else {
            checkmarkView.contentTintColor = .white
        }
        layer?.borderWidth = isSelectedSwatch ? 2.5 : 1.0
        layer?.borderColor = (isSelectedSwatch ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.35)).cgColor
    }

    @objc private func didTap() {
        onPick(swatchColor)
    }
}

@MainActor
private final class SizePillButton: NSButton {
    private let onPick: @MainActor () -> Void
    private let labelField: NSTextField

    var isSelectedOption: Bool = false {
        didSet { updateAppearance() }
    }

    init(title: String, isSelected: Bool, onPick: @escaping @MainActor () -> Void) {
        self.onPick = onPick
        self.isSelectedOption = isSelected
        self.labelField = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        focusRingType = .none

        labelField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        labelField.alignment = .center
        labelField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelField)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 54),
            heightAnchor.constraint(equalToConstant: 24),
            labelField.centerXAnchor.constraint(equalTo: centerXAnchor),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        target = self
        action = #selector(didTap)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    private func updateAppearance() {
        if isSelectedOption {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            labelField.textColor = .white
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
            labelField.textColor = .labelColor
        }
    }

    @objc private func didTap() {
        onPick()
    }
}
