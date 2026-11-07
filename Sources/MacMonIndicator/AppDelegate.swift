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
    private var dashboard: DashboardMenu?
    private var processMonitor: ProcessMonitor?
    private var settingsWindow: SettingsWindowController?

    private var intervalWork: DispatchWorkItem?
    private var screensAsleep = false
    private var onAC = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMonIndicator", isDirectory: true)
        history = HistoryStore(directory: dir)
        menu.delegate = self
        menu.autoenablesItems = false
        status = StatusItemController(menu: menu)
        status.update(nil)

        onAC = SystemSensors().readBattery()?.onAC ?? true // start macmon at the right interval
        macmon.onSample = { [weak self] s in self?.handle(s) }
        macmon.start(intervalMs: desiredInterval())

        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.status.applySettings()
            self.status.update(self.latest)
            self.macmon.setInterval(self.desiredInterval())
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            log.notice("system will sleep: stopping macmon")
            self?.macmon.stop()
            self?.history.flush(sync: true)
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
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            log.notice("displays woke")
            self.screensAsleep = false
            self.macmon.setInterval(self.desiredInterval())
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        macmon.stop()
        history.flush(sync: true)
    }

    /// 1 s while the menu is open, 10 s while the displays sleep, otherwise the user's AC/battery choice.
    private func desiredInterval() -> Int {
        if menuOpen { return 1000 }
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
        let d = DashboardMenu(history: history, latest: latest, hasBattery: macmon.hasBattery)
        dashboard = d
        // Only mention macmon when something is wrong.
        let problem = (macmon.state == .notFound || macmon.state == .failed) ? macmonStatusText() : nil
        menu.items = d.items(status: problem, target: self, settings: #selector(openSettings), quit: #selector(quit))
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

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        let pm = ProcessMonitor()
        pm.onUpdate = { [weak self] snap in self?.dashboard?.processes.snapshot = snap }
        if let s = latest, s.diskRead.isFinite { pm.setTotalDisk(mbps: s.diskRead + s.diskWrite) }
        pm.start(useHelper: Settings.shared.useRootHelper && RootHelper.isInstalled)
        processMonitor = pm
        applyInterval(after: 0.5)   // 1 s sampling once the menu stays open
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        processMonitor?.stop()
        processMonitor = nil
        applyInterval(after: 10)    // back to the normal interval if it stays closed
        // Free the views after the chosen item's action (if any) has run.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.menuOpen else { return }
            self.menu.removeAllItems()
            self.dashboard = nil
        }
    }

    // MARK: - Settings, export, quit

    @objc private func openSettings() {
        if settingsWindow == nil {
            let wc = SettingsWindowController()
            wc.macmonStatus = { [weak self] in self?.macmonStatusText() ?? "" }
            wc.exportCSV = { [weak self] in self?.exportCSV() }
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
