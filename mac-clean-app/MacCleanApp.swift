import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ServiceManagement

private struct CacheCatalogResponse: Decodable {
    let items: [CacheReviewItem]
}

private struct CacheReviewItem: Decodable {
    let id: String
    let label: String
    let path: String
    let detail: String
    let requiredApps: [String]
    let requiredProcesses: [String]
    let sizeBytes: Double
}

private struct DownloadCatalogResponse: Decodable {
    let minimumSizeMB: Double
    let items: [DownloadReviewItem]
    let warnings: [String]
}

private struct DownloadReviewItem: Decodable {
    let path: String
    let name: String
    let relativePath: String
    let sizeBytes: Double
    let modifiedAtMs: Double
    let category: String
    let isDirectory: Bool
}

private struct DetailChecklistItem {
    let id: String
    let title: String
    let subtitle: String
    var modifiedAtMs: Double? = nil
    var selectable: Bool = true
}

private struct WorktreeCatalogResponse: Decodable {
    let items: [WorktreeReviewItem]
    let warnings: [String]
}

private struct WorktreeReviewItem: Decodable {
    let path: String
    let name: String
    let branch: String
    let sizeBytes: Double
    let eligible: Bool
    let reasons: [String]
}

private struct HistoryCatalogResponse: Decodable {
    let items: [HistoryReviewItem]
    let warnings: [String]
    let protectedRoots: [String]
}

private struct HistoryReviewItem: Decodable {
    let id: String
    let source: String
    let label: String
    let path: String
    let name: String
    let relativePath: String
    let kind: String
    let sizeBytes: Double
    let modifiedAtMs: Double
    let ageDays: Int
    let selectable: Bool
    let reasons: [String]
    let appLabels: [String]
}

private struct HistoryReviewGroup {
    let id: String
    let label: String
    let subtitle: String
    let modifiedAtMs: Double
    let itemIDs: [String]
    let sizeBytes: Double
    let selectable: Bool
    let reasons: String
}

private struct ScreenshotShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let defaultValue = ScreenshotShortcut(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(cmdKey | optionKey | controlKey),
        keyLabel: "S"
    )

    static let fullScreenDefaultValue = ScreenshotShortcut(
        keyCode: UInt32(kVK_ANSI_F),
        modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey),
        keyLabel: "F"
    )

    static let fullScreenAlternateDefaultValue = ScreenshotShortcut(
        keyCode: UInt32(kVK_ANSI_3),
        modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey),
        keyLabel: "3"
    )

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    var display: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty,
              let keyLabel = Self.label(for: event),
              event.keyCode != UInt16(kVK_Escape) else { return nil }

        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    private static func label(for event: NSEvent) -> String? {
        if let characters = event.charactersIgnoringModifiers,
           characters.count == 1,
           !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return characters.uppercased()
        }
        let specialKeys: [UInt16: String] = [
            UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "Space",
            UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12"
        ]
        return specialKeys[event.keyCode]
    }
}

private enum ScreenshotCaptureMode: Equatable {
    case areaSelection
    case fullScreen
}

private final class ShortcutRecorderField: NSTextField {
    var onShortcutRecorded: ((ScreenshotShortcut) -> Bool)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var shortcut: ScreenshotShortcut
    private var isRecording = false

    init(shortcut: ScreenshotShortcut, accessibilityLabel: String) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        stringValue = shortcut.display
        isEditable = false
        isSelectable = false
        isBordered = true
        drawsBackground = true
        backgroundColor = NSColor(calibratedRed: 0.055, green: 0.09, blue: 0.14, alpha: 1)
        textColor = NSColor(calibratedRed: 0.45, green: 0.86, blue: 1, alpha: 1)
        alignment = .center
        font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        focusRingType = .none
        setAccessibilityLabel(accessibilityLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        onRecordingChanged?(true)
        stringValue = "Press shortcut…"
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            cancelRecording()
            return
        }
        guard let shortcut = ScreenshotShortcut(event: event) else {
            NSSound.beep()
            return
        }
        let accepted = onShortcutRecorded?(shortcut) ?? true
        if accepted {
            self.shortcut = shortcut
        } else {
            NSSound.beep()
        }
        stringValue = self.shortcut.display
        isRecording = false
        onRecordingChanged?(false)
    }

    override func cancelOperation(_ sender: Any?) {
        if isRecording {
            cancelRecording()
            return
        }
        super.cancelOperation(sender)
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    func setShortcut(_ shortcut: ScreenshotShortcut) {
        self.shortcut = shortcut
        stringValue = shortcut.display
    }

    private func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        stringValue = shortcut.display
        onRecordingChanged?(false)
    }
}

final class MacCleanAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var mainWindow: NSWindow?
    private var screenshotEditors: [ScreenshotMarkupWindowController] = []
    private var pinnedEditorsWithHiddenToolbars: [ScreenshotMarkupWindowController] = []
    private var screenshotHotKey: EventHotKeyRef?
    private var fullScreenScreenshotHotKey: EventHotKeyRef?
    private var screenshotHotKeyHandler: EventHandlerRef?
    private var screenshotShortcut = ScreenshotShortcut.defaultValue
    private var fullScreenScreenshotShortcut = ScreenshotShortcut.fullScreenDefaultValue
    private var pendingScreenshotCaptureMode = ScreenshotCaptureMode.areaSelection
    private weak var captureButton: MetalButton?
    private weak var areaScreenshotShortcutField: ShortcutRecorderField?
    private weak var fullScreenScreenshotShortcutField: ShortcutRecorderField?
    private var screenshotHotKeysSuspendedForShortcutRecording = false
    private let screenshotShortcutDefaultsPrefix = "MacClean.captureShortcut."
    private let fullScreenScreenshotShortcutDefaultsPrefix = "MacClean.fullScreenCaptureShortcut."
    private let screenshotCaptureDelayDefaultsKey = "MacClean.captureDelaySeconds"
    private var screenshotCaptureDelaySeconds = 0
    private var captureDelayMenuItem: NSMenuItem?
    private var captureDelayMenuItems: [Int: NSMenuItem] = [:]
    private weak var customCaptureDelayMenuItem: NSMenuItem?
    private var screenshotCaptureInProgress = false
    private var screenshotCaptureCountdownRemaining = 0
    private var screenshotCaptureCountdownTimer: Timer?
    private var frozenCaptureController: FrozenScreenshotSelectionWindowController?
    private var mainWindowFrameBeforeCapture: NSRect?
    private var screenCapturePermissionAtLaunch = false
    private var statusFeedbackID: UUID?
    private var launchAtLoginCheckbox: NSButton?
    private var detailPanel: DetailPanelView?
    private var detailHasUserAction = false
    private var runningProcess = false
    private var downloadMinimumMegabytes = 100.0
    private var historyMinimumMegabytes = 0.0
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        screenCapturePermissionAtLaunch = CGPreflightScreenCaptureAccess()
        screenshotCaptureDelaySeconds = min(
            max(UserDefaults.standard.integer(forKey: screenshotCaptureDelayDefaultsKey), 0),
            60
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "externaldrive.badge.checkmark",
                accessibilityDescription: "Mac Clean"
            )
            button.imagePosition = .imageOnly
            button.title = ""
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Mac Clean"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu = NSMenu()
        let menuTitle = NSMenuItem(title: "Mac Clean", action: nil, keyEquivalent: "")
        menuTitle.isEnabled = false
        menu.addItem(menuTitle)
        menu.addItem(.separator())
        addItem("Open Mac Clean", action: #selector(showMainWindow))
        addItem("Snapshot", action: #selector(captureScreenshot))
        let captureDelayMenuItem = NSMenuItem(title: "Capture Delay: Off", action: nil, keyEquivalent: "")
        let captureDelayMenu = NSMenu()
        for seconds in [0, 3, 5, 10] {
            let title = seconds == 0 ? "Off" : "\(seconds) seconds"
            let item = NSMenuItem(title: title, action: #selector(selectCaptureDelay(_:)), keyEquivalent: "")
            item.tag = seconds
            item.target = self
            captureDelayMenu.addItem(item)
            captureDelayMenuItems[seconds] = item
        }
        captureDelayMenu.addItem(.separator())
        let customCaptureDelayMenuItem = NSMenuItem(
            title: "Custom…",
            action: #selector(setCustomCaptureDelay),
            keyEquivalent: ""
        )
        customCaptureDelayMenuItem.target = self
        captureDelayMenu.addItem(customCaptureDelayMenuItem)
        captureDelayMenuItem.submenu = captureDelayMenu
        menu.addItem(captureDelayMenuItem)
        self.captureDelayMenuItem = captureDelayMenuItem
        self.customCaptureDelayMenuItem = customCaptureDelayMenuItem
        updateCaptureDelayMenu()
        addItem("Safe Disk Cleanup", action: #selector(safeDiskCleanupFromMenu))
        menu.addItem(.separator())
        addItem("Quit Mac Clean", action: #selector(quit))

        let appMenuBar = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let shortcutMenuItem = NSMenuItem(
            title: "Open Capture Settings",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        shortcutMenuItem.target = self
        appMenu.addItem(shortcutMenuItem)
        appMenu.addItem(.separator())
        let quitMenuItem = NSMenuItem(
            title: "Quit Mac Clean",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        quitMenuItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitMenuItem)
        appMenuItem.submenu = appMenu
        appMenuBar.addItem(appMenuItem)
        NSApp.mainMenu = appMenuBar

        registerScreenshotShortcut()
        createMainWindow()
        detailPanel?.present(
            title: "Memory Snapshot",
            summary: "--% free • captured once at launch",
            output: "Select Scan / Dry Run to inspect disk usage.",
            success: true
        )
        loadMemorySnapshot()
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenshotCaptureCountdownTimer?.invalidate()
        screenshotCaptureCountdownTimer = nil
        frozenCaptureController?.close()
        frozenCaptureController = nil
        restorePinnedScreenshotsAfterCapture()
        resetCaptureStatusItem()
        unregisterScreenshotHotKeys()
        if let screenshotHotKeyHandler {
            RemoveEventHandler(screenshotHotKeyHandler)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow()
        }
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showMainWindow()
        return false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showMainWindow()
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        showMainWindow()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !screenshotCaptureInProgress,
              screenshotEditors.isEmpty,
              mainWindow != nil,
              mainWindow?.isVisible != true else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.screenshotCaptureInProgress,
                  self.screenshotEditors.isEmpty else { return }
            self.showMainWindow()
        }
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard let screen = window.screen ?? NSScreen.main else { return newFrame }
        let visibleFrame = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        let preferredFrame = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: 980, height: 800)
        )
        let width = min(preferredFrame.width, visibleFrame.width)
        let height = min(preferredFrame.height, visibleFrame.height)
        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func createMainWindow() {
        guard mainWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Clean"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 900, height: 740)
        window.contentMaxSize = NSSize(width: 1040, height: 900)
        window.maxSize = NSSize(width: 1060, height: 928)
        window.delegate = self

        let rootView = MetalBackgroundView(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let mark = NSImageView(
            image: NSImage(
                systemSymbolName: "externaldrive.badge.checkmark",
                accessibilityDescription: "Mac Clean"
            ) ?? NSImage()
        )
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.contentTintColor = NSColor(calibratedRed: 0.36, green: 0.82, blue: 1.0, alpha: 1)
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 48).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let eyebrow = NSTextField(labelWithString: "LOCAL MAINTENANCE CONSOLE")
        eyebrow.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        eyebrow.textColor = NSColor(calibratedRed: 0.36, green: 0.82, blue: 1.0, alpha: 0.9)

        let title = NSTextField(labelWithString: "Mac Clean")
        title.font = NSFont.systemFont(ofSize: 28, weight: .bold)
        title.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)

        let titleStack = NSStackView(views: [eyebrow, title])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        let protocolTitle = NSTextField(labelWithString: "SAFETY PROTOCOL  /  DRY-RUN FIRST")
        protocolTitle.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        protocolTitle.textColor = NSColor(calibratedRed: 0.36, green: 0.82, blue: 1.0, alpha: 0.9)
        protocolTitle.alignment = .right

        let headerSafetyNote = NSTextField(wrappingLabelWithString: "Read-only audit • confirmation required\nProtected data stays untouched")
        headerSafetyNote.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        headerSafetyNote.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        headerSafetyNote.alignment = .right
        headerSafetyNote.maximumNumberOfLines = 2
        headerSafetyNote.lineBreakMode = .byWordWrapping
        headerSafetyNote.preferredMaxLayoutWidth = 330

        let headerSafetyStack = NSStackView(views: [protocolTitle, headerSafetyNote])
        headerSafetyStack.orientation = .vertical
        headerSafetyStack.alignment = .trailing
        headerSafetyStack.spacing = 3
        headerSafetyStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let scanButton = MetalButton(
            title: "Scan",
            target: self,
            action: #selector(scan),
            primary: true
        )
        scanButton.alignment = .center
        scanButton.toolTip = "Run a read-only disk and memory audit."
        scanButton.translatesAutoresizingMaskIntoConstraints = false
        scanButton.widthAnchor.constraint(equalToConstant: 96).isActive = true
        scanButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let captureButton = MetalButton(
            title: "Capture",
            target: self,
            action: #selector(captureScreenshot),
            primary: false
        )
        captureButton.alignment = .center
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        captureButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        self.captureButton = captureButton
        updateCaptureButtonTooltip()

        let activityButton = MetalButton(
            title: "Activity Monitor",
            target: self,
            action: #selector(openActivityMonitor)
        )
        activityButton.alignment = .center
        activityButton.toolTip = "Open Apple's built-in memory inspector."
        activityButton.translatesAutoresizingMaskIntoConstraints = false
        activityButton.widthAnchor.constraint(equalToConstant: 152).isActive = true
        activityButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let header = NSStackView(views: [mark, titleStack, spacer, captureButton, scanButton, activityButton, headerSafetyStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let loginAtLaunch = NSButton(
            checkboxWithTitle: "Launch Mac Clean at login",
            target: self,
            action: #selector(toggleLaunchAtLogin)
        )
        loginAtLaunch.controlSize = .large
        loginAtLaunch.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        loginAtLaunch.attributedTitle = NSAttributedString(
            string: "Launch Mac Clean at login",
            attributes: [
                .foregroundColor: NSColor(calibratedWhite: 0.9, alpha: 1),
                .font: NSFont.systemFont(ofSize: 13, weight: .medium)
            ]
        )
        loginAtLaunch.contentTintColor = NSColor(calibratedRed: 0.36, green: 0.82, blue: 1.0, alpha: 1)
        loginAtLaunch.toolTip = "Keep Mac Clean available in the menu bar after you sign in."
        launchAtLoginCheckbox = loginAtLaunch

        let quickCaptureRecorder = ShortcutRecorderField(
            shortcut: fullScreenScreenshotShortcut,
            accessibilityLabel: "Quick Capture shortcut"
        )
        quickCaptureRecorder.onRecordingChanged = { [weak self] isRecording in
            self?.setScreenshotHotKeysSuspendedForShortcutRecording(isRecording)
        }
        quickCaptureRecorder.onShortcutRecorded = { [weak self] shortcut in
            self?.saveScreenshotShortcut(shortcut, for: .fullScreen) ?? false
        }
        fullScreenScreenshotShortcutField = quickCaptureRecorder

        let areaCaptureRecorder = ShortcutRecorderField(
            shortcut: screenshotShortcut,
            accessibilityLabel: "Area Capture shortcut"
        )
        areaCaptureRecorder.onRecordingChanged = { [weak self] isRecording in
            self?.setScreenshotHotKeysSuspendedForShortcutRecording(isRecording)
        }
        areaCaptureRecorder.onShortcutRecorded = { [weak self] shortcut in
            self?.saveScreenshotShortcut(shortcut, for: .areaSelection) ?? false
        }
        areaScreenshotShortcutField = areaCaptureRecorder

        let quickCaptureSettings = shortcutRecorderGroup(title: "Quick Capture", recorder: quickCaptureRecorder)
        let areaCaptureSettings = shortcutRecorderGroup(title: "Area Capture", recorder: areaCaptureRecorder)

        let footerNote = NSTextField(labelWithString: "NO BACKGROUND SCANS  •  USER-CONTROLLED ACTIONS")
        footerNote.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        footerNote.textColor = NSColor(calibratedWhite: 0.48, alpha: 1)
        footerNote.alignment = .right
        footerNote.setContentHuggingPriority(.required, for: .horizontal)

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [
            loginAtLaunch,
            footerSpacer,
            quickCaptureSettings,
            areaCaptureSettings,
            footerNote
        ])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let detailPanelView = DetailPanelView()
        detailPanel = detailPanelView
        detailPanelView.onRevealDockerDisk = { [weak self] in self?.revealDockerDisk() }
        detailPanelView.onOpenSystemSettings = { [weak self] in self?.openSystemSettings() }
        let cleanupGrid = makeCardGrid([
            ActionCardView(
                iconName: "checkmark.shield",
                title: "Safe Disk Cleanup",
                detail: "Docker BuildKit and dangling images only.",
                buttonTitle: "Clean",
                target: self,
                action: #selector(safeDiskCleanup)
            ),
            ActionCardView(
                iconName: "shippingbox",
                title: "Unused Images (30 days)",
                detail: "Remove old images after confirmation.",
                buttonTitle: "Prune",
                target: self,
                action: #selector(unusedImages)
            ),
            ActionCardView(
                iconName: "arrow.down.doc",
                title: "Large Files / Downloads",
                detail: "Review size and date; selected files go to Trash.",
                buttonTitle: "Review",
                target: self,
                action: #selector(reviewDownloads)
            ),
            ActionCardView(
                iconName: "arrow.triangle.2.circlepath",
                title: "Cache Review",
                detail: "Inspect each cache and select only what to clear.",
                buttonTitle: "Review",
                target: self,
                action: #selector(reviewCaches)
            ),
            ActionCardView(
                iconName: "arrow.triangle.branch",
                title: "Worktrees Review",
                detail: "Review Git worktrees across local home projects.",
                buttonTitle: "Review",
                target: self,
                action: #selector(reviewWorktrees),
                compact: true
            ),
            ActionCardView(
                iconName: "text.bubble",
                title: "Chat History Review",
                detail: "Codex, Claude Code and Antigravity transcripts by date.",
                buttonTitle: "Review",
                target: self,
                action: #selector(reviewHistory),
                compact: true
            )
        ])

        let fullWidthViews: [NSView] = [
            header,
            detailPanelView,
            cleanupGrid,
            footer
        ]
        for view in fullWidthViews {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        rootView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -22)
        ])

        window.contentView = rootView
        window.setContentSize(NSSize(width: 980, height: 800))
        window.center()
        mainWindow = window
        updateLaunchAtLoginUI()
    }

    private func makeCardGrid(_ cards: [NSView]) -> NSStackView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        var index = 0
        while index < cards.count {
            let end = min(index + 2, cards.count)
            let rowCards = Array(cards[index..<end])
            let row = NSStackView(views: rowCards)
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 14
            row.heightAnchor.constraint(equalToConstant: rowCards.count == 1 ? 70 : 100).isActive = true
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            index = end
        }
        return grid
    }

    @objc private func statusItemClicked() {
        guard !screenshotCaptureInProgress else { return }
        guard let event = NSApp.currentEvent, let button = statusItem.button else {
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    private func registerScreenshotShortcut() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let delegate = Unmanaged<MacCleanAppDelegate>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard parameterStatus == noErr else { return noErr }
                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case 1:
                        delegate.captureScreenshot()
                    case 2:
                        delegate.captureFullScreenScreenshot()
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &screenshotHotKeyHandler
        )
        guard installStatus == noErr else { return }

        let configuredArea = loadScreenshotShortcut(
            prefix: screenshotShortcutDefaultsPrefix,
            defaultValue: .defaultValue
        )
        let configuredFullScreen = loadScreenshotShortcut(
            prefix: fullScreenScreenshotShortcutDefaultsPrefix,
            defaultValue: .fullScreenDefaultValue
        )

        let areaCandidates = configuredArea == .defaultValue
            ? [.defaultValue]
            : [configuredArea, .defaultValue]
        let fullScreenCandidates = configuredFullScreen == .fullScreenDefaultValue
            ? [.fullScreenDefaultValue, .fullScreenAlternateDefaultValue]
            : [configuredFullScreen, .fullScreenDefaultValue, .fullScreenAlternateDefaultValue]

        for area in areaCandidates {
            for fullScreen in fullScreenCandidates where area != fullScreen {
                if registerScreenshotHotKeys(area: area, fullScreen: fullScreen) {
                    screenshotShortcut = area
                    fullScreenScreenshotShortcut = fullScreen
                    return
                }
            }
        }
        if let screenshotHotKeyHandler {
            RemoveEventHandler(screenshotHotKeyHandler)
            self.screenshotHotKeyHandler = nil
        }
    }

    private func registerScreenshotHotKey(
        _ shortcut: ScreenshotShortcut,
        id: UInt32
    ) -> (OSStatus, EventHotKeyRef?) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D434C4E), id: id)
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        return (status, hotKey)
    }

    private func registerScreenshotHotKeys(
        area: ScreenshotShortcut,
        fullScreen: ScreenshotShortcut
    ) -> Bool {
        unregisterScreenshotHotKeys()
        guard area != fullScreen else { return false }

        let (areaStatus, areaHotKey) = registerScreenshotHotKey(area, id: 1)
        guard areaStatus == noErr, let areaHotKey else { return false }

        let (fullScreenStatus, fullScreenHotKey) = registerScreenshotHotKey(fullScreen, id: 2)
        guard fullScreenStatus == noErr, let fullScreenHotKey else {
            UnregisterEventHotKey(areaHotKey)
            return false
        }

        screenshotHotKey = areaHotKey
        fullScreenScreenshotHotKey = fullScreenHotKey
        return true
    }

    private func loadScreenshotShortcut(
        prefix: String,
        defaultValue: ScreenshotShortcut
    ) -> ScreenshotShortcut {
        let defaults = UserDefaults.standard
        let keyCodeKey = prefix + "keyCode"
        let modifiersKey = prefix + "modifiers"
        let labelKey = prefix + "keyLabel"
        guard defaults.object(forKey: keyCodeKey) != nil,
              defaults.object(forKey: modifiersKey) != nil,
              let keyLabel = defaults.string(forKey: labelKey) else {
            return defaultValue
        }
        return ScreenshotShortcut(
            keyCode: UInt32(truncatingIfNeeded: defaults.integer(forKey: keyCodeKey)),
            modifiers: UInt32(truncatingIfNeeded: defaults.integer(forKey: modifiersKey)),
            keyLabel: keyLabel
        )
    }

    private func shortcutRecorderGroup(
        title: String,
        recorder: ShortcutRecorderField
    ) -> NSStackView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
        label.alignment = .center

        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalToConstant: 126).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 34).isActive = true
        recorder.toolTip = "Click to record this shortcut. Press Escape to cancel."

        let group = NSStackView(views: [label, recorder])
        group.orientation = .vertical
        group.alignment = .centerX
        group.spacing = 3
        return group
    }

    private func unregisterScreenshotHotKeys() {
        if let screenshotHotKey {
            UnregisterEventHotKey(screenshotHotKey)
            self.screenshotHotKey = nil
        }
        if let fullScreenScreenshotHotKey {
            UnregisterEventHotKey(fullScreenScreenshotHotKey)
            self.fullScreenScreenshotHotKey = nil
        }
    }

    private func setScreenshotHotKeysSuspendedForShortcutRecording(_ suspended: Bool) {
        guard suspended != screenshotHotKeysSuspendedForShortcutRecording else { return }
        screenshotHotKeysSuspendedForShortcutRecording = suspended

        if suspended {
            unregisterScreenshotHotKeys()
        } else if (screenshotHotKey == nil || fullScreenScreenshotHotKey == nil),
                  !registerScreenshotHotKeys(
            area: screenshotShortcut,
            fullScreen: fullScreenScreenshotShortcut
        ) {
            NSSound.beep()
        }
    }

    private func saveScreenshotShortcut(
        _ shortcut: ScreenshotShortcut,
        for mode: ScreenshotCaptureMode
    ) -> Bool {
        let area = mode == .areaSelection ? shortcut : screenshotShortcut
        let fullScreen = mode == .fullScreen ? shortcut : fullScreenScreenshotShortcut
        guard area != fullScreen else { return false }

        guard registerScreenshotHotKeys(area: area, fullScreen: fullScreen) else {
            _ = registerScreenshotHotKeys(
                area: screenshotShortcut,
                fullScreen: fullScreenScreenshotShortcut
            )
            return false
        }

        screenshotShortcut = area
        fullScreenScreenshotShortcut = fullScreen
        let defaults = UserDefaults.standard
        persistScreenshotShortcut(area, prefix: screenshotShortcutDefaultsPrefix, to: defaults)
        persistScreenshotShortcut(fullScreen, prefix: fullScreenScreenshotShortcutDefaultsPrefix, to: defaults)
        areaScreenshotShortcutField?.setShortcut(area)
        fullScreenScreenshotShortcutField?.setShortcut(fullScreen)
        updateCaptureButtonTooltip()
        return true
    }

    private func persistScreenshotShortcut(
        _ shortcut: ScreenshotShortcut,
        prefix: String,
        to defaults: UserDefaults
    ) {
        defaults.set(Int(shortcut.keyCode), forKey: prefix + "keyCode")
        defaults.set(Int(shortcut.modifiers), forKey: prefix + "modifiers")
        defaults.set(shortcut.keyLabel, forKey: prefix + "keyLabel")
    }

    private func updateCaptureButtonTooltip() {
        let delayDescription = screenshotCaptureDelaySeconds == 0
            ? "The screen freezes immediately."
            : "The screen freezes after a \(screenshotCaptureDelaySeconds)-second delay."
        captureButton?.toolTip = "Click two opposite corners on the frozen screen to capture an area. Include pinned screenshots to combine them. \(delayDescription) Area shortcut: \(screenshotShortcut.display). Full-screen shortcut: \(fullScreenScreenshotShortcut.display)."
    }

    private func updateCaptureDelayMenu() {
        let title = screenshotCaptureDelaySeconds == 0
            ? "Capture Delay: Off"
            : "Capture Delay: \(screenshotCaptureDelaySeconds)s"
        captureDelayMenuItem?.title = title
        captureDelayMenuItems.forEach { seconds, item in
            item.state = seconds == screenshotCaptureDelaySeconds ? .on : .off
        }
        customCaptureDelayMenuItem?.state = captureDelayMenuItems[screenshotCaptureDelaySeconds] == nil ? .on : .off
        updateCaptureButtonTooltip()
    }

    private func saveCaptureDelay(_ seconds: Int) {
        screenshotCaptureDelaySeconds = min(max(seconds, 0), 60)
        UserDefaults.standard.set(screenshotCaptureDelaySeconds, forKey: screenshotCaptureDelayDefaultsKey)
        updateCaptureDelayMenu()
    }

    @objc private func selectCaptureDelay(_ sender: NSMenuItem) {
        saveCaptureDelay(sender.tag)
    }

    @objc private func setCustomCaptureDelay() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Capture Delay"
        alert.informativeText = "Choose how many seconds to wait before Mac Clean freezes the displays (0–60)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(string: "\(screenshotCaptureDelaySeconds)")
        input.frame = NSRect(x: 0, y: 0, width: 220, height: 26)
        input.alignment = .center
        input.selectText(nil)
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let seconds = Int(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...60).contains(seconds) else {
            let invalidAlert = NSAlert()
            invalidAlert.alertStyle = .warning
            invalidAlert.messageText = "Invalid Capture Delay"
            invalidAlert.informativeText = "Enter a whole number from 0 to 60 seconds."
            invalidAlert.runModal()
            return
        }
        saveCaptureDelay(seconds)
    }

    @objc private func captureScreenshot() {
        performScreenshotCapture(mode: .areaSelection)
    }

    private func captureFullScreenScreenshot() {
        performScreenshotCapture(mode: .fullScreen)
    }

    private func performScreenshotCapture(mode: ScreenshotCaptureMode) {
        guard !screenshotCaptureInProgress else { return }
        if let awaitingPin = screenshotEditors.first(where: \.isAwaitingPin) {
            awaitingPin.showPinRequiredMessage()
            return
        }
        let pinnedScreenshotCount = screenshotEditors.filter(\.isScreenshotPinned).count
        guard screenCapturePermissionAtLaunch else {
            let permissionAvailableNow = CGPreflightScreenCaptureAccess()
            showMainWindow()
            let output = permissionAvailableNow
                ? "macOS now reports Screen Recording access, but this app session started before the permission was applied. Fully quit and reopen Mac Clean, then try Capture again."
                : "macOS is not authorizing this Mac Clean build. In System Settings > Privacy & Security > Screen & System Audio Recording, remove any old Mac Clean entry, add ~/Applications/Mac Clean.app, and enable it. Then fully quit and reopen Mac Clean."
            showResult(
                title: permissionAvailableNow ? "Restart Mac Clean to Capture" : "Capture Permission Required",
                output: output,
                success: false,
                showsSystemSettings: !permissionAvailableNow
            )
            return
        }
        mainWindowFrameBeforeCapture = mainWindow?.frame
        screenshotCaptureInProgress = true
        pendingScreenshotCaptureMode = mode
        mainWindow?.orderOut(nil)
        // Keep pinned screenshots visible so they remain part of either capture.
        // Hide their controls so the toolbars are not included in the result.
        pinnedEditorsWithHiddenToolbars = screenshotEditors.filter { $0.hidePinnedToolbarForCapture() }
        NSApp.windows.forEach { $0.displayIfNeeded() }

        startScreenshotCaptureCountdown(pinnedScreenshotCount: pinnedScreenshotCount, mode: mode)
    }

    private func startScreenshotCaptureCountdown(
        pinnedScreenshotCount: Int,
        mode: ScreenshotCaptureMode
    ) {
        screenshotCaptureCountdownRemaining = screenshotCaptureDelaySeconds
        guard screenshotCaptureCountdownRemaining > 0 else {
            resetCaptureStatusItem()
            captureFrozenScreens(pinnedScreenshotCount: pinnedScreenshotCount, mode: mode)
            return
        }

        showCaptureCountdownStatus()
        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(screenshotCaptureCountdownTick(_:)),
            userInfo: pinnedScreenshotCount,
            repeats: true
        )
        screenshotCaptureCountdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func screenshotCaptureCountdownTick(_ timer: Timer) {
        screenshotCaptureCountdownRemaining -= 1
        guard screenshotCaptureCountdownRemaining > 0 else {
            timer.invalidate()
            screenshotCaptureCountdownTimer = nil
            resetCaptureStatusItem()
            captureFrozenScreens(
                pinnedScreenshotCount: timer.userInfo as? Int ?? 0,
                mode: pendingScreenshotCaptureMode
            )
            return
        }
        showCaptureCountdownStatus()
    }

    private func showCaptureCountdownStatus() {
        guard let button = statusItem.button else { return }
        statusFeedbackID = nil
        button.imagePosition = .imageLeading
        button.title = "Freeze in \(screenshotCaptureCountdownRemaining)s"
        button.toolTip = "The screen will freeze when the capture delay ends."
        statusItem.length = NSStatusItem.variableLength
    }

    private func captureFrozenScreens(pinnedScreenshotCount: Int, mode: ScreenshotCaptureMode) {
        Task { @MainActor [weak self] in
            do {
                let displays = try await FrozenScreenCapture.captureDisplays()
                guard let self, self.screenshotCaptureInProgress else { return }

                if mode == .fullScreen {
                    guard let image = FrozenScreenCapture.fullScreenImage(
                        from: displays,
                        at: NSEvent.mouseLocation
                    ) else {
                        self.finishScreenshotCapture(error: "Could not create the full-screen screenshot.")
                        return
                    }
                    self.finishScreenshotCapture(image: image)
                    return
                }

                let controller = FrozenScreenshotSelectionWindowController(displays: displays)
                self.frozenCaptureController = controller
                controller.onComplete = { [weak self, weak controller] image in
                    guard let self else { return }
                    if self.frozenCaptureController === controller {
                        self.frozenCaptureController = nil
                    }
                    self.finishScreenshotCapture(image: image)
                }
                controller.showSelection()
                self.showCaptureRegionStatus(pinnedScreenshotCount: pinnedScreenshotCount)
            } catch {
                self?.finishScreenshotCapture(error: error.localizedDescription)
            }
        }
    }

    private func finishScreenshotCapture(image: NSImage? = nil, error: String? = nil) {
        screenshotCaptureCountdownTimer?.invalidate()
        screenshotCaptureCountdownTimer = nil
        screenshotCaptureInProgress = false
        resetCaptureStatusItem()
        restorePinnedScreenshotsAfterCapture()

        if let error {
            showMainWindow()
            showResult(title: "Frozen Capture Failed", output: error, success: false)
            restoreMainWindowFrameAfterCapture()
            return
        }
        guard let image else {
            showMainWindow()
            showResult(
                title: "Capture Cancelled",
                output: "The frozen screen selection was cancelled.",
                success: true
            )
            restoreMainWindowFrameAfterCapture()
            return
        }

        openScreenshotEditor(image)
        restoreMainWindowFrameAfterCapture()
    }

    private func restorePinnedScreenshotsAfterCapture() {
        let editors = pinnedEditorsWithHiddenToolbars
        pinnedEditorsWithHiddenToolbars.removeAll()
        editors.forEach { $0.restorePinnedToolbarAfterCapture() }
    }

    private func restoreMainWindowFrameAfterCapture() {
        guard let savedFrame = mainWindowFrameBeforeCapture else { return }
        mainWindowFrameBeforeCapture = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.mainWindow else { return }
            let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 24, dy: 24)
            var frame = savedFrame
            if let visibleFrame {
                frame.size.width = min(frame.width, min(1060, visibleFrame.width))
                frame.size.height = min(frame.height, visibleFrame.height)
                frame.origin.x = min(max(visibleFrame.minX, frame.minX), visibleFrame.maxX - frame.width)
                frame.origin.y = min(max(visibleFrame.minY, frame.minY), visibleFrame.maxY - frame.height)
            } else {
                frame.size.width = min(frame.width, 1060)
            }
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private func showCaptureRegionStatus(pinnedScreenshotCount: Int) {
        guard let button = statusItem.button else { return }
        statusFeedbackID = nil
        button.imagePosition = .imageLeading
        statusItem.length = NSStatusItem.variableLength
        if pinnedScreenshotCount > 0 {
            button.title = "Frozen • \(pinnedScreenshotCount) pinned"
            button.toolTip = "Click two opposite corners around the pinned screenshots you want to combine. Press Escape to cancel."
        } else {
            button.title = "Frozen • Select Area"
            button.toolTip = "Click two opposite corners to capture an area. Press Escape to cancel."
        }
    }

    private func resetCaptureStatusItem() {
        statusFeedbackID = nil
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Mac Clean"
        statusItem.button?.imagePosition = .imageOnly
        statusItem.length = NSStatusItem.squareLength
    }

    private func showMenuBarCleanupResult(success: Bool) {
        guard let button = statusItem.button else { return }
        let tooltip = success ? "Safe Disk Cleanup completed" : "Safe Disk Cleanup failed"
        button.toolTip = tooltip
        guard !screenshotCaptureInProgress else { return }

        let feedbackID = UUID()
        statusFeedbackID = feedbackID
        button.title = success ? "Clean complete" : "Clean failed"
        button.imagePosition = .imageLeading
        statusItem.length = NSStatusItem.variableLength

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.statusFeedbackID == feedbackID else { return }
            self.resetCaptureStatusItem()
        }
    }

    private func openScreenshotEditor(_ image: NSImage) {
        guard let editor = ScreenshotMarkupWindowController(image: image) else {
            showMainWindow()
            showResult(title: "Screenshot & Markup", output: "Could not open the captured image for markup.", success: false)
            return
        }
        if let previousFrame = screenshotEditors.last(where: \.isScreenshotPinned)?.window?.frame,
           let screenFrame = NSScreen.main?.visibleFrame,
           let window = editor.window {
            var origin = CGPoint(x: previousFrame.minX + 34, y: previousFrame.minY - 34)
            origin.x = min(max(screenFrame.minX, origin.x), screenFrame.maxX - window.frame.width)
            origin.y = min(max(screenFrame.minY, origin.y), screenFrame.maxY - window.frame.height)
            window.setFrameOrigin(origin)
        }
        screenshotEditors.append(editor)
        editor.onClose = { [weak self, weak editor] in
            guard let editor else { return }
            self?.screenshotEditors.removeAll { $0 === editor }
        }
        NSApp.activate(ignoringOtherApps: true)
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.constrainMainWindowWidth() }
    }

    private func addItem(_ title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func updateLaunchAtLoginUI() {
        let state: NSControl.StateValue = launchAtLoginEnabled ? .on : .off
        launchAtLoginCheckbox?.state = state
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
                updateLaunchAtLoginUI()
                showResult(
                    title: "Launch at Login Disabled",
                    output: "Mac Clean will not start automatically after the next sign-in.",
                    success: true
                )
            } else {
                try SMAppService.mainApp.register()
                updateLaunchAtLoginUI()
                if SMAppService.mainApp.status == .requiresApproval {
                    showResult(
                        title: "Approval Required",
                        output: "Open System Settings > General > Login Items and enable Mac Clean. macOS requires approval before it can start at login.",
                        success: false
                    )
                } else {
                    showResult(
                        title: "Launch at Login Enabled",
                        output: "Mac Clean will start automatically after you sign in. It does not run cleanup until you choose an action.",
                        success: true
                    )
                }
            }
        } catch {
            updateLaunchAtLoginUI()
            showResult(
                title: "Launch at Login",
                output: "macOS could not update the login item: \(error.localizedDescription)",
                success: false
            )
        }
    }

    @objc private func showMainWindow() {
        if mainWindow == nil {
            createMainWindow()
            loadMemorySnapshot()
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.orderFrontRegardless()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func loadMemorySnapshot() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
        process.arguments = ["-Q"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            let percentage = self?.extractMemoryFreePercentage(from: output)

            DispatchQueue.main.async {
                guard let self else { return }
                let formatted = percentage.map { "\($0)% free" } ?? "--% free"
                if !self.detailHasUserAction {
                    self.detailPanel?.present(
                        title: "Memory Snapshot",
                        summary: "\(formatted) • captured once at launch",
                        output: "Select Scan / Dry Run to inspect disk usage.",
                        success: true
                    )
                }
            }
        }
    }

    private func extractMemoryFreePercentage(from output: String) -> String? {
        let pattern = #"memory free percentage:\s*([0-9]+)%"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output)
            ),
            let range = Range(match.range(at: 1), in: output)
        else {
            return nil
        }
        return String(output[range])
    }

    @objc private func scan() {
        runMacClean(title: "Scan / Dry Run", arguments: [])
    }

    @objc private func safeDiskCleanup() {
        runSafeDiskCleanup(showMenuBarFeedback: false)
    }

    private func runSafeDiskCleanup(showMenuBarFeedback: Bool) {
        confirm(
            title: "Run safe disk cleanup?",
            message: "This cleans Docker BuildKit cache and dangling images only. It does not remove containers or volumes. Package caches are reviewed separately.",
            style: .informational
        ) { [weak self] in
            self?.runMacClean(
                title: "Safe Disk Cleanup",
                arguments: ["--apply", "--yes", "--no-protected-audit"]
            ) { [weak self] _, success in
                if showMenuBarFeedback {
                    self?.showMenuBarCleanupResult(success: success)
                }
            }
        }
    }

    @objc private func safeDiskCleanupFromMenu() {
        runSafeDiskCleanup(showMenuBarFeedback: true)
    }

    @objc private func unusedImages() {
        confirm(
            title: "Remove old unused images?",
            message: "This also runs the safe cleanup and removes unused Docker images older than 30 days. Containers and volumes are preserved.",
            style: .warning
        ) { [weak self] in
            self?.runMacClean(title: "Unused Images (30 days)", arguments: ["--apply", "--yes", "--unused-images", "--no-protected-audit"])
        }
    }

    @objc private func reviewDownloads() {
        loadDownloads(minimumMB: downloadMinimumMegabytes)
    }

    private func loadDownloads(minimumMB: Double) {
        runMacClean(
            title: "Large Files / Downloads",
            arguments: ["--downloads-json", "--downloads-min-mb", String(minimumMB)]
        ) { [weak self] output, success in
            guard let self, success, let data = output.data(using: .utf8),
                  let catalog = try? JSONDecoder().decode(DownloadCatalogResponse.self, from: data) else {
                return
            }
            self.downloadMinimumMegabytes = catalog.minimumSizeMB
            let rows = catalog.items.map { item in
                return DetailChecklistItem(
                    id: item.path,
                    title: "\(item.name)  •  \(Self.formattedBytes(item.sizeBytes))  •  \(item.category)",
                    subtitle: "\(item.relativePath)  •  Modified \(Self.formattedDate(item.modifiedAtMs))"
                )
            }
            let warning = catalog.warnings.isEmpty ? "" : " • " + catalog.warnings.joined(separator: " ")
            let sizeSummary = catalog.minimumSizeMB == 0 ? "all sizes" : ">\(Self.formattedMegabytes(catalog.minimumSizeMB))"
            self.detailPanel?.presentChecklist(
                title: "Large Files / Downloads",
                summary: "\(rows.count) items • \(sizeSummary) • selected items move to Trash\(warning)",
                items: rows,
                actionTitle: "Move Selected to Trash",
                minimumSizeMB: catalog.minimumSizeMB,
                onSizeFilter: { [weak self] value in self?.loadDownloads(minimumMB: value) }
            ) { [weak self] selectedPaths in
                self?.trashSelectedDownloads(selectedPaths, from: catalog.items, minimumMB: catalog.minimumSizeMB)
            }
        }
    }

    @objc private func reviewCaches() {
        runMacClean(title: "Cache Review", arguments: ["--cache-catalog-json"]) { [weak self] output, success in
            guard let self, success, let data = output.data(using: .utf8),
                  let catalog = try? JSONDecoder().decode(CacheCatalogResponse.self, from: data) else {
                return
            }
            guard !catalog.items.isEmpty else {
                self.showResult(title: "Cache Review", output: "No allowlisted cache folders were found. Nothing was changed.", success: true)
                return
            }
            let rows = catalog.items.map { item in
                let path = item.path.replacingOccurrences(of: self.homeDirectory, with: "~")
                let required = item.requiredApps + item.requiredProcesses.map { "\($0) command" }
                let apps = required.isEmpty ? "No related app/process check" : "Close: \(required.joined(separator: ", "))"
                return DetailChecklistItem(
                    id: item.id,
                    title: "\(item.label)  •  \(Self.formattedBytes(item.sizeBytes))",
                    subtitle: "\(item.detail)  •  \(apps)  •  \(path)"
                )
            }
            self.detailPanel?.presentChecklist(
                title: "Cache Review",
                summary: "Caches are checked individually; busy items are skipped. Codex sessions are excluded.",
                items: rows,
                actionTitle: "Clear Selected Caches"
            ) { [weak self] selectedIDs in
                self?.clearSelectedCaches(selectedIDs, from: catalog.items)
            }
        }
    }

    @objc private func reviewWorktrees() {
        runMacClean(title: "Worktrees Review", arguments: ["--worktrees-json"]) { [weak self] output, success in
            guard let self, success, let data = output.data(using: .utf8),
                  let catalog = try? JSONDecoder().decode(WorktreeCatalogResponse.self, from: data) else { return }
            guard !catalog.items.isEmpty else {
                self.showResult(title: "Worktrees Review", output: "No linked project worktrees were found.\n" + catalog.warnings.joined(separator: "\n"), success: true)
                return
            }
            let eligible = catalog.items.filter { $0.eligible }.count
            let rows = catalog.items.map { item in
                return DetailChecklistItem(
                    id: item.path,
                    title: "\(item.name) • \(Self.formattedBytes(item.sizeBytes)) • \(item.eligible ? "Eligible" : "Keep")",
                    subtitle: "\(item.branch) • " + (item.eligible ? "Merged into main, clean, no local data or open files" : item.reasons.joined(separator: "; ")),
                    selectable: item.eligible
                )
            }
            self.detailPanel?.presentChecklist(
                title: "Worktrees Review",
                summary: "\(eligible) eligible / \(rows.count) total • Select All selects eligible items only • branches preserved",
                items: rows,
                actionTitle: "Remove Selected Worktrees"
            ) { [weak self] paths in
                guard let self else { return }
                let selected = catalog.items.filter { paths.contains($0.path) && $0.eligible }
                let selectedBytes = selected.reduce(0) { $0 + $1.sizeBytes }
                self.confirm(
                    title: "Remove \(selected.count) completed worktree(s)?",
                    message: "Working copies: \(Self.formattedBytes(selectedBytes)). Branches and committed history remain. Git status, ignored files, main ancestry, and open files will be checked again.\n\nSelections are rechecked immediately before removal; changed or busy items are skipped.",
                    style: .warning
                ) {
                    var arguments = ["--apply", "--yes"]
                    for item in selected { arguments.append(contentsOf: ["--worktree-path", item.path]) }
                    self.runMacClean(title: "Worktrees Review", arguments: arguments)
                }
            }
        }
    }

    @objc private func reviewHistory() {
        runMacClean(title: "Chat History Review", arguments: ["--history-json"]) { [weak self] output, success in
            guard let self, success, let data = output.data(using: .utf8),
                  let catalog = try? JSONDecoder().decode(HistoryCatalogResponse.self, from: data) else { return }
            guard !catalog.items.isEmpty else {
                self.showResult(title: "Chat History Review", output: "No supported Codex, Claude Code, or Antigravity history files were found.\n" + catalog.warnings.joined(separator: "\n"), success: true)
                return
            }
            self.presentHistoryReview(catalog, minimumMB: self.historyMinimumMegabytes)
        }
    }

    private func presentHistoryReview(_ catalog: HistoryCatalogResponse, minimumMB: Double) {
            let matchingItems = catalog.items.filter { minimumMB == 0 || $0.sizeBytes > minimumMB * 1_000_000 }
            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.dateFormat = "yyyy-MM-dd"
            let grouped = Dictionary(grouping: matchingItems) { item in
                "\(item.source)|\(dayFormatter.string(from: Date(timeIntervalSince1970: item.modifiedAtMs / 1000)))|\(item.selectable)"
            }
            let groups: [HistoryReviewGroup] = grouped.values.map { sourceItems in
                let sorted = sourceItems.sorted { $0.modifiedAtMs < $1.modifiedAtMs }
                let first = sorted[0]
                let newest = sorted.last?.modifiedAtMs ?? first.modifiedAtMs
                let total = sorted.reduce(0) { $0 + $1.sizeBytes }
                let selectable = sorted.allSatisfy(\.selectable)
                let reasons = Array(Set(sorted.flatMap(\.reasons))).joined(separator: "; ")
                let apps = Array(Set(sorted.flatMap(\.appLabels))).joined(separator: ", ")
                let day = dayFormatter.string(from: Date(timeIntervalSince1970: first.modifiedAtMs / 1000))
                let detail = selectable
                    ? "\(sorted.count) files • \(Self.formattedDate(first.modifiedAtMs)) → \(Self.formattedDate(newest)) • close: \(apps)"
                    : "\(sorted.count) files • Keep: \(reasons)"
                return HistoryReviewGroup(
                    id: "history-group:\(first.source):\(day):\(selectable)",
                    label: "\(first.label) • \(day) • \(sorted.count) files • \(Self.formattedBytes(total))",
                    subtitle: detail,
                    modifiedAtMs: newest,
                    itemIDs: sorted.map(\.id),
                    sizeBytes: total,
                    selectable: selectable,
                    reasons: reasons
                )
            }.sorted { $0.modifiedAtMs < $1.modifiedAtMs }
            let eligible = matchingItems.filter { $0.selectable }.count
            let rows = groups.map { group in
                DetailChecklistItem(
                    id: group.id,
                    title: group.label,
                    subtitle: group.subtitle,
                    modifiedAtMs: group.modifiedAtMs,
                    selectable: group.selectable
                )
            }
            let warning = catalog.warnings.isEmpty ? "" : " • " + catalog.warnings.joined(separator: " ")
            let sizeSummary = minimumMB == 0 ? "all sizes" : "per file >\(Self.formattedMegabytes(minimumMB))"
            self.detailPanel?.presentChecklist(
                title: "Chat History Review",
                summary: "\(matchingItems.count)/\(catalog.items.count) files • \(eligible) eligible • \(sizeSummary) • oldest first\(warning)",
                items: rows,
                actionTitle: "Move Selected History to Trash",
                allowsAgeSelection: true,
                minimumSizeMB: minimumMB,
                onSizeFilter: { [weak self] value in
                    guard let self else { return }
                    self.historyMinimumMegabytes = value
                    self.presentHistoryReview(catalog, minimumMB: value)
                }
            ) { [weak self] selectedIDs in
                guard let self else { return }
                let selectedGroups = groups.filter { selectedIDs.contains($0.id) && $0.selectable }
                let selectedHistoryIDs = Set(selectedGroups.flatMap(\.itemIDs))
                let selected = matchingItems.filter { selectedHistoryIDs.contains($0.id) && $0.selectable }
                let total = selected.reduce(0) { $0 + $1.sizeBytes }
                self.confirm(
                    title: "Move \(selected.count) history file(s) to Trash?",
                    message: "Estimated space: \(Self.formattedBytes(total)) across \(selectedGroups.count) date group(s).\n\nTranscript and conversation database files will move to macOS Trash. Runtime bundles, caches, settings and indexes are excluded. The app will recheck dates, sizes and open files before moving anything.",
                    style: .warning
                ) {
                    var arguments = ["--apply", "--yes"]
                    for item in selected { arguments.append(contentsOf: ["--history-id", item.id]) }
                    self.runMacClean(title: "Chat History Review", arguments: arguments)
                }
            }
    }

    private func clearSelectedCaches(_ selectedIDs: [String], from items: [CacheReviewItem]) {
        guard !selectedIDs.isEmpty else { return }
        let selected = items.filter { selectedIDs.contains($0.id) }
        let total = selected.reduce(0) { $0 + $1.sizeBytes }
        let names = selected.prefix(6).map { "• \($0.label) — \(Self.formattedBytes($0.sizeBytes))" }.joined(separator: "\n")
        let remaining = selected.count > 6 ? "\n• and \(selected.count - 6) more" : ""
        confirm(
            title: "Clear \(selected.count) selected cache item(s)?",
            message: "Estimated reclaimable space: \(Self.formattedBytes(total)).\n\n\(names)\(remaining)\n\nOnly these allowlisted paths will be removed. Codex sessions are not included.",
            style: .warning
        ) { [weak self] in
            guard let self else { return }
            var arguments = ["--apply", "--yes", "--no-docker", "--no-protected-audit"]
            for id in selectedIDs {
                arguments.append(contentsOf: ["--cache-id", id])
            }
            self.runMacClean(title: "Cache Review", arguments: arguments)
        }
    }

    private func trashSelectedDownloads(_ selectedPaths: [String], from items: [DownloadReviewItem], minimumMB: Double) {
        guard !selectedPaths.isEmpty else { return }
        let selected = items.filter { selectedPaths.contains($0.path) }
        let total = selected.reduce(0) { $0 + $1.sizeBytes }
        let names = selected.prefix(6).map { "• \($0.name) — \(Self.formattedBytes($0.sizeBytes))" }.joined(separator: "\n")
        let remaining = selected.count > 6 ? "\n• and \(selected.count - 6) more" : ""
        confirm(
            title: "Move \(selected.count) selected item(s) to Trash?",
            message: "Estimated size: \(Self.formattedBytes(total)).\n\n\(names)\(remaining)\n\nThis moves items to macOS Trash; it does not permanently delete them.",
            style: .warning
        ) { [weak self] in
            guard let self else { return }
            self.runMacClean(title: "Revalidate Downloads", arguments: ["--downloads-json", "--downloads-min-mb", String(minimumMB)]) { [weak self] output, success in
                guard let self, success, let data = output.data(using: .utf8),
                      let freshCatalog = try? JSONDecoder().decode(DownloadCatalogResponse.self, from: data) else {
                    self?.showResult(title: "Large Files / Downloads", output: "Could not revalidate the selected items. Nothing was moved.", success: false)
                    return
                }
                let freshByPath = Dictionary(uniqueKeysWithValues: freshCatalog.items.map { ($0.path, $0) })
                var changed: [String] = []
                let stillCurrent = selected.filter { item in
                    guard let fresh = freshByPath[item.path],
                          fresh.sizeBytes == item.sizeBytes,
                          abs(fresh.modifiedAtMs - item.modifiedAtMs) <= 1000 else {
                        changed.append("\(item.name): changed since review; not moved")
                        return false
                    }
                    return true
                }
                self.moveDownloadsToTrash(stillCurrent, skipped: changed)
            }
        }
    }

    private func moveDownloadsToTrash(_ selected: [DownloadReviewItem], skipped: [String]) {
        let downloadsRoot = URL(fileURLWithPath: homeDirectory).appendingPathComponent("Downloads").standardizedFileURL
        var moved: [String] = []
        var failures = skipped
        for item in selected {
            let url = URL(fileURLWithPath: item.path).standardizedFileURL
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            let rootPath = downloadsRoot.path.hasSuffix("/") ? downloadsRoot.path : downloadsRoot.path + "/"
            let resolvedRoot = downloadsRoot.resolvingSymlinksInPath().standardizedFileURL.path
            let resolvedRootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
            guard url.path.hasPrefix(rootPath), resolvedURL.path.hasPrefix(resolvedRootPrefix) else {
                failures.append("\(item.name): outside Downloads or linked elsewhere")
                continue
            }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let type = attributes[.type] as? FileAttributeType
                guard type != .typeSymbolicLink, type == .typeRegular || type == .typeDirectory else {
                    failures.append("\(item.name): not a regular file or installer folder")
                    continue
                }
                if type == .typeRegular,
                   let currentSize = attributes[.size] as? NSNumber,
                   currentSize.doubleValue != item.sizeBytes {
                    failures.append("\(item.name): changed since review; scan again")
                    continue
                }
                if let currentDate = attributes[.modificationDate] as? Date,
                   abs(currentDate.timeIntervalSince1970 * 1000 - item.modifiedAtMs) > 1000 {
                    failures.append("\(item.name): changed since review; scan again")
                    continue
                }
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                moved.append(item.name)
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        let output = [
            "Moved to Trash: \(moved.count)",
            moved.map { "• \($0)" }.joined(separator: "\n"),
            failures.isEmpty ? "" : "Not moved:\n" + failures.map { "• \($0)" }.joined(separator: "\n")
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        showResult(title: "Large Files / Downloads", output: output, success: failures.isEmpty)
    }

    private static func formattedBytes(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func formattedMegabytes(_ megabytes: Double) -> String {
        return String(format: "%g MB", megabytes)
    }

    private static func formattedDate(_ milliseconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    @objc private func openActivityMonitor() {
        let candidates = [
            "/System/Applications/Utilities/Activity Monitor.app",
            "/Applications/Utilities/Activity Monitor.app"
        ]
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            showResult(title: "Activity Monitor", output: "Activity Monitor was not found.", success: false)
        }
    }

    private func revealDockerDisk() {
        let path = "\(homeDirectory)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        guard FileManager.default.fileExists(atPath: path) else {
            showResult(title: "Docker.raw", output: "Docker.raw was not found at the standard Docker Desktop location. No files were changed.", success: false)
            return
        }
        confirm(
            title: "Reveal Docker.raw in Finder?",
            message: "This opens the file's location for inspection only. Mac Clean will not delete, move, or compact Docker.raw. Use Docker Desktop or System Settings for supported storage controls.",
            style: .informational
        ) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    private func openSystemSettings() {
        let path = "/System/Applications/System Settings.app"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            showResult(title: "System Settings", output: "System Settings was not found.", success: false)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func runMacClean(
        title: String,
        arguments: [String],
        completion: ((String, Bool) -> Void)? = nil
    ) {
        let launcher = "\(homeDirectory)/.local/bin/mac-clean"
        if FileManager.default.isExecutableFile(atPath: launcher) {
            runProcess(title: title, executable: launcher, arguments: arguments, completion: completion)
            return
        }

        let message = "The CLI was not found at \(launcher). Run `npm run mac:clean:install` in the Mac Clean project first."
        showResult(
            title: "Mac Clean",
            output: message,
            success: false
        )
        completion?(message, false)
    }

    private func runProcess(
        title: String,
        executable: String,
        arguments: [String],
        completion: ((String, Bool) -> Void)? = nil
    ) {
        guard !runningProcess else {
            let message = "Another cleanup action is already running."
            showResult(title: "Mac Clean", output: message, success: false)
            completion?(message, false)
            return
        }

        detailHasUserAction = true
        detailPanel?.present(
            title: title,
            summary: "Processing…",
            output: "Collecting command output…",
            success: true,
            running: true
        )
        runningProcess = true
        statusItem.button?.isEnabled = false

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        var environment = ProcessInfo.processInfo.environment
        var pathEntries = [
            "\(homeDirectory)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        if let existingPath = environment["PATH"], !existingPath.isEmpty {
            pathEntries.append(existingPath)
        }
        environment["PATH"] = pathEntries.joined(separator: ":")
        environment["HOME"] = homeDirectory
        process.environment = environment

        do {
            try process.run()
        } catch {
            runningProcess = false
            statusItem.button?.isEnabled = true
            let message = "Could not start command: \(error.localizedDescription)"
            showResult(title: title, output: message, success: false)
            completion?(message, false)
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? "(command returned non-text output)"
            let success = process.terminationStatus == 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.runningProcess = false
                self.statusItem.button?.isEnabled = true
                self.showResult(title: title, output: output, success: success)
                completion?(output, success)
            }
        }
    }

    private func confirm(title: String, message: String, style: NSAlert.Style, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }

    private func showResult(
        title: String,
        output: String,
        success: Bool,
        showsSystemSettings: Bool = false
    ) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        detailHasUserAction = true
        detailPanel?.present(
            title: title,
            summary: summaryForOutput(trimmed, success: success),
            output: trimmed.isEmpty ? "No output." : String(trimmed.prefix(16000)),
            success: success,
            showsSystemActions: title == "Scan / Dry Run",
            showsSystemSettings: showsSystemSettings
        )
        DispatchQueue.main.async { [weak self] in self?.constrainMainWindowWidth() }
    }

    private func constrainMainWindowWidth() {
        guard let window = mainWindow else { return }
        let maximumFrameWidth: CGFloat = 1060
        guard window.frame.width > maximumFrameWidth else { return }
        var frame = window.frame
        let centerX = frame.midX
        frame.size.width = maximumFrameWidth
        frame.origin.x = centerX - maximumFrameWidth / 2
        window.setFrame(frame, display: true, animate: false)
    }

    private func summaryForOutput(_ output: String, success: Bool) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let importantLines = lines.filter { line in
            let lowercased = line.lowercased()
            return lowercased.contains("disk:")
                || lowercased.contains("memory:")
                || lowercased.contains("free")
                || lowercased.contains("reclaimable")
                || lowercased.contains("removed")
                || lowercased.contains("pruned")
                || lowercased.contains("cleared")
                || lowercased.contains("completed")
                || lowercased.contains("error")
        }

        let selectedLines = importantLines.isEmpty ? Array(lines.prefix(2)) : Array(importantLines.prefix(2))
        if !selectedLines.isEmpty {
            return String(selectedLines.joined(separator: "   •   ").prefix(240))
        }
        return success ? "Completed" : "Command failed"
    }
}

class MetalBackgroundView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let background = NSGradient(colors: [
            NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.085, alpha: 1),
            NSColor(calibratedRed: 0.075, green: 0.115, blue: 0.17, alpha: 1),
            NSColor(calibratedRed: 0.025, green: 0.04, blue: 0.065, alpha: 1)
        ])
        background?.draw(in: bounds, angle: -28)

        let glow = NSBezierPath(
            ovalIn: NSRect(
                x: bounds.width * 0.56,
                y: bounds.height * 0.62,
                width: bounds.width * 0.72,
                height: bounds.height * 0.72
            )
        )
        NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.68, alpha: 0.09).setFill()
        glow.fill()

        let grid = NSBezierPath()
        let step: CGFloat = 32
        var x: CGFloat = 0
        while x <= bounds.width {
            grid.move(to: NSPoint(x: x, y: 0))
            grid.line(to: NSPoint(x: x, y: bounds.height))
            x += step
        }
        var y: CGFloat = 0
        while y <= bounds.height {
            grid.move(to: NSPoint(x: 0, y: y))
            grid.line(to: NSPoint(x: bounds.width, y: y))
            y += step
        }
        NSColor(calibratedWhite: 0.8, alpha: 0.025).setStroke()
        grid.lineWidth = 0.5
        grid.stroke()

        let topRule = NSBezierPath()
        topRule.move(to: NSPoint(x: 0, y: bounds.height - 1))
        topRule.line(to: NSPoint(x: bounds.width, y: bounds.height - 1))
        NSColor(calibratedRed: 0.36, green: 0.82, blue: 1.0, alpha: 0.35).setStroke()
        topRule.lineWidth = 1
        topRule.stroke()
    }
}

class MetalCardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        let fill = NSGradient(colors: [
            NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.26, alpha: 0.92),
            NSColor(calibratedRed: 0.055, green: 0.09, blue: 0.14, alpha: 0.96)
        ])
        fill?.draw(in: path, angle: 90)

        NSColor(calibratedRed: 0.34, green: 0.62, blue: 0.8, alpha: 0.3).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class DetailPanelView: MetalCardView {
    private let eyebrowLabel = NSTextField(labelWithString: "LIVE DETAIL")
    private let titleLabel = NSTextField(labelWithString: "Memory Snapshot")
    private let stateLabel = NSTextField(labelWithString: "CAPTURED")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let outputView = NSTextView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let sizeFilterField = NSTextField(string: "0")
    private var sizeFilterRow: NSStackView!
    private var sizeFilterHandler: ((Double) -> Void)?
    private var selectAllButton: MetalButton!
    private var selectOlderButton: MetalButton!
    private var operationButton: MetalButton!
    private var revealDockerButton: MetalButton!
    private var systemSettingsButton: MetalButton!
    private var checklistView: NSStackView?
    private var checklistWidthConstraint: NSLayoutConstraint?
    private var selectionButtons: [String: NSButton] = [:]
    private var selectionDates: [String: Double] = [:]
    private var selectionHandler: (([String]) -> Void)?
    var onRevealDockerDisk: (() -> Void)?
    var onOpenSystemSettings: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        eyebrowLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        eyebrowLabel.textColor = NSColor(calibratedRed: 0.36, green: 0.82, blue: 1.0, alpha: 0.9)
        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        stateLabel.textColor = NSColor(calibratedRed: 0.38, green: 0.95, blue: 0.78, alpha: 1)
        stateLabel.alignment = .right
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        summaryLabel.textColor = NSColor(calibratedRed: 0.45, green: 0.86, blue: 1.0, alpha: 0.95)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.isRichText = false
        outputView.drawsBackground = false
        outputView.textColor = NSColor(calibratedWhite: 0.76, alpha: 1)
        outputView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        outputView.textContainerInset = NSSize(width: 0, height: 0)
        outputView.textContainer?.lineFragmentPadding = 0
        outputView.isVerticallyResizable = true
        outputView.isHorizontallyResizable = false
        outputView.minSize = NSSize(width: 0, height: 0)
        outputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputView.autoresizingMask = [.width]
        outputView.textContainer?.widthTracksTextView = true
        outputView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = outputView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let sizeLabel = NSTextField(labelWithString: "File size >")
        sizeLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        let sizeUnitLabel = NSTextField(labelWithString: "MB")
        sizeUnitLabel.textColor = sizeLabel.textColor
        let sizeHint = NSTextField(labelWithString: "0 = all sizes")
        sizeHint.font = NSFont.systemFont(ofSize: 11)
        sizeHint.textColor = NSColor(calibratedWhite: 0.64, alpha: 1)
        sizeFilterField.placeholderString = "0"
        sizeFilterField.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        sizeFilterField.alignment = .right
        sizeFilterField.target = self
        sizeFilterField.action = #selector(applySizeFilter)
        sizeFilterField.setAccessibilityLabel("Minimum file size in MB")
        sizeFilterField.toolTip = "Filter individual files by size. Enter 0 to show all sizes. 1 MB = 1,000,000 bytes."
        sizeFilterField.translatesAutoresizingMaskIntoConstraints = false
        sizeFilterField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        sizeFilterField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let sizeFilterButton = MetalButton(title: "Filter", target: self, action: #selector(applySizeFilter))
        sizeFilterButton.translatesAutoresizingMaskIntoConstraints = false
        sizeFilterButton.widthAnchor.constraint(equalToConstant: 90).isActive = true
        sizeFilterButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        sizeFilterRow = NSStackView(views: [sizeLabel, sizeFilterField, sizeUnitLabel, sizeFilterButton, sizeHint])
        sizeFilterRow.orientation = .horizontal
        sizeFilterRow.alignment = .centerY
        sizeFilterRow.spacing = 8
        sizeFilterRow.heightAnchor.constraint(equalToConstant: 36).isActive = true
        sizeFilterRow.isHidden = true

        let contentStack = NSStackView(views: [sizeFilterRow, scrollView])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 7
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        selectAllButton = MetalButton(title: "Select All", target: self, action: #selector(toggleSelectAll))
        selectAllButton.translatesAutoresizingMaskIntoConstraints = false
        selectAllButton.widthAnchor.constraint(equalToConstant: 128).isActive = true
        selectAllButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        selectAllButton.isHidden = true

        selectOlderButton = MetalButton(title: "Select >30 days", target: self, action: #selector(selectOlder))
        selectOlderButton.translatesAutoresizingMaskIntoConstraints = false
        selectOlderButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        selectOlderButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        selectOlderButton.isHidden = true

        operationButton = MetalButton(title: "Continue", target: self, action: #selector(confirmSelection), primary: true)
        operationButton.translatesAutoresizingMaskIntoConstraints = false
        operationButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 164).isActive = true
        operationButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        operationButton.isHidden = true

        revealDockerButton = MetalButton(title: "Reveal Docker.raw", target: self, action: #selector(revealDocker))
        revealDockerButton.translatesAutoresizingMaskIntoConstraints = false
        revealDockerButton.widthAnchor.constraint(equalToConstant: 152).isActive = true
        revealDockerButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        revealDockerButton.isHidden = true

        systemSettingsButton = MetalButton(title: "System Settings", target: self, action: #selector(openSettings))
        systemSettingsButton.translatesAutoresizingMaskIntoConstraints = false
        systemSettingsButton.widthAnchor.constraint(equalToConstant: 148).isActive = true
        systemSettingsButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        systemSettingsButton.isHidden = true

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [selectAllButton, selectOlderButton, footerSpacer, revealDockerButton, systemSettingsButton, operationButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView(views: [titleLabel, titleSpacer, stateLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(eyebrowLabel)
        addSubview(titleRow)
        addSubview(summaryLabel)
        addSubview(contentStack)
        addSubview(footer)

        NSLayoutConstraint.activate([
            eyebrowLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            eyebrowLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            eyebrowLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),

            titleRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            titleRow.heightAnchor.constraint(equalToConstant: 22),

            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            summaryLabel.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 4),
            summaryLabel.heightAnchor.constraint(equalToConstant: 17),

            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 5),
            contentStack.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -7),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 36)
        ])

        heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let preferredHeight = heightAnchor.constraint(equalToConstant: 300)
        preferredHeight.priority = .defaultHigh
        preferredHeight.isActive = true
    }

    override func layout() {
        super.layout()
        if let checklistView {
            resizeChecklistView(checklistView)
        } else {
            resizeOutputView()
        }
    }

    func present(
        title: String,
        summary: String,
        output: String,
        success: Bool,
        running: Bool = false,
        showsSystemActions: Bool = false,
        showsSystemSettings: Bool = false
    ) {
        selectionHandler = nil
        sizeFilterHandler = nil
        sizeFilterRow.isHidden = true
        selectionButtons.removeAll()
        selectionDates.removeAll()
        checklistView = nil
        checklistWidthConstraint = nil
        scrollView.documentView = outputView
        selectAllButton.isHidden = true
        selectOlderButton.isHidden = true
        operationButton.isHidden = true
        operationButton.isEnabled = false
        revealDockerButton.isHidden = !showsSystemActions
        systemSettingsButton.isHidden = !(showsSystemActions || showsSystemSettings)
        titleLabel.stringValue = title
        summaryLabel.stringValue = summary
        outputView.string = output.isEmpty ? "No output." : output
        resizeOutputView()
        outputView.scrollRangeToVisible(NSRange(location: 0, length: 0))

        if running {
            stateLabel.stringValue = "RUNNING"
            stateLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.28, alpha: 1)
        } else if title == "Memory Snapshot" {
            stateLabel.stringValue = "CAPTURED"
            stateLabel.textColor = NSColor(calibratedRed: 0.38, green: 0.95, blue: 0.78, alpha: 1)
        } else if success {
            stateLabel.stringValue = "COMPLETE"
            stateLabel.textColor = NSColor(calibratedRed: 0.38, green: 0.95, blue: 0.78, alpha: 1)
        } else {
            stateLabel.stringValue = "ATTENTION"
            stateLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.42, alpha: 1)
        }
    }

    fileprivate func presentChecklist(
        title: String,
        summary: String,
        items: [DetailChecklistItem],
        actionTitle: String,
        allowsAgeSelection: Bool = false,
        minimumSizeMB: Double? = nil,
        onSizeFilter: ((Double) -> Void)? = nil,
        onAction: @escaping ([String]) -> Void
    ) {
        titleLabel.stringValue = title
        summaryLabel.stringValue = summary
        stateLabel.stringValue = "REVIEW"
        stateLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.28, alpha: 1)
        outputView.string = ""
        selectionHandler = onAction
        sizeFilterHandler = onSizeFilter
        sizeFilterRow.isHidden = minimumSizeMB == nil || onSizeFilter == nil
        if let minimumSizeMB {
            sizeFilterField.stringValue = String(minimumSizeMB)
            sizeFilterField.textColor = .labelColor
        }
        selectionButtons.removeAll()
        selectionDates.removeAll()
        selectAllButton.isHidden = items.isEmpty
        selectOlderButton.isHidden = !allowsAgeSelection || items.isEmpty
        setSelectAllButtonTitle("Select All")
        revealDockerButton.isHidden = true
        systemSettingsButton.isHidden = true
        operationButton.title = actionTitle
        operationButton.attributedTitle = NSAttributedString(
            string: actionTitle,
            attributes: [
                .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1),
                .font: NSFont.systemFont(ofSize: 14, weight: .medium)
            ]
        )
        operationButton.isHidden = false
        operationButton.isEnabled = false
        operationButton.toolTip = actionTitle
        operationButton.invalidateIntrinsicContentSize()

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.distribution = .fill
        list.spacing = 7
        list.translatesAutoresizingMaskIntoConstraints = false
        list.frame = NSRect(x: 0, y: 0, width: max(scrollView.contentView.bounds.width, 1), height: 1)
        checklistWidthConstraint = list.widthAnchor.constraint(equalToConstant: max(scrollView.contentView.bounds.width, 1))
        checklistWidthConstraint?.isActive = true

        if items.isEmpty && onSizeFilter != nil {
            let emptyLabel = NSTextField(wrappingLabelWithString: "No files match this size. Lower the MB value and select Filter.")
            emptyLabel.textColor = NSColor(calibratedWhite: 0.76, alpha: 1)
            emptyLabel.font = NSFont.systemFont(ofSize: 12)
            list.addArrangedSubview(emptyLabel)
            emptyLabel.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }

        for item in items {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(selectionChanged))
            checkbox.controlSize = .regular
            checkbox.isEnabled = item.selectable
            checkbox.toolTip = item.selectable ? "Select for review" : item.subtitle
            checkbox.setContentHuggingPriority(.required, for: .horizontal)

            let itemTitle = NSTextField(labelWithString: item.title)
            itemTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            itemTitle.textColor = NSColor(calibratedWhite: 0.94, alpha: 1)
            itemTitle.lineBreakMode = .byTruncatingTail
            itemTitle.maximumNumberOfLines = 1
            itemTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let itemSubtitle = NSTextField(wrappingLabelWithString: item.subtitle)
            itemSubtitle.font = NSFont.systemFont(ofSize: 9, weight: .regular)
            itemSubtitle.textColor = NSColor(calibratedWhite: 0.64, alpha: 1)
            itemSubtitle.maximumNumberOfLines = 2
            itemSubtitle.lineBreakMode = .byWordWrapping
            itemSubtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let labels = NSStackView(views: [itemTitle, itemSubtitle])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 2
            labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let row = NSStackView(views: [checkbox, labels])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                labels.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                itemTitle.widthAnchor.constraint(equalTo: labels.widthAnchor),
                itemSubtitle.widthAnchor.constraint(equalTo: labels.widthAnchor)
            ])
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            selectionButtons[item.id] = checkbox
            if let modifiedAtMs = item.modifiedAtMs { selectionDates[item.id] = modifiedAtMs }
        }

        checklistView = list
        scrollView.documentView = list
        resizeChecklistView(list)
        selectionChanged()
        let topY = list.isFlipped ? 0 : max(0, list.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: topY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func applySizeFilter() {
        let rawValue = sizeFilterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(rawValue), value.isFinite, value >= 0,
              value <= 9_007_199_254 else {
            sizeFilterField.textColor = .systemRed
            stateLabel.stringValue = "INVALID MB VALUE"
            operationButton.isEnabled = false
            return
        }
        sizeFilterHandler?(value)
    }

    @objc private func selectionChanged() {
        let selectedCount = selectionButtons.values.filter { $0.state == .on }.count
        stateLabel.stringValue = "\(selectedCount) SELECTED"
        let selectableCount = selectionButtons.values.filter { $0.isEnabled }.count
        selectAllButton.isEnabled = selectableCount > 0
        setSelectAllButtonTitle(selectedCount > 0 && selectedCount == selectableCount ? "Deselect All" : "Select All")
        operationButton.isEnabled = selectedCount > 0
    }

    @objc private func toggleSelectAll() {
        guard !selectionButtons.isEmpty else { return }
        let selectAll = selectionButtons.values.contains { $0.isEnabled && $0.state != .on }
        for checkbox in selectionButtons.values where checkbox.isEnabled {
            checkbox.state = selectAll ? .on : .off
        }
        selectionChanged()
    }

    @objc private func selectOlder() {
        let cutoff = Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970 * 1000
        for (id, checkbox) in selectionButtons {
            guard checkbox.isEnabled else { continue }
            if let modifiedAtMs = selectionDates[id], modifiedAtMs < cutoff { checkbox.state = .on }
        }
        selectionChanged()
    }

    private func setSelectAllButtonTitle(_ title: String) {
        selectAllButton.title = title
        selectAllButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1),
                .font: NSFont.systemFont(ofSize: 14, weight: .medium)
            ]
        )
        selectAllButton.toolTip = title
    }

    @objc private func confirmSelection() {
        let selected = selectionButtons.compactMap { key, button in button.state == .on ? key : nil }
        guard !selected.isEmpty else { return }
        selectionHandler?(selected)
    }

    @objc private func revealDocker() {
        onRevealDockerDisk?()
    }

    @objc private func openSettings() {
        onOpenSystemSettings?()
    }

    private func resizeOutputView() {
        let width = max(scrollView.contentView.bounds.width, 1)
        let fittingSize = outputView.attributedString().boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        let height = max(scrollView.contentView.bounds.height, ceil(fittingSize.height) + 2)
        outputView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        outputView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        outputView.needsDisplay = true
    }

    private func resizeChecklistView(_ list: NSStackView) {
        let width = max(scrollView.contentView.bounds.width, 1)
        checklistWidthConstraint?.constant = width
        let rowHeight: CGFloat = 62
        let height = max(CGFloat(list.arrangedSubviews.count) * rowHeight, scrollView.contentView.bounds.height)
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        list.needsLayout = true
        list.layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class ActionCardView: MetalCardView {
    init(
        iconName: String,
        title: String,
        detail: String,
        buttonTitle: String,
        target: AnyObject?,
        action: Selector,
        primary: Bool = false,
        compact: Bool = false
    ) {
        super.init(frame: .zero)

        let iconPlate = NSView()
        iconPlate.wantsLayer = true
        iconPlate.layer?.backgroundColor = NSColor(
            calibratedRed: 0.12,
            green: 0.28,
            blue: 0.4,
            alpha: 0.72
        ).cgColor
        iconPlate.layer?.cornerRadius = 8
        iconPlate.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(
            image: NSImage(systemSymbolName: iconName, accessibilityDescription: title) ?? NSImage()
        )
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = NSColor(calibratedRed: 0.45, green: 0.86, blue: 1.0, alpha: 1)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconPlate.addSubview(icon)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: iconPlate.leadingAnchor, constant: 7),
            icon.trailingAnchor.constraint(equalTo: iconPlate.trailingAnchor, constant: -7),
            icon.topAnchor.constraint(equalTo: iconPlate.topAnchor, constant: 7),
            icon.bottomAnchor.constraint(equalTo: iconPlate.bottomAnchor, constant: -7)
        ])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let button = MetalButton(
            title: buttonTitle,
            target: target,
            action: action,
            primary: primary
        )
        button.alignment = .center
        button.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconPlate)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(button)

        NSLayoutConstraint.activate([
            iconPlate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconPlate.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            iconPlate.widthAnchor.constraint(equalToConstant: 36),
            iconPlate.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.leadingAnchor.constraint(equalTo: iconPlate.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: compact ? button.leadingAnchor : trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 19),

            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            button.widthAnchor.constraint(equalToConstant: 108),
            button.heightAnchor.constraint(equalToConstant: 36)
        ])

        detailLabel.isHidden = compact
        if !compact {
            NSLayoutConstraint.activate([
                detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
                detailLabel.topAnchor.constraint(equalTo: topAnchor, constant: 55)
            ])
        }
        heightAnchor.constraint(equalToConstant: compact ? 70 : 116).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class MetalButton: NSButton {
    private let primary: Bool
    private var isHovered = false

    init(title: String, target: AnyObject?, action: Selector, primary: Bool = false) {
        self.primary = primary
        super.init(frame: .zero)

        self.title = title
        self.target = target
        self.action = action
        self.isBordered = false
        self.bezelStyle = .rounded
        self.focusRingType = .none
        self.controlSize = .large
        self.alignment = .center
        self.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        self.contentTintColor = NSColor(calibratedWhite: 0.94, alpha: 1)
        self.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1),
                .font: NSFont.systemFont(ofSize: 14, weight: .medium)
            ]
        )
        self.toolTip = title
    }

    required init?(coder: NSCoder) {
        self.primary = false
        super.init(coder: coder)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 32, height: 36)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil
            )
        )
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        let colors: [NSColor]
        if primary {
            colors = isHovered
                ? [
                    NSColor(calibratedRed: 0.18, green: 0.67, blue: 0.95, alpha: 1),
                    NSColor(calibratedRed: 0.04, green: 0.31, blue: 0.62, alpha: 1)
                ]
                : [
                    NSColor(calibratedRed: 0.12, green: 0.52, blue: 0.82, alpha: 1),
                    NSColor(calibratedRed: 0.035, green: 0.24, blue: 0.5, alpha: 1)
                ]
        } else {
            colors = isHovered
                ? [
                    NSColor(calibratedRed: 0.18, green: 0.28, blue: 0.39, alpha: 1),
                    NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.24, alpha: 1)
                ]
                : [
                    NSColor(calibratedRed: 0.12, green: 0.19, blue: 0.28, alpha: 1),
                    NSColor(calibratedRed: 0.065, green: 0.105, blue: 0.16, alpha: 1)
                ]
        }
        NSGradient(colors: colors)?.draw(in: path, angle: 90)

        let border = primary
            ? NSColor(calibratedRed: 0.34, green: 0.78, blue: 1.0, alpha: 0.7)
            : NSColor(calibratedRed: 0.38, green: 0.55, blue: 0.7, alpha: 0.42)
        border.setStroke()
        path.lineWidth = 1
        path.stroke()

        super.draw(dirtyRect)
    }
}
