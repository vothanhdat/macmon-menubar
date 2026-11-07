import AppKit

/// Top processes table. With no sort column chosen it shows the top 2 by CPU, RAM and disk;
/// clicking a column header shows the top 6 by that column (click again to go back).
final class ProcessListView: NSView {
    enum Sort: Int { case cpu, ram, disk }

    static let headerH: CGFloat = 20, rowH: CGFloat = 17, noteH: CGFloat = 16
    static let count = 6
    static let minDiskBps = 50_000.0 // below this the column shows "0"
    static var height: CGFloat { headerH + rowH * CGFloat(count) + noteH + 4 }

    var snapshot: ProcSnapshot? { didSet { recompute() } }
    var sort: Sort? {
        didSet {
            UserDefaults.standard.set(sort.map { $0.rawValue } ?? -1, forKey: "processSort")
            recompute()
        }
    }
    private var picked: [(row: ProcRow, reason: Sort)] = []

    private let inset = DashboardMenu.inset
    private let colW: [CGFloat] = [52, 52, 62] // CPU, RAM, Disk
    private let font = NSFont.systemFont(ofSize: 11)
    private let numFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let headFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    override var isFlipped: Bool { true }

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
        }
    }

    private func recompute() {
        guard let rows = snapshot?.rows else { picked = []; needsDisplay = true; return }
        if let s = sort {
            picked = rows.sorted { key($0, s) > key($1, s) }.prefix(Self.count).map { ($0, s) }
        } else {
            var out: [(ProcRow, Sort)] = []
            var seen = Set<pid_t>()
            for s in [Sort.cpu, .ram, .disk] {
                var n = 0
                for r in rows.sorted(by: { key($0, s) > key($1, s) }) where !seen.contains(r.pid) {
                    if s == .disk && (r.disk ?? 0) < Self.minDiskBps { break } // ignore idle disk users
                    out.append((r, s)); seen.insert(r.pid); n += 1
                    if n == 2 { break }
                }
            }
            if out.count < Self.count { // nothing using disk: fill with the next CPU users
                for r in rows.sorted(by: { key($0, .cpu) > key($1, .cpu) }) where !seen.contains(r.pid) {
                    out.append((r, .cpu)); seen.insert(r.pid)
                    if out.count == Self.count { break }
                }
            }
            picked = out
        }
        needsDisplay = true
    }

    private func columnX(_ i: Int) -> CGFloat {
        bounds.width - inset - colW[i...].reduce(0, +)
    }

    // Menus deliver mouseUp to custom item views; the menu stays open.
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.y < Self.headerH else { return }
        for i in 0..<3 where p.x >= columnX(i) && p.x < columnX(i) + colW[i] {
            let s = Sort(rawValue: i)!
            sort = (sort == s) ? nil : s
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
        for (i, name) in ["CPU", "RAM", "Disk"].enumerated() {
            let active = sort?.rawValue == i
            let attrs: [NSAttributedString.Key: Any] = [.font: headFont,
                                                        .foregroundColor: active ? NSColor.controlAccentColor : NSColor.secondaryLabelColor]
            drawRight(active ? name + " ▾" : name, x: columnX(i), w: colW[i], y: 3, attrs: attrs)
        }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let nameW = columnX(0) - inset - 6
        for (i, item) in picked.enumerated() {
            let y = Self.headerH + CGFloat(i) * Self.rowH
            let r = item.row
            (r.name as NSString).draw(in: NSRect(x: inset, y: y, width: nameW, height: Self.rowH),
                                      withAttributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
            let cpu = r.cpu.map { $0 < 9.95 ? String(format: "%.1f%%", $0) : String(format: "%.0f%%", $0) } ?? Fmt.dash
            let values = [cpu, Fmt.bytes(r.mem), Fmt.rate(r.disk)]
            for c in 0..<3 {
                let strong = item.reason.rawValue == c
                drawRight(values[c], x: columnX(c), w: colW[c], y: y + 1,
                          attrs: [.font: numFont, .foregroundColor: strong ? NSColor.labelColor : NSColor.tertiaryLabelColor])
            }
        }

        var note = ""
        if let snap = snapshot {
            if snap.helperFailed {
                note = "Root helper not reachable. Showing your processes only."
            } else if let hidden = snap.hiddenDiskBps, hidden >= 50_000 {
                note = "System processes: \(Fmt.rate(hidden)) disk (turn on root mode to see which)"
            }
        } else {
            note = "Collecting…"
        }
        if !note.isEmpty {
            (note as NSString).draw(in: NSRect(x: inset, y: Self.headerH + Self.rowH * CGFloat(Self.count) + 2,
                                               width: bounds.width - inset * 2, height: Self.noteH),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor,
                                                     .paragraphStyle: para])
        }
    }
}
