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
    enum Scale { case fixed(Float), auto(min: Float), ramTotal, fanMax }
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
    private let titleFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private let labelValueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)

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

        for (i, row) in rows.enumerated() {
            let o = cellOrigin(i)
            let rect = CGRect(x: o.x, y: o.y + Self.titleH + Self.chartGap, width: w, height: chartH)

            // Label row.
            (row.title as NSString).draw(at: NSPoint(x: o.x, y: o.y - 1), withAttributes: [.font: titleFont, .foregroundColor: NSColor.secondaryLabelColor])

            // Chart: rounded track, bars clipped to it.
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.clip()
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.07).cgColor)
            ctx.fill(rect)

            history.window(tier: tier, series: row.series, now: now, avg: &avgBuf, max: &maxBuf)
            var scaleMax: Float
            switch row.scale {
            case .fixed(let v): scaleMax = v
            case .ramTotal: scaleMax = latest?.ramTotalGB ?? (maxBuf.filter(\.isFinite).max() ?? 1)
            case .fanMax: scaleMax = (latest?.fanMax).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 6000
            case .auto(let minV):
                scaleMax = max(minV, (maxBuf.lazy.filter(\.isFinite).map { abs($0) }.max() ?? 0) * 1.1)
            }
            switch row.shape {
            case .up:
                drawBars(ctx, rect, bw, avgBuf, maxBuf, scaleMax, row.color, from: .bottom)
            case .signed:
                drawBars(ctx, rect, bw, avgBuf, maxBuf, scaleMax, row.color, from: .center)
            case .mirrored(let down):
                history.window(tier: tier, series: down, now: now, avg: &avgBuf2, max: &maxBuf2)
                if case .auto(let minV) = row.scale {
                    scaleMax = max(scaleMax, minV, (maxBuf2.lazy.filter(\.isFinite).max() ?? 0) * 1.1)
                }
                var top = rect; top.size.height /= 2
                var bottom = top; bottom.origin.y += top.height
                drawBars(ctx, top, bw, avgBuf, maxBuf, scaleMax, row.color, from: .bottom)
                drawBars(ctx, bottom, bw, avgBuf2, maxBuf2, scaleMax, row.color2 ?? row.color, from: .top)
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

    private enum Anchor { case bottom, top, center }

    /// One filled bar per bucket: faint for the bucket max, solid for the average. No smoothing.
    private func drawBars(_ ctx: CGContext, _ rect: CGRect, _ bw: CGFloat, _ avg: [Float], _ mx: [Float],
                          _ scaleMax: Float, _ color: NSColor, from anchor: Anchor) {
        guard scaleMax > 0 else { return }
        // Wide bars (short ranges like 5m) get a gap so they read as separate bars.
        let width = bw >= 3 ? bw - 1 : max(bw, 0.5)
        for (values, alpha) in [(mx, CGFloat(0.35)), (avg, CGFloat(1))] {
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.beginPath()
            for (i, v) in values.enumerated() where v.isFinite && v != 0 {
                let x = rect.minX + CGFloat(i) * bw
                switch anchor {
                case .bottom:
                    let h = CGFloat(min(1, max(0, v / scaleMax))) * rect.height
                    ctx.addRect(CGRect(x: x, y: rect.maxY - h, width: width, height: h))
                case .top:
                    let h = CGFloat(min(1, max(0, v / scaleMax))) * rect.height
                    ctx.addRect(CGRect(x: x, y: rect.minY, width: width, height: h))
                case .center:
                    let h = CGFloat(min(1, abs(v) / scaleMax)) * rect.height / 2
                    ctx.addRect(CGRect(x: x, y: v > 0 ? rect.midY - h : rect.midY, width: width, height: h))
                }
            }
            ctx.fillPath()
        }
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
                }
            case .gpu:
                return Row(title: id.title, series: .gpu, shape: .up, scale: .fixed(100), color: .systemIndigo, color2: nil) { v, _ in
                    (Fmt.pct(v(.gpu)), nil)
                }
            case .ram:
                return Row(title: id.title, series: .ram, shape: .up, scale: .ramTotal, color: .systemGreen, color2: nil) { v, live in
                    var main = Fmt.gb(v(.ram))
                    if let total = live?.ramTotalGB, total.isFinite { main += " / " + Fmt.gb(total) }
                    let sw = v(.swap)
                    return (main, sw.isFinite && sw > 0.05 ? "swap " + Fmt.gb(sw) : nil)
                }
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
                return Row(title: id.title, series: .cpuTemp, shape: .up, scale: .fixed(100), color: .systemRed, color2: nil) { v, _ in
                    (Fmt.temp(v(.cpuTemp)), "GPU " + Fmt.temp(v(.gpuTemp)))
                }
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
