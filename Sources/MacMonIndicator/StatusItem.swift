import AppKit

/// Owns the NSStatusItem. The content is rasterized into an image only when the text or colors
/// change. With no warnings it is a template image, so macOS tints it for every menu bar
/// (light/dark, each display) without asking us to redraw.
final class StatusItemController {
    let item: NSStatusItem
    let renderer = StatusRenderer()
    private var lastKey = ""
    private var cells: [StatusRenderer.Cell] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var renderedDark = false
    private var renderedTemplate = true

    private func isDark(_ view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    init(menu: NSMenu) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu // left and right click open the same native menu
        if let button = item.button {
            button.imagePosition = .imageOnly
            // Colored (warning) images are drawn for one appearance, so redraw when the menu bar switches
            // between light and dark. Setting the image also fires this observer, so compare first.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] button, _ in
                DispatchQueue.main.async {
                    guard let self, self.isDark(button) != self.renderedDark, self.renderedTemplate == false else { return }
                    self.render(force: true)
                }
            }
        }
        applySettings()
    }

    private var shown: [(value: Float, time: TimeInterval)] = []
    private static let maxStale: TimeInterval = 60

    func applySettings() {
        let s = Settings.shared
        let look = s.barLook
        renderer.configure(metrics: s.barMetrics, icons: s.showIcons, twoLines: s.twoLines, look: look)
        // Fixed length instead of variableLength: macOS pads image items by ~8 pt per side; this
        // uses the configurable edge padding instead.
        item.length = renderer.width + look.edge * 2
        cells = renderer.metrics.map { _ in .init(text: Fmt.dash, level: .normal) }
        shown = renderer.metrics.map { _ in (.nan, 0) }
        lastKey = ""
        render(force: true)
    }

    func update(_ sample: Sample?) {
        let settings = Settings.shared
        let t = settings.thresholds
        guard let s = sample else {
            cells = renderer.metrics.map { _ in .init(text: Fmt.dash, level: .normal) }
            render(force: false)
            return
        }
        let steady = settings.steadyMenuBar
        for (i, m) in renderer.metrics.enumerated() where i < cells.count {
            let v = m.value(s), level = m.level(s, t)
            let old = shown[i]
            // Steady mode keeps the shown number until it moves by a meaningful step, the warning
            // level changes, or it is a minute old. Every redraw costs macOS ~20 ms of CPU.
            let changed = !steady || level != cells[i].level || old.value.isFinite != v.isFinite
                || abs(v - old.value) >= m.step(from: old.value) || s.time - old.time >= Self.maxStale
            if changed {
                cells[i] = .init(text: m.text(s), level: level)
                shown[i] = (v, s.time)
            }
        }
        render(force: false)
    }

    private func render(force: Bool) {
        let key = cells.map { "\($0.text)\($0.level.rawValue)" }.joined(separator: "|")
        guard force || key != lastKey, let button = item.button else { return }
        lastKey = key
        let template = cells.allSatisfy { $0.level == .normal }
        renderedTemplate = template
        renderedDark = isDark(button)
        var image: NSImage?
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            image = renderer.image(cells: cells, template: template)
        }
        button.image = image
        button.toolTip = zip(renderer.metrics, cells).map { "\($0.title): \($1.text)" }.joined(separator: "\n")
    }
}

/// How the menu bar item looks. Adjustable in Settings.
struct BarLook: Equatable {
    var size: CGFloat = 9       // text size in pt for two lines (one line uses size + 3)
    var lineGap: CGFloat = 5    // space between the two lines, pt
    var itemGap: CGFloat = 8    // space between columns, pt
    var opacity: CGFloat = 1    // 0.3 … 1
    var edge: CGFloat = 3       // empty space left and right of the whole item, pt
}

/// Draws the metrics as a grid: two rows (F1 layout) or one row, icon + right-aligned value per cell.
final class StatusRenderer {
    struct Cell { var text: String; var level: Level }

    static let height: CGFloat = 22
    private(set) var metrics: [BarMetric] = []
    private var icons = true
    private var twoLines = true
    private var look = BarLook()
    private var font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private var iconWidths: [CGFloat] = []    // per column: widest icon in that column
    private var iconGap: CGFloat = 2.5
    private var valueWidths: [CGFloat] = []   // per column
    private var columns = 0
    private var symbols: [String: NSImage] = [:]
    private(set) var width: CGFloat = 22

    private let pad: CGFloat = 1

    func configure(metrics: [BarMetric], icons: Bool, twoLines: Bool, look: BarLook) {
        self.metrics = metrics
        self.icons = icons
        self.twoLines = twoLines && metrics.count > 1
        self.look = look
        // Rows are laid out on the digits' cap height, not the full line height (digits have no
        // descenders), which is why fairly large text fits two lines into 22 pt.
        let size = self.twoLines ? look.size : look.size + 3
        font = .monospacedDigitSystemFont(ofSize: size, weight: self.twoLines ? .semibold : .medium)
        iconGap = max(1.5, (size * 0.22).rounded())
        symbols = [:]
        let rows = self.twoLines ? 2 : 1
        columns = max(1, (metrics.count + rows - 1) / rows)
        // Each column's icon box is as wide as its widest icon, so narrow icons (thermometer,
        // bolt) don't get empty space on both sides. Very wide symbols are capped.
        let symbolCfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        iconWidths = (0..<columns).map { c in
            (0..<rows).compactMap { r -> CGFloat? in
                let i = c * rows + r
                guard i < metrics.count,
                      let img = NSImage(systemSymbolName: metrics[i].symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(symbolCfg) else { return nil }
                return min(ceil(img.size.width), (size * 1.5).rounded())
            }.max() ?? 0
        }
        valueWidths = (0..<columns).map { c in
            (0..<rows).compactMap { r -> CGFloat? in
                let i = c * rows + r
                guard i < metrics.count else { return nil }
                return ceil((metrics[i].widthTemplate as NSString).size(withAttributes: [.font: font]).width)
            }.max() ?? 0
        }
        let iconPart = icons ? iconWidths.reduce(0) { $0 + $1 + iconGap } : 0
        let content = valueWidths.reduce(0, +) + iconPart + CGFloat(max(0, columns - 1)) * look.itemGap
        width = metrics.isEmpty ? 22 : ceil(content + pad * 2)
    }

    /// Solid color for a level (opacity is applied to the whole image).
    private func color(_ l: Level, template: Bool) -> NSColor {
        if template { return .black } // macOS tints template images; only the alpha matters
        switch l {
        case .normal: return .labelColor
        case .warn: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// SF Symbol at the text's point size (symbols are designed to match text of the same size),
    /// drawn in one solid color. Cached per symbol and color.
    private func symbol(_ name: String, _ level: Level, template: Bool, color: NSColor) -> NSImage? {
        let key = "\(name)|\(template ? -1 : level.rawValue)"
        if let img = symbols[key] { return img }
        let cfg = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        symbols[key] = img
        return img
    }

    /// Rasterizes the cells at 2x. Call inside the target appearance so dynamic colors resolve correctly.
    func image(cells: [Cell], template: Bool) -> NSImage {
        let size = NSSize(width: width, height: Self.height)
        let scale: CGFloat = 2
        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        ctx.scaleBy(x: scale, y: scale) // a bitmap context works in pixels; draw in points
        // Opacity applies to the finished drawing at once, so icons and text fade the same.
        ctx.setAlpha(look.opacity)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        draw(cells: cells, in: CGRect(origin: .zero, size: size), ctx: ctx, template: template)
        ctx.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        image.isTemplate = template
        return image
    }

    private func px(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 } // snap to device pixels (2x)

    private func draw(cells: [Cell], in bounds: CGRect, ctx: CGContext, template: Bool) {
        guard !metrics.isEmpty else { return }
        let rows = twoLines ? 2 : 1
        let cap = font.capHeight
        let mid = bounds.height / 2
        // Baselines: two lines are centered as a block of (cap + gap + cap); one line centers its cap.
        let gap = min(look.lineGap, bounds.height - 2 * cap - 1)
        let baselines = twoLines ? [px(mid + gap / 2), px(mid - gap / 2 - cap)] : [px(mid - cap / 2)]
        var x = pad
        for c in 0..<columns {
            for r in 0..<rows {
                let i = c * rows + r
                guard i < metrics.count, i < cells.count else { continue }
                let cell = cells[i]
                let col = color(cell.level, template: template)
                let baseline = baselines[r]
                var cx = x
                if icons {
                    let iconW = iconWidths[c]
                    if let img = symbol(metrics[i].symbol, cell.level, template: template, color: col) {
                        var w = img.size.width, h = img.size.height
                        if w > iconW { h *= iconW / w; w = iconW } // very wide symbols shrink to fit the box
                        let fit = CGRect(x: px(cx + (iconW - w) / 2), y: px(baseline + cap / 2 - h / 2), width: w, height: h)
                        img.draw(in: fit)
                    }
                    cx += iconW + iconGap
                }
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: col]
                let str = cell.text as NSString
                // Left-aligned next to its icon. The column keeps a fixed width (widest possible value),
                // so the next column never shifts when a number gets longer.
                // draw(at:) takes the bottom of the line box, which sits `descender` below the baseline.
                str.draw(at: NSPoint(x: cx, y: baseline + font.descender), withAttributes: attrs)
            }
            x += (icons ? iconWidths[c] + iconGap : 0) + valueWidths[c] + look.itemGap
        }
    }
}
