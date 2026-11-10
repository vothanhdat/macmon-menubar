import Foundation
import Darwin

struct ProcRow {
    let pid: pid_t
    let name: String
    var cpu: Double?   // % of one core
    var cpuTime: Double // seconds of CPU used since the process started
    var mem: Double    // bytes
    var disk: Double?  // bytes/s, nil when not readable without root
    /// % of one core spent in the kernel on its behalf (system calls, page faults); part of `cpu`.
    var kernel: Double? = nil
}

struct ProcSnapshot {
    var rows: [ProcRow] = []
    /// Disk throughput not attributed to any visible process (system processes in non-root mode).
    var hiddenDiskBps: Double?
    var usingHelper = false
    var helperFailed = false
    /// The installed root helper is an older version that doesn't report kernel time.
    var helperOutdated = false
}

/// Samples per-process CPU (and the kernel's part of it), memory and disk I/O. Runs only while
/// the menu is open or the dashboard window can be seen.
/// - Your processes: libproc (exact CPU and kernel time, memory footprint, disk bytes).
/// - Other users' / system processes: /bin/ps (CPU and kernel time + RSS; it has root rights),
///   disk unknown.
/// - Root mode: the helper daemon returns everything for every process.
///
/// macOS counts disk bytes per process but not disk operations. Kernel time is the closest sign
/// of heavy file work: a process walking or checking many small files spends most of its CPU in
/// the kernel, even when the files come from memory and the drive never sees them.
final class ProcessMonitor {
    var onUpdate: ((ProcSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "MacMonIndicator.procmon", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var prev: [pid_t: (cpuNs: UInt64, disk: UInt64?, kernelNs: UInt64?)] = [:]
    private var prevTime: UInt64 = 0
    private let me = getuid()
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()
    private var totalDiskBps = Double.nan
    private var useHelper = false
    private var running = false // queue-only

    func start(useHelper: Bool) {
        queue.async { self.useHelper = useHelper; self.running = true }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Short initial delay: a menu that only flashes open (mouse sweeping the menu bar) costs nothing.
        t.schedule(deadline: .now() + 0.3, repeating: .seconds(2), leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
        // A second quick scan so CPU/disk rates appear without waiting a full period.
        queue.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.scan() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        onUpdate = nil
        queue.async { self.running = false }
    }

    /// Latest system-wide disk throughput (MB/s) from the main sampler.
    func setTotalDisk(mbps: Float) {
        queue.async { self.totalDiskBps = Double(mbps) * 1e6 }
    }

    private struct Raw {
        var name: String
        var cpuNs: UInt64
        var mem: Double
        var disk: UInt64?
        var kernelNs: UInt64?
    }

    private func scan() {
        guard running else { return }
        var snap = ProcSnapshot()
        var raw: [pid_t: Raw]
        if useHelper, let h = RootHelper.snapshot() {
            raw = h.processes.mapValues { Raw(name: $0.name, cpuNs: $0.cpuNs, mem: $0.mem, disk: $0.disk, kernelNs: $0.kernelNs) }
            snap.usingHelper = true
            snap.helperOutdated = h.version < 2
        } else {
            snap.helperFailed = useHelper
            raw = collectOwn()
            collectOthers(into: &raw)
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let dt = Double(now &- prevTime)
        let havePrev = prevTime > 0 && dt > 0
        var visibleDisk = 0.0
        snap.rows.reserveCapacity(raw.count)
        for (pid, r) in raw {
            var row = ProcRow(pid: pid, name: r.name, cpu: nil, cpuTime: Double(r.cpuNs) / 1e9, mem: r.mem, disk: nil)
            if havePrev, let p = prev[pid] {
                row.cpu = r.cpuNs >= p.cpuNs ? Double(r.cpuNs - p.cpuNs) / dt * 100 : 0
                // Less time than before means the pid was reused: no rate then.
                if let k = r.kernelNs, let pk = p.kernelNs, k >= pk, r.cpuNs >= p.cpuNs {
                    row.kernel = Double(k - pk) / dt * 100
                }
                if let d = r.disk, let pd = p.disk {
                    row.disk = d >= pd ? Double(d - pd) / (dt / 1e9) : 0
                    visibleDisk += row.disk ?? 0
                }
            } else if r.disk != nil, havePrev {
                row.disk = 0
            }
            snap.rows.append(row)
        }
        if !snap.usingHelper, havePrev, totalDiskBps.isFinite {
            snap.hiddenDiskBps = max(0, totalDiskBps - visibleDisk)
        }
        prev = raw.mapValues { ($0.cpuNs, $0.disk, $0.kernelNs) }
        prevTime = now

        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snap) }
    }

    private func machToNs(_ t: UInt64) -> UInt64 { t / timebase.denom * timebase.numer + (t % timebase.denom) * timebase.numer / timebase.denom }

    /// Owner, name and start time of each listed pid, kept while it stays listed. Looking up who
    /// owns each of ~800 processes, and what yours are called, on every scan was most of the app's
    /// own system calls (about 1,200 a second while scanning). A pid reused by a new process of
    /// yours shows a different start time and is looked up again. (One reused by a process of
    /// yours within a scan's 2 s, after belonging to someone else, shows through /bin/ps until it
    /// ends: pids count up to 99,999 before reuse, so that is unlikely.)
    private var known: [pid_t: (mine: Bool, name: String, start: UInt64)] = [:]
    private var nameBuf = [CChar](repeating: 0, count: 256)

    /// Whether a process is yours, and its name if it is. Nil if it has gone.
    private func lookUp(_ pid: pid_t) -> (mine: Bool, name: String)? {
        var si = proc_bsdshortinfo()
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0 else { return nil }
        guard si.pbsi_uid == me else { return (false, "") }
        var name = ""
        if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 { name = String(cString: nameBuf) }
        if name.isEmpty {
            name = withUnsafeBytes(of: si.pbsi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        return (true, name)
    }

    private func collectOwn() -> [pid_t: Raw] {
        var out: [pid_t: Raw] = [:]
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return out }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let n = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        let listed = pids.prefix(Int(max(0, n))).filter { $0 > 0 }
        for pid in listed {
            if known[pid] == nil {
                guard let info = lookUp(pid) else { continue }
                known[pid] = (info.mine, info.name, 0)
            }
            guard var entry = known[pid], entry.mine else { continue } // someone else's: /bin/ps covers it
            var ru = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ru) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            if entry.start != ru.ri_proc_start_abstime {
                if entry.start != 0, let info = lookUp(pid) { entry.name = info.name } // a new process with a reused pid
                entry.start = ru.ri_proc_start_abstime
                known[pid] = entry
            }
            out[pid] = Raw(name: entry.name,
                           cpuNs: machToNs(ru.ri_user_time &+ ru.ri_system_time),
                           mem: Double(ru.ri_phys_footprint),
                           disk: ru.ri_diskio_bytesread &+ ru.ri_diskio_byteswritten,
                           kernelNs: machToNs(ru.ri_system_time))
        }
        let alive = Set(listed)
        known = known.filter { alive.contains($0.key) }
        return out
    }

    /// Adds every process we could not read ourselves, using /bin/ps.
    private func collectOthers(into out: inout [pid_t: Raw]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,rss=,time=,stime=,comm="] // stime: the kernel's part of time
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
            let comm = String(f[4])
            let name = comm.hasPrefix("/") ? (comm as NSString).lastPathComponent : comm
            out[pid] = Raw(name: name, cpuNs: Self.parseCPUTime(f[2]), mem: rssKB * 1024, disk: nil,
                           kernelNs: Self.parseCPUTime(f[3]))
        }
    }

    /// Parses ps "time" ("197:05.63", "1:02:03.45", "2-03:04:05").
    static func parseCPUTime(_ s: Substring) -> UInt64 {
        var days = 0.0
        var rest = s
        if let dash = s.firstIndex(of: "-") {
            days = Double(s[s.startIndex..<dash]) ?? 0
            rest = s[s.index(after: dash)...]
        }
        var total = 0.0
        for part in rest.split(separator: ":") { total = total * 60 + (Double(part) ?? 0) }
        return UInt64((total + days * 86400) * 1e9)
    }
}
