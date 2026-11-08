import Foundation
import Darwin

struct ProcRow {
    let pid: pid_t
    let name: String
    var cpu: Double?   // % of one core
    var cpuTime: Double // seconds of CPU used since the process started
    var mem: Double    // bytes
    var disk: Double?  // bytes/s, nil when not readable without root
}

struct ProcSnapshot {
    var rows: [ProcRow] = []
    /// Disk throughput not attributed to any visible process (system processes in non-root mode).
    var hiddenDiskBps: Double?
    var usingHelper = false
    var helperFailed = false
}

/// Samples per-process CPU, memory and disk I/O. Runs only while the menu is open.
/// - Your processes: libproc (exact CPU time, memory footprint, disk bytes).
/// - Other users' / system processes: /bin/ps (CPU time + RSS; it has root rights), disk unknown.
/// - Root mode: the helper daemon returns everything for every process.
final class ProcessMonitor {
    var onUpdate: ((ProcSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "MacMonIndicator.procmon", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var prev: [pid_t: (cpuNs: UInt64, disk: UInt64?)] = [:]
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
    }

    private func scan() {
        guard running else { return }
        var snap = ProcSnapshot()
        var raw: [pid_t: Raw]
        if useHelper, let h = RootHelper.snapshot() {
            raw = h.mapValues { Raw(name: $0.name, cpuNs: $0.cpuNs, mem: $0.mem, disk: $0.disk) }
            snap.usingHelper = true
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
        prev = raw.mapValues { ($0.cpuNs, $0.disk) }
        prevTime = now

        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snap) }
    }

    private func machToNs(_ t: UInt64) -> UInt64 { t / timebase.denom * timebase.numer + (t % timebase.denom) * timebase.numer / timebase.denom }

    private func collectOwn() -> [pid_t: Raw] {
        var out: [pid_t: Raw] = [:]
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return out }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let n = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        var nameBuf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            var si = proc_bsdshortinfo()
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0,
                  si.pbsi_uid == me else { continue }
            var ru = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ru) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            var name = ""
            if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 { name = String(cString: nameBuf) }
            if name.isEmpty {
                name = withUnsafeBytes(of: si.pbsi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            }
            out[pid] = Raw(name: name,
                           cpuNs: machToNs(ru.ri_user_time &+ ru.ri_system_time),
                           mem: Double(ru.ri_phys_footprint),
                           disk: ru.ri_diskio_bytesread &+ ru.ri_diskio_byteswritten)
        }
        return out
    }

    /// Adds every process we could not read ourselves, using /bin/ps.
    private func collectOthers(into out: inout [pid_t: Raw]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,rss=,time=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = pid_t(f[0]), out[pid] == nil, let rssKB = Double(f[1]) else { continue }
            let comm = String(f[3])
            let name = comm.hasPrefix("/") ? (comm as NSString).lastPathComponent : comm
            out[pid] = Raw(name: name, cpuNs: Self.parseCPUTime(f[2]), mem: rssKB * 1024, disk: nil)
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
