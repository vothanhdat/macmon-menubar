import AppKit
import Darwin

/// Memory numbers as Activity Monitor shows them (phys_footprint) plus the malloc heap.
enum MemoryProbe {
    static func vmInfo() -> task_vm_info_data_t {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return info
    }

    static func footprint() -> Double { Double(vmInfo().phys_footprint) / 1_048_576 }

    /// Set by MenuCycler; menu open/close also report then.
    static var enabled = false

    static func report(_ tag: String) {
        var s = malloc_statistics_t()
        malloc_zone_statistics(nil, &s)
        let t = ProcessInfo.processInfo.systemUptime
        let vm = vmInfo()
        let line = String(format: "[mem] %7.1f %@: footprint %.1f MB, RSS %.1f MB, malloc in use %.1f MB, images %d",
                          t, tag, Double(vm.phys_footprint) / 1_048_576, Double(vm.resident_size) / 1_048_576,
                          Double(s.size_in_use) / 1_048_576, _dyld_image_count())
        log.notice("\(line, privacy: .public)")
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }
}

/// CPU time used by the whole process so far (user + system, all threads).
enum CPUProbe {
    static func seconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
}

/// Development aid for measuring memory the same way every time:
/// `MACMON_DEBUG_MENU_CYCLES=3` opens the menu, keeps it open a few seconds
/// (`MACMON_DEBUG_MENU_HOLD`, default 6 s), closes it, and logs the memory at fixed times after
/// each close (`MACMON_DEBUG_MENU_GAP`, default 60 s, between opens). Output goes to stderr and the log.
/// `MACMON_DEBUG_HOVER=1` also measures CPU while the menu is open: first with the pointer still,
/// then while sweeping it across the charts (synthetic mouse-moved events at 120 Hz).
/// `MACMON_DEBUG_PANEL=1` shows the charts in a small floating panel at the bottom right instead
/// of opening the menu: an open menu takes the keyboard, so typing elsewhere would close it.
/// `MACMON_DEBUG_WINDOW=1` opens the dashboard window instead (without activating the app), runs
/// the same tests with clicks sent through the window, then resizes, minimizes and closes it.
final class MenuCycler {
    /// Opens the dashboard window (set by the app delegate).
    var openWindow: (() -> NSWindow?)?
    private var testWindow: NSWindow?
    private let menu: NSMenu
    private let anchor: NSView
    private var left: Int
    private let hold: TimeInterval
    private let gap: TimeInterval
    private let hover: Bool
    private let inPanel: Bool
    private var panel: NSPanel?

    init?(menu: NSMenu, anchor: NSView?) {
        let env = ProcessInfo.processInfo.environment
        guard let n = env["MACMON_DEBUG_MENU_CYCLES"].flatMap(Int.init), n > 0, let anchor else { return nil }
        MemoryProbe.enabled = true
        self.menu = menu
        self.anchor = anchor
        left = n
        hold = env["MACMON_DEBUG_MENU_HOLD"].flatMap(Double.init) ?? 6
        gap = env["MACMON_DEBUG_MENU_GAP"].flatMap(Double.init) ?? 60
        hover = env["MACMON_DEBUG_HOVER"] != nil
        inPanel = env["MACMON_DEBUG_PANEL"] != nil
        inWindow = env["MACMON_DEBUG_WINDOW"] != nil
    }
    private let inWindow: Bool

    private static func line(_ s: String) {
        log.notice("\(s, privacy: .public)")
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    /// Runs `body` after `delay` even while the menu is tracking.
    private static func after(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        RunLoop.main.add(Timer(timeInterval: delay, repeats: false) { _ in body() }, forMode: .common)
    }

    /// Phases of equal length: pointer still, sweeping the grid, then (after a click on the first
    /// chart) sweeping the zoomed chart. A second click goes back; the menu's size is logged each time.
    private func hoverTest() {
        let settle = 2.0, phase = max(1, (hold - settle - 0.5) / 3)
        var mark = (cpu: 0.0, wall: 0.0, draws: ChartsView.drawStats, overlay: TextLayer.stats)
        let begin = { mark = (CPUProbe.seconds(), CACurrentMediaTime(), ChartsView.drawStats, TextLayer.stats) }
        let end = { (tag: String) in
            let cpu = CPUProbe.seconds() - mark.cpu, wall = CACurrentMediaTime() - mark.wall
            let d = ChartsView.drawStats, n = d.count - mark.draws.count
            let o = TextLayer.stats, on = o.count - mark.overlay.count
            Self.line(String(format: "[cpu] %@: %.1f%% CPU over %.1f s; %d chart draws, %.2f ms each; %d text layer draws, %.2f ms each",
                             tag, cpu / wall * 100, wall, n, (d.seconds - mark.draws.seconds) / Double(max(1, n)) * 1000,
                             on, (o.seconds - mark.overlay.seconds) / Double(max(1, on)) * 1000))
        }
        let charts = { [weak self] () -> ChartsView? in
            func find(_ v: NSView?) -> ChartsView? {
                guard let v else { return nil }
                if let c = v as? ChartsView { return c }
                return v.subviews.lazy.compactMap(find).first
            }
            return find(self?.testWindow?.contentView ?? self?.panel?.contentView?.subviews.first ?? self?.menu.items.first?.view)
        }
        let inWindow = self.inWindow
        func send(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 30) {
            guard let c = charts(), let w = c.window else { return }
            let event = { (t: NSEvent.EventType) in
                NSEvent.mouseEvent(with: t, location: c.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 0)
            }
            if type == .mouseMoved {
                if let e = event(.mouseMoved) { c.mouseMoved(with: e) }
            } else if inWindow {
                // A real click: down and up through the window, as AppKit routes them.
                if let d = event(.leftMouseDown), let u = event(.leftMouseUp) { w.sendEvent(d); w.sendEvent(u) }
            } else if let e = event(type) {
                c.mouseUp(with: e)
            }
        }
        let size = { (tag: String) in
            guard let c = charts(), let w = c.window else { return }
            Self.line("[zoom] \(tag): charts \(Int(c.frame.height)) pt tall, window \(Int(w.frame.width)) x \(Int(w.frame.height))")
        }
        // MACMON_DEBUG_RENDER=<dir>: also capture the menu from the screen (with `screencapture`).
        let render = { (name: String) in
            guard let dir = ProcessInfo.processInfo.environment["MACMON_DEBUG_RENDER"], let w = charts()?.window,
                  let screen = NSScreen.screens.first else { return }
            let f = w.frame
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R\(Int(f.minX)),\(Int(screen.frame.maxY - f.maxY)),\(Int(f.width)),\(Int(f.height))", "\(dir)/\(name).png"]
            try? p.run()
            Self.line("[render] \(dir)/\(name).png")
        }
        var sweep: Timer?
        let startSweep = {
            let t0 = CACurrentMediaTime()
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                guard let c = charts() else { return }
                // Back and forth across the first column, 0.8 s each way.
                let f = (CACurrentMediaTime() - t0).truncatingRemainder(dividingBy: 1.6) / 0.8
                send(.mouseMoved, x: Dashboard.inset + 1 + (f < 1 ? f : 2 - f) * (c.bounds.width / 2 - Dashboard.inset - 8))
            }
            RunLoop.main.add(t, forMode: .common)
            sweep = t
        }
        Self.after(settle) { size("grid"); begin() }
        Self.after(settle + phase - 0.5) { render("grid") }
        Self.after(settle + phase * 1.5) { render("grid-hover") }
        Self.after(settle + phase * 2.5) { render("zoomed-hover") }
        Self.after(settle + phase) {
            end("open, pointer still")
            begin()
            startSweep()
        }
        Self.after(settle + phase * 2) {
            sweep?.invalidate()
            end("open, sweeping charts")
            send(.leftMouseUp, x: Dashboard.inset + 20)
            Self.after(0.3) { size("zoomed") }
            begin()
            startSweep()
        }
        Self.after(settle + phase * 3) {
            sweep?.invalidate()
            end("open, sweeping zoomed chart")
            send(.leftMouseUp, x: Dashboard.inset + 20)
            Self.after(0.3) { size("back to grid") }
            if inWindow { Self.after(0.5) { [weak self] in self?.windowTest() } }
        }
    }

    /// Bigger window sizes (layout and draw time), then minimize and restore.
    private func windowTest() {
        guard let w = testWindow else { return }
        let sizes = [NSSize(width: 420, height: 0), NSSize(width: 700, height: 800), NSSize(width: 1000, height: 1100)]
        func report(_ tag: String) {
            func find<T: NSView>(_ v: NSView?, _: T.Type) -> T? {
                guard let v else { return nil }
                if let t = v as? T { return t }
                return v.subviews.lazy.compactMap { find($0, T.self) }.first
            }
            let c = find(w.contentView, ChartsView.self), p = find(w.contentView, ProcessListView.self)
            Self.line("[window] \(tag): content \(Int(w.contentLayoutRect.width)) x \(Int(w.contentLayoutRect.height)), charts "
                      + "\(Int(c?.frame.width ?? 0)) x \(Int(c?.frame.height ?? 0)) (each \(Int(c?.layout.chartHeight ?? 0)) pt), "
                      + "process rows \(p?.rowCount ?? 0), bottom \(Int(p?.frame.maxY ?? 0))")
        }
        var t = 0.0
        for s in sizes {
            Self.after(t) {
                w.setContentSize(s) // height 0: the minimum
                Self.after(0.3) {
                    report("\(Int(s.width)) x \(Int(s.height))")
                    let d0 = ChartsView.drawStats
                    for _ in 0..<5 { find(w.contentView)?.display() }
                    let d = ChartsView.drawStats
                    Self.line(String(format: "[window] chart redraw at this size: %.2f ms (%d draws)",
                                     (d.seconds - d0.seconds) * 1000 / Double(max(1, d.count - d0.count)), d.count - d0.count))
                }
            }
            t += 1
        }
        func find(_ v: NSView?) -> ChartsView? {
            guard let v else { return nil }
            if let c = v as? ChartsView { return c }
            return v.subviews.lazy.compactMap(find).first
        }
        // Minimized: no chart draws and no process scans, only the sampler (1 s for another 10 s).
        var mark = (cpu: 0.0, wall: 0.0, draws: 0)
        Self.after(t) { w.miniaturize(nil) }
        Self.after(t + 1) { mark = (CPUProbe.seconds(), CACurrentMediaTime(), ChartsView.drawStats.count) }
        Self.after(t + 3) {
            let cpu = CPUProbe.seconds() - mark.cpu, wall = CACurrentMediaTime() - mark.wall
            Self.line(String(format: "[window] minimized: %.1f%% CPU over %.1f s, %d chart draws", cpu / wall * 100, wall,
                             ChartsView.drawStats.count - mark.draws))
            w.deminiaturize(nil)
        }
    }

    func start() {
        MemoryProbe.report("launch")
        // After the 20 s launch baseline (not needed for the panel).
        DispatchQueue.main.asyncAfter(deadline: .now() + (inPanel || inWindow ? 5 : 25)) { self.cycle() }
    }

    private func cycle() {
        guard left > 0 else {
            MemoryProbe.report("done")
            // MACMON_DEBUG_FAKE_DISPLAY_SLEEP=1: pretend the displays went to sleep, to test the quiet restart.
            if ProcessInfo.processInfo.environment["MACMON_DEBUG_FAKE_DISPLAY_SLEEP"] != nil {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            }
            return
        }
        left -= 1
        MemoryProbe.report("before open")
        if inWindow {
            testWindow = openWindow?()
            if hover { hoverTest() }
            // The hover test is followed by resizing, minimizing and restoring (about 8 s).
            DispatchQueue.main.asyncAfter(deadline: .now() + hold + (hover ? 8 : 0)) { [weak self] in
                MemoryProbe.report("open, closing")
                self?.testWindow?.performClose(nil)
                self?.testWindow = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) { self.cycle() }
            return
        }
        if hover { hoverTest() }
        if inPanel {
            openPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) { self.cycle() }
            return
        }
        let t = Timer(timeInterval: hold, repeats: false) { [menu] _ in
            MemoryProbe.report("open, closing")
            menu.cancelTracking()
        }
        RunLoop.main.add(t, forMode: .common)
        // On recent macOS this returns before the menu has closed, so times count from here.
        // The glass effect's graphics memory (up to ~170 MB while open, freed 20-40 s after
        // closing) doesn't always appear for a popped-up menu; the rest matches a real click.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        for after in [1.0, 10, 30, 50] where hold + after < gap {
            DispatchQueue.main.asyncAfter(deadline: .now() + hold + after) { MemoryProbe.report("closed +\(Int(after)) s") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { self.cycle() }
    }

    /// The menu's charts in a floating panel that never takes the keyboard, for `hold` seconds.
    private func openPanel() {
        menu.delegate?.menuNeedsUpdate?(menu)
        guard let item = menu.items.first, let top = item.view else { return }
        item.view = nil
        let size = NSSize(width: top.frame.width, height: max(top.frame.height, 260))
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let p = NSPanel(contentRect: NSRect(x: screen.maxX - size.width - 12, y: screen.minY + 12, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.backgroundColor = .windowBackgroundColor
        p.isReleasedWhenClosed = false
        let content = FlippedView(frame: NSRect(origin: .zero, size: size))
        p.contentView = content
        content.addSubview(top)
        p.orderFrontRegardless()
        panel = p
        menu.delegate?.menuWillOpen?(menu)
        Self.after(hold) { [weak self] in
            guard let self else { return }
            MemoryProbe.report("open, closing")
            p.orderOut(nil)
            self.panel = nil
            self.menu.delegate?.menuDidClose?(self.menu)
        }
    }
}
