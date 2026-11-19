import AppKit
import Foundation
import UniformTypeIdentifiers

private enum ScreenshotMarkupTool: CaseIterable, Equatable {
    case select
    case rectangle
    case ellipse
    case line
    case arrow
    case freehand
    case highlighter
    case mosaic
    case text
}

private enum ScreenshotShapeFillStyle: Int, CaseIterable {
    case translucent
    case solid
    case calloutDown
    case calloutUp

    var title: String {
        switch self {
        case .translucent: "Semi-transparent"
        case .solid: "Solid"
        case .calloutDown: "Callout box • pointer down"
        case .calloutUp: "Callout box • pointer up"
        }
    }

    var symbol: String {
        switch self {
        case .translucent: "square.lefthalf.filled"
        case .solid: "square.fill"
        case .calloutDown: "text.bubble"
        case .calloutUp: "text.bubble.fill"
        }
    }

    var isCallout: Bool {
        self == .calloutDown || self == .calloutUp
    }

    var pointerUp: Bool {
        self == .calloutUp
    }
}

private enum ScreenshotResizeHandle: CaseIterable {
    case northWest, north, northEast, east, southEast, south, southWest, west
}

private enum ScreenshotStrokeWeight: Int, CaseIterable, Equatable {
    case level1, level2, level3, level4, level5, level6

    var lineWidth: CGFloat {
        switch self {
        case .level1: 1
        case .level2: 1.5
        case .level3: 2.5
        case .level4: 3.5
        case .level5: 5
        case .level6: 7
        }
    }

    var menuTitle: String {
        "Level \(rawValue + 1)  ·  \(String(format: "%g", Double(lineWidth))) pt"
    }
}

private enum MarkupPaletteColor: Int, CaseIterable {
    case red, orange, yellow, green, blue, indigo, violet
    case black, white, cyan, pink, gray

    var title: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .violet: "Violet"
        case .black: "Black"
        case .white: "White"
        case .cyan: "Cyan"
        case .pink: "Pink"
        case .gray: "Gray"
        }
    }

    var color: NSColor {
        let components: (CGFloat, CGFloat, CGFloat)
        switch self {
        case .red: components = (1.00, 0.24, 0.28)
        case .orange: components = (1.00, 0.53, 0.16)
        case .yellow: components = (1.00, 0.82, 0.22)
        case .green: components = (0.16, 0.75, 0.38)
        case .blue: components = (0.12, 0.49, 0.96)
        case .indigo: components = (0.34, 0.34, 0.82)
        case .violet: components = (0.66, 0.32, 0.91)
        case .black: components = (0.08, 0.09, 0.12)
        case .white: components = (1.00, 1.00, 1.00)
        case .cyan: components = (0.12, 0.78, 0.88)
        case .pink: components = (0.96, 0.36, 0.63)
        case .gray: components = (0.57, 0.61, 0.67)
        }
        return NSColor(calibratedRed: components.0, green: components.1, blue: components.2, alpha: 1)
    }
}

private struct ScreenshotMarkupAnnotation {
    var tool: ScreenshotMarkupTool
    var rect: CGRect
    var text: String?
    var strokeColor: NSColor
    var textColor: NSColor
    var fillStyle: ScreenshotShapeFillStyle = .translucent
    var fontSize: CGFloat
    var isWatermark: Bool = false
    var mosaicImage: CGImage? = nil
    var strokeWeight: ScreenshotStrokeWeight = .level4
    var points: [CGPoint] = []
}

private struct WatermarkPreset: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var text: String
}

private enum ScreenshotExportFormat: CaseIterable {
    case png, jpeg, tiff

    var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        }
    }

    var bitmapFileType: NSBitmapImageRep.FileType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .tiff: "tiff"
        }
    }

    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .tiff: "TIFF"
        }
    }

    static func resolve(contentType: UTType?, pathExtension: String) -> Self {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "tif", "tiff": return .tiff
        case "png": return .png
        default: break
        }
        guard let contentType else { return .png }
        if contentType.conforms(to: .jpeg) { return .jpeg }
        if contentType.conforms(to: .tiff) { return .tiff }
        return .png
    }
}

private enum ScreenshotDragMode {
    case draw
    case move(index: Int)
    case resize(index: Int, handle: ScreenshotResizeHandle)
}

private final class ScreenshotMarkupBackgroundView: MetalBackgroundView {
    var showsMetalBackground = true {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { showsMetalBackground }

    override func draw(_ dirtyRect: NSRect) {
        guard showsMetalBackground else {
            NSGraphicsContext.current?.cgContext.clear(dirtyRect)
            return
        }
        super.draw(dirtyRect)
    }
}

private final class ScreenshotMarkupWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, onEscape != nil {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape {
            onEscape()
            return
        }
        super.cancelOperation(sender)
    }
}

final class ScreenshotMarkupWindowController: NSWindowController, NSWindowDelegate {
    private let canvas: ScreenshotMarkupCanvasView
    private let statusLabel = NSTextField(labelWithString: "Select an object to move it • Choose a tool to add markup")
    private var toolButtons: [ScreenshotMarkupTool: MarkupIconButton] = [:]
    private var fillButton: MarkupIconButton!
    private var fontSize: CGFloat = 24
    private var shapeFillStyle = ScreenshotShapeFillStyle.translucent
    private var strokeWeight = ScreenshotStrokeWeight.level4
    private var isFloatingPreview = false
    private var isPinned = false
    private var isPinnedToolbarVisible = true
    private var floatingBaseSize = NSSize.zero
    private var floatingZoomScale: CGFloat = 1
    private var toolbarPanel: NSPanel?
    private var outsideClickPinGlobalMonitor: Any?
    private var outsideClickPinLocalMonitor: Any?
    private weak var screenshotBackground: ScreenshotMarkupBackgroundView?
    private var canvasInsetConstraints: [NSLayoutConstraint] = []
    private var canvasFullBleedConstraints: [NSLayoutConstraint] = []
    private var pinButton: MarkupIconButton!
    private var strokeWeightButton: MarkupIconButton!
    private var outlineColorButton: MarkupIconButton!
    private var textColorButton: MarkupIconButton!
    private var outlineColor = MarkupPaletteColor(
        rawValue: UserDefaults.standard.integer(forKey: "MacClean.markup.outlineColor")
    ) ?? .red
    private var textColor = MarkupPaletteColor(
        rawValue: UserDefaults.standard.integer(forKey: "MacClean.markup.textColor")
    ) ?? .red
    var onClose: (() -> Void)?

    init?(image: NSImage) {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        let window = ScreenshotMarkupWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let captureScale = CGFloat(cgImage.width) / max(image.size.width, 1)
        self.canvas = ScreenshotMarkupCanvasView(image: cgImage, captureScale: captureScale)
        super.init(window: window)
        canvas.markupColor = outlineColor.color
        canvas.textColor = textColor.color

        window.title = "Screenshot & Markup"
        window.titleVisibility = .visible
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.025, green: 0.04, blue: 0.065, alpha: 1)
        window.minSize = NSSize(width: 780, height: 460)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let selectButton = makeToolButton(.select, symbol: "cursorarrow", help: "Select and move objects (V)", action: #selector(selectTool))
        let rectangleButton = makeToolButton(.rectangle, symbol: "rectangle", help: "Draw a rectangle (R)", action: #selector(selectRectangle))
        let ellipseButton = makeToolButton(.ellipse, symbol: "circle", help: "Draw an ellipse (O)", action: #selector(selectEllipse))
        let lineButton = makeToolButton(.line, symbol: "minus", help: "Draw a line (L)", action: #selector(selectLineTool))
        let arrowButton = makeToolButton(.arrow, symbol: "arrow.up.right", help: "Draw an arrow (A)", action: #selector(selectArrow))
        let freehandButton = makeToolButton(.freehand, symbol: "pencil.tip.crop.circle", help: "Draw freehand (P)", action: #selector(selectFreehand))
        let highlighterButton = makeToolButton(.highlighter, symbol: "highlighter", help: "Highlight an area (H)", action: #selector(selectHighlighter))
        let textButton = makeToolButton(.text, symbol: "textformat", help: "Add or edit text (T)", action: #selector(selectText))
        let mosaicButton = makeToolButton(.mosaic, symbol: "square.grid.3x3.fill", help: "Drag over an area to pixelate it", action: #selector(selectMosaic))
        let watermarkButton = MarkupIconButton(symbol: "checkmark.seal", help: "Create or reuse a watermark", target: self, action: #selector(showWatermarkMenu(_:)))

        fillButton = MarkupIconButton(symbol: shapeFillStyle.symbol, help: "Shape fill: \(shapeFillStyle.title) • click to choose", target: self, action: #selector(showShapeFillStyleMenu))
        fillButton.setActive(true)

        strokeWeightButton = MarkupIconButton(symbol: "lineweight", help: "Outline width: 3.5 pt • click to choose from 6 levels", target: self, action: #selector(showStrokeWeightMenu))
        strokeWeightButton.setStrokeWeightIndicator(lineWidth: strokeWeight.lineWidth)

        outlineColorButton = MarkupIconButton(
            symbol: "square",
            help: "Outline color: \(outlineColor.title) • choose from 12 colors",
            target: self,
            action: #selector(showOutlineColorMenu(_:))
        )
        outlineColorButton.setColorIndicator(symbol: "square", color: outlineColor.color)
        textColorButton = MarkupIconButton(
            symbol: "textformat",
            help: "Text color: \(textColor.title) • choose from 12 colors",
            target: self,
            action: #selector(showTextColorMenu(_:))
        )
        textColorButton.setColorIndicator(symbol: "textformat", color: textColor.color)

        let undoButton = MarkupIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", target: self, action: #selector(undo))
        let deleteButton = MarkupIconButton(symbol: "trash", help: "Delete selected object (Delete)", target: self, action: #selector(deleteSelection))
        let copyButton = MarkupIconButton(symbol: "doc.on.doc", help: "Copy marked screenshot (⌘C)", target: self, action: #selector(copyImage), primary: true)
        let saveButton = MarkupIconButton(symbol: "square.and.arrow.down", help: "Save as PNG, JPEG or TIFF…", target: self, action: #selector(saveImage))
        pinButton = MarkupIconButton(symbol: "pin", help: "Pin this screenshot, or click outside the preview", target: self, action: #selector(togglePin))

        let drawingTools: [NSView] = [
            selectButton, rectangleButton, ellipseButton, lineButton, arrowButton,
            freehandButton, highlighterButton, textButton, mosaicButton, watermarkButton
        ]
        let styleTools: [NSView] = [outlineColorButton, textColorButton, strokeWeightButton, fillButton]
        let finalTools: [NSView] = [undoButton, deleteButton, copyButton, saveButton, pinButton]
        let toolRow = NSStackView(views: drawingTools + styleTools + finalTools)
        toolRow.orientation = .horizontal
        toolRow.alignment = .centerY
        toolRow.spacing = 0
        toolRow.translatesAutoresizingMaskIntoConstraints = false

        canvas.onCopyRequested = { [weak self] in self?.copyImage() }
        canvas.onFloatingZoomScroll = { [weak self] event in self?.zoomFloatingWindow(with: event) }
        canvas.onSelectionChanged = { [weak self] selectedFontSize in
            guard let self, let selectedFontSize else { return }
            self.fontSize = selectedFontSize
        }
        canvas.onTextSizeScroll = { [weak self] adjustment in
            guard let self else { return }
            self.setTextSize(self.fontSize + adjustment)
        }
        canvas.onRightClick = { [weak self] in self?.togglePinnedToolbarVisibility() }
        canvas.onFloatingWindowDrag = { [weak self] event in self?.window?.performDrag(with: event) }
        canvas.onToolChanged = { [weak self] selectedTool in self?.updateSelectedTool(selectedTool) }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let background = ScreenshotMarkupBackgroundView(frame: .zero)
        screenshotBackground = background
        background.addSubview(canvas)
        canvasInsetConstraints = [
            canvas.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            canvas.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            canvas.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            canvas.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14)
        ]
        canvasFullBleedConstraints = [
            canvas.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: background.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ]
        NSLayoutConstraint.activate(canvasInsetConstraints)

        let toolbarChrome = NSVisualEffectView()
        toolbarChrome.material = .hudWindow
        toolbarChrome.blendingMode = .withinWindow
        toolbarChrome.state = .active
        toolbarChrome.appearance = NSAppearance(named: .darkAqua)
        toolbarChrome.wantsLayer = true
        toolbarChrome.layer?.cornerRadius = 13
        toolbarChrome.layer?.borderWidth = 1
        toolbarChrome.layer?.borderColor = NSColor(calibratedRed: 0.42, green: 0.62, blue: 0.78, alpha: 0.5).cgColor
        toolbarChrome.translatesAutoresizingMaskIntoConstraints = false
        toolbarChrome.addSubview(toolRow)
        toolRow.leadingAnchor.constraint(equalTo: toolbarChrome.leadingAnchor, constant: 6).isActive = true
        toolRow.trailingAnchor.constraint(equalTo: toolbarChrome.trailingAnchor, constant: -6).isActive = true
        toolRow.topAnchor.constraint(equalTo: toolbarChrome.topAnchor, constant: 4).isActive = true
        toolbarChrome.widthAnchor.constraint(equalTo: toolRow.widthAnchor, constant: 12).isActive = true
        toolbarChrome.heightAnchor.constraint(equalToConstant: 62).isActive = true

        statusLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = NSColor(calibratedWhite: 0.84, alpha: 1)
        statusLabel.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.07, blue: 0.11, alpha: 0.82)
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.wantsLayer = true
        statusLabel.layer?.cornerRadius = 7
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbarChrome.addSubview(statusLabel)
        statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: toolbarChrome.leadingAnchor, constant: 10).isActive = true
        statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: toolbarChrome.trailingAnchor, constant: -10).isActive = true
        statusLabel.centerXAnchor.constraint(equalTo: toolbarChrome.centerXAnchor).isActive = true
        statusLabel.bottomAnchor.constraint(equalTo: toolbarChrome.bottomAnchor, constant: -4).isActive = true
        statusLabel.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let toolbarWidth = max(160, toolRow.fittingSize.width + 12)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: toolbarWidth, height: 62),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = toolbarChrome
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.animationBehavior = .utilityWindow
        toolbarPanel = panel

        window.contentView = background
        selectTool()
        prepareFloatingPreview(imageWidth: cgImage.width, imageHeight: cgImage.height)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        removeOutsideClickPinMonitors()
        toolbarPanel?.orderOut(nil)
        toolbarPanel?.close()
        toolbarPanel = nil
        onClose?()
        onClose = nil
    }

    func windowDidMove(_ notification: Notification) {
        updateToolbarPanelPosition()
    }

    func windowDidResize(_ notification: Notification) {
        updateToolbarPanelPosition()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateToolbarPanelPosition()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateToolbarPanelPosition()
    }

    private func makeToolButton(
        _ tool: ScreenshotMarkupTool,
        symbol: String,
        help: String,
        action: Selector
    ) -> MarkupIconButton {
        let button = MarkupIconButton(symbol: symbol, help: help, target: self, action: action)
        toolButtons[tool] = button
        return button
    }

    @objc private func selectTool() { setTool(.select) }
    @objc private func selectRectangle() { setTool(.rectangle) }
    @objc private func selectEllipse() { setTool(.ellipse) }
    @objc private func selectLineTool() { setTool(.line) }
    @objc private func selectArrow() { setTool(.arrow) }
    @objc private func selectFreehand() { setTool(.freehand) }
    @objc private func selectHighlighter() { setTool(.highlighter) }
    @objc private func selectMosaic() { setTool(.mosaic) }
    @objc private func selectText() { setTool(.text) }

    private func setTool(_ tool: ScreenshotMarkupTool) {
        canvas.tool = tool
        window?.makeFirstResponder(canvas)
        updateSelectedTool(tool)
        switch tool {
        case .select: statusLabel.stringValue = "Drag an object to move it • Drag a handle to resize it"
        case .rectangle: statusLabel.stringValue = "Rectangle selected • Drag on the image to draw"
        case .ellipse: statusLabel.stringValue = "Ellipse selected • Drag on the image to draw"
        case .line: statusLabel.stringValue = "Line selected • Drag from start to end"
        case .arrow: statusLabel.stringValue = "Arrow selected • Drag from tail to arrowhead"
        case .freehand: statusLabel.stringValue = "Freehand selected • Draw with the mouse"
        case .highlighter: statusLabel.stringValue = "Highlighter selected • Drag over the area to emphasize"
        case .mosaic: statusLabel.stringValue = "Mosaic selected • Drag over sensitive content • Select to move or resize"
        case .text: statusLabel.stringValue = "Click anywhere and type • scroll up/down to resize text"
        }
    }

    private func updateSelectedTool(_ tool: ScreenshotMarkupTool) {
        toolButtons.forEach { key, button in button.setActive(key == tool) }
    }

    @objc private func showOutlineColorMenu(_ sender: NSButton) {
        showMarkupColorMenu(forText: false, sender: sender)
    }

    @objc private func showTextColorMenu(_ sender: NSButton) {
        showMarkupColorMenu(forText: true, sender: sender)
    }

    private func showMarkupColorMenu(forText: Bool, sender: NSButton) {
        let selectedColor = forText ? textColor : outlineColor
        let menu = NSMenu()
        for paletteColor in MarkupPaletteColor.allCases {
            let item = NSMenuItem(
                title: paletteColor.title,
                action: forText ? #selector(selectTextColor(_:)) : #selector(selectOutlineColor(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = paletteColor.rawValue
            item.state = paletteColor == selectedColor ? .on : .off
            item.image = colorSwatchImage(paletteColor.color)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func selectOutlineColor(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let paletteColor = MarkupPaletteColor(rawValue: rawValue) else { return }
        outlineColor = paletteColor
        UserDefaults.standard.set(paletteColor.rawValue, forKey: "MacClean.markup.outlineColor")
        canvas.markupColor = paletteColor.color
        canvas.changeSelectedStrokeColor(paletteColor.color)
        outlineColorButton.setColorIndicator(symbol: "square", color: paletteColor.color)
        outlineColorButton.toolTip = "Outline color: \(paletteColor.title) • choose from 12 colors"
        statusLabel.stringValue = "Outline color set to \(paletteColor.title)"
    }

    @objc private func selectTextColor(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let paletteColor = MarkupPaletteColor(rawValue: rawValue) else { return }
        textColor = paletteColor
        UserDefaults.standard.set(paletteColor.rawValue, forKey: "MacClean.markup.textColor")
        canvas.textColor = paletteColor.color
        canvas.changeSelectedTextColor(paletteColor.color)
        textColorButton.setColorIndicator(symbol: "textformat", color: paletteColor.color)
        textColorButton.toolTip = "Text color: \(paletteColor.title) • choose from 12 colors"
        statusLabel.stringValue = "Text color set to \(paletteColor.title)"
    }

    private func colorSwatchImage(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let swatch = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            swatch.fill()
            NSColor(calibratedWhite: 0.1, alpha: 0.5).setStroke()
            swatch.lineWidth = 0.7
            swatch.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func showWatermarkMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let createItem = NSMenuItem(title: "Create Watermark…", action: #selector(createWatermark(_:)), keyEquivalent: "")
        createItem.target = self
        menu.addItem(createItem)

        let presets = loadWatermarkPresets()
        if !presets.isEmpty {
            menu.addItem(.separator())
            for preset in presets {
                let item = NSMenuItem(title: preset.name, action: #selector(addSavedWatermark(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.id.uuidString
                item.toolTip = preset.text
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let manageItem = NSMenuItem(title: "Manage Saved Watermarks…", action: #selector(manageWatermarks(_:)), keyEquivalent: "")
            manageItem.target = self
            menu.addItem(manageItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func createWatermark(_ sender: Any?) {
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))
        let textLabel = NSTextField(labelWithString: "Watermark text")
        textLabel.frame = NSRect(x: 0, y: 126, width: 360, height: 18)
        let textField = NSTextField(string: "")
        textField.frame = NSRect(x: 0, y: 98, width: 360, height: 24)
        textField.placeholderString = "e.g. CONFIDENTIAL"
        let nameLabel = NSTextField(labelWithString: "Reusable preset name")
        nameLabel.frame = NSRect(x: 0, y: 66, width: 360, height: 18)
        let nameField = NSTextField(string: "")
        nameField.frame = NSRect(x: 0, y: 38, width: 360, height: 24)
        nameField.placeholderString = "Optional; defaults to watermark text"
        let saveCheckbox = NSButton(checkboxWithTitle: "Save this watermark for reuse", target: nil, action: nil)
        saveCheckbox.frame = NSRect(x: 0, y: 4, width: 360, height: 24)
        saveCheckbox.state = .on
        [textLabel, textField, nameLabel, nameField, saveCheckbox].forEach(form.addSubview)

        let alert = NSAlert()
        alert.messageText = "Create Watermark"
        alert.informativeText = "A semi-transparent text watermark will be added near the center of the screenshot. Select it to move or resize it."
        alert.alertStyle = .informational
        alert.accessoryView = form
        alert.addButton(withTitle: "Add Watermark")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = textField
        let restoreToolbar = hideToolbarPanelForModal()
        defer { restoreToolbarPanelAfterModal(restoreToolbar) }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            statusLabel.stringValue = "Enter watermark text first"
            return
        }
        if saveCheckbox.state == .on {
            let requestedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let preset = WatermarkPreset(name: requestedName.isEmpty ? String(text.prefix(40)) : requestedName, text: text)
            var presets = loadWatermarkPresets()
            presets.removeAll { $0.name.localizedCaseInsensitiveCompare(preset.name) == .orderedSame }
            presets.append(preset)
            saveWatermarkPresets(presets)
        }
        canvas.addWatermark(text)
        statusLabel.stringValue = "Watermark added • Select and drag it to move"
    }

    @objc private func addSavedWatermark(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let id = UUID(uuidString: identifier),
              let preset = loadWatermarkPresets().first(where: { $0.id == id }) else { return }
        canvas.addWatermark(preset.text)
        statusLabel.stringValue = "Added watermark: \(preset.name) • Select and drag it to move"
    }

    @objc private func manageWatermarks(_ sender: Any?) {
        let presets = loadWatermarkPresets()
        guard !presets.isEmpty else { return }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28), pullsDown: false)
        popup.addItems(withTitles: presets.map(\.name))
        popup.selectItem(at: 0)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 34))
        accessory.addSubview(popup)
        let alert = NSAlert()
        alert.messageText = "Manage Saved Watermarks"
        alert.informativeText = "Choose a saved preset to remove it from the reusable list."
        alert.alertStyle = .informational
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Delete Preset")
        alert.addButton(withTitle: "Cancel")
        let restoreToolbar = hideToolbarPanelForModal()
        defer { restoreToolbarPanelAfterModal(restoreToolbar) }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = min(max(0, popup.indexOfSelectedItem), presets.count - 1)
        var remaining = presets
        let removed = remaining.remove(at: index)
        saveWatermarkPresets(remaining)
        statusLabel.stringValue = "Removed saved watermark preset: \(removed.name)"
    }

    private func loadWatermarkPresets() -> [WatermarkPreset] {
        guard let data = UserDefaults.standard.data(forKey: "MacClean.watermarkPresets"),
              let presets = try? JSONDecoder().decode([WatermarkPreset].self, from: data) else { return [] }
        return presets
    }

    private func saveWatermarkPresets(_ presets: [WatermarkPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: "MacClean.watermarkPresets")
    }

    @objc private func showShapeFillStyleMenu() {
        let menu = NSMenu()
        for style in ScreenshotShapeFillStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(selectShapeFillStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == shapeFillStyle ? .on : .off
            item.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: style.title)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: fillButton.bounds.height + 4), in: fillButton)
    }

    @objc private func selectShapeFillStyle(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let style = ScreenshotShapeFillStyle(rawValue: rawValue) else { return }
        shapeFillStyle = style
        canvas.shapeFillStyle = style
        canvas.changeSelectedShapeFillStyle(style)
        fillButton.setSymbol(style.symbol)
        fillButton.setActive(true)
        fillButton.toolTip = "Shape fill: \(style.title) • click to choose"
        statusLabel.stringValue = style.isCallout
            ? "\(style.title) selected • double-click a box to add text"
            : "New shapes use \(style.title.lowercased()) fill"
    }

    @objc private func showStrokeWeightMenu() {
        let menu = NSMenu()
        ScreenshotStrokeWeight.allCases.forEach { weight in
            let item = NSMenuItem(title: weight.menuTitle, action: #selector(selectStrokeWeight(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = weight.rawValue
            item.state = weight == strokeWeight ? .on : .off
            item.image = strokeWeightMenuImage(for: weight)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: strokeWeightButton.bounds.height + 4), in: strokeWeightButton)
    }

    @objc private func selectStrokeWeight(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let weight = ScreenshotStrokeWeight(rawValue: rawValue) else { return }
        strokeWeight = weight
        canvas.strokeWeight = weight
        canvas.changeSelectedStrokeWeight(weight)
        strokeWeightButton.setStrokeWeightIndicator(lineWidth: weight.lineWidth)
        strokeWeightButton.toolTip = "Outline width: \(weight.menuTitle) • click to choose"
        statusLabel.stringValue = "New and selected shapes use a \(String(format: "%g", Double(weight.lineWidth))) pt outline"
    }

    private func strokeWeightMenuImage(for weight: ScreenshotStrokeWeight) -> NSImage {
        let image = NSImage(size: NSSize(width: 30, height: 16), flipped: false) { rect in
            let line = NSBezierPath()
            line.lineCapStyle = .round
            line.lineWidth = max(1, weight.lineWidth)
            line.move(to: NSPoint(x: 2, y: rect.midY))
            line.line(to: NSPoint(x: rect.maxX - 2, y: rect.midY))
            NSColor.labelColor.setStroke()
            line.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setTextSize(_ value: CGFloat) {
        fontSize = min(96, max(8, value.rounded()))
        canvas.defaultFontSize = fontSize
        canvas.changeSelectedTextSize(fontSize)
        statusLabel.stringValue = "Text size: \(Int(fontSize)) pt"
    }

    @objc private func undo() {
        canvas.undoLastAnnotation()
        statusLabel.stringValue = "Last annotation undone"
    }

    @objc private func deleteSelection() {
        guard canvas.deleteSelection() else {
            statusLabel.stringValue = "Select an object first"
            return
        }
        statusLabel.stringValue = "Selected object deleted"
    }

    @objc private func copyImage() {
        guard let data = canvas.renderPNGData() else {
            statusLabel.stringValue = "Could not render the marked image"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType("public.png"))
        statusLabel.stringValue = "Marked screenshot copied • ⌘V to paste"
    }

    @objc private func togglePin() {
        guard isFloatingPreview else { return }
        setPinned(!isPinned, bringPreviewToFront: true)
    }

    private func pinFromOutsideClick() {
        guard isFloatingPreview, !isPinned else { return }
        setPinned(true, bringPreviewToFront: false)
    }

    private func setPinned(_ pinned: Bool, bringPreviewToFront: Bool) {
        isPinned = pinned
        isPinnedToolbarVisible = !pinned
        canvas.movesFloatingWindowOnMouseDown = isPinned
        canvas.allowsWindowDragOnEmptyArea = !isPinned
        pinButton.setSymbol(isPinned ? "pin.fill" : "pin")
        pinButton.setActive(isPinned)
        pinButton.toolTip = isPinned
            ? "Unpin this screenshot; another capture will require pinning again"
            : "Pin this screenshot, or click outside the preview"
        if isPinned {
            statusLabel.stringValue = "Pinned • Right-click to show tools • Drag to move • Esc closes"
            toolbarPanel?.orderOut(nil)
            if bringPreviewToFront {
                window?.makeKeyAndOrderFront(nil)
                window?.makeFirstResponder(canvas)
            }
        } else {
            statusLabel.stringValue = "Floating preview • Click outside to pin • Scroll to zoom • Esc closes"
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(canvas)
            updateToolbarPanelPosition()
        }
        refreshOutsideClickPinMonitors()
    }

    private func refreshOutsideClickPinMonitors() {
        removeOutsideClickPinMonitors()
        guard isFloatingPreview, !isPinned else { return }

        outsideClickPinGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async { [weak self] in
                self?.pinPreviewIfClickWasOutside(at: location)
            }
        }
        outsideClickPinLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async { [weak self] in
                self?.pinPreviewIfClickWasOutside(at: location)
            }
            return event
        }
    }

    private func removeOutsideClickPinMonitors() {
        if let outsideClickPinGlobalMonitor {
            NSEvent.removeMonitor(outsideClickPinGlobalMonitor)
            self.outsideClickPinGlobalMonitor = nil
        }
        if let outsideClickPinLocalMonitor {
            NSEvent.removeMonitor(outsideClickPinLocalMonitor)
            self.outsideClickPinLocalMonitor = nil
        }
    }

    private func pinPreviewIfClickWasOutside(at location: NSPoint) {
        guard isFloatingPreview, !isPinned, let window,
              !window.frame.contains(location) else { return }
        if let toolbarPanel, toolbarPanel.frame.contains(location) { return }
        let insideAnotherMacCleanWindow = NSApp.windows.contains { candidate in
            candidate !== window
                && candidate !== toolbarPanel
                && candidate.isVisible
                && candidate.frame.contains(location)
        }
        guard !insideAnotherMacCleanWindow else { return }
        pinFromOutsideClick()
    }

    private func prepareFloatingPreview(imageWidth: Int, imageHeight: Int) {
        guard let window else { return }
        isFloatingPreview = true
        canvas.movesFloatingWindowOnMouseDown = false
        canvas.allowsWindowDragOnEmptyArea = true
        NSLayoutConstraint.deactivate(canvasInsetConstraints)
        NSLayoutConstraint.activate(canvasFullBleedConstraints)
        screenshotBackground?.showsMetalBackground = false
        canvas.showsOutlineBorder = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.minSize = NSSize(width: 1, height: 1)
        window.styleMask = [.borderless]
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        (window as? ScreenshotMarkupWindow)?.onEscape = { [weak self] in self?.closeFloatingScreenshot() }
        canvas.onEscapeRequested = { [weak self] in self?.closeFloatingScreenshot() }
        pinButton.setSymbol("pin")
        pinButton.setActive(false)
        pinButton.toolTip = "Pin this screenshot; clicking outside also pins it"
        statusLabel.stringValue = "\(imageWidth) × \(imageHeight) px • Click outside to pin • Scroll to zoom • Esc closes"
        fitFloatingWindowToScreenshot()
        window.makeFirstResponder(canvas)
        refreshOutsideClickPinMonitors()
    }

    private func togglePinnedToolbarVisibility() {
        guard isPinned else { return }
        isPinnedToolbarVisible.toggle()
        canvas.movesFloatingWindowOnMouseDown = !isPinnedToolbarVisible
        if isPinnedToolbarVisible {
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(canvas)
            statusLabel.stringValue = "Pinned • Right-click to hide tools • Hide tools, then drag to move • Esc closes"
            updateToolbarPanelPosition()
        } else {
            toolbarPanel?.orderOut(nil)
            window?.makeFirstResponder(canvas)
        }
    }

    private func fitFloatingWindowToScreenshot() {
        guard let window else { return }
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 36, dy: 36)
        let available = screenFrame?.size ?? NSSize(width: 1200, height: 800)
        let maxSize = NSSize(width: available.width * 0.82, height: available.height * 0.82)
        let aspect = canvas.imageAspectRatio
        guard aspect > 0 else { return }
        var size = NSSize(width: maxSize.width, height: maxSize.width / aspect)
        if size.height > maxSize.height {
            size = NSSize(width: maxSize.height * aspect, height: maxSize.height)
        }
        floatingBaseSize = size
        floatingZoomScale = 1
        let origin = NSPoint(x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        updateToolbarPanelPosition()
    }

    private func zoomFloatingWindow(with event: NSEvent) {
        guard isFloatingPreview,
              abs(event.scrollingDeltaY) > 0.05,
              floatingBaseSize.width > 0,
              floatingBaseSize.height > 0,
              let window else { return }

        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 5
        let nextScale = min(2.5, max(0.3, floatingZoomScale * exp(delta * 0.012)))
        guard abs(nextScale - floatingZoomScale) > 0.001 else { return }
        floatingZoomScale = nextScale

        let size = NSSize(
            width: floatingBaseSize.width * floatingZoomScale,
            height: floatingBaseSize.height * floatingZoomScale
        )
        let frame = window.frame
        var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            if size.width <= visibleFrame.width {
                origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
            } else {
                origin.x = visibleFrame.midX - size.width / 2
            }
            if size.height <= visibleFrame.height {
                origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
            } else {
                origin.y = visibleFrame.midY - size.height / 2
            }
        }
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        if !isPinned {
            statusLabel.stringValue = "Zoom \(Int((floatingZoomScale * 100).rounded()))% • Scroll to zoom • Pin to keep • Esc closes"
        }
    }

    private func closeFloatingScreenshot() {
        guard isFloatingPreview else { return }
        window?.close()
    }

    private func updateToolbarPanelPosition() {
        guard isFloatingPreview,
              let window,
              let toolbarPanel,
              let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8) else { return }

        let panelSize = toolbarPanel.frame.size
        let imageFrame = window.frame
        let gap: CGFloat = 8
        let spaceAbove = screenFrame.maxY - imageFrame.maxY
        let spaceBelow = imageFrame.minY - screenFrame.minY
        let fitsAbove = spaceAbove >= panelSize.height + gap
        let fitsBelow = spaceBelow >= panelSize.height + gap
        let placeAbove = fitsAbove
            ? (!fitsBelow || spaceAbove >= spaceBelow)
            : (!fitsBelow && spaceAbove >= spaceBelow)

        let y: CGFloat
        if placeAbove {
            y = fitsAbove ? imageFrame.maxY + gap : imageFrame.maxY - panelSize.height - gap
        } else {
            y = fitsBelow ? imageFrame.minY - panelSize.height - gap : imageFrame.minY + gap
        }

        let maxX = screenFrame.maxX - panelSize.width
        let x = maxX >= screenFrame.minX
            ? min(max(imageFrame.midX - panelSize.width / 2, screenFrame.minX), maxX)
            : screenFrame.minX
        let maxY = screenFrame.maxY - panelSize.height
        let clampedY = maxY >= screenFrame.minY
            ? min(max(y, screenFrame.minY), maxY)
            : screenFrame.minY

        toolbarPanel.level = window.level
        toolbarPanel.setFrame(
            NSRect(origin: NSPoint(x: x, y: clampedY), size: panelSize),
            display: true
        )

        guard window.isVisible, !isPinned || isPinnedToolbarVisible else {
            toolbarPanel.orderOut(nil)
            return
        }
        toolbarPanel.orderFrontRegardless()
        toolbarPanel.order(.above, relativeTo: window.windowNumber)
    }

    private func hideToolbarPanelForModal() -> Bool {
        let wasVisible = toolbarPanel?.isVisible == true
        if wasVisible { toolbarPanel?.orderOut(nil) }
        return wasVisible
    }

    private func restoreToolbarPanelAfterModal(_ shouldRestore: Bool) {
        guard shouldRestore else { return }
        updateToolbarPanelPosition()
    }

    var isScreenshotPinned: Bool { isPinned }
    var isAwaitingPin: Bool { isFloatingPreview && !isPinned }

    func showPinRequiredMessage() {
        guard isAwaitingPin else { return }
        statusLabel.stringValue = "Pin this screenshot before capturing another • Esc closes"
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
        updateToolbarPanelPosition()
    }

    @discardableResult
    func hidePinnedToolbarForCapture() -> Bool {
        guard isPinned, window?.isVisible == true else { return false }
        toolbarPanel?.orderOut(nil)
        return true
    }

    func restorePinnedToolbarAfterCapture() {
        guard isPinned else { return }
        updateToolbarPanelPosition()
    }

    @objc private func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = ScreenshotExportFormat.allCases.map(\.contentType)
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Mac Clean Screenshot.png"

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 36))
        let formatLabel = NSTextField(labelWithString: "Image format")
        formatLabel.frame = NSRect(x: 0, y: 8, width: 86, height: 20)
        let formatPicker = NSPopUpButton(frame: NSRect(x: 90, y: 3, width: 150, height: 28), pullsDown: false)
        formatPicker.addItems(withTitles: ScreenshotExportFormat.allCases.map(\.displayName))
        formatPicker.selectItem(at: 0)
        accessory.addSubview(formatLabel)
        accessory.addSubview(formatPicker)
        panel.accessoryView = accessory
        let restoreToolbar = hideToolbarPanelForModal()

        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self else { return }
            defer { self.restoreToolbarPanelAfterModal(restoreToolbar) }
            guard response == .OK, let url = panel.url else { return }
            let selectedIndex = min(max(0, formatPicker.indexOfSelectedItem), ScreenshotExportFormat.allCases.count - 1)
            let format = ScreenshotExportFormat.allCases[selectedIndex]
            let outputURL = url.deletingPathExtension().appendingPathExtension(format.fileExtension)
            do {
                guard let data = self.canvas.renderImageData(as: format) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: outputURL, options: .atomic)
                self.statusLabel.stringValue = "Saved \(format.displayName) to \(outputURL.lastPathComponent)"
            } catch {
                self.statusLabel.stringValue = "Save failed: \(error.localizedDescription)"
            }
        }
    }
}

private final class ScreenshotMarkupCanvasView: NSView, NSTextViewDelegate {
    private let image: CGImage
    private let captureScale: CGFloat
    private var annotations: [ScreenshotMarkupAnnotation] = []
    private var undoStack: [[ScreenshotMarkupAnnotation]] = []
    private var selectedIndex: Int?
    private var dragMode: ScreenshotDragMode?
    private var dragStart: CGPoint?
    private var dragOriginRect: CGRect?
    private var currentRect: CGRect?
    private var dragPoints: [CGPoint] = []
    var tool: ScreenshotMarkupTool = .select {
        didSet { onToolChanged?(tool) }
    }
    var markupColor = NSColor(calibratedRed: 1, green: 0.24, blue: 0.28, alpha: 1)
    var textColor = NSColor(calibratedRed: 1, green: 0.24, blue: 0.28, alpha: 1)
    var shapeFillStyle = ScreenshotShapeFillStyle.translucent
    var strokeWeight = ScreenshotStrokeWeight.level4
    var defaultFontSize: CGFloat = 24
    private var inlineEditor: MarkupInlineTextView?
    private var inlineOriginalAnnotations: [ScreenshotMarkupAnnotation]?
    private var inlineOriginalText: String?
    private var inlineOriginalSelectedIndex: Int?
    private var inlineDidChange = false
    private var inlineIsNewAnnotation = false
    var onTextSizeScroll: ((CGFloat) -> Void)?
    var onFloatingZoomScroll: ((NSEvent) -> Void)?
    var onCopyRequested: (() -> Void)?
    var onSelectionChanged: ((CGFloat?) -> Void)?
    var onToolChanged: ((ScreenshotMarkupTool) -> Void)?
    var onRightClick: (() -> Void)?
    var onFloatingWindowDrag: ((NSEvent) -> Void)?
    var onEscapeRequested: (() -> Void)?
    var movesFloatingWindowOnMouseDown = false
    var allowsWindowDragOnEmptyArea = false
    var showsOutlineBorder = true {
        didSet { needsDisplay = true }
    }

    var imageAspectRatio: CGFloat {
        CGFloat(image.width) / max(CGFloat(image.height), 1)
    }

    init(image: CGImage, captureScale: CGFloat) {
        self.image = image
        self.captureScale = max(1, captureScale)
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // Pinned previews should begin dragging on the first press, even when the
    // floating window is inactive. Otherwise macOS consumes that press only to
    // activate the window and requires a second click to move it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        movesFloatingWindowOnMouseDown
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsOutlineBorder {
            NSColor(calibratedRed: 0.018, green: 0.03, blue: 0.05, alpha: 1).setFill()
            bounds.fill()
        }

        let fittedRect = imageRect
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(image, in: fittedRect)
        for (index, annotation) in annotations.enumerated() {
            let isBeingEdited = inlineEditor != nil && selectedIndex == index
            draw(
                annotation,
                in: fittedRect,
                scale: previewScale,
                suppressAnnotationText: isBeingEdited
            )
        }
        if let currentRect, let dragStart, case .draw? = dragMode {
            let endPoint = currentRect.origin
            var previewPoints = dragPoints
            if previewPoints.last != endPoint { previewPoints.append(endPoint) }
            let preview = ScreenshotMarkupAnnotation(
                tool: tool,
                rect: normalizedBounds(for: previewPoints, fallbackFrom: dragStart, to: endPoint),
                text: nil,
                strokeColor: markupColor,
                textColor: textColor,
                fillStyle: shapeFillStyle,
                fontSize: defaultFontSize,
                strokeWeight: strokeWeight,
                points: previewPoints
            )
            draw(preview, in: fittedRect, scale: previewScale)
        }
        if let selectedIndex, annotations.indices.contains(selectedIndex) {
            drawSelection(for: annotations[selectedIndex], in: fittedRect)
        }

        if showsOutlineBorder {
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            NSColor(calibratedRed: 0.34, green: 0.62, blue: 0.8, alpha: 0.55).setStroke()
            border.lineWidth = 1
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if movesFloatingWindowOnMouseDown {
            onFloatingWindowDrag?(event)
            return
        }
        if inlineEditor != nil { finishInlineTextEditing(commit: true) }
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        let normalized = normalizedPoint(from: point)

        if event.clickCount > 1,
           let index = hitAnnotation(at: point),
           annotations[index].tool == .rectangle,
           annotations[index].fillStyle.isCallout {
            setSelection(index)
            beginInlineTextEditing(at: index)
            return
        }

        switch tool {
        case .select:
            if let selectedIndex, let handle = hitHandle(at: point, for: annotations[selectedIndex]) {
                dragMode = .resize(index: selectedIndex, handle: handle)
                checkpoint()
                dragStart = normalized
                dragOriginRect = annotations[selectedIndex].rect
                window?.makeFirstResponder(self)
                return
            }
            if let index = hitAnnotation(at: point) {
                setSelection(index)
                if event.clickCount > 1, annotations[index].tool == .text {
                    beginInlineTextEditing(at: index)
                    return
                }
                dragMode = .move(index: index)
                checkpoint()
                dragStart = normalized
                dragOriginRect = annotations[index].rect
                window?.makeFirstResponder(self)
            } else {
                setSelection(nil)
                if allowsWindowDragOnEmptyArea {
                    onFloatingWindowDrag?(event)
                }
            }
        case .text:
            if let index = hitAnnotation(at: point), annotations[index].tool == .text {
                beginInlineTextEditing(at: index)
            } else {
                beginInlineTextEditing(at: normalized)
            }
        case .rectangle, .ellipse, .line, .arrow, .freehand, .highlighter, .mosaic:
            setSelection(nil)
            dragMode = .draw
            dragStart = normalized
            currentRect = CGRect(origin: normalized, size: .zero)
            dragPoints = [normalized]
            window?.makeFirstResponder(self)
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragMode, let dragStart else { return }
        let point = normalizedPoint(from: convert(event.locationInWindow, from: nil))
        switch dragMode {
        case .draw:
            currentRect = point.asCGRect
            if tool == .line || tool == .arrow {
                dragPoints = [dragStart, point]
            } else if tool == .freehand || tool == .highlighter {
                if let last = dragPoints.last,
                   hypot(point.x - last.x, point.y - last.y) >= 0.001 {
                    dragPoints.append(point)
                }
            }
        case .move(let index):
            guard let dragOriginRect else { return }
            let dx = point.x - dragStart.x
            let dy = point.y - dragStart.y
            let movedRect = translated(dragOriginRect, dx: dx, dy: dy)
            let actualDX = movedRect.minX - dragOriginRect.minX
            let actualDY = movedRect.minY - dragOriginRect.minY
            annotations[index].rect = movedRect
            annotations[index].points = annotations[index].points.map {
                CGPoint(x: min(1, max(0, $0.x + actualDX)), y: min(1, max(0, $0.y + actualDY)))
            }
        case .resize(let index, let handle):
            guard let dragOriginRect else { return }
            let resizedRect = resized(dragOriginRect, handle: handle, to: point)
            annotations[index].points = annotations[index].points.map { point in
                let xFraction = dragOriginRect.width > 0 ? (point.x - dragOriginRect.minX) / dragOriginRect.width : 0.5
                let yFraction = dragOriginRect.height > 0 ? (point.y - dragOriginRect.minY) / dragOriginRect.height : 0.5
                return CGPoint(
                    x: resizedRect.minX + xFraction * resizedRect.width,
                    y: resizedRect.minY + yFraction * resizedRect.height
                )
            }
            annotations[index].rect = resizedRect
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragMode else { return }
        if case .draw = dragMode, let dragStart {
            let point = normalizedPoint(from: convert(event.locationInWindow, from: nil))
            if (tool == .line || tool == .arrow || tool == .freehand || tool == .highlighter),
               dragPoints.last != point {
                dragPoints.append(point)
            }
            let pathPoints = (tool == .line || tool == .arrow) ? [dragStart, point] : dragPoints
            let isPathTool = tool == .line || tool == .arrow || tool == .freehand || tool == .highlighter
            let rect = isPathTool
                ? normalizedBounds(for: pathPoints, fallbackFrom: dragStart, to: point)
                : normalizedRect(from: dragStart, to: point)
            let hasUsableSize = isPathTool
                ? max(rect.width, rect.height) > 0.002
                : rect.width > 0.002 && rect.height > 0.002
            if hasUsableSize {
                checkpoint()
                var annotation = ScreenshotMarkupAnnotation(
                    tool: tool,
                    rect: rect,
                    text: nil,
                    strokeColor: markupColor,
                    textColor: textColor,
                    fillStyle: shapeFillStyle,
                    fontSize: defaultFontSize,
                    strokeWeight: strokeWeight,
                    points: isPathTool ? pathPoints : []
                )
                if tool == .mosaic {
                    annotation.mosaicImage = makeMosaicImage(for: rect)
                }
                annotations.append(annotation)
                setSelection(annotations.count - 1)
            }
        }
        self.dragMode = nil
        dragStart = nil
        dragOriginRect = nil
        currentRect = nil
        dragPoints.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let selectedText = selectedIndex.map { annotations.indices.contains($0) && annotations[$0].tool == .text } ?? false
        if tool == .text || selectedText {
            guard abs(event.scrollingDeltaY) > 0.05 else { return }
            onTextSizeScroll?(event.scrollingDeltaY > 0 ? 2 : -2)
            return
        }
        if let onFloatingZoomScroll {
            onFloatingZoomScroll(event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onEscapeRequested {
            onEscapeRequested()
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            undoLastAnnotation()
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            onCopyRequested?()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            _ = deleteSelection()
            return
        }
        if let character = event.charactersIgnoringModifiers?.lowercased() {
            switch character {
            case "v": tool = .select
            case "r": tool = .rectangle
            case "o": tool = .ellipse
            case "l": tool = .line
            case "a": tool = .arrow
            case "p": tool = .freehand
            case "h": tool = .highlighter
            case "t": tool = .text
            default: super.keyDown(with: event)
            }
            return
        }
        super.keyDown(with: event)
    }

    private func beginInlineTextEditing(at normalizedPoint: CGPoint) {
        beginInlineTextEditing(at: normalizedPoint, existingIndex: nil)
    }

    private func beginInlineTextEditing(at index: Int) {
        beginInlineTextEditing(at: .zero, existingIndex: index)
    }

    private func beginInlineTextEditing(at normalizedPoint: CGPoint, existingIndex: Int?) {
        guard inlineEditor == nil else { return }
        inlineOriginalAnnotations = annotations
        inlineOriginalSelectedIndex = selectedIndex
        inlineDidChange = false
        inlineIsNewAnnotation = existingIndex == nil

        let index: Int
        if let existingIndex, annotations.indices.contains(existingIndex) {
            index = existingIndex
            inlineOriginalText = annotations[index].text ?? ""
        } else {
            inlineOriginalText = nil
            annotations.append(ScreenshotMarkupAnnotation(
                tool: .text,
                rect: CGRect(origin: normalizedPoint, size: .zero),
                text: "",
                strokeColor: markupColor,
                textColor: textColor,
                fontSize: defaultFontSize
            ))
            index = annotations.count - 1
        }
        setSelection(index)

        let annotation = annotations[index]
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100_000, height: 1_000))
        container.lineFragmentPadding = 0
        container.lineBreakMode = annotation.tool == .rectangle && annotation.fillStyle.isCallout
            ? .byWordWrapping
            : .byClipping
        layoutManager.addTextContainer(container)

        let editor = MarkupInlineTextView(frame: .zero, textContainer: container)
        editor.string = annotation.text ?? ""
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.insertionPointColor = NSColor(calibratedRed: 0.45, green: 0.86, blue: 1, alpha: 1)
        editor.textContainerInset = NSSize(width: 2, height: 2)
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.onSizeScroll = { [weak self] adjustment in self?.onTextSizeScroll?(adjustment) }
        inlineEditor = editor
        addSubview(editor)
        updateInlineEditorLayout()

        let didFocus = window?.makeFirstResponder(editor) ?? false
        if didFocus {
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        }
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self, let editor, self.inlineEditor === editor, editor.window != nil else { return }
            _ = self.window?.makeFirstResponder(editor)
        }
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? MarkupInlineTextView,
              editor === inlineEditor,
              let selectedIndex,
              annotations.indices.contains(selectedIndex) else { return }
        let value = editor.string
        annotations[selectedIndex].text = value
        inlineDidChange = value != (inlineOriginalText ?? "")
        updateInlineEditorLayout()
        needsDisplay = true
    }

    func textDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextView) === inlineEditor else { return }
        finishInlineTextEditing(commit: true, focusCanvas: false)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let command = NSStringFromSelector(commandSelector)
        if command == "cancelOperation:" {
            finishInlineTextEditing(commit: false)
            return true
        }
        if command == "insertNewline:" || command == "insertLineBreak:" {
            if let selectedIndex,
               annotations.indices.contains(selectedIndex),
               annotations[selectedIndex].tool == .rectangle,
               annotations[selectedIndex].fillStyle.isCallout {
                return false
            }
            finishInlineTextEditing(commit: true)
            return true
        }
        return false
    }

    private func finishInlineTextEditing(commit: Bool, focusCanvas: Bool = true) {
        guard let editor = inlineEditor else { return }
        let text = editor.string
        let snapshot = inlineOriginalAnnotations ?? annotations
        let originalText = inlineOriginalText ?? ""
        let wasNew = inlineIsNewAnnotation
        let didChange = inlineDidChange
        let editedIndex = selectedIndex
        let oldSelection = inlineOriginalSelectedIndex

        inlineEditor = nil
        inlineOriginalAnnotations = nil
        inlineOriginalText = nil
        inlineOriginalSelectedIndex = nil
        inlineDidChange = false
        inlineIsNewAnnotation = false
        editor.delegate = nil
        editor.onSizeScroll = nil
        if focusCanvas { window?.makeFirstResponder(self) }
        editor.removeFromSuperview()

        guard let editedIndex, annotations.indices.contains(editedIndex) else { return }
        annotations[editedIndex].text = text
        if !commit {
            annotations = snapshot
            setSelection(oldSelection)
        } else if text.isEmpty && (wasNew || !originalText.isEmpty) {
            if wasNew {
                annotations = snapshot
                setSelection(oldSelection)
            } else {
                annotations.remove(at: editedIndex)
                if didChange { undoStack.append(snapshot) }
                setSelection(nil)
            }
        } else {
            if didChange { undoStack.append(snapshot) }
            setSelection(editedIndex)
        }
        if undoStack.count > 80 { undoStack.removeFirst() }
        needsDisplay = true
    }

    private func updateInlineEditorLayout() {
        guard let editor = inlineEditor,
              let selectedIndex,
              annotations.indices.contains(selectedIndex) else { return }
        let annotation = annotations[selectedIndex]
        let font = NSFont.systemFont(ofSize: max(8, annotation.fontSize * previewScale), weight: .bold)
        editor.font = font
        editor.textColor = annotation.textColor
        editor.typingAttributes = [.font: font, .foregroundColor: annotation.textColor]
        if let textStorage = editor.textStorage, textStorage.length > 0 {
            let range = NSRange(location: 0, length: textStorage.length)
            textStorage.addAttribute(.font, value: font, range: range)
            textStorage.addAttribute(.foregroundColor, value: annotation.textColor, range: range)
        }
        let isCallout = annotation.tool == .rectangle && annotation.fillStyle.isCallout
        if isCallout {
            let bounds = calloutTextRect(for: annotation, in: displayedRect(annotation), scale: previewScale)
            editor.frame = bounds
            editor.textContainer?.lineBreakMode = .byWordWrapping
            editor.textContainer?.widthTracksTextView = true
            editor.textContainer?.containerSize = NSSize(width: max(1, bounds.width - 4), height: max(1, bounds.height - 4))
            return
        }

        let textOrigin = CGPoint(
            x: imageRect.minX + annotation.rect.minX * imageRect.width,
            y: imageRect.minY + annotation.rect.minY * imageRect.height
        )
        editor.textContainer?.lineBreakMode = .byClipping
        let measuredText = editor.string.isEmpty ? " " : editor.string
        let measuredSize = measuredText.size(withAttributes: [.font: font])
        let availableWidth = max(48, imageRect.maxX - textOrigin.x)
        let width = min(availableWidth, max(48, measuredSize.width + 12))
        let height = max(28, font.pointSize + 10)
        let y = min(max(imageRect.minY, textOrigin.y - 4), imageRect.maxY - height)
        editor.frame = CGRect(x: textOrigin.x, y: y, width: width, height: height)
        editor.textContainer?.containerSize = NSSize(width: width - 4, height: height)
    }

    func addWatermark(_ text: String) {
        let fontSize: CGFloat = 32
        let pointFont = NSFont.systemFont(ofSize: fontSize * previewScale, weight: .semibold)
        let textWidth = text.size(withAttributes: [.font: pointFont]).width / max(imageRect.width, 1)
        let originX = min(0.95, max(0.03, 0.5 - textWidth / 2))
        checkpoint()
        annotations.append(ScreenshotMarkupAnnotation(
            tool: .text,
            rect: CGRect(x: originX, y: 0.5, width: 0, height: 0),
            text: text,
            strokeColor: textColor,
            textColor: textColor.withAlphaComponent(0.34),
            fontSize: fontSize,
            isWatermark: true
        ))
        setSelection(annotations.count - 1)
        tool = .select
        needsDisplay = true
    }

    func addText(_ text: String, at point: CGPoint, fontSize: CGFloat) {
        checkpoint()
        annotations.append(ScreenshotMarkupAnnotation(
            tool: .text,
            rect: CGRect(origin: point, size: .zero),
            text: text,
            strokeColor: markupColor,
            textColor: textColor,
            fontSize: fontSize
        ))
        setSelection(annotations.count - 1)
        needsDisplay = true
    }

    func updateText(at index: Int, value: String) {
        guard annotations.indices.contains(index), annotations[index].tool == .text else { return }
        checkpoint()
        annotations[index].text = value
        needsDisplay = true
    }

    func changeSelectedStrokeColor(_ color: NSColor) {
        guard let selectedIndex,
              annotations.indices.contains(selectedIndex),
              [.rectangle, .ellipse, .line, .arrow, .freehand, .highlighter].contains(annotations[selectedIndex].tool) else { return }
        checkpoint()
        annotations[selectedIndex].strokeColor = color
        needsDisplay = true
    }

    func changeSelectedTextColor(_ color: NSColor) {
        guard let selectedIndex,
              annotations.indices.contains(selectedIndex),
              annotations[selectedIndex].tool == .text
                || (annotations[selectedIndex].tool == .rectangle && annotations[selectedIndex].fillStyle.isCallout) else { return }
        checkpoint()
        annotations[selectedIndex].textColor = color
        updateInlineEditorLayout()
        needsDisplay = true
    }

    func changeSelectedShapeFillStyle(_ style: ScreenshotShapeFillStyle) {
        guard let selectedIndex,
              annotations.indices.contains(selectedIndex),
              annotations[selectedIndex].tool == .rectangle || annotations[selectedIndex].tool == .ellipse else { return }
        let effectiveStyle = annotations[selectedIndex].tool == .ellipse && style.isCallout
            ? .translucent
            : style
        guard annotations[selectedIndex].fillStyle != effectiveStyle else { return }
        checkpoint()
        annotations[selectedIndex].fillStyle = effectiveStyle
        needsDisplay = true
    }

    func changeSelectedStrokeWeight(_ weight: ScreenshotStrokeWeight) {
        guard let selectedIndex,
              annotations.indices.contains(selectedIndex),
              [.rectangle, .ellipse, .line, .arrow, .freehand, .highlighter].contains(annotations[selectedIndex].tool),
              annotations[selectedIndex].strokeWeight != weight else { return }
        checkpoint()
        annotations[selectedIndex].strokeWeight = weight
        needsDisplay = true
    }

    func changeSelectedTextSize(_ size: CGFloat) {
        guard let selectedIndex, annotations.indices.contains(selectedIndex), annotations[selectedIndex].tool == .text else { return }
        guard annotations[selectedIndex].fontSize != size else { return }
        checkpoint()
        annotations[selectedIndex].fontSize = size
        updateInlineEditorLayout()
        needsDisplay = true
    }

    func deleteSelection() -> Bool {
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return false }
        checkpoint()
        annotations.remove(at: selectedIndex)
        setSelection(nil)
        needsDisplay = true
        return true
    }

    func undoLastAnnotation() {
        guard let previous = undoStack.popLast() else { return }
        annotations = previous
        setSelection(nil)
        needsDisplay = true
    }

    private func checkpoint() {
        undoStack.append(annotations)
        if undoStack.count > 80 { undoStack.removeFirst() }
    }

    func renderPNGData() -> Data? {
        renderImageData(as: .png)
    }

    func renderImageData(as format: ScreenshotExportFormat) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: image.width,
            pixelsHigh: image.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        let outputRect = NSRect(x: 0, y: 0, width: image.width, height: image.height)
        NSImage(cgImage: image, size: outputRect.size).draw(in: outputRect)
        annotations.forEach { draw($0, in: outputRect, scale: captureScale) }
        NSGraphicsContext.restoreGraphicsState()

        let properties: [NSBitmapImageRep.PropertyKey: Any]
        switch format {
        case .jpeg: properties = [.compressionFactor: 0.92]
        case .png, .tiff: properties = [:]
        }
        return bitmap.representation(using: format.bitmapFileType, properties: properties)
    }

    private var previewScale: CGFloat {
        imageRect.width / CGFloat(image.width) * captureScale
    }

    private var imageRect: CGRect {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func normalizedPoint(from point: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(
            x: min(1, max(0, (point.x - rect.minX) / rect.width)),
            y: min(1, max(0, (point.y - rect.minY) / rect.height))
        )
    }

    private func normalizedRect(from first: CGPoint, to second: CGPoint) -> CGRect {
        CGRect(x: first.x, y: first.y, width: second.x - first.x, height: second.y - first.y).standardized
    }

    private func normalizedBounds(for points: [CGPoint], fallbackFrom start: CGPoint, to end: CGPoint) -> CGRect {
        let candidates = points.isEmpty ? [start, end] : points
        let minSize: CGFloat = 0.004
        var minX = candidates.map(\.x).min() ?? start.x
        var maxX = candidates.map(\.x).max() ?? end.x
        var minY = candidates.map(\.y).min() ?? start.y
        var maxY = candidates.map(\.y).max() ?? end.y

        if maxX - minX < minSize {
            let center = (minX + maxX) / 2
            minX = min(1 - minSize, max(0, center - minSize / 2))
            maxX = minX + minSize
        }
        if maxY - minY < minSize {
            let center = (minY + maxY) / 2
            minY = min(1 - minSize, max(0, center - minSize / 2))
            maxY = minY + minSize
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func translated(_ rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(
            x: min(1 - rect.width, max(0, rect.minX + dx)),
            y: min(1 - rect.height, max(0, rect.minY + dy)),
            width: rect.width,
            height: rect.height
        )
    }

    private func resized(_ original: CGRect, handle: ScreenshotResizeHandle, to point: CGPoint) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        let minimum: CGFloat = 0.004

        switch handle {
        case .northWest, .west, .southWest: minX = min(maxX - minimum, max(0, point.x))
        case .northEast, .east, .southEast: maxX = max(minX + minimum, min(1, point.x))
        default: break
        }
        switch handle {
        case .southWest, .south, .southEast: minY = min(maxY - minimum, max(0, point.y))
        case .northWest, .north, .northEast: maxY = max(minY + minimum, min(1, point.y))
        default: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func setSelection(_ index: Int?) {
        selectedIndex = index
        let selectedFontSize: CGFloat? = {
            guard let index, annotations.indices.contains(index), annotations[index].tool == .text else { return nil }
            return annotations[index].fontSize
        }()
        onSelectionChanged?(selectedFontSize)
        needsDisplay = true
    }

    private func hitAnnotation(at point: CGPoint) -> Int? {
        let normalized = normalizedPoint(from: point)
        return annotations.indices.reversed().first { index in
            let annotation = annotations[index]
            if annotation.tool == .text {
                return textRect(annotation).contains(point)
            }
            let rect = annotation.rect.insetBy(dx: -0.008, dy: -0.008)
            return rect.contains(normalized)
        }
    }

    private func textRect(_ annotation: ScreenshotMarkupAnnotation) -> CGRect {
        let origin = CGPoint(
            x: imageRect.minX + annotation.rect.minX * imageRect.width,
            y: imageRect.minY + annotation.rect.minY * imageRect.height
        )
        let font = NSFont.systemFont(ofSize: max(8, annotation.fontSize * previewScale), weight: .bold)
        let size = (annotation.text ?? "").size(withAttributes: [.font: font])
        return CGRect(x: origin.x, y: origin.y, width: max(24, size.width), height: max(22, size.height))
    }

    private func displayedRect(_ annotation: ScreenshotMarkupAnnotation) -> CGRect {
        CGRect(
            x: imageRect.minX + annotation.rect.minX * imageRect.width,
            y: imageRect.minY + annotation.rect.minY * imageRect.height,
            width: annotation.rect.width * imageRect.width,
            height: annotation.rect.height * imageRect.height
        )
    }

    private func handlePoint(_ handle: ScreenshotResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .northWest: return CGPoint(x: rect.minX, y: rect.maxY)
        case .north: return CGPoint(x: rect.midX, y: rect.maxY)
        case .northEast: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .east: return CGPoint(x: rect.maxX, y: rect.midY)
        case .southEast: return CGPoint(x: rect.maxX, y: rect.minY)
        case .south: return CGPoint(x: rect.midX, y: rect.minY)
        case .southWest: return CGPoint(x: rect.minX, y: rect.minY)
        case .west: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func hitHandle(at point: CGPoint, for annotation: ScreenshotMarkupAnnotation) -> ScreenshotResizeHandle? {
        guard annotation.tool != .text else { return nil }
        let rect = displayedRect(annotation)
        let hitOrder: [ScreenshotResizeHandle] = [.northWest, .northEast, .southWest, .southEast, .north, .east, .south, .west]
        return hitOrder.first { handle in
            let center = handlePoint(handle, in: rect)
            let hitSize: CGFloat = isCornerHandle(handle) ? 24 : 18
            return CGRect(x: center.x - hitSize / 2, y: center.y - hitSize / 2, width: hitSize, height: hitSize).contains(point)
        }
    }

    private func drawSelection(for annotation: ScreenshotMarkupAnnotation, in imageRect: CGRect) {
        let rect = annotation.tool == .text ? textRect(annotation) : displayedRect(annotation)
        let outline = NSBezierPath(rect: rect.insetBy(dx: -3, dy: -3))
        NSColor(calibratedRed: 0.37, green: 0.82, blue: 1, alpha: 0.9).setStroke()
        outline.lineWidth = 1
        let pattern: [CGFloat] = [4, 3]
        outline.setLineDash(pattern, count: pattern.count, phase: 0)
        outline.stroke()
        guard annotation.tool != .text else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedRed: 0.01, green: 0.04, blue: 0.08, alpha: 0.85)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()

        let drawOrder: [ScreenshotResizeHandle] = [.north, .east, .south, .west, .northWest, .northEast, .southWest, .southEast]
        drawOrder.forEach { handle in
            let point = handlePoint(handle, in: rect)
            let corner = isCornerHandle(handle)
            let radius: CGFloat = corner ? 6 : 4.5
            let dot = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
            dot.fill()
            NSColor(calibratedRed: 0.12, green: 0.64, blue: 0.9, alpha: 1).setStroke()
            dot.lineWidth = corner ? 2 : 1.5
            dot.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func isCornerHandle(_ handle: ScreenshotResizeHandle) -> Bool {
        switch handle {
        case .northWest, .northEast, .southWest, .southEast: true
        case .north, .east, .south, .west: false
        }
    }

    private func makeMosaicImage(for normalizedRect: CGRect) -> CGImage? {
        let rect = normalizedRect.standardized
        let pixelWidth = image.width
        let pixelHeight = image.height
        let left = max(0, Int(floor(rect.minX * CGFloat(pixelWidth))))
        let right = min(pixelWidth, Int(ceil(rect.maxX * CGFloat(pixelWidth))))
        let top = max(0, Int(floor((1 - rect.maxY) * CGFloat(pixelHeight))))
        let bottom = min(pixelHeight, Int(ceil((1 - rect.minY) * CGFloat(pixelHeight))))
        guard right > left, bottom > top,
              let crop = image.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) else { return nil }

        let blockSize = 24
        let reducedWidth = max(1, (crop.width + blockSize - 1) / blockSize)
        let reducedHeight = max(1, (crop.height + blockSize - 1) / blockSize)
        guard let context = CGContext(
            data: nil,
            width: reducedWidth,
            height: reducedHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(crop, in: CGRect(x: 0, y: 0, width: reducedWidth, height: reducedHeight))
        return context.makeImage()
    }

    private func draw(
        _ annotation: ScreenshotMarkupAnnotation,
        in imageRect: CGRect,
        scale: CGFloat,
        suppressAnnotationText: Bool = false
    ) {
        let rect = CGRect(
            x: imageRect.minX + annotation.rect.minX * imageRect.width,
            y: imageRect.minY + annotation.rect.minY * imageRect.height,
            width: annotation.rect.width * imageRect.width,
            height: annotation.rect.height * imageRect.height
        )
        if annotation.tool == .text {
            guard !suppressAnnotationText else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(8, annotation.fontSize * scale), weight: .bold),
                .foregroundColor: annotation.textColor
            ]
            annotation.text?.draw(at: rect.origin, withAttributes: attributes)
            return
        }

        if annotation.tool == .mosaic {
            if let mosaicImage = annotation.mosaicImage, let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.interpolationQuality = .none
                context.draw(mosaicImage, in: rect)
                context.restoreGState()
            } else {
                annotation.strokeColor.withAlphaComponent(0.24).setFill()
                NSBezierPath(rect: rect).fill()
            }
            return
        }

        if annotation.tool == .line || annotation.tool == .arrow {
            let points = annotation.points.count >= 2
                ? annotation.points
                : [CGPoint(x: annotation.rect.minX, y: annotation.rect.minY), CGPoint(x: annotation.rect.maxX, y: annotation.rect.maxY)]
            let start = CGPoint(
                x: imageRect.minX + points[0].x * imageRect.width,
                y: imageRect.minY + points[0].y * imageRect.height
            )
            let endPoint = points[points.count - 1]
            let end = CGPoint(
                x: imageRect.minX + endPoint.x * imageRect.width,
                y: imageRect.minY + endPoint.y * imageRect.height
            )
            let lineWidth = max(1, annotation.strokeWeight.lineWidth * scale)
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = lineWidth
            path.move(to: start)
            path.line(to: end)
            annotation.strokeColor.setStroke()
            path.stroke()

            if annotation.tool == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let headLength = max(8 * scale, lineWidth * 3.2)
                let headAngle: CGFloat = .pi / 6
                let left = CGPoint(
                    x: end.x - headLength * cos(angle - headAngle),
                    y: end.y - headLength * sin(angle - headAngle)
                )
                let right = CGPoint(
                    x: end.x - headLength * cos(angle + headAngle),
                    y: end.y - headLength * sin(angle + headAngle)
                )
                let head = NSBezierPath()
                head.move(to: end)
                head.line(to: left)
                head.line(to: right)
                head.close()
                annotation.strokeColor.setFill()
                head.fill()
            }
            return
        }

        if annotation.tool == .freehand || annotation.tool == .highlighter {
            guard let first = annotation.points.first else { return }
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: CGPoint(
                x: imageRect.minX + first.x * imageRect.width,
                y: imageRect.minY + first.y * imageRect.height
            ))
            for point in annotation.points.dropFirst() {
                path.line(to: CGPoint(
                    x: imageRect.minX + point.x * imageRect.width,
                    y: imageRect.minY + point.y * imageRect.height
                ))
            }
            if annotation.tool == .highlighter {
                path.lineWidth = max(12 * scale, annotation.strokeWeight.lineWidth * 3 * scale)
                annotation.strokeColor.withAlphaComponent(0.36).setStroke()
            } else {
                path.lineWidth = max(1, annotation.strokeWeight.lineWidth * scale)
                annotation.strokeColor.setStroke()
            }
            path.stroke()
            return
        }

        let path: NSBezierPath
        if annotation.tool == .ellipse {
            path = NSBezierPath(ovalIn: rect)
        } else if annotation.fillStyle.isCallout {
            path = calloutPath(in: rect, scale: scale, pointerUp: annotation.fillStyle.pointerUp)
        } else {
            path = NSBezierPath(rect: rect)
        }
        switch annotation.fillStyle {
        case .translucent, .calloutDown, .calloutUp:
            annotation.strokeColor.withAlphaComponent(0.26).setFill()
            path.fill()
        case .solid:
            annotation.strokeColor.setFill()
            path.fill()
        }
        annotation.strokeColor.setStroke()
        path.lineWidth = max(1, annotation.strokeWeight.lineWidth * scale)
        path.stroke()

        if annotation.tool == .rectangle,
           annotation.fillStyle.isCallout,
           !suppressAnnotationText,
           let text = annotation.text,
           !text.isEmpty {
            let textRect = calloutTextRect(for: annotation, in: rect, scale: scale)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(8, annotation.fontSize * scale), weight: .bold),
                .foregroundColor: annotation.textColor
            ]
            (text as NSString).draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
        }
    }

    private func calloutPath(in rect: CGRect, scale: CGFloat, pointerUp: Bool) -> NSBezierPath {
        let body = calloutBodyRect(in: rect, scale: scale, pointerUp: pointerUp)
        let radius = min(12 * scale, body.width * 0.15, body.height * 0.15)
        let tailHalfWidth = min(body.width * 0.12, max(8 * scale, body.width * 0.06))
        let tailCenterX = body.midX
        let path = NSBezierPath()
        path.lineJoinStyle = .round

        if pointerUp {
            path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
            path.line(to: CGPoint(x: body.maxX - radius, y: body.minY))
            path.curve(
                to: CGPoint(x: body.maxX, y: body.minY + radius),
                controlPoint1: CGPoint(x: body.maxX - radius * 0.45, y: body.minY),
                controlPoint2: CGPoint(x: body.maxX, y: body.minY + radius * 0.45)
            )
            path.line(to: CGPoint(x: body.maxX, y: body.maxY - radius))
            path.curve(
                to: CGPoint(x: body.maxX - radius, y: body.maxY),
                controlPoint1: CGPoint(x: body.maxX, y: body.maxY - radius * 0.45),
                controlPoint2: CGPoint(x: body.maxX - radius * 0.45, y: body.maxY)
            )
            path.line(to: CGPoint(x: tailCenterX + tailHalfWidth, y: body.maxY))
            path.line(to: CGPoint(x: tailCenterX, y: rect.maxY))
            path.line(to: CGPoint(x: tailCenterX - tailHalfWidth, y: body.maxY))
            path.line(to: CGPoint(x: body.minX + radius, y: body.maxY))
            path.curve(
                to: CGPoint(x: body.minX, y: body.maxY - radius),
                controlPoint1: CGPoint(x: body.minX + radius * 0.45, y: body.maxY),
                controlPoint2: CGPoint(x: body.minX, y: body.maxY - radius * 0.45)
            )
            path.line(to: CGPoint(x: body.minX, y: body.minY + radius))
            path.curve(
                to: CGPoint(x: body.minX + radius, y: body.minY),
                controlPoint1: CGPoint(x: body.minX, y: body.minY + radius * 0.45),
                controlPoint2: CGPoint(x: body.minX + radius * 0.45, y: body.minY)
            )
        } else {
            path.move(to: CGPoint(x: body.minX + radius, y: body.maxY))
            path.line(to: CGPoint(x: body.maxX - radius, y: body.maxY))
            path.curve(
                to: CGPoint(x: body.maxX, y: body.maxY - radius),
                controlPoint1: CGPoint(x: body.maxX - radius * 0.45, y: body.maxY),
                controlPoint2: CGPoint(x: body.maxX, y: body.maxY - radius * 0.45)
            )
            path.line(to: CGPoint(x: body.maxX, y: body.minY + radius))
            path.curve(
                to: CGPoint(x: body.maxX - radius, y: body.minY),
                controlPoint1: CGPoint(x: body.maxX, y: body.minY + radius * 0.45),
                controlPoint2: CGPoint(x: body.maxX - radius * 0.45, y: body.minY)
            )
            path.line(to: CGPoint(x: tailCenterX + tailHalfWidth, y: body.minY))
            path.line(to: CGPoint(x: tailCenterX, y: rect.minY))
            path.line(to: CGPoint(x: tailCenterX - tailHalfWidth, y: body.minY))
            path.line(to: CGPoint(x: body.minX + radius, y: body.minY))
            path.curve(
                to: CGPoint(x: body.minX, y: body.minY + radius),
                controlPoint1: CGPoint(x: body.minX + radius * 0.45, y: body.minY),
                controlPoint2: CGPoint(x: body.minX, y: body.minY + radius * 0.45)
            )
            path.line(to: CGPoint(x: body.minX, y: body.maxY - radius))
            path.curve(
                to: CGPoint(x: body.minX + radius, y: body.maxY),
                controlPoint1: CGPoint(x: body.minX, y: body.maxY - radius * 0.45),
                controlPoint2: CGPoint(x: body.minX + radius * 0.45, y: body.maxY)
            )
        }
        path.close()
        return path
    }

    private func calloutBodyRect(in rect: CGRect, scale: CGFloat, pointerUp: Bool) -> CGRect {
        let tailHeight = min(rect.height * 0.24, max(10 * scale, rect.height * 0.14))
        let bodyHeight = max(1, rect.height - tailHeight)
        return CGRect(
            x: rect.minX,
            y: pointerUp ? rect.minY : rect.minY + tailHeight,
            width: rect.width,
            height: bodyHeight
        )
    }

    private func calloutTextRect(for annotation: ScreenshotMarkupAnnotation, in rect: CGRect, scale: CGFloat) -> CGRect {
        let body = calloutBodyRect(in: rect, scale: scale, pointerUp: annotation.fillStyle.pointerUp)
        let padding = min(max(6, 10 * scale), max(0, min(body.width, body.height) * 0.2))
        return body.insetBy(dx: padding, dy: padding)
    }
}

private final class MarkupInlineTextView: NSTextView {
    var onSizeScroll: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 0.05 else { return }
        onSizeScroll?(event.scrollingDeltaY > 0 ? 2 : -2)
    }
}

private final class MarkupColorIndicatorView: NSView {
    var color: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let swatch = NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5)
        color.setFill()
        swatch.fill()
        NSColor(calibratedWhite: 0.05, alpha: 0.55).setStroke()
        swatch.lineWidth = 0.6
        swatch.stroke()
    }
}

private final class MarkupIconButton: NSButton {
    private let baseColor = NSColor.clear
    private let selectedColor = NSColor(calibratedRed: 0.06, green: 0.37, blue: 0.55, alpha: 1)
    private let primaryColor = NSColor(calibratedRed: 0.07, green: 0.38, blue: 0.62, alpha: 1)
    private let isPrimaryAction: Bool
    private var symbolName: String
    private var colorIndicator: MarkupColorIndicatorView?

    init(symbol: String, help: String, target: AnyObject?, action: Selector, primary: Bool = false) {
        self.symbolName = symbol
        self.isPrimaryAction = primary
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        ) ?? NSImage()
        super.init(frame: .zero)
        self.image = image
        self.target = target
        self.action = action
        self.toolTip = help
        self.setAccessibilityLabel(help)
        self.isBordered = false
        self.focusRingType = .none
        self.imagePosition = .imageOnly
        self.contentTintColor = NSColor(calibratedRed: 0.78, green: 0.91, blue: 1, alpha: 1)
        self.wantsLayer = true
        self.layer?.cornerRadius = 5
        self.layer?.borderWidth = 0
        self.layer?.backgroundColor = (primary ? primaryColor : baseColor).cgColor
        self.translatesAutoresizingMaskIntoConstraints = false
        self.widthAnchor.constraint(equalToConstant: 30).isActive = true
        self.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStrokeWeightIndicator(lineWidth: CGFloat) {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineWidth = min(6, max(1, lineWidth * 0.75))
            path.move(to: NSPoint(x: 2, y: 10))
            path.line(to: NSPoint(x: 18, y: 10))
            NSColor(calibratedRed: 0.42, green: 0.86, blue: 1, alpha: 1).setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = false
        self.image = image
        self.setAccessibilityLabel("Outline width: \(String(format: "%g", Double(lineWidth))) points")
    }

    func setActive(_ active: Bool) {
        layer?.backgroundColor = (active ? selectedColor : (isPrimaryAction ? primaryColor : baseColor)).cgColor
    }

    func setSymbol(_ symbol: String) {
        symbolName = symbol
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
    }

    func setColorIndicator(symbol: String, color: NSColor) {
        setSymbol(symbol)
        let indicator: MarkupColorIndicatorView
        if let colorIndicator {
            indicator = colorIndicator
        } else {
            indicator = MarkupColorIndicatorView()
            indicator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.widthAnchor.constraint(equalToConstant: 14),
                indicator.heightAnchor.constraint(equalToConstant: 3),
                indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
                indicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
            ])
            colorIndicator = indicator
        }
        indicator.color = color
    }
}

private extension CGPoint {
    var asCGRect: CGRect { CGRect(origin: self, size: .zero) }
}
