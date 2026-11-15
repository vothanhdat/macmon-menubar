import AppKit

/// Programs over time, under the Process History table: a column per hour or day. Either one
/// program, optionally with a second measure of the same unit as a line over the columns, or
/// several stacked in each column. Pointing at a column shows its numbers.
final class ProcessHistoryChartView: NSView {
    struct Model {
        var starts: [Double]                    // each column's start, seconds since 1970
        var hourly: Bool
        var bars: [Double?]                     // nil: not known, or not running then
        var barName: String
        var line: [Double?]? = nil
        var lineName: String? = nil
        var format: (Double) -> String
        /// A round number at or above the highest value, for the top of the scale.
        var top: (Double) -> Double
        /// More lines for a column's tooltip.
        var extra: (Int) -> [String] = { _ in [] }
        /// Parts of each column, bottom to top; when there are any they are drawn instead of `bars`.
        var stack: [Segment] = []

        /// Each stacked column's height (nothing when it isn't stacked).
        var totals: [Double] { stack.isEmpty ? [] : starts.indices.map { i in stack.reduce(0) { $0 + $1.values[i] } } }
        /// The top of the scale: a round number at or above everything drawn.
        var scaleTop: Double {
            let values = stack.isEmpty ? (bars + (line ?? [])).compactMap { $0 } : totals
            return top(max(values.max() ?? 0, 1e-9))
        }
    }

    struct Segment {
        var name: String
        var color: NSColor
        var values: [Double]
    }

    /// What to draw; nil shows `message` instead.
    var model: Model? { didSet { hover = nil; needsDisplay = true } }
    var message = "" { didSet { needsDisplay = true } }

    static let barColor = NSColor.systemBlue
    /// An orange dark enough to read on a light window and not too bright on a dark one.
    static let lineColor = NSColor(srgbRed: 0xD9 / 255.0, green: 0x73 / 255.0, blue: 0x0D / 255.0, alpha: 1)

    /// Eight colours for programs in a stack, told apart also with a colour vision deficiency
    /// when neighbours in this order, each in a lighter step for a light window and a darker one
    /// for a dark window.
    static let palette: [NSColor] = zip([0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4, 0x008300, 0x6250d6, 0xe34948], paletteDark).map { light, dark in
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) }
    }
    /// The palette's steps for a dark background (also what the terminal view gets).
    static let paletteDark = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x0ca30c, 0x9085e9, 0xe66767]
    /// Everything not shown on its own, and CPU no scan could place: greys, not programs.
    static let otherColor = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.36) : NSColor(white: 0, alpha: 0.32) }
    static let unseenColor = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.17) : NSColor(white: 0, alpha: 0.15) }

    private static func rgb(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    private var hover: Int?
    private var cursor = NSPoint.zero
    private let axisAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                            .foregroundColor: NSColor.secondaryLabelColor]
    private let legendAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10),
                                                              .foregroundColor: NSColor.secondaryLabelColor]
    private let tipAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                           .foregroundColor: NSColor.labelColor]
    private let tipTitleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                                .foregroundColor: NSColor.secondaryLabelColor]

    override var isFlipped: Bool { true }

    // MARK: - Scales

    /// 1, 2 or 5 times a power of ten, at or above `v`.
    static func roundUp(_ v: Double) -> Double {
        guard v > 0, v.isFinite else { return 1 }
        let p = pow(10, floor(log10(v)))
        return [1, 2, 5, 10].map { $0 * p }.first { $0 >= v * 0.999999 } ?? 10 * p
    }

    /// A round length of time (seconds) at or above `v`: 30 s, 1 min, 15 min, 2 h…
    static func roundUpTime(_ v: Double) -> Double {
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 4 * 3600, 6 * 3600, 12 * 3600, 86400]
        if v < 1 { return max(roundUp(v), 0.1) }
        return steps.first { $0 >= v * 0.999999 } ?? roundUp(v / 86400) * 86400
    }

    /// The plot area: room at the left for the scale, at the bottom for times, at the top for the legend.
    private var plot: NSRect {
        let top: CGFloat = model?.line != nil || model?.stack.isEmpty == false ? 22 : 8
        return NSRect(x: 56, y: top, width: max(10, bounds.width - 56 - 14), height: max(10, bounds.height - top - 18))
    }

    private func timeLabel(_ i: Int, long: Bool) -> String {
        guard let m = model else { return "" }
        return Self.timeLabel(m.starts[i], hourly: m.hourly, long: long)
    }

    /// A column's time: "14:00" or "15 Nov" under it, "Sun 15 Nov, 14:00–15:00" in full.
    static func timeLabel(_ start: Double, hourly: Bool, long: Bool) -> String {
        let f = DateFormatter()
        let date = Date(timeIntervalSince1970: start)
        if !long {
            f.dateFormat = hourly ? "HH:mm" : "d MMM"
            return f.string(from: date)
        }
        f.dateFormat = "EEE d MMM"
        guard hourly else { return f.string(from: date) }
        let t = DateFormatter()
        t.dateFormat = "HH:mm"
        return "\(f.string(from: date)), \(t.string(from: date))–\(t.string(from: date.addingTimeInterval(3600)))"
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model, !m.starts.isEmpty else {
            let s = message as NSString
            let size = s.size(withAttributes: tipTitleAttrs)
            s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: tipTitleAttrs)
            return
        }
        let p = plot, n = m.starts.count
        let values = m.totals
        let top = m.scaleTop
        func y(_ v: Double) -> CGFloat { p.maxY - CGFloat(min(v, top) / top) * p.height }
        let slot = p.width / CGFloat(n)
        func x(_ i: Int) -> CGFloat { p.minX + (CGFloat(i) + 0.5) * slot }

        // Scale: hairlines at half and full, with their values; the baseline a little stronger.
        for (f, alpha) in [(0.0, 0.25), (0.5, 0.1), (1.0, 0.1)] {
            let ly = (y(top * f)).rounded() - 0.5
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSRect(x: p.minX, y: ly, width: p.width, height: 1).fill()
            let label = (f == 0 ? "0" : m.format(top * f)) as NSString
            let size = label.size(withAttributes: axisAttrs)
            label.draw(at: NSPoint(x: p.minX - 6 - size.width, y: ly - size.height / 2), withAttributes: axisAttrs)
        }

        // Times under the columns: about eight of them, counted back from the newest.
        let step = max(1, Int((Double(n) / 8).rounded(.up)))
        for i in 0..<n where (n - 1 - i) % step == 0 {
            let label = timeLabel(i, long: false) as NSString
            let size = label.size(withAttributes: axisAttrs)
            let lx = min(max(x(i) - size.width / 2, p.minX - 20), bounds.width - size.width - 2)
            label.draw(at: NSPoint(x: lx, y: p.maxY + 4), withAttributes: axisAttrs)
        }

        if let h = hover {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSRect(x: p.minX + CGFloat(h) * slot, y: p.minY, width: slot, height: p.height).fill()
        }

        // Columns: at most 24 pt wide, with a gap between neighbours and rounded tops.
        let width = slot >= 4 ? min(24, slot - 2) : slot
        func column(_ i: Int, _ v: Double) -> (rect: NSRect, path: NSBezierPath) {
            let h = max(1, p.maxY - y(v)), r = min(4, width / 2, h)
            let rect = NSRect(x: x(i) - width / 2, y: p.maxY - h, width: width, height: h)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY + r))
            path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: 180, endAngle: 270)
            path.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 270, endAngle: 360)
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.close()
            return (rect, path)
        }
        Self.barColor.setFill()
        for (i, v) in m.bars.enumerated() where m.stack.isEmpty {
            if let v, v > 0 { column(i, v).path.fill() }
        }
        // Stacked: the column's shape cut into its parts, with a gap between them where they
        // are tall enough to spare it.
        for i in 0..<n where !m.stack.isEmpty && values[i] > 0 {
            let (rect, path) = column(i, values[i])
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            var bottom = rect.maxY
            let last = m.stack.lastIndex { $0.values[i] > 0 }
            for (k, seg) in m.stack.enumerated() where seg.values[i] > 0 {
                let h = CGFloat(seg.values[i] / values[i]) * rect.height
                let gap: CGFloat = k != last && width >= 4 && h > 4 ? 1.5 : 0
                seg.color.setFill()
                NSRect(x: rect.minX, y: bottom - h + gap, width: rect.width, height: h - gap).fill()
                bottom -= h
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // The line, broken where a value is missing. Dots when there is room for them, and
        // always on a point with no neighbours (a line of one point can't be seen).
        if let line = m.line {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            var drawing = false
            var dots: [NSPoint] = []
            for (i, v) in line.enumerated() {
                guard let v else { drawing = false; continue }
                let pt = NSPoint(x: x(i), y: y(v))
                if drawing { path.line(to: pt) } else { path.move(to: pt) }
                drawing = true
                let alone = (i == 0 || line[i - 1] == nil) && (i == n - 1 || line[i + 1] == nil)
                if n <= 31 || alone || hover == i { dots.append(pt) }
            }
            Self.lineColor.setStroke()
            path.stroke()
            for pt in dots {
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)).fill()
                Self.lineColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)).fill()
            }
        }

        drawLegend(m, at: p)
        if let h = hover { drawTip(m, column: h, in: p) }
    }

    /// Names what is drawn, when there is more than one thing: the columns and the line, or the
    /// parts of a stack. Programs that don't fit are left out (the table marks them too).
    private func drawLegend(_ m: Model, at p: NSRect) {
        var entries: [(name: String, color: NSColor, line: Bool, program: Bool)] = []
        if !m.stack.isEmpty {
            entries = m.stack.map { (Self.short($0.name, 20), $0.color, false, $0.color != Self.otherColor && $0.color != Self.unseenColor) }
        } else if let lineName = m.lineName, m.line != nil {
            entries = [(m.barName, Self.barColor, false, false), (lineName, Self.lineColor, true, false)]
        }
        guard !entries.isEmpty else { return }
        func width(_ e: (name: String, color: NSColor, line: Bool, program: Bool)) -> CGFloat {
            (e.name as NSString).size(withAttributes: legendAttrs).width + (e.line ? 19 : 14) + 16
        }
        var hidden = 0
        while entries.reduce(0, { $0 + width($1) }) + (hidden > 0 ? 60 : 0) > p.width, let i = entries.lastIndex(where: { $0.program }) {
            entries.remove(at: i)
            hidden += 1
        }
        var lx = p.minX
        let ly: CGFloat = 3
        for e in entries {
            e.color.setFill()
            if e.line {
                NSRect(x: lx, y: ly + 5.5, width: 14, height: 2).fill()
                NSBezierPath(ovalIn: NSRect(x: lx + 3.5, y: ly + 3, width: 7, height: 7)).fill()
            } else {
                NSBezierPath(roundedRect: NSRect(x: lx, y: ly + 2, width: 9, height: 9), xRadius: 2, yRadius: 2).fill()
            }
            (e.name as NSString).draw(at: NSPoint(x: lx + (e.line ? 19 : 14), y: ly), withAttributes: legendAttrs)
            lx += width(e)
        }
        if hidden > 0 { ("+\(hidden) more" as NSString).draw(at: NSPoint(x: lx, y: ly), withAttributes: legendAttrs) }
    }

    /// A name cut in the middle to at most `n` characters.
    static func short(_ name: String, _ n: Int) -> String {
        guard name.count > n else { return name }
        return name.prefix(n / 2) + "…" + name.suffix(n - n / 2 - 1)
    }

    private func drawTip(_ m: Model, column i: Int, in p: NSRect) {
        var rows: [(text: String, color: NSColor?)] = []
        if m.stack.isEmpty {
            rows.append(("\(m.barName): \(m.bars[i].map(m.format) ?? Fmt.dash)", Self.barColor))
            if let line = m.line, let name = m.lineName { rows.append(("\(name): \(line[i].map(m.format) ?? Fmt.dash)", Self.lineColor)) }
        } else {
            // As stacked, from the top down, with each part's share of the column.
            let total = m.stack.reduce(0) { $0 + $1.values[i] }
            for seg in m.stack.reversed() where seg.values[i] > 0 {
                rows.append(("\(Self.short(seg.name, 28)): \(m.format(seg.values[i])) · \(HistoryFmt.pct(seg.values[i] / total * 100))", seg.color))
            }
            rows.append(("Total: \(m.format(total))", nil))
        }
        rows += m.extra(i).map { ($0, nil) }
        let title = timeLabel(i, long: true) as NSString
        let lineH: CGFloat = rows.count > 6 ? 14 : 15, pad: CGFloat = 8, mark: CGFloat = 13
        let textW = rows.map { ($0.text as NSString).size(withAttributes: tipAttrs).width + mark }.max() ?? 0
        let w = max(textW, title.size(withAttributes: tipTitleAttrs).width) + pad * 2
        let h = lineH * CGFloat(rows.count + 1) + pad * 2 - 2
        // Beside the pointer, on the side with room, and inside the view.
        var origin = NSPoint(x: cursor.x + 14, y: cursor.y - h / 2)
        if origin.x + w > bounds.width - 4 { origin.x = cursor.x - 14 - w }
        origin.x = max(4, origin.x)
        origin.y = min(max(2, origin.y), bounds.height - h - 2)
        let box = NSBezierPath(roundedRect: NSRect(origin: origin, size: NSSize(width: w, height: h)), xRadius: 6, yRadius: 6)
        NSColor.windowBackgroundColor.setFill()
        box.fill()
        NSColor.labelColor.withAlphaComponent(0.2).setStroke()
        box.lineWidth = 1
        box.stroke()
        title.draw(at: NSPoint(x: origin.x + pad, y: origin.y + pad - 2), withAttributes: tipTitleAttrs)
        for (k, row) in rows.enumerated() {
            let ry = origin.y + pad - 2 + lineH * CGFloat(k + 1)
            if let c = row.color {
                c.setFill()
                NSBezierPath(roundedRect: NSRect(x: origin.x + pad, y: ry + 3.5, width: 8, height: 8), xRadius: 2, yRadius: 2).fill()
            }
            (row.text as NSString).draw(at: NSPoint(x: origin.x + pad + mark, y: ry), withAttributes: tipAttrs)
        }
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// The column under a point (anywhere in its slot, above or below the column itself), or nil.
    func column(at point: NSPoint) -> Int? {
        guard let m = model, !m.starts.isEmpty else { return nil }
        let p = plot
        guard point.x >= p.minX, point.x < p.maxX, point.y >= 0, point.y <= bounds.height else { return nil }
        return min(m.starts.count - 1, Int((point.x - p.minX) / (p.width / CGFloat(m.starts.count))))
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        hover = column(at: cursor)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }
}
