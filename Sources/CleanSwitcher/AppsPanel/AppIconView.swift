import Cocoa

protocol AppIconViewDelegate: AnyObject {
    func appClicked(_ id: String)
    /// `center` in the canvas's (flipped) coordinates.
    func appDragged(_ id: String, to center: CGPoint)
    func appDragEnded(_ id: String)
    /// The cursor came onto it, or left it.
    func appHovered(_ id: String, _ inside: Bool)
    /// A right click — a two-finger tap — on it.
    func appRightClicked(_ id: String)
    /// The cursor moved on it — the user's hand, not a warp or a relayout.
    func appCursorMoved(_ id: String)
}

/// One app's icon on the canvas: full while pinned, lighter while recent. Click opens,
/// drag moves.
final class AppIconView: NSView {
    let id: String
    weak var delegate: AppIconViewDelegate?

    private let iconLayer = CALayer()
    private let backdrop = CALayer()       // the hover's plate behind the icon, like Cmd+Tab's
    private let chip = CALayer()           // its letters, on the icon's bottom edge
    private let chipText = CATextLayer()
    private let icon: NSImage
    private var renderedPixels = 0
    private var dragStart: (mouse: CGPoint, center: CGPoint)?
    private var dragMoved = false

    var recent = false { didSet { updateLook() } }
    private var hovered = false { didSet { updateLook() } }

    /// Recent: faded. Hovered: a plate behind it, or a white glow — as set in Preferences.
    private func updateLook() {
        let style = hovered ? Preferences.appsHoverStyle : .none
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.opacity = recent ? 0.5 : 1
        backdrop.isHidden = style != .backdrop
        let inset = -bounds.width * 0.03
        backdrop.frame = bounds.insetBy(dx: inset, dy: inset)
        backdrop.cornerRadius = backdrop.frame.width * 0.25
        iconLayer.shadowColor = (style == .glow ? NSColor.white : NSColor.black).cgColor
        iconLayer.shadowOpacity = style == .glow ? 0.9 : 0.45
        iconLayer.shadowRadius = style == .glow ? bounds.width * 0.16 : 6
        CATransaction.commit()
    }

    override var isFlipped: Bool { true }

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    init(id: String, icon: NSImage) {
        self.id = id
        self.icon = icon
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        backdrop.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        backdrop.isHidden = true
        layer?.addSublayer(backdrop)
        layer?.addSublayer(iconLayer)
        iconLayer.contentsGravity = .resize
        iconLayer.shadowColor = NSColor.black.cgColor
        iconLayer.shadowOpacity = 0.45
        iconLayer.shadowRadius = 6
        iconLayer.shadowOffset = .zero
        chip.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
        chip.cornerRadius = 6
        chip.shadowOpacity = 0.45
        chip.shadowRadius = 3
        chip.shadowOffset = CGSize(width: 0, height: 2)
        chip.isHidden = true
        chipText.alignmentMode = .center
        chip.addSublayer(chipText)
        layer?.addSublayer(chip)
    }

    /// Its letters in a chip, the first `typed` of them faded; nil — no chip.
    func showLetters(_ letters: String?, typed: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chip.isHidden = letters == nil
        if let letters = letters {
            let font = NSFont.systemFont(ofSize: 12, weight: .bold)
            let text = NSMutableAttributedString(string: letters, attributes: [.font: font, .foregroundColor: NSColor(white: 0.07, alpha: 1), .kern: 0.5])
            text.addAttribute(.foregroundColor, value: NSColor(white: 0.07, alpha: 0.4), range: NSRange(location: 0, length: min(typed, letters.count)))
            let width = max(20, ceil(text.size().width) + 12)
            chip.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.height - 12, width: width, height: 18)
            chipText.frame = CGRect(x: 0, y: 2, width: width, height: 16)
            chipText.string = text
            chipText.contentsScale = window?.backingScaleFactor ?? 2
        }
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Its center at `center` (canvas coordinates), `size` wide.
    func place(center: CGPoint, size: CGFloat, animated: Bool) {
        let frame = backingAlignedRect(NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), options: .alignAllEdgesNearest)
        if animated, self.frame.size == frame.size {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
                animator().frame = frame
            }
        } else {
            self.frame = frame
        }

        // - The icon drawn at exactly its pixels, from its sharpest representation

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.frame = CGRect(origin: .zero, size: frame.size)
        let scale = window?.backingScaleFactor ?? 2, pixels = Int((size * scale).rounded())
        if pixels != renderedPixels, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current?.imageInterpolation = .high
            icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            iconLayer.contents = bitmap.cgImage
            renderedPixels = pixels
        }
        iconLayer.contentsScale = scale
        CATransaction.commit()

        // - Hovered as the cursor is now: a move under a still cursor sends no enter or exit

        if let window = window { hovered = !isHidden && frame.contains(superview?.convert(window.mouseLocationOutsideOfEventStream, from: nil) ?? .zero) }
    }

    // - Input: a move under 5pt is a click

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview.map({ convert(point, from: $0) }) else { return nil }
        return bounds.insetBy(dx: bounds.width * 0.1, dy: bounds.height * 0.1).contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; delegate?.appHovered(id, true) }
    override func mouseExited(with event: NSEvent) { hovered = false; delegate?.appHovered(id, false) }
    override func rightMouseDown(with event: NSEvent) { delegate?.appRightClicked(id) }
    override func mouseMoved(with event: NSEvent) { delegate?.appCursorMoved(id) }

    override func mouseDown(with event: NSEvent) {
        guard let canvas = superview else { return }
        dragStart = (canvas.convert(event.locationInWindow, from: nil), center)
        dragMoved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let canvas = superview, let start = dragStart else { return }
        let mouse = canvas.convert(event.locationInWindow, from: nil)
        if hypot(mouse.x - start.mouse.x, mouse.y - start.mouse.y) >= 5 { dragMoved = true }
        guard dragMoved else { return }
        delegate?.appDragged(id, to: CGPoint(x: start.center.x + mouse.x - start.mouse.x, y: start.center.y + mouse.y - start.mouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard dragStart != nil else { return }
        dragMoved ? delegate?.appDragEnded(id) : delegate?.appClicked(id)
    }
}
