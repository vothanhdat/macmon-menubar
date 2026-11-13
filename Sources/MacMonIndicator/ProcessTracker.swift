import Foundation
import Darwin

/// Keeps per-program statistics in the background: every 5 minutes it reads each process's
/// running totals (CPU time, CPU energy, disk bytes) and adds what changed since the last scan to
/// the program's hour in ProcessHistoryStore. Programs are kept by executable path (not pid), and
/// also by app bundle, so all of an app's helper processes add up.
///
/// The totals count between scans, so a process alive at two scans is counted exactly however long
/// the gap. What scans miss: processes that start and end between two scans, and what a process
/// used between the last scan and its end. That CPU time shows as "unseen": the whole Mac's CPU
/// time minus what the scans found.
///
/// - Your processes: libproc, everything.
/// - Other users' and system processes: /bin/ps (CPU time and memory only), unless the root
///   helper is on, which reads everything for every process.
///
/// Writes to disk once an hour (the hour that ended), and when the Mac sleeps or the app quits.
final class ProcessTracker {
    enum HelperState { case notUsed, ok, outdated, unreachable }

    enum Range: Int, CaseIterable {
        case today, last24h, week, month, quarter
        var title: String { ["Today", "24 Hours", "7 Days", "30 Days", "90 Days"][rawValue] }
        var days: Int { [1, 1, 7, 30, 90][rawValue] }
    }

    struct Summary {
        var programs: [(path: String, stats: ProcStats)] = []
        var unseen = ProcStats()
        var lastScan: Date?
        var helper = HelperState.notUsed
        /// The oldest data in the range (history may not reach back as far as the range).
        var since: Date?
    }

    /// Seconds between scans. MACMON_DEBUG_PROCESS_INTERVAL: shorter, for testing.
    static let interval: TimeInterval = ProcessInfo.processInfo.environment["MACMON_DEBUG_PROCESS_INTERVAL"]
        .flatMap(Double.init).map { max(1, $0) } ?? 300
    static let unseenKey = "#unseen"

    /// Called on the main queue after each scan.
    var onScan: (() -> Void)?

    private let queue = DispatchQueue(label: "MacMonIndicator.proctrack", qos: .utility)
    private let store: ProcessHistoryStore?
    private var timer: DispatchSourceTimer?

    // Everything below: queue only.
    private var keyIDs: [String: Int64] = [:]
    private var keyPaths: [Int64: String] = [:]
    private var live: [pid_t: TrackedProcess] = [:]
    private var lastWall = 0.0          // seconds since 1970
    private var lastUp: UInt64 = 0      // uptime ns (stops while asleep)
    private var lastTicks: [UInt32] = []
    private var hour: Int64 = 0         // the hour `current` belongs to
    private var current: [Int64: ProcStats] = [:]
    private var rolledUpTo: Int64 = 0   // start of the first day not yet added up into a daily row
    private var helper = HelperState.notUsed
    private var paths: [pid_t: (start: Double, path: String)] = [:]
    private let me = getuid()
    private let host = mach_host_self()
    private let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    init(directory: URL) {
        store = ProcessHistoryStore(url: directory.appendingPathComponent("process-history.sqlite"))
        queue.async { self.load() }
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // The first scan waits a little, so it doesn't add to the app's start.
        t.schedule(deadline: .now() + min(20, Self.interval), repeating: Self.interval, leeway: .seconds(max(1, Int(Self.interval / 10))))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    /// Stops scanning and saves everything, so the next start continues from here.
    func stop() {
        timer?.cancel()
        timer = nil
        save()
    }

    /// Saves the current hour and the running processes' counters (before sleep, quit or restart).
    func save() {
        queue.sync { self.write(withLive: true) }
    }

    /// Deletes all process history; counting starts again at the next scan.
    func clear(then done: @escaping () -> Void) {
        queue.async {
            self.store?.clear()
            self.keyIDs = [:]
            self.keyPaths = [:]
            self.live = [:]
            self.lastUp = 0
            self.current = [:]
            self.hour = 0
            self.rolledUpTo = 0
            DispatchQueue.main.async(execute: done)
        }
    }

    // MARK: - State on disk

    private static func bootTime() -> Int64 {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return Int64(tv.tv_sec)
    }

    private func load() {
        guard let store else { return }
        keyPaths = store.keys()
        keyIDs = Dictionary(keyPaths.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        rolledUpTo = store.meta("rolled_up_to") ?? 0
        if let h = store.meta("hour") {
            hour = h
            current = store.stats(span: 0, bucket: h)
        }
        // The running processes' counters continue the last run, if they are from this boot and
        // were saved together with the stats (not after a crash).
        if store.meta("live_valid") == 1, store.meta("boot") == Self.bootTime(), let up = store.meta("last_up_ns"),
           let wall = store.meta("last_wall_ms") {
            live = store.live()
            lastUp = UInt64(up)
            lastWall = Double(wall) / 1000
            lastTicks = ["ticks_user", "ticks_system", "ticks_nice"].compactMap { store.meta($0).map { UInt32(truncatingIfNeeded: $0) } }
        }
    }

    /// Writes the current hour's rows; with `withLive`, also the running processes' counters, which
    /// are only valid together with the rows written at the same time.
    private func write(withLive: Bool) {
        guard let store else { return }
        store.transaction {
            if hour != 0 { store.write(span: 0, bucket: hour, current) }
            store.setMeta("hour", hour)
            store.setMeta("rolled_up_to", rolledUpTo)
            if withLive && lastUp > 0 {
                store.setLive(live)
                store.setMeta("boot", Self.bootTime())
                store.setMeta("last_up_ns", Int64(lastUp))
                store.setMeta("last_wall_ms", Int64(lastWall * 1000))
                for (k, v) in zip(["ticks_user", "ticks_system", "ticks_nice"], lastTicks) { store.setMeta(k, Int64(v)) }
                store.setMeta("live_valid", 1)
            } else {
                store.setMeta("live_valid", 0)
            }
        }
    }

    private func keyID(_ path: String) -> Int64 {
        if let id = keyIDs[path] { return id }
        guard let id = store?.addKey(path) else { return 0 }
        keyIDs[path] = id
        keyPaths[id] = path
        return id
    }

    private static func hourStart(_ t: Double) -> Int64 { Int64((t / 3600).rounded(.down)) * 3600 }
    private static func dayStart(_ t: Double) -> Int64 {
        Int64(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: t)).timeIntervalSince1970)
    }
    private static func addDays(_ day: Int64, _ n: Int) -> Int64 {
        let d = Calendar.current.date(byAdding: .day, value: n, to: Date(timeIntervalSince1970: Double(day)))!
        return dayStart(d.timeIntervalSince1970)
    }

    /// Moves on to a new hour: writes the old one, adds up days that have ended into daily rows,
    /// and drops hours older than 48 h and days older than 90.
    private func rotate(to newHour: Int64) {
        guard let store else { return }
        store.transaction {
            if hour != 0, !current.isEmpty { store.write(span: 0, bucket: hour, current) }
            current = [:]
            hour = newHour
            let today = Self.dayStart(Double(newHour))
            if rolledUpTo == 0 { rolledUpTo = store.firstBucket().map { Self.dayStart(Double($0)) } ?? today }
            while rolledUpTo < today {
                let next = Self.addDays(rolledUpTo, 1)
                store.rollUp(day: rolledUpTo, next: next)
                rolledUpTo = next
            }
            store.prune(hourlyBefore: min(newHour - 48 * 3600, rolledUpTo), dailyBefore: Self.addDays(today, -90))
            store.setMeta("hour", hour)
            store.setMeta("rolled_up_to", rolledUpTo)
            store.setMeta("live_valid", 0) // the saved counters no longer match the rows
        }
    }

    // MARK: - Scanning

    /// One process as read now. Counters are totals since the process started.
    private struct Seen {
        var start: Double
        var path: String
        var cpu: Double
        var pcore = 0.0
        var energy = 0.0
        var diskRead = 0.0
        var diskWritten = 0.0
        var mem: Double
        var maxMem: Double
        var detail: Bool
    }

    private func scan() {
        guard store != nil else { return }
        let nowWall = Date().timeIntervalSince1970
        let nowUp = DispatchTime.now().uptimeNanoseconds
        let ticks = cpuTicks()
        let procs = collect(now: nowWall)
        let dt = lastUp > 0 && nowUp > lastUp ? Double(nowUp - lastUp) / 1e9 : 0
        // Nothing to measure against: the first scan, or after a long gap (the app wasn't running),
        // which can't be placed in time. Then this scan only sets the starting point.
        let fresh = dt <= 0 || dt > Self.interval * 3 || nowWall < lastWall

        var acc: [Int64: ProcStats] = [:]
        var next: [pid_t: TrackedProcess] = [:]
        next.reserveCapacity(procs.count)
        var found = 0.0 // CPU seconds the scan found
        for (pid, p) in procs {
            let exe = keyID(p.path)
            let app = ProcKey.app(of: p.path).map(keyID) ?? 0
            next[pid] = TrackedProcess(start: p.start, exe: exe, app: app, cpu: p.cpu, pcore: p.pcore, energy: p.energy,
                                       diskRead: p.diskRead, diskWritten: p.diskWritten, detail: p.detail)
            guard !fresh else { continue }
            var d = ProcStats(peakCopies: 1, ramPeak: p.mem, ramOnePeak: max(p.mem, p.maxMem), detail: p.detail)
            let span: Double
            if let b = live[pid], abs(b.start - p.start) < 2 {
                d.cpu = max(0, p.cpu - b.cpu)
                if p.detail && b.detail {
                    d.pcore = max(0, p.pcore - b.pcore)
                    d.energy = max(0, p.energy - b.energy)
                    d.diskRead = max(0, p.diskRead - b.diskRead)
                    d.diskWritten = max(0, p.diskWritten - b.diskWritten)
                }
                span = dt
            } else if p.start >= lastWall - 2 {
                // Started since the last scan: everything it used so far belongs to this interval.
                d.launches = 1
                d.cpu = p.cpu
                d.pcore = p.pcore
                d.energy = p.energy
                d.diskRead = p.diskRead
                d.diskWritten = p.diskWritten
                span = min(dt, max(1, nowWall - p.start))
            } else {
                span = dt // running before, but the last scan couldn't read it
            }
            d.running = span
            d.copyTime = span
            d.ramTime = p.mem * span
            found += d.cpu
            acc[exe, default: ProcStats()].addCopy(d)
            if app != 0 { acc[app, default: ProcStats()].addCopy(d) }
        }

        if !fresh {
            // Copies that ended since the last scan: they ended somewhere in between.
            let mid = (lastWall + nowWall) / 2
            for (pid, b) in live {
                if let n = next[pid], abs(n.start - b.start) < 2 { continue }
                let e = ProcStats(running: dt / 2, copyTime: dt / 2, exits: 1, lifetime: max(0, mid - b.start), detail: b.detail)
                acc[b.exe, default: ProcStats()].addCopy(e)
                if b.app != 0 { acc[b.app, default: ProcStats()].addCopy(e) }
            }
            // CPU time no scan saw: the whole Mac's, minus what was found.
            if ticks.count == lastTicks.count, !ticks.isEmpty {
                let busy = Double(zip(ticks, lastTicks).reduce(UInt64(0)) { $0 + UInt64($1.0 &- $1.1) }) / Double(sysconf(Int32(_SC_CLK_TCK)))
                if busy - found > 0 { acc[keyID(Self.unseenKey), default: ProcStats()].add(ProcStats(cpu: busy - found)) }
            }
        }

        // An interval belongs to the hour its middle falls in. Never an earlier hour than the
        // current one (after the clock is set back): that would replace the rows saved for it.
        let bucket = max(hour, Self.hourStart(fresh ? nowWall : (lastWall + nowWall) / 2))
        if bucket != hour { rotate(to: bucket) }
        for (k, s) in acc { current[k, default: ProcStats()].add(s) }

        live = next
        lastWall = nowWall
        lastUp = nowUp
        lastTicks = ticks
        DispatchQueue.main.async { [weak self] in self?.onScan?() }
    }

    /// Busy CPU ticks of the whole Mac (user, system, nice), all cores together.
    private func cpuTicks() -> [UInt32] {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return [] }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.3]
    }

    private func collect(now: Double) -> [pid_t: Seen] {
        var out: [pid_t: Seen] = [:]
        helper = .notUsed
        if Settings.shared.useRootHelper && RootHelper.isInstalled {
            if let h = RootHelper.snapshot() {
                if h.version >= 3 {
                    helper = .ok
                    for (pid, p) in h.processes {
                        let mem = p.mem
                        out[pid] = Seen(start: Double(p.startUs ?? 0) / 1e6, path: ProcKey.normalize(p.path ?? p.name),
                                        cpu: Double(p.cpuNs) / 1e9, pcore: Double(p.pcoreNs ?? 0) / 1e9,
                                        energy: Double(p.energyNj ?? 0) / 1e9, diskRead: Double(p.diskRead),
                                        diskWritten: Double(p.diskWritten), mem: mem, maxMem: p.maxMem ?? mem, detail: true)
                    }
                    return out
                }
                helper = .outdated
            } else {
                helper = .unreachable
            }
        }
        collectOwn(into: &out)
        collectOthers(into: &out, now: now)
        paths = paths.filter { out[$0.key] != nil }
        return out
    }

    /// The executable's path (cached per process), or nil.
    private func path(_ pid: pid_t, start: Double) -> String? {
        if let c = paths[pid], abs(c.start - start) < 2 { return c.path }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let p = ProcKey.normalize(String(cString: buf))
        paths[pid] = (start, p)
        return p
    }

    /// Your processes, with everything libproc knows.
    private func collectOwn(into out: inout [pid_t: Seen]) {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let n = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
        var nameBuf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            // Full BSD info (with the start time) is only given for your own processes.
            var bi = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  bi.pbi_uid == me else { continue }
            let start = Double(bi.pbi_start_tvsec) + Double(bi.pbi_start_tvusec) / 1e6
            // V6 adds energy and P-core time to V4 (same layout, appended); an older macOS gets V4.
            var ru = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &ru) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0 ? 0 : proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard rc == 0 else { continue }
            let p = path(pid, start: start) ?? (proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 ? String(cString: nameBuf) : "?")
            out[pid] = Seen(start: start, path: p,
                            cpu: Double(ru.ri_user_time &+ ru.ri_system_time) * timebase,
                            pcore: Double(ru.ri_user_ptime &+ ru.ri_system_ptime) * timebase,
                            energy: Double(ru.ri_energy_nj) / 1e9, diskRead: Double(ru.ri_diskio_bytesread),
                            diskWritten: Double(ru.ri_diskio_byteswritten), mem: Double(ru.ri_phys_footprint),
                            maxMem: Double(ru.ri_lifetime_max_phys_footprint), detail: true)
        }
    }

    /// Everyone else's processes, through /bin/ps: CPU time, memory (resident) and running time.
    private func collectOthers(into out: inout [pid_t: Seen], now: Double) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,rss=,time=,etime=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = pid_t(f[0]), out[pid] == nil, let rssKB = Double(f[1]) else { continue }
            // ps gives the running time to the second; the start time it implies varies by up to a
            // second between scans, which the matching allows for.
            let start = (now - Double(ProcessMonitor.parseCPUTime(f[3])) / 1e9).rounded()
            let mem = rssKB * 1024
            out[pid] = Seen(start: start, path: path(pid, start: start) ?? ProcKey.normalize(String(f[4])),
                            cpu: Double(ProcessMonitor.parseCPUTime(f[2])) / 1e9, mem: mem, maxMem: mem, detail: false)
        }
    }

    // MARK: - Reading

    /// Each program's totals over `range`, on the main queue.
    func summary(_ range: Range, _ done: @escaping (Summary) -> Void) {
        queue.async {
            var result = Summary(lastScan: self.lastUp > 0 ? Date(timeIntervalSince1970: self.lastWall) : nil, helper: self.helper)
            guard let store = self.store else { DispatchQueue.main.async { done(result) }; return }
            let now = Date().timeIntervalSince1970
            let today = Self.dayStart(now)
            let start = range == .last24h ? Self.hourStart(now) - 23 * 3600 : Self.addDays(today, -(range.days - 1))
            var rows: [Int64: ProcStats] = [:]
            func merge(_ r: [Int64: ProcStats]) { for (k, s) in r { rows[k, default: ProcStats()].add(s) } }
            // Whole days come from the daily rows, the rest (today, and days not added up yet) from hours.
            let hoursFrom = range.days > 1 ? max(start, min(self.rolledUpTo, today)) : start
            if range.days > 1 { merge(store.sum(span: 1, from: start, to: hoursFrom)) }
            merge(store.sum(span: 0, from: hoursFrom, to: .max, excluding: self.hour))
            if self.hour >= start { merge(self.current) }
            for (k, s) in rows {
                guard let path = self.keyPaths[k] else { continue }
                if path == Self.unseenKey { result.unseen = s } else { result.programs.append((path, s)) }
            }
            result.since = store.firstBucket().map { Date(timeIntervalSince1970: Double(max($0, start))) }
            DispatchQueue.main.async { done(result) }
        }
    }
}

/// How processes are grouped into programs.
enum ProcKey {
    /// The path a program is kept under. Homebrew's version folder and App Translocation's random
    /// folder are left out, so an update or a moved app keeps its history.
    static func normalize(_ path: String) -> String {
        guard path.contains("/Cellar/") || path.contains("/AppTranslocation/") else { return path }
        var c = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let i = c.firstIndex(of: "Cellar"), i + 2 < c.count - 1 { c[i + 2] = "*" }
        if let i = c.firstIndex(of: "AppTranslocation"), i + 1 < c.count - 1 { c[i + 1] = "*" }
        return c.joined(separator: "/")
    }

    /// The outermost app bundle a path is inside, if any.
    static func app(of path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func isApp(_ key: String) -> Bool { key.hasSuffix(".app") }

    /// "Google Chrome Helper (Renderer)" for an executable, "Google Chrome" for an app.
    static func name(_ key: String) -> String {
        let last = (key as NSString).lastPathComponent
        return isApp(key) ? String(last.dropLast(4)) : last
    }
}
