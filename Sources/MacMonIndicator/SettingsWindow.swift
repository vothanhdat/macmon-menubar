import AppKit
import ServiceManagement

/// Settings window, built in code. Created on demand and released when closed.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var macmonStatus: () -> String = { "" }
    var exportCSV: (() -> Void)?

    private let s = Settings.shared
    private var slotPopups: [NSPopUpButton] = []
    private var chartPopups: [NSPopUpButton] = []
    private let columnsPopup = NSPopUpButton()
    private let valuePopup = NSPopUpButton()
    private let zoomBox = NSButton(checkboxWithTitle: "Zoom Temp and RAM", target: nil, action: nil)
    private let heightSlider = NSSlider(value: 30, minValue: Double(ChartLayout.heightRange.lowerBound),
                                        maxValue: Double(ChartLayout.heightRange.upperBound), target: nil, action: nil)
    private let heightLabel = NSTextField(labelWithString: "")
    private static let valueTitles: [(ChartLayout.Value, String)] = [
        (.split, "Main value in chart, details on label row"), (.chart, "Value in chart"), (.label, "Value on label row"),
    ]
    private let iconsBox = NSButton(checkboxWithTitle: "Show icons", target: nil, action: nil)
    private let twoLinesBox = NSButton(checkboxWithTitle: "Two lines", target: nil, action: nil)
    private let steadyBox = NSButton(checkboxWithTitle: "Ignore small changes", target: nil, action: nil)
    // Menu bar look: text size, line spacing, item spacing, opacity.
    private let sizeSlider = NSSlider(value: 10, minValue: 8, maxValue: 12, target: nil, action: nil)
    private let lineSlider = NSSlider(value: 2, minValue: 0, maxValue: 5, target: nil, action: nil)
    private let itemSlider = NSSlider(value: 8, minValue: 2, maxValue: 16, target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 1, minValue: 0.3, maxValue: 1, target: nil, action: nil)
    private let edgeSlider = NSSlider(value: 3, minValue: 0, maxValue: 8, target: nil, action: nil)
    private var lookLabels: [NSTextField] = []
    private let acPopup = NSPopUpButton()
    private let batteryPopup = NSPopUpButton()
    private var warnFields: [NSTextField] = []
    private let loginBox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let restartBox = NSButton(checkboxWithTitle: "Free memory while the display sleeps", target: nil, action: nil)
    private let rootBox = NSButton(checkboxWithTitle: "Show system processes (root helper)", target: nil, action: nil)
    private let macmonLabel = NSTextField(wrappingLabelWithString: "")
    private let acChoices = [1000, 2000, 3000, 5000]
    private let batteryChoices = [2000, 5000, 10000]
    private static let maxSlots = 6

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled, .closable],
                         backing: .buffered, defer: true)
        w.title = "MacMon Indicator Settings"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        return l
    }

    private func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 360
        return l
    }

    private func build() {
        // Menu bar slots: a 2 × 3 grid that mirrors how the two-line layout looks.
        let metrics = s.barMetrics
        for i in 0..<Self.maxSlots {
            let p = NSPopUpButton()
            p.controlSize = .small
            p.font = .systemFont(ofSize: 11)
            p.addItem(withTitle: "None")
            for m in BarMetric.allCases { p.addItem(withTitle: m.title) }
            if i < metrics.count, let idx = BarMetric.allCases.firstIndex(of: metrics[i]) { p.selectItem(at: idx + 1) }
            p.target = self
            p.action = #selector(slotsChanged)
            slotPopups.append(p)
        }
        let slotGrid = NSGridView(views: [
            [slotPopups[0], slotPopups[2], slotPopups[4]],
            [slotPopups[1], slotPopups[3], slotPopups[5]],
        ])
        slotGrid.rowSpacing = 4
        slotGrid.columnSpacing = 6

        // Menu charts: 8 positions, each a chart or None (this both hides and reorders charts).
        let charts = s.chartIDs
        for i in 0..<ChartID.allCases.count {
            let p = NSPopUpButton()
            p.controlSize = .small
            p.font = .systemFont(ofSize: 11)
            p.addItem(withTitle: "None")
            for c in ChartID.allCases { p.addItem(withTitle: c.title) }
            if i < charts.count, let idx = ChartID.allCases.firstIndex(of: charts[i]) { p.selectItem(at: idx + 1) }
            p.target = self
            p.action = #selector(chartsChanged)
            chartPopups.append(p)
        }
        let chartGrid = NSGridView(views: stride(from: 0, to: chartPopups.count, by: 2).map { [chartPopups[$0], chartPopups[$0 + 1]] })
        chartGrid.rowSpacing = 4
        chartGrid.columnSpacing = 6
        let layout = s.chartLayout
        for (popup, titles) in [(columnsPopup, ["1 column", "2 columns"]), (valuePopup, Self.valueTitles.map(\.1))] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 11)
            popup.addItems(withTitles: titles)
            popup.target = self
            popup.action = #selector(chartLayoutChanged)
        }
        columnsPopup.selectItem(at: layout.columns - 1)
        valuePopup.selectItem(at: Self.valueTitles.firstIndex { $0.0 == layout.value } ?? 0)
        zoomBox.state = s.zoomCharts ? .on : .off
        zoomBox.target = self
        zoomBox.action = #selector(zoomChanged)
        zoomBox.toolTip = "Scale the Temp and RAM charts to the range of their data, so small changes are visible."
        let chartOptions = NSStackView(views: [columnsPopup, valuePopup, zoomBox])
        chartOptions.spacing = 8

        heightSlider.doubleValue = Double(layout.chartHeight)
        heightSlider.isContinuous = true // the label follows while dragging; the setting is saved on release
        heightSlider.controlSize = .small
        heightSlider.target = self
        heightSlider.action = #selector(chartHeightChanged)
        heightSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        heightLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        heightLabel.textColor = .secondaryLabelColor
        heightLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        updateHeightLabel()
        let heightTitle = label("Chart height")
        heightTitle.font = .systemFont(ofSize: 12)
        let heightRow = NSStackView(views: [heightTitle, heightSlider, heightLabel,
                                            note("Click a chart in the menu to see it large.")])
        heightRow.spacing = 6

        iconsBox.state = s.showIcons ? .on : .off
        iconsBox.target = self
        iconsBox.action = #selector(layoutChanged)
        twoLinesBox.state = s.twoLines ? .on : .off
        twoLinesBox.target = self
        twoLinesBox.action = #selector(layoutChanged)
        steadyBox.state = s.steadyMenuBar ? .on : .off
        steadyBox.target = self
        steadyBox.action = #selector(layoutChanged)
        steadyBox.toolTip = "Redraw a value only when it changes noticeably (or once a minute). Saves CPU; the menu always shows exact values."
        let layoutRow = NSStackView(views: [iconsBox, twoLinesBox, steadyBox])
        layoutRow.spacing = 16

        let look = s.barLook
        var lookViews: [[NSView]] = []
        for (name, slider, value) in [("Text size", sizeSlider, look.size), ("Line spacing", lineSlider, look.lineGap),
                                      ("Item spacing", itemSlider, look.itemGap), ("Opacity", opacitySlider, look.opacity),
                                      ("Edge padding", edgeSlider, look.edge)] {
            slider.doubleValue = Double(value)
            slider.isContinuous = true // live preview in the menu bar while dragging
            slider.controlSize = .small
            slider.target = self
            slider.action = #selector(lookChanged)
            slider.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let valueLabel = label("")
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
            lookLabels.append(valueLabel)
            let l = label(name)
            l.font = .systemFont(ofSize: 12)
            lookViews.append([l, slider, valueLabel])
        }
        updateLookLabels()
        let lookRow1 = NSStackView(views: lookViews[0] + lookViews[3] + lookViews[4])
        let lookRow2 = NSStackView(views: lookViews[1] + lookViews[2])
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetLook))
        reset.controlSize = .small
        reset.bezelStyle = .rounded
        lookRow2.addArrangedSubview(reset)
        for r in [lookRow1, lookRow2] { r.spacing = 6 }

        for (popup, choices, current) in [(acPopup, acChoices, s.intervalAC), (batteryPopup, batteryChoices, s.intervalBattery)] {
            for c in choices { popup.addItem(withTitle: "\(c / 1000) s") }
            popup.selectItem(at: choices.firstIndex(of: current) ?? 1)
            popup.target = self
            popup.action = #selector(intervalChanged)
        }
        let intervalRow = NSStackView(views: [label("On power adapter"), acPopup, label("On battery"), batteryPopup])
        intervalRow.spacing = 8

        let t = s.thresholds
        var warnViews: [NSView] = []
        for (name, value) in [("CPU %", t.cpu), ("GPU %", t.gpu), ("RAM %", t.ram), ("Temp °C", t.temp)] {
            let f = NSTextField(string: "\(Int(value))")
            f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let fmt = NumberFormatter()
            fmt.minimum = 1
            fmt.maximum = 120
            fmt.maximumFractionDigits = 0
            f.formatter = fmt
            f.target = self
            f.action = #selector(thresholdsChanged)
            warnFields.append(f)
            warnViews += [label(name), f]
        }
        let warnRow = NSStackView(views: warnViews)
        warnRow.spacing = 6

        loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginBox.target = self
        loginBox.action = #selector(loginChanged)

        restartBox.state = s.quietRestart ? .on : .off
        restartBox.target = self
        restartBox.action = #selector(restartChanged)
        restartBox.toolTip = "After the menu has been used, the app restarts itself once the display has been asleep for a minute, which gives back memory macOS keeps for the menu. Nobody sees it, and history is kept."

        rootBox.state = (s.useRootHelper && RootHelper.isInstalled) ? .on : .off
        rootBox.target = self
        rootBox.action = #selector(rootChanged)

        macmonLabel.stringValue = macmonStatus()
        macmonLabel.font = .systemFont(ofSize: 11)
        macmonLabel.textColor = .secondaryLabelColor
        macmonLabel.preferredMaxLayoutWidth = 360
        macmonLabel.isSelectable = true

        let export = NSButton(title: "Export history as CSV…", target: self, action: #selector(exportClicked))
        export.bezelStyle = .rounded

        let grid = NSGridView(views: [
            [label("Menu bar", bold: true), slotGrid],
            [NSGridCell.emptyContentView, note("Two lines: each column shows the top item above the bottom one. One line: left to right in the order 1–6 (top before bottom).")],
            [NSGridCell.emptyContentView, layoutRow],
            [NSGridCell.emptyContentView, lookRow1],
            [NSGridCell.emptyContentView, lookRow2],
            [label("Menu charts", bold: true), chartGrid],
            [NSGridCell.emptyContentView, note("Left to right, top to bottom in two columns; top to bottom in one. Battery and fans only show on Macs that have them.")],
            [NSGridCell.emptyContentView, chartOptions],
            [NSGridCell.emptyContentView, heightRow],
            [label("Update every", bold: true), intervalRow],
            [label("Turn red at", bold: true), warnRow],
            [NSGridCell.emptyContentView, note("Temperature turns orange 10 °C below its limit. RAM also follows macOS memory pressure.")],
            [label("General", bold: true), loginBox],
            [NSGridCell.emptyContentView, restartBox],
            [NSGridCell.emptyContentView, rootBox],
            [NSGridCell.emptyContentView, note("Lets the process list show disk use of system processes such as Spotlight and Time Machine. Turning it on or off asks for your admin password. The helper is read-only and only runs while the menu is open.")],
            [label("macmon", bold: true), macmonLabel],
            [NSGridCell.emptyContentView, export],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        for r in [0, 5, 9, 10, 12, 16] { grid.row(at: r).yPlacement = .center }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window?.contentView = content
    }

    @objc private func chartsChanged() {
        s.chartIDs = chartPopups.compactMap { p in
            p.indexOfSelectedItem > 0 ? ChartID.allCases[p.indexOfSelectedItem - 1] : nil
        }
    }

    @objc private func zoomChanged() { s.zoomCharts = zoomBox.state == .on }

    @objc private func chartLayoutChanged() {
        s.chartLayout = ChartLayout(columns: columnsPopup.indexOfSelectedItem + 1,
                                    value: Self.valueTitles[max(0, valuePopup.indexOfSelectedItem)].0)
        // Until the height has been set, it follows the column count's default.
        heightSlider.doubleValue = Double(s.chartLayout.chartHeight)
        updateHeightLabel()
    }

    @objc private func chartHeightChanged() {
        updateHeightLabel()
        // Save once the drag ends (or for a key press), not for every step.
        if NSApp.currentEvent?.type != .leftMouseDragged { s.chartHeight = heightSlider.doubleValue.rounded() }
    }

    private func updateHeightLabel() { heightLabel.stringValue = "\(Int(heightSlider.doubleValue.rounded())) pt" }

    @objc private func slotsChanged() {
        s.barMetrics = slotPopups.compactMap { p in
            p.indexOfSelectedItem > 0 ? BarMetric.allCases[p.indexOfSelectedItem - 1] : nil
        }
    }

    private func updateLookLabels() {
        guard lookLabels.count == 5 else { return }
        lookLabels[0].stringValue = String(format: "%.1f pt", sizeSlider.doubleValue)
        lookLabels[1].stringValue = String(format: "%.1f", lineSlider.doubleValue)
        lookLabels[2].stringValue = String(format: "%.0f", itemSlider.doubleValue)
        lookLabels[3].stringValue = String(format: "%.0f%%", opacitySlider.doubleValue * 100)
        lookLabels[4].stringValue = String(format: "%.0f", edgeSlider.doubleValue)
    }

    @objc private func lookChanged() {
        // Text size snaps to half points so glyphs stay crisp.
        let size = (sizeSlider.doubleValue * 2).rounded() / 2
        s.barLook = BarLook(size: CGFloat(size), lineGap: CGFloat((lineSlider.doubleValue * 2).rounded() / 2),
                            itemGap: CGFloat(itemSlider.doubleValue.rounded()), opacity: CGFloat(opacitySlider.doubleValue),
                            edge: CGFloat(edgeSlider.doubleValue.rounded()))
        updateLookLabels()
    }

    @objc private func resetLook() {
        s.resetBarLook()
        let look = s.barLook
        sizeSlider.doubleValue = Double(look.size)
        lineSlider.doubleValue = Double(look.lineGap)
        itemSlider.doubleValue = Double(look.itemGap)
        opacitySlider.doubleValue = Double(look.opacity)
        edgeSlider.doubleValue = Double(look.edge)
        updateLookLabels()
    }

    @objc private func layoutChanged() {
        s.showIcons = iconsBox.state == .on
        s.twoLines = twoLinesBox.state == .on
        s.steadyMenuBar = steadyBox.state == .on
    }

    @objc private func intervalChanged() {
        s.intervalAC = acChoices[max(0, acPopup.indexOfSelectedItem)]
        s.intervalBattery = batteryChoices[max(0, batteryPopup.indexOfSelectedItem)]
    }

    @objc private func thresholdsChanged() {
        let v = warnFields.map { Float($0.integerValue) }
        s.thresholds = Thresholds(cpu: v[0], gpu: v[1], ram: v[2], temp: v[3])
    }

    @objc private func loginChanged() {
        do {
            if loginBox.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            showAlert("Couldn't change the login item", error.localizedDescription)
        }
        let status = SMAppService.mainApp.status
        if status == .requiresApproval {
            showAlert("Approve in System Settings", "Allow MacMon Indicator under General → Login Items.")
            SMAppService.openSystemSettingsLoginItems()
        }
        loginBox.state = status == .enabled ? .on : .off
    }

    @objc private func restartChanged() { s.quietRestart = restartBox.state == .on }

    @objc private func rootChanged() {
        if rootBox.state == .on {
            if !RootHelper.isInstalled, let err = RootHelper.install() {
                rootBox.state = .off
                if err != "Cancelled." { showAlert("Couldn't install the root helper", err) }
                return
            }
            s.useRootHelper = true
        } else {
            s.useRootHelper = false
            if RootHelper.isInstalled, let err = RootHelper.uninstall(), err != "Cancelled." {
                showAlert("Couldn't remove the root helper", err)
            }
        }
    }

    @objc private func exportClicked() { exportCSV?() }

    private func showAlert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
