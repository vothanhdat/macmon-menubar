import AppKit

/// Top processes table. With no sort column chosen it shows the top few by each column (2 each in
/// the menu's 10 rows); clicking a column header shows the top ones by that column (click again
/// to go back). A tall window shows more rows.
final class ProcessListView: NSView {
    /// Raw values are saved in the settings, so new columns get new numbers.
    enum Sort: Int { case cpu, ram, disk, time, kernel } // kernel took the place of system calls

    static let headerH: CGFloat = 20, rowH: CGFloat = 17, noteH: CGFloat = 16
    static let defaultRows = 10
    static let minDiskBps = 50_000.0 // below this the column shows "0"
    static func height(rows: Int) -> CGFloat { headerH + rowH * CGFloat(rows) + noteH + 4 }
    static var height: CGFloat { height(rows: defaultRows) }

    var rowCount = ProcessListView.defaultRows { didSet { if rowCount != oldValue { recompute() } } }

    var snapshot: ProcSnapshot? { didSet { recompute() } }
    var sort: Sort? {
        didSet {
            UserDefaults.standard.set(sort.map { $0.rawValue } ?? -1, forKey: "processSort")
            recompute()
        }
    }
    private var picked: [(row: ProcRow, reason: Sort)] = []

    private let inset = Dashboard.inset
    /// Columns left to right. CPU time is the total since the process started, as in Activity Monitor.
    /// Kernel is the part of CPU spent in the kernel on the process's behalf (system calls, page
    /// faults): the per-process sign of heavy file work, since macOS doesn't count disk operations
    /// per process.
    private let columns: [(sort: Sort, title: String, width: CGFloat)] = [
        (.cpu, "CPU", 46), (.time, "CPU time", 62), (.ram, "RAM", 50), (.disk, "Disk", 58), (.kernel, "Kernel", 54),
    ]
    private let font = NSFont.systemFont(ofSize: 11)
    private let numFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let headFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let saved = UserDefaults.standard.object(forKey: "processSort") as? Int ?? -1
        sort = Sort(rawValue: saved)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func key(_ r: ProcRow, _ s: Sort) -> Double {
        switch s {
        case .cpu: return r.cpu ?? 0
        case .ram: return r.mem
        case .disk: return r.disk ?? -1
        case .time: return r.cpuTime
        case .kernel: return r.kernel ?? -1
        }
    }

    private func recompute() {
        guard let rows = snapshot?.rows else { picked = []; needsDisplay = true; return }
        if let s = sort {
            picked = rows.sorted { key($0, s) > key($1, s) }.prefix(rowCount).map { ($0, s) }
        } else {
            var out: [(ProcRow, Sort)] = []
            var seen = Set<pid_t>()
            // The top few by each column, left to right; a process counts for the first column it tops.
            let each = max(2, rowCount / columns.count)
            for s in columns.map(\.sort) {
                var n = 0
                for r in rows.sorted(by: { key($0, s) > key($1, s) }) where !seen.contains(r.pid) {
                    if s == .disk && (r.disk ?? 0) < Self.minDiskBps { break } // ignore idle disk users
                    if s == .kernel && r.kernel == nil { break }            // not known yet
                    out.append((r, s)); seen.insert(r.pid); n += 1
                    if n == each { break }
                }
            }
            if out.count < rowCount { // e.g. nothing using disk: fill with the next CPU users
                for r in rows.sorted(by: { key($0, .cpu) > key($1, .cpu) }) where !seen.contains(r.pid) {
                    out.append((r, .cpu)); seen.insert(r.pid)
                    if out.count == rowCount { break }
                }
            }
            picked = out
        }
        needsDisplay = true
    }

    private func columnX(_ i: Int) -> CGFloat {
        bounds.width - inset - columns[i...].reduce(0) { $0 + $1.width }
    }

    // Menus deliver mouseUp to custom item views; the menu stays open.
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.y < Self.headerH else { return }
        for (i, c) in columns.enumerated() where p.x >= columnX(i) && p.x < columnX(i) + c.width {
            sort = (sort == c.sort) ? nil : c.sort
            return
        }
        if p.x < columnX(0) { sort = nil }
    }

    private func drawRight(_ s: String, x: CGFloat, w: CGFloat, y: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let width = (s as NSString).size(withAttributes: attrs).width
        (s as NSString).draw(at: NSPoint(x: x + w - width, y: y), withAttributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        let secondary: [NSAttributedString.Key: Any] = [.font: headFont, .foregroundColor: NSColor.secondaryLabelColor]
        let title = sort == nil ? "Top processes" : "Top processes ↺"
        (title as NSString).draw(at: NSPoint(x: inset, y: 3), withAttributes: secondary)
        for (i, c) in columns.enumerated() {
            let active = sort == c.sort
            let attrs: [NSAttributedString.Key: Any] = [.font: headFont,
                                                        .foregroundColor: active ? NSColor.controlAccentColor : NSColor.secondaryLabelColor]
            drawRight(active ? c.title + " ▾" : c.title, x: columnX(i), w: c.width, y: 3, attrs: attrs)
        }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let nameW = columnX(0) - inset - 6
        for (i, item) in picked.enumerated() {
            let y = Self.headerH + CGFloat(i) * Self.rowH
            let r = item.row
            (r.name as NSString).draw(in: NSRect(x: inset, y: y, width: nameW, height: Self.rowH),
                                      withAttributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
            let pct = { (v: Double?) in v.map { $0 < 9.95 ? String(format: "%.1f%%", $0) : String(format: "%.0f%%", $0) } ?? Fmt.dash }
            for (c, col) in columns.enumerated() {
                let text: String
                switch col.sort {
                case .cpu: text = pct(r.cpu)
                case .time: text = Fmt.duration(r.cpuTime)
                case .ram: text = Fmt.bytes(r.mem)
                case .disk: text = Fmt.rate(r.disk)
                case .kernel: text = pct(r.kernel)
                }
                let strong = item.reason == col.sort
                drawRight(text, x: columnX(c), w: col.width, y: y + 1,
                          attrs: [.font: numFont, .foregroundColor: strong ? NSColor.labelColor : NSColor.tertiaryLabelColor])
            }
        }

        var note = ""
        if let snap = snapshot {
            if snap.helperFailed {
                note = "Root helper not reachable. Showing your processes only."
            } else if snap.helperOutdated {
                note = "Root helper is out of date: turn system processes off and on in Settings for kernel time."
            } else if let hidden = snap.hiddenDiskBps, hidden >= 50_000 {
                note = "System processes: \(Fmt.rate(hidden)) disk (turn on root mode to see which)"
            }
        } else {
            note = "Collecting…"
        }
        if !note.isEmpty {
            (note as NSString).draw(in: NSRect(x: inset, y: Self.headerH + Self.rowH * CGFloat(rowCount) + 2,
                                               width: bounds.width - inset * 2, height: Self.noteH),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor,
                                                     .paragraphStyle: para])
        }
    }
}
