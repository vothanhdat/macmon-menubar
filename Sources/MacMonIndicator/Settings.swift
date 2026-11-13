import Foundation

/// User preferences, backed by UserDefaults.
final class Settings {
    static let shared = Settings()
    static let changed = Notification.Name("MacMonIndicatorSettingsChanged")
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "barMetrics": ["cpu", "ram", "cpuTemp", "power"],
            "showIcons": true,
            "twoLines": true,
            "steadyMenuBar": true,
            "barSize": 9.0,
            "barLineGap": 5.0,
            "barItemGap": 8.0,
            "barOpacity": 1.0,
            "barEdge": 3.0,
            "chartIDs": ChartID.allCases.map(\.rawValue),
            "chartColumns": 2,
            "chartValue": ChartLayout.Value.split.rawValue,
            "zoomCharts": false,
            "intervalAC": 2000,
            "intervalBattery": 5000,
            "warnCPU": 90.0,
            "warnGPU": 90.0,
            "warnRAM": 90.0,
            "warnTemp": 90.0,
            "useRootHelper": false,
            "quietRestart": true,
            "trackProcesses": true,
        ])
        showNewCharts()
    }

    /// Charts added in a later version show up once, at the end, for people who already chose
    /// their charts. Hiding one in Settings keeps it hidden.
    private func showNewCharts() {
        let all = ChartID.allCases.map(\.rawValue)
        // Before this list was kept, the app had the first eight charts.
        let known = d.stringArray(forKey: "chartIDsKnown") ?? Array(all.prefix(8))
        guard known.count < all.count else { return }
        let ids = d.stringArray(forKey: "chartIDs") ?? []
        let added = all.filter { !known.contains($0) && !ids.contains($0) }
        if !added.isEmpty { d.set(ids + added, forKey: "chartIDs") }
        d.set(all, forKey: "chartIDsKnown")
    }

    private func notify() { NotificationCenter.default.post(name: Self.changed, object: nil) }

    /// Menu bar slots in order. In two-line mode they fill top, bottom, then the next column.
    var barMetrics: [BarMetric] {
        get { (d.stringArray(forKey: "barMetrics") ?? []).compactMap(BarMetric.init(rawValue:)) }
        set { d.set(newValue.map(\.rawValue), forKey: "barMetrics"); notify() }
    }
    var showIcons: Bool {
        get { d.bool(forKey: "showIcons") }
        set { d.set(newValue, forKey: "showIcons"); notify() }
    }
    var twoLines: Bool {
        get { d.bool(forKey: "twoLines") }
        set { d.set(newValue, forKey: "twoLines"); notify() }
    }
    var barLook: BarLook {
        get {
            BarLook(size: CGFloat(d.double(forKey: "barSize")), lineGap: CGFloat(d.double(forKey: "barLineGap")),
                    itemGap: CGFloat(d.double(forKey: "barItemGap")), opacity: CGFloat(d.double(forKey: "barOpacity")),
                    edge: CGFloat(d.double(forKey: "barEdge")))
        }
        set {
            d.set(Double(newValue.size), forKey: "barSize"); d.set(Double(newValue.lineGap), forKey: "barLineGap")
            d.set(Double(newValue.itemGap), forKey: "barItemGap"); d.set(Double(newValue.opacity), forKey: "barOpacity")
            d.set(Double(newValue.edge), forKey: "barEdge")
            notify()
        }
    }
    /// Charts in the menu, in order (hidden ones are left out).
    var chartIDs: [ChartID] {
        get { (d.stringArray(forKey: "chartIDs") ?? []).compactMap(ChartID.init(rawValue:)) }
        set { d.set(newValue.map(\.rawValue), forKey: "chartIDs"); notify() }
    }
    /// Zoom the Temp and RAM charts to the range their data covers (off: fixed 0–100° / 0–total).
    var zoomCharts: Bool {
        get { d.bool(forKey: "zoomCharts") }
        set { d.set(newValue, forKey: "zoomCharts"); notify() }
    }
    var chartLayout: ChartLayout {
        get {
            ChartLayout(columns: min(2, max(1, d.integer(forKey: "chartColumns"))),
                        value: ChartLayout.Value(rawValue: d.string(forKey: "chartValue") ?? "") ?? .split,
                        height: chartHeight.map { CGFloat($0) })
        }
        set {
            d.set(newValue.columns, forKey: "chartColumns")
            d.set(newValue.value.rawValue, forKey: "chartValue")
            notify()
        }
    }
    /// Height of each menu chart in points; nil uses the default for the column count.
    var chartHeight: Double? {
        get { d.object(forKey: "chartHeight") as? Double }
        set {
            if let newValue { d.set(newValue, forKey: "chartHeight") } else { d.removeObject(forKey: "chartHeight") }
            notify()
        }
    }
    func resetBarLook() {
        for k in ["barSize", "barLineGap", "barItemGap", "barOpacity", "barEdge"] { d.removeObject(forKey: k) }
        notify()
    }
    /// Skip menu bar redraws for tiny changes (each redraw costs macOS ~20 ms of CPU).
    var steadyMenuBar: Bool {
        get { d.bool(forKey: "steadyMenuBar") }
        set { d.set(newValue, forKey: "steadyMenuBar"); notify() }
    }
    var intervalAC: Int {
        get { d.integer(forKey: "intervalAC") }
        set { d.set(newValue, forKey: "intervalAC"); notify() }
    }
    var intervalBattery: Int {
        get { d.integer(forKey: "intervalBattery") }
        set { d.set(newValue, forKey: "intervalBattery"); notify() }
    }
    var thresholds: Thresholds {
        get {
            Thresholds(cpu: d.float(forKey: "warnCPU"), gpu: d.float(forKey: "warnGPU"),
                       ram: d.float(forKey: "warnRAM"), temp: d.float(forKey: "warnTemp"))
        }
        set {
            d.set(newValue.cpu, forKey: "warnCPU"); d.set(newValue.gpu, forKey: "warnGPU")
            d.set(newValue.ram, forKey: "warnRAM"); d.set(newValue.temp, forKey: "warnTemp")
            notify()
        }
    }
    /// Read system processes through the root helper (only if it is installed).
    /// Restart while the displays sleep to give back memory the menu left behind (see AppDelegate).
    var quietRestart: Bool {
        get { d.bool(forKey: "quietRestart") }
        set { d.set(newValue, forKey: "quietRestart") }
    }
    var useRootHelper: Bool {
        get { d.bool(forKey: "useRootHelper") }
        set { d.set(newValue, forKey: "useRootHelper"); notify() }
    }
    /// Keep per-program statistics (CPU, energy, memory, disk), scanned every 5 minutes.
    var trackProcesses: Bool {
        get { d.bool(forKey: "trackProcesses") }
        set { d.set(newValue, forKey: "trackProcesses"); notify() }
    }
    var macmonPath: String? {
        get { d.string(forKey: "macmonPath") }
        set { d.set(newValue, forKey: "macmonPath"); notify() }
    }
}
