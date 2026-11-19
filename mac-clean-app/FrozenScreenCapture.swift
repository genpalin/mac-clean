import AppKit
import ScreenCaptureKit

struct FrozenDisplaySnapshot {
    let screenFrame: CGRect
    let image: NSImage
    let scaleFactor: CGFloat
}

enum FrozenScreenCaptureError: LocalizedError {
    case noDisplays
    case displayUnavailable(String)
    case unsupportedOperatingSystem

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            "macOS did not report any displays to capture."
        case .displayUnavailable(let name):
            "Could not freeze the display named \(name). Check Screen & System Audio Recording access and try again."
        case .unsupportedOperatingSystem:
            "Frozen screen capture requires macOS 14 or later."
        }
    }
}

@MainActor
enum FrozenScreenCapture {
    static func captureDisplays() async throws -> [FrozenDisplaySnapshot] {
        guard #available(macOS 14.0, *) else {
            throw FrozenScreenCaptureError.unsupportedOperatingSystem
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw FrozenScreenCaptureError.noDisplays }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        var snapshots: [FrozenDisplaySnapshot] = []
        for screen in screens {
            guard
                let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                let display = content.displays.first(where: { $0.displayID == screenNumber.uint32Value })
            else {
                throw FrozenScreenCaptureError.displayUnavailable(screen.localizedName)
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scaleFactor = max(screen.backingScaleFactor, 1)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int((screen.frame.width * scaleFactor).rounded()))
            configuration.height = max(1, Int((screen.frame.height * scaleFactor).rounded()))
            configuration.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            snapshots.append(
                FrozenDisplaySnapshot(
                    screenFrame: screen.frame,
                    image: NSImage(cgImage: cgImage, size: screen.frame.size),
                    scaleFactor: scaleFactor
                )
            )
        }

        return snapshots
    }

    static func fullScreenImage(from displays: [FrozenDisplaySnapshot], at point: CGPoint) -> NSImage? {
        guard !displays.isEmpty else { return nil }
        return FrozenScreenshotSelectionSession(displays: displays).fullScreenImage(at: point)
    }
}

private final class FrozenCaptureWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onEscape {
            onEscape()
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

@MainActor
final class FrozenScreenshotSelectionWindowController: NSWindowController {
    private let session: FrozenScreenshotSelectionSession
    private var overlayWindows: [FrozenCaptureWindow] = []
    private var selectionViews: [FrozenScreenshotSelectionView] = []
    private var didComplete = false
    var onComplete: ((NSImage?) -> Void)?

    init(displays: [FrozenDisplaySnapshot]) {
        let session = FrozenScreenshotSelectionSession(displays: displays)
        self.session = session
        let firstDisplay = displays[0]
        let window = FrozenCaptureWindow(
            contentRect: firstDisplay.screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        for (index, display) in displays.enumerated() {
            let overlay = index == 0 ? window : FrozenCaptureWindow(
                contentRect: display.screenFrame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            Self.configure(overlay, for: display)
            let selectionView = FrozenScreenshotSelectionView(display: display, session: session)
            overlay.contentView = selectionView
            overlay.onEscape = { [weak self] in self?.finish(with: nil) }
            overlayWindows.append(overlay)
            selectionViews.append(selectionView)
        }

        session.onChange = { [weak self] in
            self?.selectionViews.forEach { $0.needsDisplay = true }
        }
        session.onSelection = { [weak self] image in self?.finish(with: image) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSelection() {
        guard let primaryWindow = window else { return }
        session.pointerMoved(to: NSEvent.mouseLocation)
        NSApp.activate(ignoringOtherApps: true)
        for overlay in overlayWindows where overlay !== primaryWindow {
            overlay.orderFrontRegardless()
        }
        showWindow(nil)
        primaryWindow.makeKeyAndOrderFront(nil)
        selectionViews.first?.windowDidBecomeActive()
    }

    private static func configure(_ window: FrozenCaptureWindow, for display: FrozenDisplaySnapshot) {
        window.title = "Select Frozen Screenshot"
        window.setFrame(display.screenFrame, display: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.acceptsMouseMovedEvents = true
    }

    private func finish(with image: NSImage?) {
        guard !didComplete else { return }
        didComplete = true
        let completion = onComplete
        onComplete = nil

        if let primaryWindow = window {
            for overlay in overlayWindows where overlay !== primaryWindow {
                overlay.onEscape = nil
                overlay.close()
            }
        }
        overlayWindows.removeAll()
        selectionViews.removeAll()
        close()
        completion?(image)
    }
}

@MainActor
private final class FrozenScreenshotSelectionSession {
    let displays: [FrozenDisplaySnapshot]
    private(set) var firstCorner: CGPoint?
    private(set) var pointerLocation: CGPoint?
    var onChange: (() -> Void)?
    var onSelection: ((NSImage?) -> Void)?

    init(displays: [FrozenDisplaySnapshot]) {
        self.displays = displays
    }

    var selection: CGRect? {
        guard let firstCorner, let pointerLocation else { return nil }
        return CGRect(
            x: firstCorner.x,
            y: firstCorner.y,
            width: pointerLocation.x - firstCorner.x,
            height: pointerLocation.y - firstCorner.y
        ).standardized
    }

    func pointerMoved(to point: CGPoint) {
        pointerLocation = point
        onChange?()
    }

    func selectCorner(at point: CGPoint) {
        pointerLocation = point
        guard let selection, selection.width >= 2, selection.height >= 2 else {
            if firstCorner == nil { firstCorner = point }
            onChange?()
            return
        }
        onSelection?(makeImage(for: selection))
    }

    func fullScreenImage(at point: CGPoint) -> NSImage? {
        let display = displays.first(where: { $0.screenFrame.contains(point) })
            ?? NSScreen.main.flatMap { mainScreen in
                displays.first(where: { $0.screenFrame == mainScreen.frame })
            }
            ?? displays.first
        guard let display else { return nil }
        return makeImage(for: display.screenFrame)
    }

    func contains(_ point: CGPoint, on display: FrozenDisplaySnapshot) -> Bool {
        display.screenFrame.contains(point)
    }

    func isBadgeDisplay(_ display: FrozenDisplaySnapshot, for selection: CGRect) -> Bool {
        guard let largest = displays.max(by: {
            intersectionArea($0.screenFrame, selection) < intersectionArea($1.screenFrame, selection)
        }) else { return false }
        return largest.screenFrame == display.screenFrame
    }

    private func makeImage(for selection: CGRect) -> NSImage? {
        let scale = displays
            .filter { intersectionArea($0.screenFrame, selection) > 0 }
            .map(\.scaleFactor)
            .max() ?? 1
        let pixelsWide = max(1, Int((selection.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((selection.height * scale).rounded(.up)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        bitmap.size = selection.size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: selection.size).fill()

        for display in displays {
            let intersection = display.screenFrame.intersection(selection)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { continue }

            let destination = display.screenFrame.offsetBy(dx: -selection.minX, dy: -selection.minY)
            let clipRect = intersection.offsetBy(dx: -selection.minX, dy: -selection.minY)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clipRect).addClip()
            display.image.draw(in: destination, from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }

        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: selection.size)
        result.addRepresentation(bitmap)
        return result
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        guard !overlap.isNull else { return 0 }
        return overlap.width * overlap.height
    }
}

@MainActor
private final class FrozenScreenshotSelectionView: NSView {
    private let display: FrozenDisplaySnapshot
    private let session: FrozenScreenshotSelectionSession
    private var trackingArea: NSTrackingArea?

    init(display: FrozenDisplaySnapshot, session: FrozenScreenshotSelectionSession) {
        self.display = display
        self.session = session
        super.init(frame: CGRect(origin: .zero, size: display.screenFrame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func windowDidBecomeActive() {
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        NSCursor.crosshair.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFrozenDisplay()

        NSColor.black.withAlphaComponent(0.30).setFill()
        bounds.fill()

        if let globalSelection = session.selection,
           globalSelection.width > 1,
           globalSelection.height > 1 {
            let localSelection = globalSelection.offsetBy(
                dx: -display.screenFrame.minX,
                dy: -display.screenFrame.minY
            )
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: localSelection).addClip()
            drawFrozenDisplay()
            NSGraphicsContext.restoreGraphicsState()

            NSColor(calibratedRed: 0.22, green: 0.79, blue: 1, alpha: 1).setStroke()
            let border = NSBezierPath(rect: localSelection)
            border.lineWidth = 1.5
            border.stroke()
            drawCornerHandles(for: globalSelection)
            if session.isBadgeDisplay(display, for: globalSelection) {
                drawSizeBadge(for: localSelection)
            }
        }

        drawCrosshairGuides()
        drawInstructions()
    }

    override func mouseMoved(with event: NSEvent) {
        session.pointerMoved(to: globalPoint(for: event))
        NSCursor.crosshair.set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        session.selectCorner(at: globalPoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        session.pointerMoved(to: globalPoint(for: event))
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        let localPoint = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: localPoint.x + display.screenFrame.minX,
            y: localPoint.y + display.screenFrame.minY
        )
    }

    private func drawFrozenDisplay() {
        display.image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }

    private func drawCrosshairGuides() {
        guard let pointerLocation = session.pointerLocation else { return }
        let guides = NSBezierPath()
        guides.lineWidth = 0.7
        guides.setLineDash([3, 4], count: 2, phase: 0)
        if pointerLocation.y >= display.screenFrame.minY, pointerLocation.y <= display.screenFrame.maxY {
            let localY = pointerLocation.y - display.screenFrame.minY
            guides.move(to: CGPoint(x: bounds.minX, y: localY))
            guides.line(to: CGPoint(x: bounds.maxX, y: localY))
        }
        if pointerLocation.x >= display.screenFrame.minX, pointerLocation.x <= display.screenFrame.maxX {
            let localX = pointerLocation.x - display.screenFrame.minX
            guides.move(to: CGPoint(x: localX, y: bounds.minY))
            guides.line(to: CGPoint(x: localX, y: bounds.maxY))
        }
        NSColor.white.withAlphaComponent(0.82).setStroke()
        guides.stroke()
    }

    private func drawInstructions() {
        let title = session.firstCorner == nil
            ? "Click the first corner  •  Esc cancels"
            : "Click the opposite corner to capture  •  Esc cancels"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = title.size(withAttributes: attributes)
        let rect = CGRect(
            x: bounds.midX - textSize.width / 2 - 14,
            y: bounds.maxY - 42,
            width: textSize.width + 28,
            height: 28
        )
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        title.draw(
            at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

    private func drawCornerHandles(for globalRect: CGRect) {
        let radius: CGFloat = 4
        for globalPoint in [
            CGPoint(x: globalRect.minX, y: globalRect.minY),
            CGPoint(x: globalRect.minX, y: globalRect.maxY),
            CGPoint(x: globalRect.maxX, y: globalRect.minY),
            CGPoint(x: globalRect.maxX, y: globalRect.maxY)
        ] where session.displays.first(where: { session.contains(globalPoint, on: $0) })?.screenFrame == display.screenFrame {
            let point = CGPoint(
                x: globalPoint.x - display.screenFrame.minX,
                y: globalPoint.y - display.screenFrame.minY
            )
            let handle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handle).fill()
        }
    }

    private func drawSizeBadge(for rect: CGRect) {
        let scale = session.displays
            .filter { !$0.screenFrame.intersection(rect.offsetBy(dx: display.screenFrame.minX, dy: display.screenFrame.minY)).isNull }
            .map(\.scaleFactor).max() ?? display.scaleFactor
        let title = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded())) px"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = title.size(withAttributes: attributes)
        let badgeSize = CGSize(width: textSize.width + 16, height: 24)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 7)
        if origin.y + badgeSize.height > bounds.maxY - 6 {
            origin.y = rect.minY - badgeSize.height - 7
        }
        origin.x = min(max(bounds.minX + 6, origin.x), bounds.maxX - badgeSize.width - 6)
        let badge = CGRect(origin: origin, size: badgeSize)
        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        title.draw(
            at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

}
