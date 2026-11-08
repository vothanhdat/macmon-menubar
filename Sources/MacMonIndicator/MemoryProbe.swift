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
final class MenuCycler {
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
    }

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
            let top = self?.panel?.contentView?.subviews.first ?? self?.menu.items.first?.view
            return top?.subviews.compactMap { $0 as? ChartsView }.first
        }
        func send(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 30) {
            guard let c = charts(), let w = c.window,
                  let e = NSEvent.mouseEvent(with: type, location: c.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [],
                                             timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 0) else { return }
            if type == .mouseMoved { c.mouseMoved(with: e) } else { c.mouseUp(with: e) }
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
                send(.mouseMoved, x: DashboardMenu.inset + 1 + (f < 1 ? f : 2 - f) * (c.bounds.width / 2 - DashboardMenu.inset - 8))
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
            send(.leftMouseUp, x: DashboardMenu.inset + 20)
            Self.after(0.3) { size("zoomed") }
            begin()
            startSweep()
        }
        Self.after(settle + phase * 3) {
            sweep?.invalidate()
            end("open, sweeping zoomed chart")
            send(.leftMouseUp, x: DashboardMenu.inset + 20)
            Self.after(0.3) { size("back to grid") }
        }
    }

    func start() {
        MemoryProbe.report("launch")
        // After the 20 s launch baseline (not needed for the panel).
        DispatchQueue.main.asyncAfter(deadline: .now() + (inPanel ? 5 : 25)) { self.cycle() }
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
