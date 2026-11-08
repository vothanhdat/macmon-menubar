import AppKit

/// `MacMonIndicator --snapshot <dir>` renders the menu bar item and the menu contents to PNG files
/// (light and dark) using live macmon readings. History comes from a throwaway file filled with
/// demo data, so your real history is untouched. Used for README screenshots and visual checks.
enum SnapshotMode {
    static func run(outputDir: String, demoProcesses: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("macmon-indicator-snapshot-\(getpid())")
        try? FileManager.default.removeItem(at: tmp)
        let history = HistoryStore(directory: tmp)
        let source = MacmonSource()
        let pm = ProcessMonitor()
        var procSnap: ProcSnapshot?
        pm.onUpdate = { procSnap = $0 }
        pm.start(useHelper: Settings.shared.useRootHelper && RootHelper.isInstalled)
        var count = 0

        source.onSample = { s in
            count += 1
            if s.diskRead.isFinite { pm.setTotalDisk(mbps: s.diskRead + s.diskWrite) }
            if count == 1 { seedDemoHistory(history, like: s) }
            history.add(s)
            guard count >= 3 else { return }
            source.stop()
            try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
            if demoProcesses { procSnap = demoProcessSnapshot() }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                renderStatus(s, appearance: appearance, to: "\(outputDir)/menubar-\(name).png")
                var hot = s
                hot.cpuTemp = 95
                renderStatus(hot, appearance: appearance, to: "\(outputDir)/menubar-warning-\(name).png")
                renderDashboard(history: history, sample: s, procs: procSnap, hasBattery: source.hasBattery,
                                appearance: appearance, to: "\(outputDir)/dropdown-\(name).png")
            }
            pm.stop()
            try? FileManager.default.removeItem(at: tmp)
            print("Wrote snapshots to \(outputDir)")
            exit(0)
        }
        source.start(intervalMs: 1000)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write("Timed out waiting for macmon (state: \(source.state))\n".data(using: .utf8)!)
            exit(1)
        }
        app.run()
    }

    /// Fixed process list for public screenshots (so they don't show what you are running).
    private static func demoProcessSnapshot() -> ProcSnapshot {
        let rows: [(String, Double, Double, Double?)] = [
            ("Xcode", 48.2, 2.1e9, 1.2e6), ("WindowServer", 21.5, 2.6e8, nil), ("Safari", 6.1, 1.4e9, 0.3e6),
            ("Docker", 3.4, 1.1e9, 0.2e6), ("Spotlight", 4.2, 9.0e7, 6.3e6), ("cloudd", 1.1, 6.0e7, 2.4e6),
        ]
        var snap = ProcSnapshot()
        snap.rows = rows.enumerated().map { ProcRow(pid: pid_t(1000 + $0.offset), name: $0.element.0, cpu: $0.element.1,
                                                   mem: $0.element.2, disk: $0.element.3) }
        snap.hiddenDiskBps = 1.8e6
        return snap
    }

    /// Plausible-looking demo data for the past 7 days, ending just before `s`.
    private static func seedDemoHistory(_ h: HistoryStore, like s: Sample) {
        let now = s.time
        func wave(_ t: Double, _ period: Double) -> Float { Float(0.5 + 0.5 * sin(t / period)) }
        var t = now - 7 * 86400
        while t < now - 5 {
            var d = s
            d.time = t
            let busy = wave(t, 900) * wave(t, 5400) + (Int(t / 10) % 37 == 0 ? 0.6 : 0)
            d.cpu = min(100, 6 + 60 * busy)
            d.ecpu = min(100, d.cpu * 1.6)
            d.pcpu = d.cpu * 0.7
            d.gpu = 4 + 30 * wave(t, 2000) * wave(t, 700)
            d.ramUsedGB = (s.ramUsedGB.isFinite ? s.ramUsedGB : 12) * (0.85 + 0.15 * wave(t, 20000))
            d.sysPower = 6 + 40 * busy
            d.cpuPower = 0.5 + 20 * busy
            d.gpuPower = 0.2 + 8 * wave(t, 2000) * wave(t, 700)
            d.batteryW = -(d.sysPower)
            d.cpuTemp = 40 + 45 * busy
            d.gpuTemp = 38 + 30 * wave(t, 2000)
            d.fan0 = busy > 0.55 ? 1800 + 3000 * (busy - 0.55) : 0
            d.fan1 = d.fan0
            d.diskRead = 3 * wave(t, 300) + (Int(t / 10) % 23 == 0 ? 80 : 0)
            d.diskWrite = 6 * wave(t, 450) + (Int(t / 10) % 29 == 0 ? 120 : 0)
            h.add(d)
            t += now - t > 3600 ? 120 : 10
        }
    }

    private static func renderStatus(_ s: Sample, appearance: NSAppearance.Name, to path: String) {
        let r = StatusRenderer()
        let st = Settings.shared
        r.configure(metrics: st.barMetrics, icons: st.showIcons, twoLines: st.twoLines, look: st.barLook)
        let cells = r.metrics.map { StatusRenderer.Cell(text: $0.text(s), level: $0.level(s, st.thresholds)) }
        var image: NSImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = r.image(cells: cells, template: false)
        }
        guard let image else { return }
        let bg = appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        let pad: CGFloat = 6, scale: CGFloat = 2
        let size = NSSize(width: r.width + pad * 2, height: StatusRenderer.height + pad * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        bg.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(x: pad, y: pad, width: r.width, height: StatusRenderer.height))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func renderDashboard(history: HistoryStore, sample: Sample, procs: ProcSnapshot?, hasBattery: Bool,
                                        appearance: NSAppearance.Name, to path: String) {
        let d = DashboardMenu(history: history, latest: sample, hasBattery: hasBattery)
        d.update(sample: sample)
        d.processes.snapshot = procs
        // Approximates the menu's glass background; the real menu blurs what is behind it.
        let bg = appearance == .darkAqua ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        write(d.snapshotView(), appearance: appearance, background: bg, padding: 0, to: path)
    }

    private static func write(_ view: NSView, appearance: NSAppearance.Name, background: NSColor, padding: CGFloat, to path: String) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: view.frame.width + padding * 2, height: view.frame.height + padding * 2))
        container.appearance = NSAppearance(named: appearance)
        container.wantsLayer = true
        container.layer?.backgroundColor = background.cgColor
        view.frame.origin = NSPoint(x: padding, y: padding)
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(container.bounds.width * scale),
                                         pixelsHigh: Int(container.bounds.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = container.bounds.size
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            background.setFill()
            container.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            container.cacheDisplay(in: container.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// `--iconset <dir.iconset>`: the app icon as PNGs at every size macOS uses. `make app` turns
    /// them into AppIcon.icns with `iconutil`.
    static func writeIconset(to dir: String) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = points * scale
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
                rep.size = NSSize(width: px, height: px) // draw in pixels
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                About.icon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
            }
        }
        exit(0)
    }

    /// `--about <dir>`: the About panel's contents, light and dark (about-light.png, about-dark.png).
    static func aboutPreview(to dir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let version = MacmonSource().version()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            About.show(macmonVersion: version)
            guard let panel = app.windows.first(where: { $0.isVisible }), let view = panel.contentView else {
                FileHandle.standardError.write("About panel did not open\n".data(using: .utf8)!)
                exit(1)
            }
            panel.contentView = NSView() // take the content out of the panel to render it on its own
            var bg = NSColor.windowBackgroundColor // resolve it in the target appearance
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                bg = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? bg
            }
            write(view, appearance: appearance, background: bg, padding: 0, to: "\(dir)/about-\(name).png")
            panel.close()
        }
        print("Wrote \(dir)/about-light.png and about-dark.png")
        exit(0)
    }

    /// `--settings <dir>`: the Settings window's content as settings-light.png and settings-dark.png.
    static func settingsPreview(to dir: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let wc = SettingsWindowController()
            guard let view = wc.window?.contentView else { exit(1) }
            view.layoutSubtreeIfNeeded()
            view.frame.size = view.fittingSize
            wc.window?.contentView = NSView() // render the content on its own
            var bg = NSColor.windowBackgroundColor
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                bg = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? bg
            }
            write(view, appearance: appearance, background: bg, padding: 0, to: "\(dir)/settings-\(name).png")
        }
        print("Wrote \(dir)/settings-light.png and settings-dark.png")
        exit(0)
    }

    // MARK: - Menu bar look previews

    /// `--bar-previews <file.png>`: a sheet of menu bar looks (text size × spacing, plus opacity),
    /// each on a dark and a light menu bar next to a Wi-Fi icon and a clock for scale.
    static func barPreviews(to path: String) {
        _ = NSApplication.shared
        var sample = Sample()
        sample.cpu = 7; sample.ramUsedGB = 15.1; sample.ramTotalGB = 24; sample.cpuTemp = 41; sample.sysPower = 8.9
        let metrics: [BarMetric] = [.cpu, .ram, .cpuTemp, .power]
        let sizes: [CGFloat] = [9, 10, 11]
        let spacings: [(name: String, line: CGFloat, item: CGFloat)] = [("compact", 1.5, 6), ("balanced", 2.5, 10), ("airy", 3.5, 14)]
        var variants: [(label: String, look: BarLook)] = []
        let letters = Array("ABCDEFGHI")
        for (r, size) in sizes.enumerated() {
            for (c, sp) in spacings.enumerated() {
                variants.append(("\(letters[r * 3 + c]) · \(Int(size)) pt · \(sp.name)", BarLook(size: size, lineGap: sp.line, itemGap: sp.item, opacity: 1)))
            }
        }
        for o in [0.85, 0.7] as [CGFloat] {
            variants.append(("E at \(Int(o * 100))% opacity", BarLook(size: 10, lineGap: 2.5, itemGap: 10, opacity: o)))
        }
        variants.append(("Current (11 pt, tight)", BarLook(size: 11, lineGap: 3.2, itemGap: 6, opacity: 1)))

        let cols = 3, cellW: CGFloat = 250, stripH: CGFloat = 32, labelH: CGFloat = 20, cellH: CGFloat = labelH + stripH * 2 + 4 + 18
        let rowsN = (variants.count + cols - 1) / cols
        let margin: CGFloat = 16, headerH: CGFloat = 30
        let sheet = NSSize(width: margin * 2 + cellW * CGFloat(cols), height: margin * 2 + headerH + cellH * CGFloat(rowsN))
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(sheet.width * scale), pixelsHigh: Int(sheet.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = sheet
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        ctx.scaleBy(x: scale, y: scale)
        // Flip so we can lay out top-down.
        ctx.translateBy(x: 0, y: sheet.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: sheet).fill()

        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.black]
        ("Menu bar look: pick a letter (shown at real size on a Retina screen)" as NSString)
            .draw(at: NSPoint(x: margin, y: margin), withAttributes: title)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.darkGray]

        let teal = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.47, alpha: 1)
        let light = NSColor(calibratedWhite: 0.93, alpha: 1)
        let wifi = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        let r = StatusRenderer()

        for (i, v) in variants.enumerated() {
            let ox = margin + CGFloat(i % cols) * cellW
            let oy = margin + headerH + CGFloat(i / cols) * cellH
            (v.label as NSString).draw(at: NSPoint(x: ox, y: oy), withAttributes: labelAttrs)
            r.configure(metrics: metrics, icons: true, twoLines: true, look: v.look)
            let cells = metrics.map { StatusRenderer.Cell(text: $0.text(sample), level: .normal) }
            let img = r.image(cells: cells, template: true)
            for (k, (bg, ink)) in [(teal, NSColor.white), (light, NSColor.black.withAlphaComponent(0.85))].enumerated() {
                let strip = NSRect(x: ox, y: oy + labelH + CGFloat(k) * (stripH + 4), width: cellW - 14, height: stripH)
                bg.setFill()
                NSBezierPath(roundedRect: strip, xRadius: 6, yRadius: 6).fill()
                let itemRect = NSRect(x: strip.minX + 10, y: strip.midY - StatusRenderer.height / 2, width: r.width, height: StatusRenderer.height)
                tinted(img, ink).draw(in: itemRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                var x = itemRect.maxX + 14
                if let w = wifi {
                    let wr = NSRect(x: x, y: strip.midY - w.size.height / 2, width: w.size.width, height: w.size.height)
                    tinted(w, ink).draw(in: wr, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    x = wr.maxX + 12
                }
                let clock: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ink]
                let cs = ("14:02" as NSString).size(withAttributes: clock)
                ("14:02" as NSString).draw(at: NSPoint(x: x, y: strip.midY - cs.height / 2), withAttributes: clock)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
        exit(0)
    }

    /// The image's alpha filled with one color (how macOS draws template images in the menu bar).
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
    }

    // MARK: - Chart layout previews

    /// `--layout-previews <file.png>`: the menu's chart area in several layouts, with demo data.
    static func layoutPreviews(to path: String) {
        _ = NSApplication.shared
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("macmon-indicator-layouts-\(getpid())")
        try? FileManager.default.removeItem(at: tmp)
        let history = HistoryStore(directory: tmp)
        var s = Sample()
        s.cpu = 9; s.ecpu = 14; s.pcpu = 6; s.gpu = 5; s.ramUsedGB = 15.1; s.ramTotalGB = 24; s.swapUsedGB = 0
        s.sysPower = 9.1; s.cpuPower = 0.9; s.gpuPower = 0.2; s.batteryW = -7.9; s.batteryPct = 43
        s.cpuTemp = 42; s.gpuTemp = 41; s.fan0 = 0; s.fan1 = 0; s.fanMax = 5777; s.fanCount = 2
        s.diskRead = 0.1; s.diskWrite = 0.3
        seedDemoHistory(history, like: s)
        history.add(s)

        let variants: [(String, ChartLayout)] = [
            ("A · 1 column · value in chart", ChartLayout(columns: 1, value: .chart)),
            ("B · 2 columns · value in chart", ChartLayout(columns: 2, value: .chart)),
            ("C · 2 columns · value on label row", ChartLayout(columns: 2, value: .label)),
            ("D · 2 columns · main value in chart, details on label row", ChartLayout(columns: 2, value: .split)),
        ]
        let w = DashboardMenu.width, margin: CGFloat = 16, labelH: CGFloat = 24, gap: CGFloat = 20
        let container = FlippedView()
        // Left column: A (tall). Right column: B, C, D.
        var colY: [CGFloat] = [margin, margin]
        for (i, v) in variants.enumerated() {
            let col = i == 0 ? 0 : 1
            let x = margin + CGFloat(col) * (w + gap)
            let title = NSTextField(labelWithString: v.0)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.frame = NSRect(x: x, y: colY[col], width: w, height: 18)
            container.addSubview(title)
            let charts = ChartsView()
            charts.history = history
            charts.latest = s
            charts.layout = v.1
            charts.tier = 0
            charts.rows = ChartsView.rows(for: ChartID.allCases, hasBattery: true, fanCount: 2)
            let h = ChartsView.height(count: charts.rows.count, layout: v.1)
            let card = NSBox(frame: NSRect(x: x, y: colY[col] + labelH, width: w, height: h + 20))
            card.boxType = .custom
            card.fillColor = NSColor(white: 0.97, alpha: 1)
            card.borderColor = NSColor(white: 0.85, alpha: 1)
            card.cornerRadius = 10
            container.addSubview(card)
            charts.frame = NSRect(x: x, y: colY[col] + labelH + 10, width: w, height: h)
            container.addSubview(charts)
            colY[col] += labelH + h + 20 + gap
        }
        container.frame = NSRect(x: 0, y: 0, width: margin * 2 + w * 2 + gap, height: max(colY[0], colY[1]) - gap + margin)
        write(container, appearance: .aqua, background: .white, padding: 0, to: path)
        try? FileManager.default.removeItem(at: tmp)
        print("Wrote \(path)")
        exit(0)
    }
}
