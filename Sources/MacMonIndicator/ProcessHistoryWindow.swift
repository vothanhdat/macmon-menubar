import AppKit

/// Process history as a sortable table: one row per app (all its processes together) or per
/// executable, over a chosen range. Created when opened, released when closed.
final class ProcessHistoryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate {
    var onClose: (() -> Void)?

    private let tracker: ProcessTracker
    private let rangeControl = NSSegmentedControl(labels: ProcessTracker.Range.allCases.map(\.title), trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private let groupControl = NSSegmentedControl(labels: ["Apps", "Executables"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let table = NSTableView()
    private let footer = NSTextField(wrappingLabelWithString: "")
    private var summary = ProcessTracker.Summary()
    private var rows: [Row] = []
    private var loaded = false
    private static let frameName = "ProcessHistory"
    private static let rangeKey = "processHistoryRange"
    private static let groupKey = "processHistoryByExecutable"

    struct Row {
        let name: String
        let path: String
        let s: ProcStats
        var avgCopies: Double { s.running > 0 ? s.copyTime / s.running : 0 }
        var avgLife: Double { s.exits > 0 ? s.lifetime / Double(s.exits) : -1 }
        var cpuPct: Double { s.running > 0 ? s.cpu / s.running * 100 : 0 }
        var energy: Double { s.detail ? s.energy : -1 }
        var power: Double { s.detail && s.running > 0 ? s.energy / s.running : -1 }
        var ramAvg: Double { s.running > 0 ? s.ramTime / s.running : 0 }
        var diskRead: Double { s.detail ? s.diskRead : -1 }
        var diskWritten: Double { s.detail ? s.diskWritten : -1 }
    }

    struct Column {
        let id: String
        let title: String
        let width: CGFloat
        let tip: String
        let text: (Row) -> String
        let value: (Row) -> Double
    }

    static let columns: [Column] = [
        Column(id: "name", title: "Name", width: 210, tip: "The app (all of its processes together) or the executable. Double-click to show it in Finder.",
               text: { $0.name }, value: { _ in 0 }),
        Column(id: "running", title: "Running", width: 72, tip: "How long at least one copy was running (while the Mac was awake)",
               text: { Fmt.duration($0.s.running) }, value: { $0.s.running }),
        Column(id: "launches", title: "Launches", width: 62, tip: "Copies seen starting. Copies that start and end between two scans (5 minutes apart) can be missed.",
               text: { "\($0.s.launches)" }, value: { Double($0.s.launches) }),
        Column(id: "life", title: "Avg life", width: 66, tip: "Average lifetime of the copies that ended, from their start to their end (± a few minutes)",
               text: { $0.avgLife >= 0 ? Fmt.duration($0.avgLife) : Fmt.dash }, value: { $0.avgLife }),
        Column(id: "copies", title: "Copies", width: 64, tip: "Copies running at once: average while running / most seen",
               text: { r in
                   guard r.s.running > 0 else { return Fmt.dash }
                   let avg = String(format: "%.1f", r.avgCopies)
                   return avg == String(format: "%.1f", Double(r.s.peakCopies)) ? "\(r.s.peakCopies)" : "\(avg) / \(r.s.peakCopies)"
               },
               value: { $0.avgCopies }),
        Column(id: "cpu", title: "CPU time", width: 78, tip: "CPU time used, all copies together",
               text: { Fmt.duration($0.s.cpu) }, value: { $0.s.cpu }),
        Column(id: "cpuPct", title: "CPU", width: 50, tip: "Average CPU while running (100% = one core)",
               text: { HistoryFmt.pct($0.cpuPct) }, value: { $0.cpuPct }),
        Column(id: "energy", title: "Energy", width: 66, tip: "CPU energy used (GPU work is not included). System processes need the root helper.",
               text: { HistoryFmt.energy($0.energy) }, value: { $0.energy }),
        Column(id: "power", title: "Power", width: 58, tip: "Average CPU power while running",
               text: { HistoryFmt.power($0.power) }, value: { $0.power }),
        Column(id: "ramAvg", title: "RAM avg", width: 62, tip: "Average memory while running, all copies together",
               text: { HistoryFmt.bytes($0.ramAvg) }, value: { $0.ramAvg }),
        Column(id: "ramPeak", title: "RAM peak", width: 66, tip: "Most memory seen at a scan, all copies together",
               text: { HistoryFmt.bytes($0.s.ramPeak) }, value: { $0.s.ramPeak }),
        Column(id: "diskRead", title: "Read", width: 58, tip: "Bytes read from disk. System processes need the root helper.",
               text: { HistoryFmt.bytes($0.diskRead) }, value: { $0.diskRead }),
        Column(id: "diskWritten", title: "Written", width: 62, tip: "Bytes written to disk. System processes need the root helper.",
               text: { HistoryFmt.bytes($0.diskWritten) }, value: { $0.diskWritten }),
    ]

    init(tracker: ProcessTracker) {
        self.tracker = tracker
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 620),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Process History"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.contentMinSize = NSSize(width: 640, height: 300)
        super.init(window: w)
        w.delegate = self
        build()
        if !w.setFrameUsingName(Self.frameName) { w.center() }
        w.setFrameAutosaveName(Self.frameName)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func build() {
        let d = UserDefaults.standard
        rangeControl.selectedSegment = min(ProcessTracker.Range.allCases.count - 1, max(0, d.integer(forKey: Self.rangeKey)))
        rangeControl.target = self
        rangeControl.action = #selector(rangeChanged)
        groupControl.selectedSegment = d.bool(forKey: Self.groupKey) ? 1 : 0
        groupControl.target = self
        groupControl.action = #selector(groupChanged)
        search.placeholderString = "Filter"
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [rangeControl, groupControl, spacer, search])
        bar.spacing = 12

        for c in Self.columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.id == "name" ? 120 : 40
            col.headerToolTip = c.tip
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: c.id == "name")
            if c.id != "name" { col.headerCell.alignment = .right }
            table.addTableColumn(col)
        }
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(revealInFinder)
        table.sortDescriptors = [NSSortDescriptor(key: "cpu", ascending: false)]
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.isSelectable = true

        let content = NSView()
        for v in [bar, scroll, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window?.contentView = content
    }

    // MARK: - Data

    private var range: ProcessTracker.Range { ProcessTracker.Range(rawValue: rangeControl.selectedSegment) ?? .today }
    private var byExecutable: Bool { groupControl.selectedSegment == 1 }

    /// Reads the range again (after a scan, or when the range changes).
    func reload() {
        tracker.summary(range) { [weak self] s in
            guard let self else { return }
            self.summary = s
            self.loaded = true
            self.rebuildRows()
        }
    }

    private func rebuildRows() {
        let filter = search.stringValue.trimmingCharacters(in: .whitespaces)
        rows = Self.rows(summary, byExecutable: byExecutable, filter: filter)
        sortRows()
        table.reloadData()
        updateFooter()
    }

    private func sortRows() {
        guard let d = table.sortDescriptors.first, let key = d.key else { return }
        Self.sort(&rows, by: key, ascending: d.ascending)
    }

    /// The rows for a summary. Apps: app bundles plus executables outside any app. Executables:
    /// every executable. Also used by the terminal view.
    static func rows(_ summary: ProcessTracker.Summary, byExecutable: Bool, filter: String = "") -> [Row] {
        summary.programs.compactMap { p in
            let show = byExecutable ? !ProcKey.isApp(p.path) : (ProcKey.isApp(p.path) || ProcKey.app(of: p.path) == nil)
            guard show else { return nil }
            let name = ProcKey.name(p.path)
            guard filter.isEmpty || name.localizedCaseInsensitiveContains(filter) || p.path.localizedCaseInsensitiveContains(filter) else { return nil }
            return Row(name: name, path: p.path, s: p.stats)
        }
    }

    /// Sorts by a column id; ties (often zeros) fall back to CPU time, then name.
    static func sort(_ rows: inout [Row], by key: String, ascending: Bool) {
        guard let col = columns.first(where: { $0.id == key }) else { return }
        if key == "name" {
            rows.sort { ascending ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                                  : $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        } else {
            rows.sort { a, b in
                let x = col.value(a), y = col.value(b)
                if x != y { return ascending ? x < y : x > y }
                if a.s.cpu != b.s.cpu { return a.s.cpu > b.s.cpu }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    private func updateFooter() {
        footer.stringValue = Self.footer(summary, range: range, empty: rows.isEmpty && summary.programs.isEmpty && loaded)
            .joined(separator: "\n")
    }

    /// Lines under the table: when the last scan ran, what the numbers can't include. `empty`:
    /// loaded, and nothing recorded yet. Also used by the terminal view.
    static func footer(_ summary: ProcessTracker.Summary, range: ProcessTracker.Range, empty: Bool) -> [String] {
        var parts: [String] = []
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        if let t = summary.lastScan {
            let gap = ProcessTracker.interval >= 60 ? "\(Int(ProcessTracker.interval / 60)) minutes" : "\(Int(ProcessTracker.interval)) seconds"
            var line = "Scanned every \(gap), last at \(time.string(from: t))."
            if let since = summary.since, range.days > 1 || range == .last24h {
                let day = DateFormatter()
                day.dateFormat = "d MMM HH:mm"
                line += " Data since \(day.string(from: since))."
            }
            if summary.unseen.cpu >= 1 {
                line += " Unseen: \(Fmt.duration(summary.unseen.cpu)) of CPU no scan could place: processes that ran between scans"
                line += summary.helper == .ok ? "." : ", and the kernel's own work."
            }
            parts.append(line)
        }
        if empty {
            parts.append("Collecting: numbers appear after the second scan.")
        }
        let partial = summary.programs.contains { !$0.stats.detail }
        switch summary.helper {
        case .outdated:
            parts.append("The root helper is out of date: turn “Show system processes” off and on in Settings for their energy and disk use.")
        case .unreachable:
            parts.append("Root helper not reachable: system processes show CPU time and memory only.")
        case .notUsed where partial:
            parts.append("System processes show CPU time and memory only. Turn on “Show system processes” in Settings for their energy and disk use.")
        default:
            break
        }
        return parts
    }

    // MARK: - Actions

    @objc private func rangeChanged() {
        UserDefaults.standard.set(rangeControl.selectedSegment, forKey: Self.rangeKey)
        reload()
    }

    @objc private func groupChanged() {
        UserDefaults.standard.set(byExecutable, forKey: Self.groupKey)
        rebuildRows()
    }

    func controlTextDidChange(_ obj: Notification) { rebuildRows() }

    @objc private func revealInFinder() {
        let r = table.clickedRow
        guard r >= 0, r < rows.count, rows[r].path.hasPrefix("/") else { return }
        var path = rows[r].path
        // Homebrew paths are kept without their version folder; "opt" links to the current version.
        if let cellar = path.range(of: "/Cellar/") {
            let rest = path[cellar.upperBound...].split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
            if rest.count == 3 { path = path[..<cellar.lowerBound] + "/opt/\(rest[0])/\(rest[2])" }
        }
        guard FileManager.default.fileExists(atPath: path) else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortRows()
        table.reloadData()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let col = Self.columns.first(where: { $0.id == id.rawValue }) else { return nil }
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let f = NSTextField(labelWithString: "")
            f.translatesAutoresizingMaskIntoConstraints = false
            f.lineBreakMode = .byTruncatingTail
            f.font = col.id == "name" ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            f.alignment = col.id == "name" ? .left : .right
            cell.addSubview(f)
            cell.textField = f
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                f.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                f.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let r = rows[row]
        cell.textField?.stringValue = col.text(r)
        let unknown = col.value(r) < 0
        cell.textField?.textColor = unknown ? .tertiaryLabelColor : .labelColor
        cell.textField?.toolTip = col.id == "name" ? r.path : (col.id == "ramPeak" ? "Biggest single copy: \(HistoryFmt.bytes(r.s.ramOnePeak))" :
            (col.id == "cpu" && r.s.detail ? "On performance cores: \(Fmt.duration(r.s.pcore))" : nil))
        return cell
    }
}

/// Number formats for the history table.
enum HistoryFmt {
    static func pct(_ p: Double) -> String {
        if p <= 0 { return "0%" }
        return p < 9.95 ? String(format: "%.1f%%", p) : String(format: "%.0f%%", p)
    }
    /// Joules, shown as watt-hours: "3.4 Wh", "120 mWh".
    static func energy(_ j: Double) -> String {
        guard j >= 0 else { return Fmt.dash }
        let wh = j / 3600
        if wh >= 9.95 { return String(format: "%.0f Wh", wh) }
        if wh >= 0.9995 { return String(format: "%.1f Wh", wh) }
        if wh >= 0.0005 { return String(format: "%.0f mWh", wh * 1000) }
        return j > 0 ? "<1 mWh" : "0"
    }
    static func power(_ w: Double) -> String {
        guard w >= 0 else { return Fmt.dash }
        if w >= 9.95 { return String(format: "%.0f W", w) }
        if w >= 0.0995 { return String(format: "%.1f W", w) }
        if w >= 0.0005 { return String(format: "%.0f mW", w * 1000) }
        return w > 0 ? "<1 mW" : "0"
    }
    static func bytes(_ b: Double) -> String {
        guard b >= 0 else { return Fmt.dash }
        return b < 500 ? "0" : Fmt.bytes(b)
    }
}
