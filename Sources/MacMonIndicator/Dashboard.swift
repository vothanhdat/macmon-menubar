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
    private let hasBattery: Bool
    private var fanCount: Int
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

    init(history: HistoryStore, latest: Sample?, hasBattery: Bool, inWindow: Bool = false) {
        self.hasBattery = hasBattery
        self.inWindow = inWindow
        fanCount = latest?.fanCount ?? 0
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
        charts.rows = ChartsView.rows(for: Settings.shared.chartIDs, hasBattery: hasBattery, fanCount: fanCount)
        reflow()
    }

    private func reflow() {
        if inWindow { onReflow?() } else { layoutMenu() }
    }

    private func layoutMenu() {
        tierBar.frame = NSRect(x: 0, y: 2, width: Self.width, height: TierBar.height)
        charts.frame = NSRect(x: 0, y: tierBar.frame.maxY + 6, width: Self.width,
                              height: ChartsView.height(count: charts.rows.count, layout: charts.layout, zoomed: charts.zoomed != nil))
        top.frame = NSRect(x: 0, y: 0, width: Self.width, height: charts.frame.maxY + 2)
        processes.frame = NSRect(x: 0, y: 0, width: Self.width, height: ProcessListView.height)
    }

    // MARK: - Window

    /// Space around the charts and the process list in a window: tabs above the charts, the
    /// separator between, a margin at the bottom.
    private static let windowChrome: CGFloat = (2 + TierBar.height + 6) + 2 + (5 + 1 + 5) + 6

    /// Smallest window content that shows everything: menu width, charts at the height chosen in
    /// Settings, the menu's number of process rows.
    var minWindowSize: NSSize {
        let layout = Settings.shared.chartLayout
        return NSSize(width: Self.width, height: Self.windowChrome + ChartsView.height(count: charts.rows.count, layout: layout)
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
        layout.height = max(base.chartHeight, ChartsView.chartHeight(fitting: size.height - Self.windowChrome - procH,
                                                                     count: charts.rows.count, layout: base))
        charts.layout = layout
        processes.rowCount = rows

        tierBar.frame = NSRect(x: 0, y: 2, width: w, height: TierBar.height)
        let chartsH = ChartsView.height(count: charts.rows.count, layout: layout, zoomed: charts.zoomed != nil)
        charts.frame = NSRect(x: 0, y: tierBar.frame.maxY + 6, width: w, height: chartsH)
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
        if #available(macOS 27, *) { more.forEach { $0.preferredImageVisibility = .hidden } }
        items += more
        return items
    }

    func update(sample: Sample) {
        if sample.fanCount != fanCount {
            fanCount = sample.fanCount
            charts.rows = ChartsView.rows(for: Settings.shared.chartIDs, hasBattery: hasBattery, fanCount: fanCount)
            reflow()
        }
        charts.latest = sample
    }

    private func showTime(_ t: TimeInterval?) {
        guard let t else { tierBar.timeText = "Now"; return }
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

    private let labels = HistoryStore.tiers.map(\.label)
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
        if let i = tabRects().firstIndex(where: { $0.contains(p) }), i != selected {
            selected = i
            onSelect?(i)
        }
    }
}
