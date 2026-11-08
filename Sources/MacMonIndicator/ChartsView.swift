import AppKit

/// Charts the user can show in the menu, in their chosen order.
enum ChartID: String, CaseIterable {
    case cpu, gpu, ram, power, battery, temp, fans, disk, diskOps

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ram: return "RAM"
        case .power: return "Power"
        case .battery: return "Battery"
        case .temp: return "Temp"
        case .fans: return "Fans"
        case .disk: return "Disk"
        case .diskOps: return "Disk ops"
        }
    }
}

/// How the chart grid is arranged.
struct ChartLayout: Equatable {
    enum Value: String, CaseIterable {
        case chart   // whole value in a small chip at the chart's bottom-right
        case label   // whole value on the label row, right-aligned
        case split   // main value in the chart chip, details on the label row
    }
    var columns = 2
    var value: Value = .split
    /// Height of each chart in points; nil uses the default for the column count.
    var height: CGFloat?

    static let heightRange: ClosedRange<CGFloat> = 20...90
    var chartHeight: CGFloat { height ?? (columns == 1 ? 25 : 30) }
}

/// All charts drawn in one view. Each cell is a label row above a filled bar chart (avg solid,
/// max faint). Cells flow into 1 or 2 columns. Hovering shows the values at that moment in every
/// cell; clicking a chart shows it alone at full size, and another click goes back to the grid.
///
/// The bars change only when data arrives (once a second while the menu is open), but the pointer
/// can move 120 times a second. So the cursor and the values live in a separate overlay layer, and
/// moving the pointer redraws only the small parts of it that change, never the bars.
final class ChartsView: NSView {
    /// `smart` zooms to the range the data actually covers (at least `minSpan` wide), for slow
    /// metrics like temperature and RAM. It only applies when "Zoom Temp and RAM" is on in
    /// Settings; otherwise the `otherwise` scale is used.
    indirect enum Scale { case fixed(Float), auto(min: Float), ramTotal, fanMax, smart(minSpan: Float, otherwise: Scale) }
    enum Shape { case up, mirrored(Series), signed }

    struct Row {
        let id: ChartID
        let series: Series
        let shape: Shape
        let scale: Scale
        let color: NSColor
        let color2: NSColor?
        /// Main value (e.g. "9.1W") and optional details (e.g. "CPU 0.9 · GPU 0.2").
        let text: (_ value: (Series) -> Float, _ live: Sample?) -> (main: String, detail: String?)
        /// Formats axis labels: the data's min/max on smart-scaled charts, the scale on charts whose
        /// scale isn't a fixed full range (see `labelsScale`) and on a zoomed chart.
        private(set) var axisLabel: ((Float) -> String)?
        /// Warning limit drawn as a dashed line when it falls inside the visible range.
        private(set) var limit: ((Thresholds, Sample?) -> Float?)?

        var title: String { id.title }

        init(id: ChartID, series: Series, shape: Shape, scale: Scale, color: NSColor, color2: NSColor?,
             text: @escaping (_ value: (Series) -> Float, _ live: Sample?) -> (main: String, detail: String?)) {
            self.id = id; self.series = series; self.shape = shape; self.scale = scale
            self.color = color; self.color2 = color2; self.text = text
        }

        func with(axis: ((Float) -> String)? = nil, limit: ((Thresholds, Sample?) -> Float?)? = nil) -> Row {
            var r = self
            r.axisLabel = axis
            r.limit = limit
            return r
        }
    }

    private static let inset = Dashboard.inset, colGap: CGFloat = 10
    private static let titleH: CGFloat = 12, chartGap: CGFloat = 1, cellGap: CGFloat = 5
    /// A zoomed chart takes the grid's place, and is at least this tall.
    private static let minZoomedHeight: CGFloat = 150
    private static func cellH(_ layout: ChartLayout) -> CGFloat { titleH + chartGap + layout.chartHeight + cellGap }

    /// Height needed for `count` charts, or for one zoomed chart in their place.
    static func height(count: Int, layout: ChartLayout, zoomed: Bool = false) -> CGFloat {
        let rows = (count + layout.columns - 1) / max(1, layout.columns)
        let grid = CGFloat(rows) * cellH(layout) - cellGap + 2
        return zoomed ? max(grid, minZoomedHeight) : grid
    }

    /// The tallest whole-point chart height at which `count` charts fit in `height` (the inverse of
    /// `height(count:layout:)`), for a window that gives the charts its space.
    static func chartHeight(fitting height: CGFloat, count: Int, layout: ChartLayout) -> CGFloat {
        let rows = CGFloat(max(1, (count + layout.columns - 1) / max(1, layout.columns)))
        return floor((height - 2 + cellGap) / rows - titleH - chartGap - cellGap)
    }

    var rows: [Row] = [] {
        didSet {
            if let z = zoomed, !rows.contains(where: { $0.id == z }) { zoomed = nil }
            contentChanged()
        }
    }
    var layout = ChartLayout() { didSet { contentChanged() } }
    var tier = 0 { didSet { contentChanged() } }
    var latest: Sample? { didSet { contentChanged() } }
    var history: HistoryStore?
    var onHover: ((TimeInterval?) -> Void)?
    /// Called after a click zooms in or out; the view's height needs updating then.
    var onZoom: (() -> Void)?

    /// The chart shown alone at full size, or nil for the grid.
    private(set) var zoomed: ChartID? {
        didSet {
            guard zoomed != oldValue else { return }
            hoverIndex = nil
            contentChanged()
            onZoom?()
        }
    }

    /// Bucket under the pointer: its x position scaled to the bucket count, no searching.
    private var hoverIndex: Int? {
        didSet {
            guard hoverIndex != oldValue else { return }
            updateCursors()
            scheduleHoverValues()
        }
    }
    /// The cursor follows every pointer move; the values (and the time) at most 30 times a second,
    /// since text changing faster can't be read anyway. The last move always shows.
    private var lastHoverValues: CFTimeInterval = 0
    private var hoverValuesTimer: Timer?
    private let overlay = Overlay()
    private var avgBuf: [Float] = [], maxBuf: [Float] = [], avgBuf2: [Float] = [], maxBuf2: [Float] = []
    private var fitScale = false // Settings.zoomCharts, read once per draw
    private let titleFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private let axisAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                                                            .foregroundColor: NSColor.secondaryLabelColor]
    private lazy var axisLabelH = ceil(("0" as NSString).size(withAttributes: axisAttrs).height) - 1
    private let mainAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                            .foregroundColor: NSColor.labelColor]
    private let detailAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                              .foregroundColor: NSColor.secondaryLabelColor]
    private let chipAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
                                                            .foregroundColor: NSColor.labelColor]
    private lazy var hotMainAttrs = mainAttrs.merging([.foregroundColor: NSColor.systemRed]) { $1 }
    private lazy var hotChipAttrs = chipAttrs.merging([.foregroundColor: NSColor.systemRed]) { $1 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// In a window that isn't in front, the first click already zooms.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateOverlay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateOverlay()
    }

    private func contentChanged() {
        needsDisplay = true
        updateOverlay()
    }

    // MARK: - Geometry

    /// One chart on screen: its label row starts at `origin`, its bars fill `chart`.
    fileprivate struct Cell {
        let row: Row
        let origin: CGPoint
        let chart: CGRect
        /// Everything that belongs to this chart, for clicks.
        var frame: CGRect { CGRect(x: origin.x, y: origin.y, width: chart.width, height: chart.maxY - origin.y) }
    }

    /// The grid, or only the zoomed chart filling the view.
    fileprivate func cells() -> [Cell] {
        let top = Self.titleH + Self.chartGap
        if let z = zoomed, let row = rows.first(where: { $0.id == z }) {
            let w = bounds.width - Self.inset * 2
            return [Cell(row: row, origin: CGPoint(x: Self.inset, y: 0),
                         chart: CGRect(x: Self.inset, y: top, width: w, height: bounds.height - top - 2))]
        }
        let cols = max(1, layout.columns)
        let w = (bounds.width - Self.inset * 2 - Self.colGap * CGFloat(cols - 1)) / CGFloat(cols)
        return rows.enumerated().map { i, row in
            let o = CGPoint(x: Self.inset + CGFloat(i % cols) * (w + Self.colGap), y: CGFloat(i / cols) * Self.cellH(layout))
            return Cell(row: row, origin: o, chart: CGRect(x: o.x, y: o.y + top, width: w, height: layout.chartHeight))
        }
    }

    /// The hover cursor of bucket `h`.
    fileprivate func cursorRect(_ c: Cell, _ h: Int) -> CGRect {
        let bw = c.chart.width / CGFloat(HistoryStore.tiers[tier].capacity)
        return CGRect(x: c.chart.minX + (CGFloat(h) + 0.5) * bw - 0.5, y: c.chart.minY - 1, width: 1, height: c.chart.height + 2)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let cap = HistoryStore.tiers[tier].capacity
        // All charts share one time axis, so only the x position within a column matters.
        hoverIndex = cells().first { p.x >= $0.chart.minX && p.x < $0.chart.maxX }
            .map { min(cap - 1, max(0, Int((p.x - $0.chart.minX) / $0.chart.width * CGFloat(cap)))) }
    }

    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    // Menus deliver mouseUp to custom item views and stay open.
    override func mouseUp(with event: NSEvent) {
        if zoomed != nil {
            zoomed = nil
        } else {
            let p = convert(event.locationInWindow, from: nil)
            guard let c = cells().first(where: { $0.frame.contains(p) }) else { return }
            zoomed = c.row.id
        }
        mouseMoved(with: event) // the cursor at the pointer, in the new layout
    }

    // MARK: - Drawing

    /// Draw count and time, collected while MemoryProbe is on (see MenuCycler).
    static var drawStats = (count: 0, seconds: 0.0)

    /// The bars, scale and titles. The overlay shows the rest, except offscreen (snapshots), where
    /// there are no layers: then the values are drawn here too.
    override func draw(_ dirtyRect: NSRect) {
        let t0 = MemoryProbe.enabled ? CACurrentMediaTime() : 0
        defer { if MemoryProbe.enabled { Self.drawStats.count += 1; Self.drawStats.seconds += CACurrentMediaTime() - t0 } }
        guard let ctx = NSGraphicsContext.current?.cgContext, let history else { return }
        let now = Date().timeIntervalSince1970
        let cap = HistoryStore.tiers[tier].capacity
        let thresholds = Settings.shared.thresholds
        fitScale = Settings.shared.zoomCharts
        let isZoomed = zoomed != nil, offscreen = window == nil

        for c in cells() {
            let row = c.row, rect = c.chart
            let bw = rect.width / CGFloat(cap)

            (row.title as NSString).draw(at: NSPoint(x: c.origin.x, y: c.origin.y - 1),
                                         withAttributes: [.font: titleFont, .foregroundColor: NSColor.secondaryLabelColor])

            // Chart: rounded track tinted with the chart's color; everything below is clipped to it.
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.clip()
            ctx.setFillColor(row.color.withAlphaComponent(0.08).cgColor)
            ctx.fill(rect)

            history.window(tier: tier, series: row.series, now: now, avg: &avgBuf, max: &maxBuf)
            if case .mirrored(let down) = row.shape {
                history.window(tier: tier, series: down, now: now, avg: &avgBuf2, max: &maxBuf2)
            }
            let r = range(row)
            // The lower half of a mirrored chart (disk writes) has its own scale.
            var lowerHi = r.hi
            if case .mirrored = row.shape { lowerHi = range(row, lowerHalf: true).hi }
            let limit = row.limit?(thresholds, latest)
            switch row.shape {
            case .up:
                drawBars(ctx, rect, bw, avgBuf, maxBuf, r.lo, r.hi, row.color, from: .bottom, warn: warnRange(row, limit: limit))
            case .signed:
                drawBars(ctx, rect, bw, avgBuf, maxBuf, 0, r.hi, row.color, from: .center)
            case .mirrored:
                var top = rect; top.size.height /= 2
                var bottom = top; bottom.origin.y += top.height
                drawBars(ctx, top, bw, avgBuf, maxBuf, 0, r.hi, row.color, from: .bottom)
                drawBars(ctx, bottom, bw, avgBuf2, maxBuf2, 0, lowerHi, row.color2 ?? row.color, from: .top)
            }

            // Warning limit as a dashed line, if it is inside the visible range.
            if let limit, limit > r.lo, limit < r.hi {
                let y = rect.maxY - CGFloat((limit - r.lo) / (r.hi - r.lo)) * rect.height
                ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.55).cgColor)
                ctx.setLineWidth(0.75)
                ctx.setLineDash(phase: 0, lengths: [2, 2])
                ctx.strokeLineSegments(between: [CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)])
                ctx.setLineDash(phase: 0, lengths: [])
            }

            // Axis labels: smart-scaled charts don't start at zero, so they show what the top and
            // bottom mean. Charts whose scale follows the data or the Mac show it, as does a zoomed chart.
            var top: String?, bottom: String?
            if let fmt = row.axisLabel {
                if r.dataMin.isFinite, r.dataMax.isFinite {
                    top = fmt(r.dataMax); bottom = fmt(r.dataMin)
                } else if isZoomed || Self.labelsScale(row.scale) {
                    top = fmt(r.hi)
                    switch row.shape {
                    case .up: break
                    case .signed: bottom = fmt(-r.hi)
                    case .mirrored: bottom = fmt(lowerHi)
                    }
                }
            }
            if let top { drawAxisLabel(ctx, top, in: rect, atTop: true) }
            // A very short chart has room for one label only.
            if let bottom, top == nil || rect.height >= 2 * axisLabelH + 6 { drawAxisLabel(ctx, bottom, in: rect, atTop: false) }
            ctx.restoreGState()

            if offscreen {
                let v = values(row, now: now, thresholds: thresholds)
                if let line = labelLine(v, c) { drawLabel(v, line) }
                if let chip = v.chip { drawChip(chip, at: chipRect(chip, in: rect), hot: v.hot) }
            }
        }
    }

    /// An axis label in the chart's top- or bottom-left corner, on a translucent backing like the
    /// value chip so it stays readable over the bars.
    private func drawAxisLabel(_ ctx: CGContext, _ text: String, in rect: CGRect, atTop: Bool) {
        let w = (text as NSString).size(withAttributes: axisAttrs).width
        let box = CGRect(x: rect.minX + 2, y: atTop ? rect.minY + 1.5 : rect.maxY - axisLabelH - 1.5,
                         width: w + 4, height: axisLabelH)
        ctx.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        ctx.fillPath()
        (text as NSString).draw(at: NSPoint(x: box.minX + 2, y: box.minY), withAttributes: axisAttrs)
    }

    // MARK: - Cursor and values

    /// The value texts of one chart, placed as the layout setting says.
    fileprivate struct Values: Equatable {
        var labelMain: String?, labelDetail: String?, chip: String?
        /// The main value is at or over the warning limit: it shows in red, as in the menu bar.
        var hot = false
    }

    /// Values at the hovered moment, or live.
    private func values(_ row: Row, now: TimeInterval, thresholds: Thresholds) -> Values {
        let value: (Series) -> Float, live: Sample?
        if let h = hoverIndex, let history {
            value = { history.value(tier: self.tier, series: $0, index: h, now: now) }
            live = nil
        } else {
            let l = latest
            value = { l?.value($0) ?? .nan }
            live = l
        }
        let t = row.text(value, live)
        let hot = row.limit?(thresholds, latest).map { value(row.series) >= $0 } ?? false
        switch layout.value {
        case .chart: return Values(chip: [t.main, t.detail].compactMap { $0 }.joined(separator: " · "), hot: hot)
        case .label: return Values(labelMain: t.main, labelDetail: t.detail, hot: hot)
        case .split: return Values(labelDetail: t.detail, chip: t.main, hot: hot)
        }
    }

    private func scheduleHoverValues() {
        guard hoverValuesTimer == nil else { return }
        let wait = lastHoverValues + 1.0 / 30 - CACurrentMediaTime()
        guard wait > 0 else { showHoverValues(); return }
        let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            self?.hoverValuesTimer = nil
            self?.showHoverValues()
        }
        RunLoop.main.add(t, forMode: .common) // also while the menu tracks the mouse
        hoverValuesTimer = t
    }

    private func showHoverValues() {
        lastHoverValues = CACurrentMediaTime()
        updateOverlay()
        let now = Date().timeIntervalSince1970
        onHover?(hoverIndex.flatMap { history?.bucketStart(tier: tier, index: $0, now: now) })
    }

    private func updateCursors() {
        guard window != nil else { return }
        for (c, l) in zip(cells(), overlay.cells) {
            if let h = hoverIndex { l.cursor.frame = cursorRect(c, h) }
            l.cursor.isHidden = hoverIndex == nil
        }
    }

    /// Moves the cursors and redraws the value texts that changed, all in plain layers (see
    /// TextLayer.swift for why). The layers show the changes with the next screen refresh.
    private func updateOverlay() {
        // Offscreen (snapshots) there are no layers to show; draw(_:) draws the values then.
        overlay.isHidden = window == nil
        guard window != nil else { return }
        let cs = cells(), now = Date().timeIntervalSince1970, thresholds = Settings.shared.thresholds
        overlay.prepare(count: cs.count)
        for (c, l) in zip(cs, overlay.cells) {
            if let h = hoverIndex { l.cursor.frame = cursorRect(c, h) }
            l.cursor.isHidden = hoverIndex == nil
            let v = values(c.row, now: now, thresholds: thresholds)
            guard v != l.values || c.chart != l.chart || c.origin != l.origin else { continue }
            l.values = v
            l.chart = c.chart
            l.origin = c.origin
            let line = labelLine(v, c)
            l.label.show(line?.rect) { [weak self] in if let line { self?.drawLabel(v, line) } }
            let chip = v.chip.map { (text: $0, rect: chipRect($0, in: c.chart)) }
            l.chip.show(chip?.rect) { [weak self] in if let chip { self?.drawChip(chip.text, at: chip.rect, hot: v.hot) } }
        }
    }

    /// The label-row values, laid out right-aligned on the label row.
    private struct LabelLine { let rect: CGRect; let mainX: CGFloat; let detailX: CGFloat }

    private func labelLine(_ v: Values, _ c: Cell) -> LabelLine? {
        let mainW = v.labelMain.map { ($0 as NSString).size(withAttributes: mainAttrs).width } ?? 0
        let detailW = v.labelDetail.map { ($0 as NSString).size(withAttributes: detailAttrs).width } ?? 0
        guard mainW + detailW > 0 else { return nil }
        let mainX = c.chart.maxX - mainW
        let detailX = (v.labelMain != nil ? mainX - 6 : c.chart.maxX) - detailW
        return LabelLine(rect: CGRect(x: detailX, y: c.origin.y - 0.5, width: c.chart.maxX - detailX, height: 13),
                         mainX: mainX, detailX: detailX)
    }

    /// Main value in the label color (red when over the limit), details dimmer before it.
    private func drawLabel(_ v: Values, _ line: LabelLine) {
        (v.labelMain as NSString?)?.draw(at: NSPoint(x: line.mainX, y: line.rect.minY), withAttributes: v.hot ? hotMainAttrs : mainAttrs)
        (v.labelDetail as NSString?)?.draw(at: NSPoint(x: line.detailX, y: line.rect.minY), withAttributes: detailAttrs)
    }

    /// The value chip in the chart's bottom-right corner.
    private func chipRect(_ text: String, in rect: CGRect) -> CGRect {
        let size = (text as NSString).size(withAttributes: chipAttrs)
        return CGRect(x: rect.maxX - size.width - 8, y: rect.maxY - size.height - 3, width: size.width + 6, height: size.height + 1)
    }

    /// Small value chip, translucent so bars still show around it.
    private func drawChip(_ text: String, at chip: CGRect, hot: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.75).cgColor)
        ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
        (text as NSString).draw(at: NSPoint(x: chip.minX + 3, y: chip.minY + 0.5), withAttributes: hot ? hotChipAttrs : chipAttrs)
    }

    /// Over the charts: per chart a cursor layer, which only ever moves, and two small text
    /// layers, redrawn when their text changes.
    private final class Overlay: LayerHostView {
        final class CellLayers {
            let cursor = StillLayer(), label: TextLayer, chip: TextLayer
            var values: Values?
            var chart = CGRect.null, origin = CGPoint.zero
            init(label: TextLayer, chip: TextLayer) { self.label = label; self.chip = chip }
        }
        private(set) var cells: [CellLayers] = []

        /// One set of layers per chart on screen.
        func prepare(count: Int) {
            guard cells.count != count else { return }
            while cells.count > count {
                let c = cells.removeLast()
                [c.cursor, c.label, c.chip].forEach { $0.removeFromSuperlayer() }
            }
            while cells.count < count {
                let c = CellLayers(label: addTextLayer(), chip: addTextLayer())
                c.cursor.isHidden = true
                layer?.addSublayer(c.cursor)
                cells.append(c)
            }
            restyle()
        }

        override func restyle() {
            super.restyle()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let color = NSColor.labelColor.withAlphaComponent(0.6).cgColor
                for c in cells { c.cursor.backgroundColor = color }
            }
        }
    }

    /// Visible value range for a row (or for the lower half of a mirrored chart), plus the data's
    /// own min/max (for smart-scale labels).
    private func range(_ row: Row, lowerHalf: Bool = false) -> (lo: Float, hi: Float, dataMin: Float, dataMax: Float) {
        lowerHalf ? range(row.scale, avgBuf2, maxBuf2) : range(row.scale, avgBuf, maxBuf)
    }

    private func range(_ scale: Scale, _ avgs: [Float], _ peaks: [Float]) -> (lo: Float, hi: Float, dataMin: Float, dataMax: Float) {
        let maxAbs = { (b: [Float]) in b.lazy.filter(\.isFinite).map { abs($0) }.max() ?? 0 }
        switch scale {
        case .fixed(let v):
            return (0, v, .nan, .nan)
        case .ramTotal:
            return (0, latest?.ramTotalGB ?? max(1, maxAbs(peaks)), .nan, .nan)
        case .fanMax:
            return (0, (latest?.fanMax).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 6000, .nan, .nan)
        case .auto(let minV):
            return (0, Self.roundUp(max(minV, maxAbs(peaks) * 1.05)), .nan, .nan)
        case .smart(_, let otherwise) where !fitScale:
            return range(otherwise, avgs, peaks)
        case .smart(let minSpan, _):
            let lows = avgs.filter(\.isFinite), highs = peaks.filter(\.isFinite)
            guard let dMin = lows.min(), let dMax = highs.max() ?? lows.max() else { return (0, 1, .nan, .nan) }
            var lo = dMin, hi = max(dMax, dMin)
            if hi - lo < minSpan { let mid = (lo + hi) / 2; lo = mid - minSpan / 2; hi = mid + minSpan / 2 }
            let pad = (hi - lo) * 0.12
            return (max(0, lo - pad), hi + pad, dMin, dMax)
        }
    }

    /// Whether the grid labels a chart's scale: only scales that follow the data (power, battery,
    /// disk) or the Mac (fan max). 0–100% charts, temperature (0–100°) and RAM (0 to total) need
    /// none. With "Zoom Temp and RAM" on, those show the data's min and max instead.
    private static func labelsScale(_ scale: Scale) -> Bool {
        switch scale {
        case .auto, .fanMax: return true
        case .fixed, .ramTotal: return false
        case .smart(_, let otherwise): return labelsScale(otherwise)
        }
    }

    /// The next round number up (1, 1.5, 2, 2.5, 3, 4, 5, 6 or 8 times a power of ten), so a
    /// scale label reads "20W", not "17.3W".
    static func roundUp(_ v: Float) -> Float {
        guard v > 0, v.isFinite else { return v }
        let p = pow(10, floor(log10(v)))
        return ([1, 1.5, 2, 2.5, 3, 4, 5, 6, 8] as [Float]).first { $0 * p >= v * 0.9999 }.map { $0 * p } ?? 10 * p
    }

    private enum Anchor { case bottom, top, center }

    /// How far below the warning limit bars start turning red, as a share of the chart's full
    /// (unzoomed) scale: 25 points for percentages and temperatures, a quarter of total RAM.
    private static let warnBand: Float = 0.25

    /// Where the red blend starts and ends for a row, or nil without a limit.
    private func warnRange(_ row: Row, limit: Float?) -> (start: Float, limit: Float)? {
        guard let limit, limit > 0 else { return nil }
        var full = row.scale
        if case .smart(_, let otherwise) = full { full = otherwise }
        return (max(0, limit - Self.warnBand * range(full, avgBuf, maxBuf).hi), limit)
    }

    /// Bars per bucket, no smoothing: a faint layer for the bucket max, a gradient fill for the
    /// average (strong at the tip, nearly clear at the base), and a crisp stepped edge on top.
    ///
    /// With a warning range (`warn`), the color follows the value: the chart's color below
    /// `start`, blending into red up to `limit`, red from there up. It depends on the value, not on
    /// the bar's height, so it means the same on a zoomed-in scale.
    private func drawBars(_ ctx: CGContext, _ rect: CGRect, _ bw: CGFloat, _ avg: [Float], _ mx: [Float],
                          _ lo: Float, _ hi: Float, _ color: NSColor, from anchor: Anchor,
                          warn: (start: Float, limit: Float)? = nil) {
        guard hi > lo else { return }
        // Buckets touch (a stepped area under the edge line); the slight overlap avoids hairline seams.
        let width = bw + 0.3
        let span = hi - lo

        func height(_ v: Float) -> CGFloat {
            switch anchor {
            case .center: return CGFloat(min(1, abs(v) / hi)) * rect.height / 2
            default: return CGFloat(min(1, max(0, (v - lo) / span))) * rect.height
            }
        }
        /// y of the bar's tip.
        func tip(_ v: Float) -> CGFloat {
            let h = height(v)
            switch anchor {
            case .bottom: return rect.maxY - h
            case .top: return rect.minY + h
            case .center: return v > 0 ? rect.midY - h : rect.midY + h
            }
        }
        func barRect(_ i: Int, _ v: Float) -> CGRect {
            let x = rect.minX + CGFloat(i) * bw, t = tip(v)
            switch anchor {
            case .bottom: return CGRect(x: x, y: t, width: width, height: rect.maxY - t)
            case .top: return CGRect(x: x, y: rect.minY, width: width, height: t - rect.minY)
            case .center: return CGRect(x: x, y: min(t, rect.midY), width: width, height: abs(rect.midY - t))
            }
        }
        let visible: (Float) -> Bool = { $0.isFinite && height($0) > 0.01 }

        // Warning colors, only for upward bars and only when some value reaches the fade.
        let heat: ((CGFloat, CGFloat) -> CGGradient?)? = {
            guard anchor == .bottom, let warn, warn.limit > warn.start,
                  mx.contains(where: { $0 > warn.start }) || avg.contains(where: { $0 > warn.start }) else { return nil }
            return { top, bottom in
                Self.heatGradient(color, lo: lo, hi: hi, fadeStart: warn.start, limit: warn.limit, alpha: (top, bottom))
            }
        }()
        /// Fills the current path with a top-to-bottom gradient over the chart.
        func fill(_ gradient: CGGradient) {
            ctx.saveGState()
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
            ctx.restoreGState()
        }

        // Peaks: faint solid bars.
        let peaks = CGMutablePath()
        for (i, v) in mx.enumerated() where visible(v) { peaks.addRect(barRect(i, v)) }
        if !peaks.isEmpty {
            ctx.addPath(peaks)
            if let g = heat?(0.16, 0.16) {
                fill(g)
            } else {
                ctx.setFillColor(color.withAlphaComponent(0.16).cgColor)
                ctx.fillPath()
            }
        }

        // Average: gradient fill, clipped to the bars.
        let path = CGMutablePath()
        for (i, v) in avg.enumerated() where visible(v) { path.addRect(barRect(i, v)) }
        if !path.isEmpty, let g = heat?(0.5, 0.04) {
            ctx.addPath(path)
            fill(g)
        } else if !path.isEmpty, let gradient = CGGradient(colorsSpace: nil, colors: [color.withAlphaComponent(0.5).cgColor,
                                                                                    color.withAlphaComponent(0.04).cgColor] as CFArray,
                                                          locations: [0, 1]) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            switch anchor {
            case .bottom:
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
            case .top:
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
            case .center:
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.midY), options: [])
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
            }
            ctx.restoreGState()
        }

        // Edge: a stepped line along the tips; it breaks at gaps (no data).
        let edge = CGMutablePath()
        var last = -2
        for (i, v) in avg.enumerated() where v.isFinite {
            let x = rect.minX + CGFloat(i) * bw, y = tip(v)
            if i == last + 1 { edge.addLine(to: CGPoint(x: x, y: y)) } else { edge.move(to: CGPoint(x: x, y: y)) }
            edge.addLine(to: CGPoint(x: x + bw, y: y))
            last = i
        }
        ctx.setLineWidth(1)
        ctx.setLineJoin(.miter)
        ctx.addPath(edge)
        if !edge.isEmpty, let g = heat?(0.95, 0.95) {
            ctx.replacePathWithStrokedPath()
            fill(g)
        } else {
            ctx.setStrokeColor(color.withAlphaComponent(0.95).cgColor)
            ctx.strokePath()
        }

        if anchor == .center {
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.15).cgColor)
            ctx.fill(CGRect(x: rect.minX, y: rect.midY - 0.25, width: rect.width, height: 0.5))
        }
    }

    /// A top-to-bottom gradient over a chart showing `lo...hi`, colored by the value at each height:
    /// `color` below `fadeStart`, red from `limit` up, blended in between. The blend is mixed in
    /// OKLab, so it changes evenly (purple → rose → red) instead of passing through a brighter
    /// magenta. Alpha runs from `alpha.top` to `alpha.bottom`.
    private static func heatGradient(_ color: NSColor, lo: Float, hi: Float, fadeStart: Float, limit: Float,
                                     alpha: (top: CGFloat, bottom: CGFloat)) -> CGGradient? {
        guard let a = color.usingColorSpace(.sRGB), let b = NSColor.systemRed.usingColorSpace(.sRGB) else { return nil }
        let span = hi - lo
        // Position from the top (0) to the bottom (1) of the value v.
        func loc(_ v: Float) -> CGFloat { CGFloat(min(1, max(0, (hi - v) / span))) }
        let la = OKLab(a), lb = OKLab(b)
        func colorAt(_ l: CGFloat) -> CGColor {
            let v = hi - Float(l) * span
            let x = CGFloat(min(1, max(0, (v - fadeStart) / (limit - fadeStart))))
            let w = x * x * (3 - 2 * x) // eases in and out of the blend
            let mix = { (p: CGFloat, q: CGFloat) in p + (q - p) * w }
            return OKLab(L: mix(la.L, lb.L), a: mix(la.a, lb.a), b: mix(la.b, lb.b))
                .cgColor(alpha: alpha.top + (alpha.bottom - alpha.top) * l)
        }
        // Outside the blend the color is constant, so the ends and a few steps inside it are enough.
        let top = loc(limit), bottom = loc(fadeStart)
        var stops: [CGFloat] = [0, 1, top, bottom]
        if bottom > top { stops += (1..<8).map { top + (bottom - top) * CGFloat($0) / 8 } }
        stops = Array(Set(stops)).sorted()
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(colorAt) as CFArray, locations: stops)
    }
}

extension ChartsView {
    /// Rows for the chosen charts, in order. Battery and fans are skipped on Macs that don't have them.
    static func rows(for ids: [ChartID], hasBattery: Bool, fanCount: Int) -> [Row] {
        ids.compactMap { id -> Row? in
            switch id {
            case .cpu:
                return Row(id: id, series: .cpu, shape: .up, scale: .fixed(100), color: .systemIndigo, color2: nil) { v, _ in
                    let e = v(.ecpu), p = v(.pcpu)
                    return (Fmt.pct(v(.cpu)), e.isFinite && p.isFinite ? "E \(Int(e.rounded())) · P \(Int(p.rounded()))" : nil)
                }.with(axis: Fmt.pct, limit: { t, _ in t.cpu })
            case .gpu:
                return Row(id: id, series: .gpu, shape: .up, scale: .fixed(100), color: .systemIndigo, color2: nil) { v, _ in
                    (Fmt.pct(v(.gpu)), nil)
                }.with(axis: Fmt.pct, limit: { t, _ in t.gpu })
            case .ram:
                return Row(id: id, series: .ram, shape: .up, scale: .smart(minSpan: 2, otherwise: .ramTotal), color: .systemGreen, color2: nil) { v, live in
                    var main = Fmt.gb(v(.ram))
                    if let total = live?.ramTotalGB, total.isFinite { main += " / " + Fmt.gb(total) }
                    let sw = v(.swap)
                    return (main, sw.isFinite && sw > 0.05 ? "swap " + Fmt.gb(sw) : nil)
                }.with(axis: Fmt.gb, limit: { t, s in s.map { $0.ramTotalGB * t.ram / 100 } })
            case .power:
                return Row(id: id, series: .sysPower, shape: .up, scale: .auto(min: 10), color: .systemOrange, color2: nil) { v, _ in
                    (Fmt.watts(v(.sysPower)), "CPU " + Fmt.num(v(.cpuPower)) + " · GPU " + Fmt.num(v(.gpuPower)))
                }.with(axis: Fmt.watts)
            case .battery:
                guard hasBattery else { return nil }
                return Row(id: id, series: .batteryW, shape: .signed, scale: .auto(min: 10), color: .systemOrange, color2: nil) { v, _ in
                    (Fmt.signedWatts(v(.batteryW)), Fmt.pct(v(.batteryPct)))
                }.with(axis: Fmt.signedWatts)
            case .temp:
                return Row(id: id, series: .cpuTemp, shape: .up, scale: .smart(minSpan: 6, otherwise: .fixed(100)), color: .systemOrange, color2: nil) { v, _ in
                    (Fmt.temp(v(.cpuTemp)), "GPU " + Fmt.temp(v(.gpuTemp)))
                }.with(axis: Fmt.temp, limit: { t, _ in t.temp })
            case .fans:
                guard fanCount > 0 else { return nil }
                return Row(id: id, series: .fan0, shape: .up, scale: .fanMax, color: .systemGray, color2: nil) { v, _ in
                    let a = v(.fan0), b = v(.fan1)
                    let fmt: (Float) -> String = { $0.isFinite ? "\(Int($0.rounded()))" : Fmt.dash }
                    return ((fanCount > 1 ? fmt(a) + " / " + fmt(b) : fmt(a)) + " rpm", nil)
                }.with(axis: { $0.isFinite ? "\(Int($0.rounded())) rpm" : Fmt.dash })
            case .disk:
                return Row(id: id, series: .diskRead, shape: .mirrored(.diskWrite), scale: .auto(min: 10),
                           color: .systemBlue, color2: .systemTeal) { v, _ in
                    ("R " + Fmt.num(v(.diskRead)) + " · W " + Fmt.num(v(.diskWrite)) + " MB/s", nil)
                }.with(axis: { $0 >= 999.5 ? Fmt.num($0 / 1000) + " GB/s" : Fmt.num($0) + " MB/s" })
            case .diskOps:
                // Operations per second: many small reads or writes slow the Mac down while the
                // MB/s stay low. Idle is usually well under 1000.
                return Row(id: id, series: .diskReadOps, shape: .mirrored(.diskWriteOps), scale: .auto(min: 1000),
                           color: .systemBlue, color2: .systemTeal) { v, _ in
                    ("R " + Fmt.ops(v(.diskReadOps)) + " · W " + Fmt.ops(v(.diskWriteOps)) + " ops/s", nil)
                }.with(axis: { Fmt.ops($0) + " ops/s" })
            }
        }
    }
}

/// A color in OKLab, a color space where equal steps look like equal changes. Mixing two colors
/// here gives an even blend, without the brighter band a mix of hues (HSB) gives.
private struct OKLab {
    var L: CGFloat, a: CGFloat, b: CGFloat

    init(L: CGFloat, a: CGFloat, b: CGFloat) { self.L = L; self.a = a; self.b = b }

    /// From an sRGB color.
    init(_ c: NSColor) {
        func linear(_ x: CGFloat) -> CGFloat { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = linear(c.redComponent), g = linear(c.greenComponent), bl = linear(c.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    func cgColor(alpha: CGFloat) -> CGColor {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        func encode(_ x: CGFloat) -> CGFloat {
            let x = min(1, max(0, x))
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return CGColor(srgbRed: encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                       green: encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                       blue: encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), alpha: alpha)
    }
}
