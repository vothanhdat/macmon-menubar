import AppKit

// Hover read-outs change up to 120 times a second (once per pointer move). Redrawing even a small
// part of an NSView on every move costs AppKit several milliseconds (it records the drawing,
// compares it with the last one and replays it), so they are drawn in plain Core Animation layers
// instead: a cursor layer only moves, and a text layer redraws only its own few pixels.

/// A plain layer without implicit animations: changes show at once.
class StillLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

/// Draws with AppKit (NSString, dynamic colors) in its host view's appearance and in the host's
/// flipped coordinates, so the same drawing code works here and in a view's draw(_:).
final class TextLayer: StillLayer {
    weak var host: NSView?
    private var drawing: (() -> Void)?

    /// Draw count and time, collected while MemoryProbe is on (see MenuCycler).
    static var stats = (count: 0, seconds: 0.0)

    /// Shows `drawing` within `rect` (host coordinates), or hides the layer for nil.
    func show(_ rect: CGRect?, _ drawing: @escaping () -> Void) {
        guard let rect else {
            isHidden = true
            self.drawing = nil
            return
        }
        isHidden = false
        frame = rect.insetBy(dx: -1, dy: -1).integral // room for antialiasing, on whole points
        self.drawing = drawing
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        guard let host, let drawing else { return }
        let t0 = MemoryProbe.enabled ? CACurrentMediaTime() : 0
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        host.effectiveAppearance.performAsCurrentDrawingAppearance(drawing)
        NSGraphicsContext.restoreGraphicsState()
        if MemoryProbe.enabled {
            Self.stats.count += 1
            Self.stats.seconds += CACurrentMediaTime() - t0
        }
    }
}

/// A transparent view that hosts plain layers in its own (flipped) coordinates. It ignores the
/// mouse, so events reach the views below.
class LayerHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // AppKit flips the hosted layer's geometry to match, so sublayers use the view's coordinates.
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func addTextLayer() -> TextLayer {
        let t = TextLayer()
        t.host = self
        t.isHidden = true
        t.contentsScale = window?.backingScaleFactor ?? 2
        layer?.addSublayer(t)
        return t
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        restyle()
    }

    /// Text resolution and colors, after the appearance or the screen changed.
    func restyle() {
        let scale = window?.backingScaleFactor ?? 2
        for case let t as TextLayer in layer?.sublayers ?? [] {
            t.contentsScale = scale
            t.setNeedsDisplay()
        }
    }
}
