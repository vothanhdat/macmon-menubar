import AppKit

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The dashboard: history range tabs, charts and top processes. The status item's menu shows it,
/// as custom views inside a real NSMenu, so it gets the same glass background, corners, shadow and
/// behavior as every other menu bar menu. A window can show it too (see DashboardWindow.swift),
/// at any size. Built when shown, released when closed.
final class Dashboard {
    /// The menu's width, and the window's minimum.
    static let width: CGFloat = 420
    static let inset: CGFloat = 14 // lines up with the titles of the standard items below
    /// Most process rows a tall window shows.
    static let maxProcessRows = 20

    let charts = ChartsView()
    let processes = ProcessListView()
    private let tierBar = TierBar()
    private let top = FlippedView()
    private let separator = NSBox()
    // This Mac's.
    private let hasBattery: Bool
    private var fanCount: Int
    private let localHistory: HistoryStore
    private var localLatest: Sample?
    // The shown Mac's.
    private var shownBattery: Bool
    private var shownFans: Int
    private let timeFormatter = DateFormatter()
    private let statusItem = NSMenuItem()
    /// In a window: everything stacked in one view, laid out to the window's content size.
    let windowView = FlippedView()
    private let inWindow: Bool
    private var windowSize = NSSize(width: Dashboard.width, height: 0)
    /// In a window: called when the content's minimum size may have changed (charts added or removed).
    var onReflow: (() -> Void)?
    /// In the menu: opens the dashboard in a window; shows a button for it in the tabs row.
    var onOpenWindow: (() -> Void)? {
        get { tierBar.onPopOut }
        set { tierBar.onPopOut = newValue }
    }

    // MARK: - Other Macs

    /// Your other Macs that share through iCloud Drive (OtherMacs.swift). With any, a row of names
    /// above the range tabs picks the Mac to show, this one first.
    struct OtherMac: Equatable {
        let id: String
        let name: String
    }
    var otherMacs: [OtherMac] = [] { didSet { if otherMacs != oldValue { macsChanged() } } }
    /// A Mac was picked (nil: this one), or the shown one clicked again. Answered with `show(_:)`.
    var onSelectMac: ((String?) -> Void)?
    /// What to say about another Mac's copy: how old it is, or that the latest was asked for.
    var macStatus: ((String) -> String)?
    /// The Mac shown, nil for this one, and which of its copies.
    private(set) var shownMac: String?
    private(set) var shownVersion: String?
    /// This Mac's processes, shown while this Mac is.
    var localProcesses: ProcSnapshot? { didSet { if shownMac == nil { processes.snapshot = localProcesses } } }
    private let macBar = TierBar()
    private let asOfFormatter = DateFormatter()
    /// The pointer is over the charts: the range row shows the time under it.
    private var hovering = false

    /// Another Mac's copy, to show instead of this Mac.
    struct Remote {
        let id: String
        /// OtherMacs.version: which copy this is.
        let version: String
        /// Nil when its copy couldn't be read: the charts stay empty.
        let history: HistoryStore?
        /// Its latest reading; `time` is when the copy was made.
        let latest: Sample
        let hasBattery: Bool
        let processes: ProcSnapshot?
        let processNote: String
    }

    func show(_ r: Remote) {
        guard otherMacs.contains(where: { $0.id == r.id }) else { return }
        shownMac = r.id
        shownVersion = r.version
        charts.history = r.history
        charts.asOf = r.latest.time
        charts.latest = r.latest
        shownBattery = r.hasBattery
        shownFans = r.latest.fanCount
        processes.snapshot = r.processes
        processes.note = r.processNote
        shownChanged()
    }

    private func showLocal() {
        shownMac = nil
        shownVersion = nil
        charts.history = localHistory
        charts.asOf = nil
        charts.latest = localLatest
        shownBattery = hasBattery
        shownFans = fanCount
        processes.snapshot = localProcesses
        processes.note = nil
        shownChanged()
    }

    private func shownChanged() {
        macBar.selected = selectedMacIndex
        if !hovering { tierBar.timeText = restingTime }
        loadSettings() // the shown Mac's charts
    }

    private var selectedMacIndex: Int {
        shownMac.flatMap { id in otherMacs.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
    }

    private func picked(_ i: Int) {
        let id = i > 0 && i <= otherMacs.count ? otherMacs[i - 1].id : nil
        if id == nil { showLocal() }
        onSelectMac?(id)
    }

    private func macsChanged() {
        macBar.labels = otherMacs.isEmpty ? [] : ["This Mac"] + otherMacs.map { Self.shortName($0.name) }
        if let id = shownMac, !otherMacs.contains(where: { $0.id == id }) { showLocal() }
        macBar.selected = selectedMacIndex
        if otherMacs.isEmpty { macBar.removeFromSuperview() } else if macBar.superview == nil { top.addSubview(macBar) }
        reflow()
    }

    /// Names longer than this are cut, so a few Macs fit side by side.
    private static func shortName(_ name: String) -> String {
        name.count > 16 ? String(name.prefix(15)) + "…" : name
    }

    /// What the range row says while the pointer isn't over the charts: "Now", or when another
    /// Mac's copy was made and how old it is ("10:15 · 40 min ago"; an older one: "2 days ago").
    private var restingTime: String {
        guard let id = shownMac, let t = charts.asOf else { return "Now" }
        let status = macStatus?(id) ?? ""
        let date = Date(timeIntervalSince1970: t)
        guard Calendar.current.isDateInToday(date) || status.isEmpty else { return status }
        let format = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE d MMM HH:mm"
        if asOfFormatter.dateFormat != format { asOfFormatter.dateFormat = format }
        let time = asOfFormatter.string(from: date)
        return status.isEmpty ? time : "\(time) · \(status)"
    }

    /// The age of another Mac's copy, or of a request to it, changed.
    func updateMacStatus() {
        if shownMac != nil, !hovering { tierBar.timeText = restingTime }
    }

    // MARK: -

    init(history: HistoryStore, latest: Sample?, hasBattery: Bool, inWindow: Bool = false) {
        self.hasBattery = hasBattery
        self.inWindow = inWindow
        fanCount = latest?.fanCount ?? 0
        localHistory = history
        localLatest = latest
        shownBattery = hasBattery
        shownFans = fanCount
        charts.history = history
        charts.latest = latest
        let saved = UserDefaults.standard.string(forKey: "historyRange") ?? HistoryStore.defaultTierLabel
        let tier = HistoryStore.tiers.firstIndex { $0.label == saved } ?? 0
        charts.tier = tier
        tierBar.selected = tier
        tierBar.onSelect = { [weak self] i in
            self?.charts.tier = i
            UserDefaults.standard.set(HistoryStore.tiers[i].label, forKey: "historyRange")
        }
        charts.onHover = { [weak self] t in self?.showTime(t) }
        charts.onZoom = { [weak self] in self?.reflow() }
        macBar.labels = []
        macBar.timeText = ""
        macBar.reselects = true
        macBar.onSelect = { [weak self] i in self?.picked(i) }
        top.addSubview(tierBar)
        top.addSubview(charts)
        statusItem.isEnabled = false
        if inWindow {
            separator.boxType = .separator
            windowView.addSubview(top)
            windowView.addSubview(separator)
            windowView.addSubview(processes)
        }
        loadSettings()
    }

    /// Picks up the chart settings (which charts, columns, height); a window keeps showing while they change.
    func loadSettings() {
        charts.layout = Settings.shared.chartLayout
        charts.rows = ChartsView.rows(for: Settings.shared.chartIDs, hasBattery: shownBattery, fanCount: shownFans)
        reflow()
    }

    private func reflow() {
        if inWindow { onReflow?() } else { layoutMenu() }
    }

    /// The Macs' row (when there are other Macs) and the range tabs. Returns where the charts start.
    private func layoutBars(width w: CGFloat) -> CGFloat {
        var y: CGFloat = 2
        if macBar.superview != nil {
            macBar.frame = NSRect(x: 0, y: y, width: w, height: TierBar.height)
            y = macBar.frame.maxY + 2
        }
        tierBar.frame = NSRect(x: 0, y: y, width: w, height: TierBar.height)
        return tierBar.frame.maxY + 6
    }

    private var macBarHeight: CGFloat { otherMacs.isEmpty ? 0 : TierBar.height + 2 }

    private func layoutMenu() {
        let chartsY = layoutBars(width: Self.width)
        charts.frame = NSRect(x: 0, y: chartsY, width: Self.width,
                              height: ChartsView.height(count: charts.rows.count, layout: charts.layout, zoomed: charts.zoomed != nil))
        top.frame = NSRect(x: 0, y: 0, width: Self.width, height: charts.frame.maxY + 2)
        processes.frame = NSRect(x: 0, y: 0, width: Self.width, height: ProcessListView.height)
    }

    // MARK: - Window

    /// Space around the charts and the process list in a window: tabs above the charts, the
    /// separator between, a margin at the bottom.
    private var windowChrome: CGFloat { (2 + macBarHeight + TierBar.height + 6) + 2 + (5 + 1 + 5) + 6 }

    /// Smallest window content that shows everything: menu width, charts at the height chosen in
    /// Settings, the menu's number of process rows.
    var minWindowSize: NSSize {
        let layout = Settings.shared.chartLayout
        return NSSize(width: Self.width, height: windowChrome + ChartsView.height(count: charts.rows.count, layout: layout)
                      + ProcessListView.height(rows: ProcessListView.defaultRows))
    }

    /// Fills a window's content size. Height beyond the minimum goes about two thirds to the charts
    /// and a third to more process rows (up to `maxProcessRows`); width goes to the charts.
    func layout(windowSize size: NSSize) {
        windowSize = size
        let w = max(Self.width, size.width)
        let base = Settings.shared.chartLayout
        let extra = max(0, size.height - minWindowSize.height)
        let rows = min(Self.maxProcessRows, ProcessListView.defaultRows + Int(extra / 3 / ProcessListView.rowH))
        let procH = ProcessListView.height(rows: rows)
        var layout = base
        layout.height = max(base.chartHeight, ChartsView.chartHeight(fitting: size.height - windowChrome - procH,
                                                                     count: charts.rows.count, layout: base))
        charts.layout = layout
        processes.rowCount = rows

        let chartsY = layoutBars(width: w)
        let chartsH = ChartsView.height(count: charts.rows.count, layout: layout, zoomed: charts.zoomed != nil)
        charts.frame = NSRect(x: 0, y: chartsY, width: w, height: chartsH)
        top.frame = NSRect(x: 0, y: 0, width: w, height: charts.frame.maxY + 2)
        separator.frame = NSRect(x: Self.inset, y: top.frame.maxY + 5, width: w - Self.inset * 2, height: 1)
        processes.frame = NSRect(x: 0, y: separator.frame.maxY + 5, width: w, height: procH)
        windowView.frame = NSRect(x: 0, y: 0, width: w, height: max(size.height, processes.frame.maxY + 6))
    }

    // MARK: - Menu

    /// Items for the status menu, top to bottom.
    func items(status: String?, target: AnyObject, openWindow: Selector, processHistory: Selector?, about: Selector,
               settings: Selector, quit: Selector) -> [NSMenuItem] {
        let chartsItem = NSMenuItem()
        chartsItem.view = top
        let procItem = NSMenuItem()
        procItem.view = processes
        var items: [NSMenuItem] = [chartsItem, .separator(), procItem, .separator()]
        if let status {
            statusItem.title = status
            items.append(statusItem)
        }
        let w = NSMenuItem(title: "Open in Window", action: openWindow, keyEquivalent: "")
        w.target = target
        let a = NSMenuItem(title: "About MacMon Indicator", action: about, keyEquivalent: "")
        a.target = target
        let s = NSMenuItem(title: "Settings…", action: settings, keyEquivalent: ",")
        s.target = target
        let q = NSMenuItem(title: "Quit MacMon Indicator", action: quit, keyEquivalent: "q")
        q.target = target
        var more = [w]
        if let processHistory {
            let h = NSMenuItem(title: "Process History", action: processHistory, keyEquivalent: "")
            h.target = target
            more.append(h)
        }
        more += [a, s, q]
        // macOS 27 adds a gear to "Settings…" on its own; plain text keeps the items alike.
        // The property is new in the macOS 27 SDK, which comes with Swift 6.4: an older Xcode
        // (as on GitHub's runners) builds without this line, and such a build shows the gear.
        #if compiler(>=6.4)
        if #available(macOS 27, *) { more.forEach { $0.preferredImageVisibility = .hidden } }
        #endif
        items += more
        return items
    }

    /// This Mac's newest reading.
    func update(sample: Sample) {
        localLatest = sample
        updateMacStatus()
        if sample.fanCount != fanCount {
            fanCount = sample.fanCount
            if shownMac == nil {
                shownFans = fanCount
                loadSettings()
            }
        }
        if shownMac == nil { charts.latest = sample }
    }

    private func showTime(_ t: TimeInterval?) {
        hovering = t != nil
        guard let t else { tierBar.timeText = restingTime; return }
        let tier = charts.tier
        let short = HistoryStore.tiers[tier].bucket < 60
        let format = short ? "HH:mm:ss" : (HistoryStore.tiers[tier].bucket < 1800 ? "HH:mm" : "EEE d MMM HH:mm")
        if timeFormatter.dateFormat != format { timeFormatter.dateFormat = format } // setting it re-parses the format
        let start = timeFormatter.string(from: Date(timeIntervalSince1970: t))
        if HistoryStore.tiers[tier].bucket > 1 && HistoryStore.tiers[tier].bucket < 1800 {
            let end = timeFormatter.string(from: Date(timeIntervalSince1970: t + HistoryStore.tiers[tier].bucket))
            tierBar.timeText = start == end ? start : "\(start)–\(end)"
        } else {
            tierBar.timeText = start
        }
    }

    /// Everything stacked in one view, for snapshot rendering.
    func snapshotView() -> NSView {
        if inWindow { return windowView }
        let v = FlippedView()
        let sep = NSBox(frame: NSRect(x: Self.inset, y: top.frame.maxY + 5, width: Self.width - Self.inset * 2, height: 1))
        sep.boxType = .separator
        v.addSubview(top)
        v.addSubview(sep)
        processes.frame.origin.y = sep.frame.maxY + 5
        v.addSubview(processes)
        v.frame = NSRect(x: 0, y: 0, width: Self.width, height: processes.frame.maxY + 6)
        return v
    }
}

/// Header of the dashboard: history range tabs (left) and the hovered time (right). In the menu,
/// a button at the far right opens the dashboard in a window.
final class TierBar: NSView {
    static let height: CGFloat = 24
    var selected = 0 { didSet { needsDisplay = true } }
    /// Changes with every pointer move over the charts, so it is drawn in a layer of its own
    /// (see TextLayer.swift); the tabs are not redrawn.
    var timeText = "Now" { didSet { if timeText != oldValue { showTime() } } }
    var onSelect: ((Int) -> Void)?
    /// Shows the "open in window" button when set.
    var onPopOut: (() -> Void)? {
        didSet { if (onPopOut == nil) != (oldValue == nil) { needsDisplay = true; showTime() } }
    }
    private let popOutIcon: NSImage? = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: "Open in Window")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor, .secondaryLabelColor])))

    /// The tabs: the history ranges, or the Macs to choose from (see Dashboard).
    var labels = HistoryStore.tiers.map(\.label) { didSet { if labels != oldValue { needsDisplay = true } } }
    /// Clicking the selected tab calls `onSelect` again (to ask another Mac for the latest).
    var reselects = false
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let timeAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                            .foregroundColor: NSColor.secondaryLabelColor]
    private let timeHost = LayerHostView()
    private lazy var timeLayer = timeHost.addTextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        timeHost.autoresizingMask = [.width, .height]
        addSubview(timeHost)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        timeHost.frame = bounds
        showTime()
    }

    /// The "open in window" button, or nil without one.
    private var popOutRect: NSRect? {
        guard onPopOut != nil, let size = popOutIcon?.size else { return nil }
        return NSRect(x: bounds.width - Dashboard.inset - size.width, y: 12 - size.height / 2, width: size.width, height: size.height)
    }

    /// Right-aligned (left of the button, if any), vertically centered.
    private func timeRect(_ size: NSSize) -> CGRect {
        let right = popOutRect.map { $0.minX - 8 } ?? bounds.width - Dashboard.inset
        return CGRect(x: right - size.width, y: 12 - size.height / 2, width: size.width, height: size.height)
    }

    private func showTime() {
        let t = timeText as NSString
        let r = timeRect(t.size(withAttributes: timeAttrs))
        timeLayer.show(r) { [timeAttrs] in t.draw(at: r.origin, withAttributes: timeAttrs) }
    }

    private func tabRects() -> [NSRect] {
        var x = Dashboard.inset - 7
        return labels.map { label in
            let w = ceil((label as NSString).size(withAttributes: [.font: font]).width) + 14
            defer { x += w + 2 }
            return NSRect(x: x, y: 2, width: w, height: 20)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, r) in tabRects().enumerated() {
            let isSel = i == selected
            if isSel {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isSel ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor,
            ]
            let s = labels[i] as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        }
        if let r = popOutRect { popOutIcon?.draw(in: r) }
        // Offscreen (snapshots) the time layer isn't shown, so draw the time here.
        if window == nil {
            let t = timeText as NSString
            t.draw(at: timeRect(t.size(withAttributes: timeAttrs)).origin, withAttributes: timeAttrs)
        }
    }

    // Menus deliver mouseUp to custom item views; the menu stays open (unless the button closes it).
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let r = popOutRect, r.insetBy(dx: -4, dy: -4).contains(p) { onPopOut?(); return }
        if let i = tabRects().firstIndex(where: { $0.contains(p) }), i != selected || reselects {
            selected = i
            onSelect?(i)
        }
    }
}
