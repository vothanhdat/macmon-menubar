import AppKit

/// Charts the user can show in the menu, in their chosen order.
enum ChartID: String, CaseIterable {
    case cpu, gpu, ram, power, battery, temp, fans, disk

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
}

/// All charts drawn in one view. Each cell is a label row above a filled bar chart (avg solid,
/// max faint). Cells flow into 1 or 2 columns. Hovering shows the values at that moment in every cell.
final class ChartsView: NSView {
    /// `smart` zooms to the range the data actually covers (at least `minSpan` wide), for slow
    /// metrics like temperature and RAM. It only applies when "Zoom Temp and RAM" is on in
    /// Settings; otherwise the `otherwise` scale is used.
    indirect enum Scale { case fixed(Float), auto(min: Float), ramTotal, fanMax, smart(minSpan: Float, otherwise: Scale) }
    enum Shape { case up, mirrored(Series), signed }

    struct Row {
        let title: String
        let series: Series
        let shape: Shape
        let scale: Scale
        let color: NSColor
        let color2: NSColor?
        /// Main value (e.g. "9.1W") and optional details (e.g. "CPU 0.9 · GPU 0.2").
        let text: (_ value: (Series) -> Float, _ live: Sample?) -> (main: String, detail: String?)
        /// Formats the min/max labels shown on smart-scaled charts.
        private(set) var axisLabel: ((Float) -> String)?
        /// Warning limit drawn as a dashed line when it falls inside the visible range.
        private(set) var limit: ((Thresholds, Sample?) -> Float?)?

        init(title: String, series: Series, shape: Shape, scale: Scale, color: NSColor, color2: NSColor?,
             text: @escaping (_ value: (Series) -> Float, _ live: Sample?) -> (main: String, detail: String?)) {
            self.title = title; self.series = series; self.shape = shape; self.scale = scale
            self.color = color; self.color2 = color2; self.text = text
        }

        func with(axis: ((Float) -> String)? = nil, limit: ((Thresholds, Sample?) -> Float?)? = nil) -> Row {
            var r = self
            r.axisLabel = axis
            r.limit = limit
            return r
        }
    }

    private static let inset = DashboardMenu.inset, colGap: CGFloat = 10
    private static let titleH: CGFloat = 12, chartGap: CGFloat = 1, cellGap: CGFloat = 5
    private static func chartH(_ layout: ChartLayout) -> CGFloat { layout.columns == 1 ? 25 : 30 }
    private static func cellH(_ layout: ChartLayout) -> CGFloat { titleH + chartGap + chartH(layout) + cellGap }

    /// Height needed for `count` charts.
    static func height(count: Int, layout: ChartLayout) -> CGFloat {
        let rows = (count + layout.columns - 1) / max(1, layout.columns)
        return CGFloat(rows) * cellH(layout) - cellGap + 2
    }

    var rows: [Row] = [] { didSet { needsDisplay = true } }
    var layout = ChartLayout() { didSet { needsDisplay = true } }
    var tier = 0 { didSet { needsDisplay = true } }
    var latest: Sample? { didSet { needsDisplay = true } }
    var history: HistoryStore?
    var onHover: ((TimeInterval?) -> Void)?

    private var hoverIndex: Int? {
        didSet {
            guard hoverIndex != oldValue else { return }
            needsDisplay = true
            let now = Date().timeIntervalSince1970
            onHover?(hoverIndex.flatMap { history?.bucketStart(tier: tier, index: $0, now: now) })
        }
    }
    private var avgBuf: [Float] = [], maxBuf: [Float] = [], avgBuf2: [Float] = [], maxBuf2: [Float] = []
    private var zoom = false // Settings.zoomCharts, read once per draw
    private let titleFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private let labelValueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    private let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)

    override var isFlipped: Bool { true }

    private var cellW: CGFloat {
        let cols = CGFloat(max(1, layout.columns))
        return (bounds.width - Self.inset * 2 - Self.colGap * (cols - 1)) / cols
    }

    private func cellOrigin(_ i: Int) -> CGPoint {
        let col = i % max(1, layout.columns), row = i / max(1, layout.columns)
        return CGPoint(x: Self.inset + CGFloat(col) * (cellW + Self.colGap), y: CGFloat(row) * Self.cellH(layout))
    }

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
        for col in 0..<max(1, layout.columns) {
            let x0 = Self.inset + CGFloat(col) * (cellW + Self.colGap)
            if p.x >= x0 && p.x < x0 + cellW {
                hoverIndex = min(cap - 1, max(0, Int((p.x - x0) / cellW * CGFloat(cap))))
                return
            }
        }
        hoverIndex = nil
    }

    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let history else { return }
        let now = Date().timeIntervalSince1970
        let cap = HistoryStore.tiers[tier].capacity
        let w = cellW
        let bw = w / CGFloat(cap)
        let chartH = Self.chartH(layout)
        let thresholds = Settings.shared.thresholds
        zoom = Settings.shared.zoomCharts

        for (i, row) in rows.enumerated() {
            let o = cellOrigin(i)
            let rect = CGRect(x: o.x, y: o.y + Self.titleH + Self.chartGap, width: w, height: chartH)

            // Label row.
            (row.title as NSString).draw(at: NSPoint(x: o.x, y: o.y - 1), withAttributes: [.font: titleFont, .foregroundColor: NSColor.secondaryLabelColor])

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
            switch row.shape {
            case .up:
                drawBars(ctx, rect, bw, avgBuf, maxBuf, r.lo, r.hi, row.color, from: .bottom)
            case .signed:
                drawBars(ctx, rect, bw, avgBuf, maxBuf, 0, r.hi, row.color, from: .center)
            case .mirrored:
                var top = rect; top.size.height /= 2
                var bottom = top; bottom.origin.y += top.height
                drawBars(ctx, top, bw, avgBuf, maxBuf, 0, r.hi, row.color, from: .bottom)
                drawBars(ctx, bottom, bw, avgBuf2, maxBuf2, 0, r.hi, row.color2 ?? row.color, from: .top)
            }

            // Warning limit as a dashed line, if it is inside the visible range.
            if let limit = row.limit?(thresholds, latest), limit > r.lo, limit < r.hi {
                let y = rect.maxY - CGFloat((limit - r.lo) / (r.hi - r.lo)) * rect.height
                ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.55).cgColor)
                ctx.setLineWidth(0.75)
                ctx.setLineDash(phase: 0, lengths: [2, 2])
                ctx.strokeLineSegments(between: [CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)])
                ctx.setLineDash(phase: 0, lengths: [])
            }

            // Smart-scaled charts don't start at zero, so show what the top and bottom mean.
            if let fmt = row.axisLabel, r.dataMin.isFinite, r.dataMax.isFinite {
                let a: [NSAttributedString.Key: Any] = [.font: axisFont, .foregroundColor: NSColor.secondaryLabelColor]
                (fmt(r.dataMax) as NSString).draw(at: NSPoint(x: rect.minX + 3, y: rect.minY), withAttributes: a)
                let low = fmt(r.dataMin) as NSString
                low.draw(at: NSPoint(x: rect.minX + 3, y: rect.maxY - low.size(withAttributes: a).height), withAttributes: a)
            }
            ctx.restoreGState()

            if let h = hoverIndex {
                ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.6).cgColor)
                ctx.fill(CGRect(x: rect.minX + (CGFloat(h) + 0.5) * bw - 0.5, y: rect.minY - 1, width: 1, height: rect.height + 2))
            }

            // Values: live, or at the hovered moment.
            let t: (main: String, detail: String?)
            if let h = hoverIndex {
                t = row.text({ history.value(tier: self.tier, series: $0, index: h, now: now) }, nil)
            } else {
                let live = latest
                t = row.text({ live?.value($0) ?? .nan }, live)
            }
            var chipText: String?, labelMain: String?, labelDetail: String?
            switch layout.value {
            case .chart: chipText = [t.main, t.detail].compactMap { $0 }.joined(separator: " · ")
            case .label: labelMain = t.main; labelDetail = t.detail
            case .split: chipText = t.main; labelDetail = t.detail
            }
            drawLabelValue(main: labelMain, detail: labelDetail, rightX: o.x + w, y: o.y)
            if let chipText { drawChip(chipText, in: rect, ctx: ctx) }
        }
    }

    /// Right-aligned on the label row: main value in the label color, details dimmer before it.
    private func drawLabelValue(main: String?, detail: String?, rightX: CGFloat, y: CGFloat) {
        var x = rightX
        if let main {
            let a: [NSAttributedString.Key: Any] = [.font: labelValueFont, .foregroundColor: NSColor.labelColor]
            let s = main as NSString
            x -= s.size(withAttributes: a).width
            s.draw(at: NSPoint(x: x, y: y - 0.5), withAttributes: a)
            x -= 6
        }
        if let detail {
            let a: [NSAttributedString.Key: Any] = [.font: labelValueFont, .foregroundColor: NSColor.secondaryLabelColor]
            let s = detail as NSString
            x -= s.size(withAttributes: a).width
            s.draw(at: NSPoint(x: x, y: y - 0.5), withAttributes: a)
        }
    }

    /// Small value chip in the chart's bottom-right corner, translucent so bars still show around it.
    private func drawChip(_ text: String, in rect: CGRect, ctx: CGContext) {
        let a: [NSAttributedString.Key: Any] = [.font: chipFont, .foregroundColor: NSColor.labelColor]
        let size = (text as NSString).size(withAttributes: a)
        let chip = CGRect(x: rect.maxX - size.width - 8, y: rect.maxY - size.height - 3, width: size.width + 6, height: size.height + 1)
        ctx.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.75).cgColor)
        ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
        (text as NSString).draw(at: NSPoint(x: chip.minX + 3, y: chip.minY + 0.5), withAttributes: a)
    }

    /// Visible value range for a row, plus the data's own min/max (for smart-scale labels).
    private func range(_ row: Row) -> (lo: Float, hi: Float, dataMin: Float, dataMax: Float) {
        range(row, row.scale)
    }

    private func range(_ row: Row, _ scale: Scale) -> (lo: Float, hi: Float, dataMin: Float, dataMax: Float) {
        let maxAbs = { (b: [Float]) in b.lazy.filter(\.isFinite).map { abs($0) }.max() ?? 0 }
        switch scale {
        case .fixed(let v):
            return (0, v, .nan, .nan)
        case .ramTotal:
            return (0, latest?.ramTotalGB ?? max(1, maxAbs(maxBuf)), .nan, .nan)
        case .fanMax:
            return (0, (latest?.fanMax).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 6000, .nan, .nan)
        case .auto(let minV):
            var m = maxAbs(maxBuf)
            if case .mirrored = row.shape { m = max(m, maxAbs(maxBuf2)) }
            return (0, max(minV, m * 1.1), .nan, .nan)
        case .smart(_, let otherwise) where !zoom:
            return range(row, otherwise)
        case .smart(let minSpan, _):
            let lows = avgBuf.filter(\.isFinite), highs = maxBuf.filter(\.isFinite)
            guard let dMin = lows.min(), let dMax = highs.max() ?? lows.max() else { return (0, 1, .nan, .nan) }
            var lo = dMin, hi = max(dMax, dMin)
            if hi - lo < minSpan { let mid = (lo + hi) / 2; lo = mid - minSpan / 2; hi = mid + minSpan / 2 }
            let pad = (hi - lo) * 0.12
            return (max(0, lo - pad), hi + pad, dMin, dMax)
        }
    }

    private enum Anchor { case bottom, top, center }

    /// Bars per bucket, no smoothing: a faint layer for the bucket max, a gradient fill for the
    /// average (strong at the tip, nearly clear at the base), and a crisp stepped edge on top.
    private func drawBars(_ ctx: CGContext, _ rect: CGRect, _ bw: CGFloat, _ avg: [Float], _ mx: [Float],
                          _ lo: Float, _ hi: Float, _ color: NSColor, from anchor: Anchor) {
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

        // Peaks: faint solid bars.
        ctx.setFillColor(color.withAlphaComponent(0.16).cgColor)
        ctx.beginPath()
        for (i, v) in mx.enumerated() where visible(v) { ctx.addRect(barRect(i, v)) }
        ctx.fillPath()

        // Average: gradient fill, clipped to the bars.
        let path = CGMutablePath()
        for (i, v) in avg.enumerated() where visible(v) { path.addRect(barRect(i, v)) }
        if !path.isEmpty, let gradient = CGGradient(colorsSpace: nil, colors: [color.withAlphaComponent(0.5).cgColor,
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
        ctx.setStrokeColor(color.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineJoin(.miter)
        ctx.addPath(edge)
        ctx.strokePath()

        if anchor == .center {
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.15).cgColor)
            ctx.fill(CGRect(x: rect.minX, y: rect.midY - 0.25, width: rect.width, height: 0.5))
        }
    }
}

extension ChartsView {
    /// Rows for the chosen charts, in order. Battery and fans are skipped on Macs that don't have them.
    static func rows(for ids: [ChartID], hasBattery: Bool, fanCount: Int) -> [Row] {
        ids.compactMap { id -> Row? in
            switch id {
            case .cpu:
                return Row(title: id.title, series: .cpu, shape: .up, scale: .fixed(100), color: .systemIndigo, color2: nil) { v, _ in
                    let e = v(.ecpu), p = v(.pcpu)
                    return (Fmt.pct(v(.cpu)), e.isFinite && p.isFinite ? "E \(Int(e.rounded())) · P \(Int(p.rounded()))" : nil)
                }.with(limit: { t, _ in t.cpu })
            case .gpu:
                return Row(title: id.title, series: .gpu, shape: .up, scale: .fixed(100), color: .systemIndigo, color2: nil) { v, _ in
                    (Fmt.pct(v(.gpu)), nil)
                }.with(limit: { t, _ in t.gpu })
            case .ram:
                return Row(title: id.title, series: .ram, shape: .up, scale: .smart(minSpan: 2, otherwise: .ramTotal), color: .systemGreen, color2: nil) { v, live in
                    var main = Fmt.gb(v(.ram))
                    if let total = live?.ramTotalGB, total.isFinite { main += " / " + Fmt.gb(total) }
                    let sw = v(.swap)
                    return (main, sw.isFinite && sw > 0.05 ? "swap " + Fmt.gb(sw) : nil)
                }.with(axis: Fmt.gb, limit: { t, s in s.map { $0.ramTotalGB * t.ram / 100 } })
            case .power:
                return Row(title: id.title, series: .sysPower, shape: .up, scale: .auto(min: 10), color: .systemOrange, color2: nil) { v, _ in
                    (Fmt.watts(v(.sysPower)), "CPU " + Fmt.num(v(.cpuPower)) + " · GPU " + Fmt.num(v(.gpuPower)))
                }
            case .battery:
                guard hasBattery else { return nil }
                return Row(title: id.title, series: .batteryW, shape: .signed, scale: .auto(min: 10), color: .systemOrange, color2: nil) { v, _ in
                    (Fmt.signedWatts(v(.batteryW)), Fmt.pct(v(.batteryPct)))
                }
            case .temp:
                return Row(title: id.title, series: .cpuTemp, shape: .up, scale: .smart(minSpan: 6, otherwise: .fixed(100)), color: .systemRed, color2: nil) { v, _ in
                    (Fmt.temp(v(.cpuTemp)), "GPU " + Fmt.temp(v(.gpuTemp)))
                }.with(axis: Fmt.temp, limit: { t, _ in t.temp })
            case .fans:
                guard fanCount > 0 else { return nil }
                return Row(title: id.title, series: .fan0, shape: .up, scale: .fanMax, color: .systemGray, color2: nil) { v, _ in
                    let a = v(.fan0), b = v(.fan1)
                    let fmt: (Float) -> String = { $0.isFinite ? "\(Int($0.rounded()))" : Fmt.dash }
                    return ((fanCount > 1 ? fmt(a) + " / " + fmt(b) : fmt(a)) + " rpm", nil)
                }
            case .disk:
                return Row(title: id.title, series: .diskRead, shape: .mirrored(.diskWrite), scale: .auto(min: 10),
                           color: .systemBlue, color2: .systemTeal) { v, _ in
                    ("R " + Fmt.num(v(.diskRead)) + " · W " + Fmt.num(v(.diskWrite)) + " MB/s", nil)
                }
            }
        }
    }
}
