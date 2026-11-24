import AppKit

/// Process history as a sortable table: one row per app (all its processes together) or per
/// executable, over a chosen range. Under it a chart over time: the top programs stacked, or the
/// selected row alone or against everything else (click it again, or Esc, for all programs again).
/// With your other Macs sharing (OtherMacs.swift), a menu at the left shows theirs instead, from
/// their copies. Created when opened, released when closed.
final class ProcessHistoryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate {
    var onClose: (() -> Void)?

    // Your other Macs, set by the app (see OtherMacs): the ones that share, how old a Mac's copy
    // is ("40 min ago", "updating…"), which copy is newest, asking for the latest, and reading one.
    var otherMacs: () -> [(id: String, name: String)] = { [] }
    var macStatus: (String) -> String = { _ in "" }
    var macVersion: (String) -> String = { _ in "" }
    var lookAt: (String) -> Void = { _ in }
    var loadMac: (String, @escaping (ProcessTracker?) -> Void) -> Void = { $1(nil) }

    /// This Mac's history.
    private let local: ProcessTracker
    /// The history shown: this Mac's or another Mac's copy, nil when that Mac has none.
    private var tracker: ProcessTracker?
    private let macPopup = NSPopUpButton()
    private var macs: [(id: String, name: String)] = []
    /// The other Mac shown (nil: this one), the copy shown, and the newest load asked for.
    private var shownMac: String?
    private var shownVersion = ""
    private var macRequest = 0
    private let rangeControl = NSSegmentedControl(labels: ProcessTracker.Range.allCases.map(\.title), trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private let groupControl = NSSegmentedControl(labels: ["Apps", "Executables"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let table = NSTableView()
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let chartTitle = NSTextField(labelWithString: "")
    private let metricControl = NSSegmentedControl(labels: Metric.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let chart = ProcessHistoryChartView()
    private var selectedPath: String?
    private let restControl = NSSegmentedControl(labels: ["Alone", "With the rest"], trackingMode: .selectOne, target: nil, action: nil)
    /// What the chart shows: the selected program alone (`series`), or programs stacked
    /// (`overview`): the top ones, or the selected one and everything else.
    private var series: ProcessTracker.Series?
    private var overview: ProcessTracker.Overview?
    /// Counts the chart's requests; a reply to an older one is dropped.
    private var chartRequest = 0
    /// Each top program's place in the palette, kept while it stays among them.
    private var slots: [String: Int] = [:]
    /// The colours of the programs in the stack of all programs, shown next to their names.
    private var swatches: [String: NSColor] = [:]
    private var selectionChanged = false
    private var pendingDeselect: DispatchWorkItem?
    private var summary = ProcessTracker.Summary()
    private var rows: [Row] = []
    private var loaded = false
    private var restoring = false
    private static let frameName = "ProcessHistory"
    private static let rangeKey = "processHistoryRange"
    private static let groupKey = "processHistoryByExecutable"
    private static let metricKey = "processHistoryMetric"
    private static let restKey = "processHistoryWithRest"

    /// What the chart under the table shows.
    enum Metric: Int, CaseIterable {
        case cpu, energy, memory, disk, network
        var title: String { ["CPU", "Energy", "Memory", "Disk", "Network"][rawValue] }
    }

    struct Row {
        let name: String
        let path: String
        let s: ProcStats
        var avgCopies: Double { s.running > 0 ? s.copyTime / s.running : 0 }
        var avgLife: Double { s.exits > 0 ? s.lifetime / Double(s.exits) : -1 }
        var cpuPct: Double { s.running > 0 ? s.cpu / s.running * 100 : 0 }
        var energy: Double { s.detail ? s.energy : -1 }
        var power: Double { s.detail && s.running > 0 ? s.energy / s.running : -1 }
        /// CPU energy used on battery, in full charges (0.12: 12% of one). Negative: not known.
        var battery: Double { s.detail ? s.batteryEnergy / 3600 / (batteryWh ?? .infinity) : -1 }
        var ramAvg: Double { s.running > 0 ? s.ramTime / s.running : 0 }
        var diskRead: Double { s.detail ? s.diskRead : -1 }
        var diskWritten: Double { s.detail ? s.diskWritten : -1 }
        var childCpu: Double { s.detail ? s.childCpu : -1 }
        /// A full charge of that Mac's battery (Summary.batteryWh).
        var batteryWh: Double? = Battery.capacityWh
    }

    struct Column {
        let id: String
        let title: String
        let width: CGFloat
        let tip: String
        let text: (Row) -> String
        let value: (Row) -> Double
    }

    /// Battery only on a Mac that has one. The window has them all, and hides Battery for a Mac
    /// without (this one or the one it shows).
    static let columns: [Column] = allColumns.filter { $0.id != "battery" || Battery.capacityWh != nil }

    static let allColumns: [Column] = [
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
        Column(id: "childCpu", title: "Children", width: 72,
               tip: "CPU time of the processes it started that have ended, with theirs. They also count under their own names when a scan saw them, so this is not to be added to CPU time. System processes need the root helper.",
               text: { $0.childCpu >= 0 ? Fmt.duration($0.childCpu) : Fmt.dash }, value: { $0.childCpu }),
        Column(id: "energy", title: "Energy", width: 66, tip: "CPU energy used (GPU work is not included). System processes need the root helper.",
               text: { HistoryFmt.energy($0.energy) }, value: { $0.energy }),
        Column(id: "power", title: "Power", width: 58, tip: "Average CPU power while running",
               text: { HistoryFmt.power($0.power) }, value: { $0.power }),
        Column(id: "battery", title: "Battery", width: 58,
               tip: "CPU energy used while on battery, as a share of a full charge\(Battery.capacityWh.map { String(format: " (about %.0f Wh)", $0) } ?? ""). The display, GPU and the rest of the Mac are not included. System processes need the root helper.",
               text: { $0.battery >= 0 ? HistoryFmt.pct($0.battery * 100) : Fmt.dash }, value: { $0.battery }),
        Column(id: "ramAvg", title: "RAM avg", width: 62, tip: "Average memory while running, all copies together",
               text: { HistoryFmt.bytes($0.ramAvg) }, value: { $0.ramAvg }),
        Column(id: "ramPeak", title: "RAM peak", width: 66, tip: "Most memory seen at a scan, all copies together",
               text: { HistoryFmt.bytes($0.s.ramPeak) }, value: { $0.s.ramPeak }),
        Column(id: "diskRead", title: "Read", width: 58, tip: "Bytes read from disk. System processes need the root helper.",
               text: { HistoryFmt.bytes($0.diskRead) }, value: { $0.diskRead }),
        Column(id: "diskWritten", title: "Written", width: 62, tip: "Bytes written to disk. System processes need the root helper.",
               text: { HistoryFmt.bytes($0.diskWritten) }, value: { $0.diskWritten }),
        Column(id: "netIn", title: "Received", width: 66,
               tip: "Bytes received over Wi-Fi and Ethernet, counted since 0.1.10. Traffic through a VPN counts for the VPN's process; loopback is left out.",
               text: { HistoryFmt.bytes($0.s.netIn) }, value: { $0.s.netIn }),
        Column(id: "netOut", title: "Sent", width: 58,
               tip: "Bytes sent over Wi-Fi and Ethernet, counted since 0.1.10. Traffic through a VPN counts for the VPN's process; loopback is left out.",
               text: { HistoryFmt.bytes($0.s.netOut) }, value: { $0.s.netOut }),
    ]

    init(tracker: ProcessTracker) {
        local = tracker
        self.tracker = tracker
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1370, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Process History"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.contentMinSize = NSSize(width: 640, height: 490)
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
        macPopup.target = self
        macPopup.action = #selector(macChanged)
        macPopup.toolTip = "This Mac, or another of your Macs from its copy in iCloud Drive"
        macPopup.isHidden = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [macPopup, rangeControl, groupControl, spacer, search])
        bar.spacing = 12

        for c in Self.allColumns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.id == "name" ? 120 : 40
            col.headerToolTip = c.tip
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: c.id == "name")
            if c.id != "name" { col.headerCell.alignment = .right }
            col.isHidden = c.id == "battery" && Battery.capacityWh == nil
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
        table.action = #selector(rowClicked)
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

        chartTitle.font = .systemFont(ofSize: 12, weight: .medium)
        chartTitle.lineBreakMode = .byTruncatingMiddle
        chartTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metricControl.selectedSegment = min(Metric.allCases.count - 1, max(0, d.integer(forKey: Self.metricKey)))
        metricControl.target = self
        metricControl.action = #selector(metricChanged)
        metricControl.controlSize = .small
        restControl.selectedSegment = d.bool(forKey: Self.restKey) ? 1 : 0
        restControl.target = self
        restControl.action = #selector(restChanged)
        restControl.controlSize = .small
        restControl.toolTip = "The selected row on its own, or as its part of all of them"
        restControl.isHidden = true
        let chartSpacer = NSView()
        chartSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let chartBar = NSStackView(views: [chartTitle, chartSpacer, restControl, metricControl])
        chartBar.spacing = 12

        let content = NSView()
        for v in [bar, scroll, chartBar, chart, footer] as [NSView] {
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
            chartBar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            chartBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            chartBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            chart.topAnchor.constraint(equalTo: chartBar.bottomAnchor, constant: 6),
            chart.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            chart.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            chart.heightAnchor.constraint(equalToConstant: 200),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            footer.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window?.contentView = content
    }

    // MARK: - Data

    private var range: ProcessTracker.Range { ProcessTracker.Range(rawValue: rangeControl.selectedSegment) ?? .today }
    private var byExecutable: Bool { groupControl.selectedSegment == 1 }

    /// Reads the range again (when it changes, or the history shown does).
    func reload() {
        guard let tracker else {
            summary = ProcessTracker.Summary(batteryWh: nil)
            loaded = true
            rebuildRows()
            loadChart()
            return
        }
        tracker.summary(range) { [weak self] s in
            guard let self, self.tracker === tracker else { return }
            self.summary = s
            self.loaded = true
            self.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("battery"))?.isHidden = s.batteryWh == nil
            self.rebuildRows()
            self.loadChart()
        }
    }

    /// After a scan of this Mac.
    func scanned() {
        if shownMac == nil { reload() }
    }

    // MARK: - Other Macs

    /// The Macs that share changed, or what they shared did.
    func otherMacsChanged() {
        let list = otherMacs()
        if !list.elementsEqual(macs, by: { $0 == $1 }) {
            macs = list
            let menu = NSMenu()
            menu.addItem(withTitle: "This Mac", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
            for m in list { menu.addItem(withTitle: m.name, action: nil, keyEquivalent: "") }
            macPopup.menu = menu
            macPopup.isHidden = list.isEmpty
        }
        guard let id = shownMac else { macPopup.selectItem(at: 0); return }
        guard let i = macs.firstIndex(where: { $0.id == id }) else { show(nil); return } // forgotten, or sharing is off
        macPopup.selectItem(at: i + 2)
        if macVersion(id) != shownVersion { show(id) } else { updateFooter() } // a newer copy, or how old it is
    }

    @objc private func macChanged() {
        let i = macPopup.indexOfSelectedItem - 2
        let id = i >= 0 && i < macs.count ? macs[i].id : nil
        if let id { lookAt(id) } // asks for the latest if its copy is old (choosing it again: once more)
        if id != shownMac { show(id) } else { updateFooter() }
    }

    /// Shows this Mac (nil) or another Mac's newest copy.
    private func show(_ id: String?) {
        let changed = id != shownMac
        shownMac = id
        macRequest += 1
        let request = macRequest
        window?.title = macName.map { "Process History — \($0)" } ?? "Process History"
        guard let id else {
            macPopup.selectItem(at: 0)
            shownVersion = ""
            tracker = local
            reload()
            return
        }
        shownVersion = macVersion(id)
        if changed {
            // Until the copy is read: nothing of this Mac's next to the other Mac's name.
            tracker = nil
            loaded = false
            summary = ProcessTracker.Summary(batteryWh: nil)
            rebuildRows()
            loadChart()
        }
        loadMac(id) { [weak self] t in
            guard let self, self.macRequest == request else { return }
            self.tracker = t
            self.reload()
        }
    }

    private var macName: String? { shownMac.flatMap { id in macs.first { $0.id == id }?.name } }

    private var withRest: Bool { restControl.selectedSegment == 1 }
    private var metric: Metric { Metric(rawValue: metricControl.selectedSegment) ?? .cpu }

    /// Reads what the chart shows: the selected program alone or with the rest, or with nothing
    /// selected the top programs stacked.
    private func loadChart() {
        chartRequest += 1
        let request = chartRequest
        restControl.isHidden = selectedPath == nil
        guard let tracker else {
            series = nil
            overview = nil
            showChart()
            return
        }
        if let path = selectedPath, !withRest {
            tracker.series(path, range) { [weak self] s in
                guard let self, self.chartRequest == request else { return }
                self.series = s
                self.overview = nil
                self.showChart()
            }
            return
        }
        var paths = selectedPath.map { [$0] } ?? Self.top(Self.rows(summary, byExecutable: byExecutable), metric)
        if selectedPath == nil {
            slots = Self.slots(slots, top: paths)
            paths.sort { (slots[$0] ?? 0) < (slots[$1] ?? 0) } // stacked in the palette's order
        }
        tracker.overview(paths, range, byExecutable: byExecutable) { [weak self] o in
            guard let self, self.chartRequest == request else { return }
            self.overview = o
            self.series = nil
            self.showChart()
        }
    }

    private func showChart() {
        var marks: [String: NSColor] = [:]
        chartTitle.toolTip = selectedPath
        if let path = selectedPath, let series {
            chartTitle.stringValue = "\(ProcKey.name(path)) · per \(series.hourly ? "hour" : "day")"
            chart.message = series.points.contains { $0.stats.running > 0 }
                ? "Not known for system processes without the root helper." : "Not seen running in this range."
            chart.model = Self.chartModel(series, metric)
        } else if let o = overview {
            let colors = o.programs.map { ProcessHistoryChartView.palette[slots[$0.path] ?? 0] }
            chartTitle.stringValue = Self.stackTitle(selectedPath, hourly: o.hourly, byExecutable: byExecutable, metric, summary)
            chart.message = loaded ? "Nothing recorded in this range." : ""
            chart.model = Self.stackModel(o, metric, colors: colors, rest: selectedPath == nil ? "Other" : "Everything else")
            if selectedPath == nil, chart.model != nil {
                marks = Dictionary(uniqueKeysWithValues: zip(o.programs.map(\.path), colors))
            }
        } else {
            chartTitle.stringValue = ""
            chart.message = ""
            chart.model = nil
        }
        if marks != swatches {
            swatches = marks
            let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            if column >= 0 { table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: [column]) }
        }
    }

    /// What a stacked chart is of: all programs, or one and everything else.
    static func stackTitle(_ selected: String?, hourly: Bool, byExecutable: Bool, _ metric: Metric, _ summary: ProcessTracker.Summary) -> String {
        var title = selected.map { "\(ProcKey.name($0)) and everything else" } ?? "All \(byExecutable ? "executables" : "apps")"
        title += " · per \(hourly ? "hour" : "day")"
        // Energy and disk bytes of system processes are only known with the root helper.
        if metric == .energy || metric == .disk, summary.programs.contains(where: { !$0.stats.detail }) {
            title += " · system processes not included"
        }
        return title
    }

    /// The programs that get a colour of their own in the stack of all of them: the `limit` with
    /// the most of what the chart shows, each at least 1% of the total. Biggest first.
    static func top(_ rows: [Row], _ metric: Metric, limit: Int = ProcessHistoryChartView.palette.count) -> [String] {
        func value(_ s: ProcStats) -> Double {
            switch metric {
            case .cpu: return s.cpu
            case .energy: return s.energy
            case .memory: return s.ramTime
            case .disk: return s.diskWritten
            case .network: return s.netIn + s.netOut
            }
        }
        let total = rows.reduce(0) { $0 + value($1.s) }
        guard total > 0 else { return [] }
        return rows.filter { value($0.s) >= total * 0.01 }
            .sorted { value($0.s) != value($1.s) ? value($0.s) > value($1.s) : $0.path < $1.path }
            .prefix(limit).map(\.path)
    }

    /// Places in the palette for the programs in `top`: one that was there before keeps its
    /// place (and so its colour, when the range or the measure changes), new ones take the free
    /// places in order.
    static func slots(_ old: [String: Int], top: [String]) -> [String: Int] {
        var out = old.filter { top.contains($0.key) }
        var free = Set(0..<ProcessHistoryChartView.palette.count).subtracting(out.values).sorted()
        for p in top where out[p] == nil && !free.isEmpty { out[p] = free.removeFirst() }
        return out
    }

    /// Programs stacked in each column, then `rest` (all the others together) and, for CPU, what
    /// no scan could place. Nil when there is nothing to draw. Memory is averaged over the time
    /// the scans covered, not over the time each program ran, so that the parts add up.
    static func stackModel(_ o: ProcessTracker.Overview, _ metric: Metric, colors: [NSColor], rest: String) -> ProcessHistoryChartView.Model? {
        let n = o.starts.count
        func value(_ s: ProcStats, _ i: Int) -> Double {
            switch metric {
            case .cpu: return s.cpu
            case .energy: return s.energy
            case .memory: return o.awake[i] > 0 ? s.ramTime / o.awake[i] : 0
            case .disk: return s.diskWritten
            case .network: return s.netIn + s.netOut
            }
        }
        var stack = o.programs.enumerated().map { k, p in
            ProcessHistoryChartView.Segment(name: ProcKey.name(p.path), color: colors[k], values: (0..<n).map { value(p.points[$0], $0) })
        }
        let total = (0..<n).map { value(o.total[$0], $0) }
        let others = (0..<n).map { i in max(0, total[i] - stack.reduce(0) { $0 + $1.values[i] }) }
        // More than rounding leaves over.
        if zip(others, total).contains(where: { $0 > $1 * 1e-9 }) {
            stack.append(.init(name: rest, color: ProcessHistoryChartView.otherColor, values: others))
        }
        if metric == .cpu, o.unseen.contains(where: { $0.cpu > 0 }) {
            stack.append(.init(name: "Unseen", color: ProcessHistoryChartView.unseenColor, values: o.unseen.map(\.cpu)))
        }
        guard stack.contains(where: { $0.values.contains { $0 > 0 } }) else { return nil }
        let format: (Double) -> String, top: (Double) -> Double
        switch metric {
        case .cpu: (format, top) = (Fmt.duration, ProcessHistoryChartView.roundUpTime)
        case .energy: (format, top) = (HistoryFmt.energy, { ProcessHistoryChartView.roundUp($0 / 3600) * 3600 })
        case .memory, .disk, .network: (format, top) = (HistoryFmt.bytes, ProcessHistoryChartView.roundUp)
        }
        return .init(starts: o.starts, hourly: o.hourly, bars: [], barName: "", format: format, top: top, stack: stack)
    }

    /// The chart of one measure, or nil when there is nothing to draw. Columns are per hour or
    /// day; where the program wasn't running there is no column.
    static func chartModel(_ series: ProcessTracker.Series, _ metric: Metric) -> ProcessHistoryChartView.Model? {
        let pts = series.points.map(\.stats)
        func values(_ f: (ProcStats) -> Double?) -> [Double?] { pts.map { $0.running > 0 ? f($0) : nil } }
        var m: ProcessHistoryChartView.Model
        let starts = series.points.map(\.start)
        switch metric {
        case .cpu:
            m = .init(starts: starts, hourly: series.hourly, bars: values { $0.cpu }, barName: "CPU time",
                      format: Fmt.duration, top: ProcessHistoryChartView.roundUpTime)
            if pts.contains(where: { $0.detail && $0.childCpu > 0 }) {
                m.line = values { $0.detail ? $0.childCpu : nil }
                m.lineName = "Children’s CPU time"
            }
            m.extra = { i in
                let s = pts[i]
                guard s.running > 0 else { return [] }
                return ["Running \(Fmt.duration(s.running)), \(HistoryFmt.pct(s.cpu / s.running * 100)) CPU on average"]
            }
        case .energy:
            m = .init(starts: starts, hourly: series.hourly, bars: values { $0.detail ? $0.energy : nil }, barName: "CPU energy",
                      format: HistoryFmt.energy, top: { ProcessHistoryChartView.roundUp($0 / 3600) * 3600 })
            m.extra = { i in
                let s = pts[i]
                guard s.running > 0, s.detail else { return [] }
                return ["\(HistoryFmt.power(s.energy / s.running)) on average over \(Fmt.duration(s.running)) running"]
            }
        case .memory:
            m = .init(starts: starts, hourly: series.hourly, bars: values { $0.ramTime / $0.running }, barName: "Average memory",
                      line: values { $0.ramPeak }, lineName: "Peak", format: HistoryFmt.bytes, top: ProcessHistoryChartView.roundUp)
        case .disk:
            m = .init(starts: starts, hourly: series.hourly, bars: values { $0.detail ? $0.diskWritten : nil }, barName: "Written",
                      line: values { $0.detail ? $0.diskRead : nil }, lineName: "Read", format: HistoryFmt.bytes,
                      top: ProcessHistoryChartView.roundUp)
        case .network:
            // A program that only ran between two scans has no running time, but can have bytes.
            let moved: ((ProcStats) -> Double) -> [Double?] = { f in pts.map { $0.running > 0 || $0.netIn + $0.netOut > 0 ? f($0) : nil } }
            m = .init(starts: starts, hourly: series.hourly, bars: moved { $0.netIn }, barName: "Received",
                      line: moved { $0.netOut }, lineName: "Sent", format: HistoryFmt.bytes, top: ProcessHistoryChartView.roundUp)
        }
        return m.bars.contains { $0 != nil } ? m : nil
    }

    private func rebuildRows() {
        let filter = search.stringValue.trimmingCharacters(in: .whitespaces)
        rows = Self.rows(summary, byExecutable: byExecutable, filter: filter)
        sortRows()
        table.reloadData()
        restoreSelection()
        updateFooter()
    }

    /// Selects the chart's program again after the rows changed (it may be filtered out: then
    /// the chart stays, with no row selected).
    private func restoreSelection() {
        restoring = true
        defer { restoring = false }
        if let path = selectedPath, let i = rows.firstIndex(where: { $0.path == path }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
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
            return Row(name: name, path: p.path, s: p.stats, batteryWh: summary.batteryWh)
        }
    }

    /// Sorts by a column id; ties (often zeros) fall back to CPU time, then name.
    static func sort(_ rows: inout [Row], by key: String, ascending: Bool) {
        guard let col = allColumns.first(where: { $0.id == key }) else { return }
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
        var lines = Self.footer(summary, range: range, empty: rows.isEmpty && summary.programs.isEmpty && loaded && shownMac == nil)
        if let id = shownMac, let name = macName {
            lines.insert(Self.copyLine(name: name, made: tracker?.copy?.made, status: macStatus(id), loaded: loaded,
                                       now: Date().timeIntervalSince1970), at: 0)
        }
        footer.stringValue = lines.joined(separator: "\n")
    }

    /// The first line under another Mac's table: when its copy was made and how old it is, or
    /// that the latest is on its way, or why there is none. `status` is OtherMacs.status.
    static func copyLine(name: String, made: Double?, status: String, loaded: Bool, now: Double) -> String {
        guard let made else {
            if !loaded || status == "updating…" { return "Getting \(name)’s process history…" }
            return "\(name) has no process history in iCloud Drive yet. It needs process history on, and this version of MacMon Indicator."
        }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(Date(timeIntervalSince1970: made), inSameDayAs: Date(timeIntervalSince1970: now))
            ? "HH:mm" : "EEE d MMM HH:mm"
        let age = status.isEmpty ? ShareFolder.ago(now - made) : status
        return "\(name)’s copy from \(f.string(from: Date(timeIntervalSince1970: made))) · \(age)" + (age.hasSuffix("…") ? "" : ".")
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
                line += summary.helper == .ok || summary.helper == .old ? "." : ", and the kernel's own work."
            }
            parts.append(line)
        }
        if empty {
            parts.append("Collecting: numbers appear after the second scan.")
        }
        if !summary.unusual.isEmpty {
            parts.append("Unusual today: " + summary.unusual.prefix(3).map(Self.unusualText).joined(separator: "; ") + ".")
        }
        let partial = summary.programs.contains { !$0.stats.detail }
        switch summary.helper {
        case .outdated:
            parts.append("The root helper is out of date: turn “Show system processes” off and on in Settings for their energy and disk use.")
        case .old:
            parts.append("The root helper is an older version: turn “Show system processes” off and on in Settings for the children’s CPU time of system processes.")
        case .unreachable:
            parts.append("Root helper not reachable: system processes show CPU time and memory only.")
        case .notUsed where partial:
            parts.append("System processes show CPU time and memory only. Turn on “Show system processes” in Settings for their energy and disk use.")
        default:
            break
        }
        return parts
    }

    /// "Spotlight 2h 10m of CPU time (usually 12m 00s a day)"
    static func unusualText(_ u: ProcessTracker.Unusual) -> String {
        "\(ProcKey.name(u.path)) \(Fmt.duration(u.today)) of CPU time (usually \(Fmt.duration(u.usual)) a day)"
    }

    // MARK: - Actions

    @objc private func rangeChanged() {
        UserDefaults.standard.set(rangeControl.selectedSegment, forKey: Self.rangeKey)
        reload()
    }

    @objc private func metricChanged() {
        UserDefaults.standard.set(metricControl.selectedSegment, forKey: Self.metricKey)
        loadChart()
    }

    @objc private func restChanged() {
        UserDefaults.standard.set(withRest, forKey: Self.restKey)
        loadChart()
    }

    /// A click on the row that was already selected takes the selection off (back to all
    /// programs), unless it turns out to be the first click of a double-click.
    @objc private func rowClicked() {
        defer { selectionChanged = false }
        guard !selectionChanged, table.clickedRow >= 0, table.clickedRow == table.selectedRow else { return }
        let work = DispatchWorkItem { [weak self] in self?.table.deselectAll(nil) }
        pendingDeselect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// Esc: back to all programs.
    override func cancelOperation(_ sender: Any?) {
        if selectedPath != nil { table.deselectAll(nil) }
    }

    /// For previews: the given range and measure, with the first row selected or none, of this
    /// Mac or another (`mac`, one of `otherMacs`).
    func preview(range: ProcessTracker.Range, metric: Metric, select: Bool, withRest: Bool, mac: String? = nil) {
        rangeControl.selectedSegment = range.rawValue
        metricControl.selectedSegment = metric.rawValue
        restControl.selectedSegment = withRest ? 1 : 0
        selectedPath = select ? rows.first?.path : nil
        if let i = macs.firstIndex(where: { $0.id == mac }) { macPopup.selectItem(at: i + 2) }
        if mac != nil { show(mac) } else { reload() }
    }

    @objc private func groupChanged() {
        UserDefaults.standard.set(byExecutable, forKey: Self.groupKey)
        // An app is not among the executables, nor an executable inside an app among the apps.
        if let path = selectedPath, !Self.rows(summary, byExecutable: byExecutable).contains(where: { $0.path == path }) {
            selectedPath = nil
        }
        rebuildRows()
        loadChart()
    }

    func controlTextDidChange(_ obj: Notification) { rebuildRows() }

    @objc private func revealInFinder() {
        pendingDeselect?.cancel()
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
        restoreSelection()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoring else { return }
        let r = table.selectedRow
        let path = r >= 0 && r < rows.count ? rows[r].path : nil
        selectionChanged = true
        DispatchQueue.main.async { [weak self] in self?.selectionChanged = false } // after this click's action, if it was a click
        guard path != selectedPath else { return }
        selectedPath = path
        loadChart()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let col = Self.allColumns.first(where: { $0.id == id.rawValue }) else { return nil }
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
            // Names have a place before them for the colour of their part of the chart.
            if col.id == "name" {
                let mark = SwatchView()
                mark.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(mark)
                NSLayoutConstraint.activate([
                    mark.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    mark.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    mark.widthAnchor.constraint(equalToConstant: 9),
                    mark.heightAnchor.constraint(equalToConstant: 9),
                ])
            }
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: col.id == "name" ? 19 : 4),
                f.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                f.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let r = rows[row]
        if col.id == "name" { cell.subviews.compactMap { $0 as? SwatchView }.first?.color = swatches[r.path] }
        cell.textField?.stringValue = col.text(r)
        let unknown = col.value(r) < 0
        cell.textField?.textColor = unknown ? .tertiaryLabelColor : .labelColor
        cell.textField?.toolTip = col.id == "name" ? r.path : (col.id == "ramPeak" ? "Biggest single copy: \(HistoryFmt.bytes(r.s.ramOnePeak))" :
            (col.id == "cpu" && r.s.detail ? "On performance cores: \(Fmt.duration(r.s.pcore))" :
            (col.id == "battery" && r.s.detail ? "On battery: \(HistoryFmt.energy(r.s.batteryEnergy)) of \(HistoryFmt.energy(r.s.energy))" : nil)))
        return cell
    }
}

/// A small square of a chart colour (nothing when there is none).
private final class SwatchView: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
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
