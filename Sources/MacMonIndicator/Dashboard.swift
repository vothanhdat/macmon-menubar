import AppKit

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Content of the status item's menu. It is a real NSMenu, so it gets the same glass background,
/// corners, shadow and behavior as every other menu bar menu. The charts and the process list
/// are custom views inside menu items. Built when the menu opens, released when it closes.
final class DashboardMenu {
    static let width: CGFloat = 420
    static let inset: CGFloat = 14 // lines up with the titles of the standard items below

    let charts = ChartsView()
    let processes = ProcessListView()
    private let tierBar = TierBar()
    private let top = FlippedView()
    private let hasBattery: Bool
    private var fanCount: Int
    private let timeFormatter = DateFormatter()
    private let statusItem = NSMenuItem()

    init(history: HistoryStore, latest: Sample?, hasBattery: Bool) {
        self.hasBattery = hasBattery
        fanCount = latest?.fanCount ?? 0
        charts.history = history
        charts.latest = latest
        charts.layout = Settings.shared.chartLayout
        charts.rows = ChartsView.rows(for: Settings.shared.chartIDs, hasBattery: hasBattery, fanCount: fanCount)
        let saved = UserDefaults.standard.string(forKey: "historyRange") ?? HistoryStore.defaultTierLabel
        let tier = HistoryStore.tiers.firstIndex { $0.label == saved } ?? 0
        charts.tier = tier
        tierBar.selected = tier
        tierBar.onSelect = { [weak self] i in
            self?.charts.tier = i
            UserDefaults.standard.set(HistoryStore.tiers[i].label, forKey: "historyRange")
        }
        charts.onHover = { [weak self] t in self?.showTime(t) }
        charts.onZoom = { [weak self] in self?.layout() }
        top.addSubview(tierBar)
        top.addSubview(charts)
        statusItem.isEnabled = false
        layout()
    }

    private func layout() {
        tierBar.frame = NSRect(x: 0, y: 2, width: Self.width, height: TierBar.height)
        charts.frame = NSRect(x: 0, y: tierBar.frame.maxY + 6, width: Self.width,
                              height: ChartsView.height(count: charts.rows.count, layout: charts.layout, zoomed: charts.zoomed != nil))
        top.frame = NSRect(x: 0, y: 0, width: Self.width, height: charts.frame.maxY + 2)
        processes.frame = NSRect(x: 0, y: 0, width: Self.width, height: ProcessListView.height)
    }

    /// Items for the status menu, top to bottom.
    func items(status: String?, target: AnyObject, about: Selector, settings: Selector, quit: Selector) -> [NSMenuItem] {
        let chartsItem = NSMenuItem()
        chartsItem.view = top
        let procItem = NSMenuItem()
        procItem.view = processes
        var items: [NSMenuItem] = [chartsItem, .separator(), procItem, .separator()]
        if let status {
            statusItem.title = status
            items.append(statusItem)
        }
        let a = NSMenuItem(title: "About MacMon Indicator", action: about, keyEquivalent: "")
        a.target = target
        let s = NSMenuItem(title: "Settings…", action: settings, keyEquivalent: ",")
        s.target = target
        let q = NSMenuItem(title: "Quit MacMon Indicator", action: quit, keyEquivalent: "q")
        q.target = target
        items += [a, s, q]
        return items
    }

    func update(sample: Sample) {
        if sample.fanCount != fanCount {
            fanCount = sample.fanCount
            charts.rows = ChartsView.rows(for: Settings.shared.chartIDs, hasBattery: hasBattery, fanCount: fanCount)
            layout()
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
        if HistoryStore.tiers[tier].bucket < 1800 {
            let end = timeFormatter.string(from: Date(timeIntervalSince1970: t + HistoryStore.tiers[tier].bucket))
            tierBar.timeText = start == end ? start : "\(start)–\(end)"
        } else {
            tierBar.timeText = start
        }
    }

    /// Everything stacked in one view, for snapshot rendering.
    func snapshotView() -> NSView {
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

/// Header of the menu: history range tabs (left) and the hovered time (right).
final class TierBar: NSView {
    static let height: CGFloat = 24
    var selected = 0 { didSet { needsDisplay = true } }
    /// Changes with every pointer move over the charts, so it is drawn in a layer of its own
    /// (see TextLayer.swift); the tabs are not redrawn.
    var timeText = "Now" { didSet { if timeText != oldValue { showTime() } } }
    var onSelect: ((Int) -> Void)?

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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        timeHost.frame = bounds
        showTime()
    }

    /// Right-aligned, vertically centered.
    private func showTime() {
        let t = timeText as NSString
        let size = t.size(withAttributes: timeAttrs)
        let r = CGRect(x: bounds.width - DashboardMenu.inset - size.width, y: 12 - size.height / 2, width: size.width, height: size.height)
        timeLayer.show(r) { [timeAttrs] in t.draw(at: r.origin, withAttributes: timeAttrs) }
    }

    private func tabRects() -> [NSRect] {
        var x = DashboardMenu.inset - 7
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
        // Offscreen (snapshots) the time layer isn't shown, so draw the time here.
        if window == nil {
            let t = timeText as NSString
            let size = t.size(withAttributes: timeAttrs)
            t.draw(at: NSPoint(x: bounds.width - DashboardMenu.inset - size.width, y: 12 - size.height / 2), withAttributes: timeAttrs)
        }
    }

    // Menus deliver mouseUp to custom item views; the menu stays open.
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = tabRects().firstIndex(where: { $0.contains(p) }), i != selected {
            selected = i
            onSelect?(i)
        }
    }
}
