import AppKit
import UniformTypeIdentifiers
import os

let log = Logger(subsystem: "local.MacMonIndicator", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: StatusItemController!
    private var history: HistoryStore!
    private let macmon = MacmonSource()
    private var latest: Sample?

    private let menu = NSMenu()
    private var menuOpen = false
    private var dashboard: Dashboard?
    private var dashboardWindow: DashboardWindowController?
    private var processMonitor: ProcessMonitor?
    private var lastProcesses: ProcSnapshot?
    private var settingsWindow: SettingsWindowController?
    private var historyDir: URL!
    private var processTracker: ProcessTracker?
    private var processHistoryWindow: ProcessHistoryWindowController?
    private var quitting = false
    private static let windowOpenKey = "dashboardWindowOpen"

    private var intervalWork: DispatchWorkItem?
    private var screensAsleep = false
    private var onAC = true
    private var cycler: MenuCycler?
    private var sigterm: DispatchSourceSignal?
    private var terminalServer: TerminalServer?
    /// Terminals connected (`macmon-indicator`, see TerminalServer.swift).
    private var terminalClients = 0
    private var restartWork: DispatchWorkItem?
    private var launchRSS: UInt64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let dir = AppPaths.dataDirectory
        history = HistoryStore(directory: dir)
        historyDir = dir
        updateProcessTracker()
        startTerminalServer()
        menu.delegate = self
        menu.autoenablesItems = false
        buildMainMenu()
        status = StatusItemController(menu: menu)
        status.update(nil)

        onAC = SystemSensors().readBattery()?.onAC ?? true // start macmon at the right interval
        screensAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0 // e.g. after a quiet restart
        if CommandLine.arguments.contains("--relaunched") { log.notice("restarted to free memory") }
        // What the app needs without the menu, for deciding whether a quiet restart is worth it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.launchRSS = MemoryProbe.vmInfo().resident_size
        }
        macmon.onSample = { [weak self] s in self?.handle(s) }
        macmon.start(intervalMs: desiredInterval())

        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.status.applySettings()
            self.status.update(self.latest)
            self.macmon.setInterval(self.desiredInterval())
            self.dashboardWindow?.settingsChanged()
            self.updateProcessTracker()
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            log.notice("system will sleep: stopping macmon")
            self?.macmon.stop()
            self?.history.flush(sync: true)
            self?.processTracker?.save()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            log.notice("system woke: starting macmon")
            self.macmon.start(intervalMs: self.desiredInterval())
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            log.notice("displays slept")
            self.screensAsleep = true
            self.macmon.setInterval(self.desiredInterval())
            self.scheduleQuietRestart()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            log.notice("displays woke")
            self.screensAsleep = false
            self.restartWork?.cancel()
            self.macmon.setInterval(self.desiredInterval())
        }
        // `kill`/`pkill` (and `make install`) send SIGTERM, which would end the app without
        // stopping macmon; the orphaned macmon then crashes on its closed pipe. Quit normally instead.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        sigterm = term

        cycler = MenuCycler(menu: menu, anchor: status.item.button)
        cycler?.openWindow = { [weak self] in self?.showDashboardWindow(activate: false); return self?.dashboardWindow?.window }
        cycler?.start()

        // Open at login, and again after a quiet restart, if it was open before.
        if UserDefaults.standard.bool(forKey: Self.windowOpenKey) { showDashboardWindow(activate: false) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true // the window stays "open" for next time
        return .terminateNow
    }

    /// Clicking the Dock icon (only there while the window is open) brings back a minimized window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, dashboardWindow != nil { showDashboardWindow(activate: true) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        macmon.stop()
        history.flush(sync: true)
        processTracker?.stop()
    }

    // MARK: - Quiet restart

    /// Showing the menu leaves memory behind that only a new process gives back: macOS keeps the
    /// pages of the menu's frameworks, fonts and glass effect mapped (htop's RSS goes from about 73
    /// to 100+ MB), and malloc keeps some of its own. While the displays sleep nobody sees the menu
    /// bar item disappear and come back, so restart then, after the displays have been asleep for
    /// a minute (short sleeps don't count). History is saved first; macmon starts again with the app.
    private func scheduleQuietRestart() {
        restartWork?.cancel()
        guard Settings.shared.quietRestart else { return }
        let work = DispatchWorkItem { [weak self] in self?.quietRestart() }
        restartWork = work
        let delay = ProcessInfo.processInfo.environment["MACMON_DEBUG_RESTART_DELAY"].flatMap(Double.init) ?? 60
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func quietRestart() {
        let rss = MemoryProbe.vmInfo().resident_size
        // Only when the menu (or Settings) has made the app noticeably bigger, nothing is open,
        // and the app runs from its bundle (not `swift run`).
        guard screensAsleep, !menuOpen, settingsWindow == nil, NSApp.modalWindow == nil,
              launchRSS > 0, rss > launchRSS + 12 << 20,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        log.notice("restarting to free memory: RSS \(rss >> 20) MB, \(self.launchRSS >> 20) MB at launch")
        macmon.stop()
        history.flush(sync: true)
        processTracker?.stop()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.addsToRecentItems = false
        config.arguments = ["--relaunched"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { [weak self] app, error in
            DispatchQueue.main.async {
                // The new copy reads the saved history; this one must not write anything more.
                if app != nil { exit(0) }
                log.error("quiet restart failed: \(String(describing: error), privacy: .public)")
                guard let self else { return }
                self.macmon.start(intervalMs: self.desiredInterval())
                self.processTracker?.start()
            }
        }
    }

    /// The dashboard window is open and can be seen (not minimized, covered or on another Space).
    private var windowVisible: Bool { dashboardWindow?.isVisible ?? false }

    /// Someone is looking: the menu is open, the window can be seen, or a terminal is connected.
    private var watched: Bool { menuOpen || windowVisible || terminalClients > 0 }

    /// 1 s while someone is looking (see `watched`), 10 s while the displays sleep, otherwise the
    /// user's AC/battery choice.
    private func desiredInterval() -> Int {
        if watched { return 1000 }
        if screensAsleep { return 10_000 }
        let s = Settings.shared
        return onAC ? s.intervalAC : s.intervalBattery
    }

    private func handle(_ s: Sample) {
        latest = s
        history.add(s)
        status.update(s)
        if s.onAC != onAC {
            onAC = s.onAC
            macmon.setInterval(desiredInterval())
        }
        dashboard?.update(sample: s)
        if windowVisible { dashboardWindow?.dashboard.update(sample: s) }
        if s.diskRead.isFinite && s.diskWrite.isFinite { processMonitor?.setTotalDisk(mbps: s.diskRead + s.diskWrite) }
    }

    private func macmonStatusText() -> String {
        switch macmon.state {
        case .notFound: return "macmon not found. Install it: brew install macmon"
        case .failed: return "macmon stopped unexpectedly, retrying…"
        case .running, .stopped: return macmon.path.map { "macmon: \($0)" } ?? ""
        }
    }

    // MARK: - Menu

    /// Called right before the menu shows: build the dashboard items.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let d = Dashboard(history: history, latest: latest, hasBattery: macmon.hasBattery)
        dashboard = d
        // Only mention macmon when something is wrong.
        let problem = (macmon.state == .notFound || macmon.state == .failed) ? macmonStatusText() : nil
        menu.items = d.items(status: problem, target: self, openWindow: #selector(openDashboardWindow),
                             processHistory: processTracker != nil ? #selector(openProcessHistory) : nil, about: #selector(openAbout),
                             settings: #selector(openSettings), quit: #selector(quit))
        d.onOpenWindow = { [weak self] in self?.openDashboardWindow() }
        // The window may already be scanning processes: show its latest list right away.
        if processMonitor != nil { d.processes.snapshot = lastProcesses }
    }

    /// Applies the desired macmon interval after a delay; a newer call replaces an older one.
    /// Sweeping the mouse along the menu bar opens and closes menus quickly, so this avoids
    /// restarting macmon for every pass.
    private func applyInterval(after delay: TimeInterval) {
        intervalWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.macmon.setInterval(self.desiredInterval())
        }
        intervalWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Process scanning runs while someone is looking (see `watched`), and only then.
    private func updateProcessMonitor() {
        let needed = watched
        if needed, processMonitor == nil {
            let pm = ProcessMonitor()
            pm.onUpdate = { [weak self] snap in
                guard let self else { return }
                self.lastProcesses = snap
                self.dashboard?.processes.snapshot = snap
                self.dashboardWindow?.dashboard.processes.snapshot = snap
            }
            if let s = latest, s.diskRead.isFinite { pm.setTotalDisk(mbps: s.diskRead + s.diskWrite) }
            pm.start(useHelper: Settings.shared.useRootHelper && RootHelper.isInstalled)
            processMonitor = pm
            if MemoryProbe.enabled { MemoryProbe.report("process scanning on") }
        } else if !needed, let pm = processMonitor {
            pm.stop()
            processMonitor = nil
            lastProcesses = nil
            if MemoryProbe.enabled { MemoryProbe.report("process scanning off") }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        if MemoryProbe.enabled { MemoryProbe.report("menuWillOpen") }
        updateProcessMonitor()
        applyInterval(after: 0.5)   // 1 s sampling once the menu stays open
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        if MemoryProbe.enabled { MemoryProbe.report("menuDidClose") }
        updateProcessMonitor()
        applyInterval(after: 10)    // back to the normal interval if it stays closed
        // Free the views after the chosen item's action (if any) has run.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.menuOpen else { return }
            self.menu.removeAllItems()
            self.dashboard = nil
        }
    }

    // MARK: - Terminal

    /// Serves `macmon-indicator` in a terminal (TerminalServer.swift).
    private func startTerminalServer() {
        let server = TerminalServer()
        server.onClientsChanged = { [weak self] n in
            guard let self, n != self.terminalClients else { return }
            let first = self.terminalClients == 0
            self.terminalClients = n
            log.notice("terminals connected: \(n)")
            self.updateProcessMonitor()
            // A terminal wants numbers now (`--once` waits for them); back to normal 10 s after the last leaves.
            if first || n == 0 { self.applyInterval(after: n > 0 ? 0 : 10) }
        }
        server.handle = { [weak self] req, reply in
            guard let self else { return }
            switch req.cmd {
            case .live:
                let problem = (self.macmon.state == .notFound || self.macmon.state == .failed) ? self.macmonStatusText() : nil
                reply(TerminalServer.encode(TerminalServer.live(
                    req, history: self.history, latest: self.latest, hasBattery: self.macmon.hasBattery,
                    intervalMs: self.macmon.intervalMs, problem: problem, processes: self.lastProcesses,
                    processHistory: self.processTracker != nil)))
            case .history:
                guard let tracker = self.processTracker else {
                    reply(TerminalServer.encode(TerminalServer.history(req, summary: nil)))
                    return
                }
                tracker.summary(ProcessTracker.Range(rawValue: req.range ?? 0) ?? .today) { summary in
                    reply(TerminalServer.encode(TerminalServer.history(req, summary: summary)))
                }
            }
        }
        if server.start(path: AppPaths.socketPath(in: historyDir)) { terminalServer = server }
    }

    // MARK: - Process history

    /// Starts or stops the background process scans to match Settings.
    private func updateProcessTracker() {
        if Settings.shared.trackProcesses {
            guard processTracker == nil else { return }
            let t = ProcessTracker(directory: historyDir)
            t.onScan = { [weak self] in self?.processHistoryWindow?.reload() }
            t.start()
            processTracker = t
        } else if let t = processTracker {
            t.stop()
            processTracker = nil
            processHistoryWindow?.close()
        }
    }

    @objc private func openProcessHistory() {
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self, let tracker = self.processTracker else { return }
            if self.processHistoryWindow == nil {
                let wc = ProcessHistoryWindowController(tracker: tracker)
                wc.onClose = { [weak self] in
                    DispatchQueue.main.async { self?.processHistoryWindow = nil } // after it has finished closing
                }
                self.processHistoryWindow = wc
            }
            self.activate()
            self.processHistoryWindow?.showWindow(nil)
            self.processHistoryWindow?.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Deletes all process history (from Settings).
    private func clearProcessHistory() {
        // With tracking off, a tracker that never scans opens the file just to clear it.
        let t = processTracker ?? ProcessTracker(directory: historyDir)
        t.clear { [weak self] in self?.processHistoryWindow?.reload() }
    }

    // MARK: - Dashboard window

    /// From the menu item or the button in the menu's tabs row.
    @objc private func openDashboardWindow() {
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in self?.showDashboardWindow(activate: true) }
    }

    /// While the window is open the app shows in the Dock and ⌘-Tab, so the window can always be
    /// found; without it the app stays out of both.
    private func showDashboardWindow(activate: Bool) {
        if dashboardWindow == nil {
            let wc = DashboardWindowController(history: history, latest: latest, hasBattery: macmon.hasBattery)
            wc.onVisibilityChange = { [weak self] visible in self?.dashboardVisibilityChanged(visible) }
            wc.onClose = { [weak self] in self?.dashboardWindowClosed() }
            dashboardWindow = wc
            UserDefaults.standard.set(true, forKey: Self.windowOpenKey)
            NSApp.setActivationPolicy(.regular)
        }
        if activate { self.activate() }
        dashboardWindow?.showWindow(nil)
        if dashboardWindow?.window?.isMiniaturized == true { dashboardWindow?.window?.deminiaturize(nil) }
        dashboardWindow?.updateVisible()
    }

    private func dashboardVisibilityChanged(_ visible: Bool) {
        if MemoryProbe.enabled { MemoryProbe.report("window \(visible ? "visible" : "hidden")") }
        if visible, let w = dashboardWindow {
            // Updates stopped while it was hidden; the charts read the history when they draw.
            if let s = latest { w.dashboard.update(sample: s) }
            w.dashboard.charts.needsDisplay = true
        }
        updateProcessMonitor()
        applyInterval(after: visible ? 0.5 : 10)
    }

    private func dashboardWindowClosed() {
        guard !quitting else { return }
        UserDefaults.standard.set(false, forKey: Self.windowOpenKey)
        NSApp.setActivationPolicy(.accessory)
        // Release it after the window has finished closing.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dashboardWindow = nil
            self.updateProcessMonitor()
            self.applyInterval(after: 10)
        }
    }

    /// The app menu shows only while the window is open (the app is a regular app then). It also
    /// gives Settings' text fields copy and paste.
    private func buildMainMenu() {
        func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = target
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = m
            return i
        }
        let main = NSMenu()
        main.addItem(submenu("MacMon Indicator", [
            item("About MacMon Indicator", #selector(openAbout), "", target: self), .separator(),
            item("Settings…", #selector(openSettings), ",", target: self), .separator(),
            item("Hide MacMon Indicator", #selector(NSApplication.hide(_:)), "h"),
            item("Quit MacMon Indicator", #selector(quit), "q", target: self),
        ]))
        main.addItem(submenu("Edit", [
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"), .separator(),
            item("Process History", #selector(openProcessHistory), "", target: self),
        ])
        main.addItem(window)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window.submenu
    }

    // MARK: - About, settings, export, quit

    @objc private func openAbout() {
        activate()
        About.show(macmonVersion: macmon.version())
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let wc = SettingsWindowController()
            wc.macmonStatus = { [weak self] in self?.macmonStatusText() ?? "" }
            wc.exportCSV = { [weak self] in self?.exportCSV() }
            wc.clearProcessHistory = { [weak self] in self?.clearProcessHistory() }
            wc.onClose = { [weak self] in self?.settingsWindow = nil }
            settingsWindow = wc
        }
        activate()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macmon-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try history.exportCSV(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func activate() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Process History in the app menu works only while process history is kept.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(openProcessHistory) ? processTracker != nil : true
    }
}
