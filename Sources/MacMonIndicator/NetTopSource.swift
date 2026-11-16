import Foundation
import Darwin

/// Turns `nettop`'s samples into the bytes each program received and sent since the sample before.
///
/// A sample is a header line (",bytes_in,bytes_out,") and a row per process with open or recent
/// connections: "name.pid,bytes_in,bytes_out,". A row's numbers are totals since nettop started
/// watching, and stay when the process's connections close. The first sample also holds what
/// connections already open had carried before, so it only sets the starting point.
/// No state outside: tested in NetTopTests.
struct NetTopParser {
    struct Bytes: Equatable {
        var received = 0.0
        var sent = 0.0
    }

    private struct Row {
        var received: UInt64
        var sent: UInt64
        var path: String
    }

    /// The program a process belongs to, from its pid and nettop's (cut off) name for it.
    let program: (pid_t, String) -> String
    private var last: [String: Row] = [:]
    private var seen: Set<String> = []
    private var samples = 0
    private var buffer = Data()

    init(program: @escaping (pid_t, String) -> String = NetTopParser.program) {
        self.program = program
    }

    /// The executable's path as process history keeps it; nettop's name when the process is gone.
    static func program(_ pid: pid_t, _ name: String) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        guard pid > 0, proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return name }
        return ProcKey.normalize(String(cString: buf))
    }

    /// Takes the next bytes of nettop's output and returns what each program moved, by path.
    mutating func consume(_ data: Data) -> [String: Bytes] {
        var out: [String: Bytes] = [:]
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let (path, b) = consume(line: line) {
                out[path, default: Bytes()].received += b.received
                out[path, default: Bytes()].sent += b.sent
            }
        }
        if buffer.count > 1 << 20 { buffer.removeAll() } // never grow unbounded on garbage input
        return out
    }

    private mutating func consume(line raw: String) -> (String, Bytes)? {
        // A pseudo-terminal ends lines with "\r\n".
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(",") {
            // A new sample starts: processes missing from the one before have ended.
            if samples > 0 { last = last.filter { seen.contains($0.key) } }
            seen.removeAll(keepingCapacity: true)
            samples += 1
            return nil
        }
        // The name can hold dots and commas; the numbers are the last two fields.
        var f = line.split(separator: ",", omittingEmptySubsequences: false)
        if f.last == "" { f.removeLast() }
        guard samples > 0, f.count >= 3, let sent = UInt64(f[f.count - 1]), let received = UInt64(f[f.count - 2]) else { return nil }
        let key = f[0..<(f.count - 2)].joined(separator: ",")
        guard let dot = key.lastIndex(of: "."), let pid = pid_t(key[key.index(after: dot)...]) else { return nil }
        seen.insert(key)
        if let b = last[key] {
            last[key]?.received = received
            last[key]?.sent = sent
            // Lower than before: another process with the same name got this pid.
            let d = received >= b.received && sent >= b.sent
                ? Bytes(received: Double(received - b.received), sent: Double(sent - b.sent))
                : Bytes(received: Double(received), sent: Double(sent))
            return d.received > 0 || d.sent > 0 ? (b.path, d) : nil
        }
        let path = program(pid, String(key[..<dot]))
        last[key] = Row(received: received, sent: sent, path: path)
        // In the first sample this is the starting point; later, a process new to the network.
        guard samples > 1, received > 0 || sent > 0 else { return nil }
        return (path, Bytes(received: Double(received), sent: Double(sent)))
    }
}

/// Network bytes per program, for process history. macOS has no call for this that an app may
/// use (`proc_pid_rusage` has none), so this runs `/usr/bin/nettop`, which needs no root and also
/// sees system processes. Only Wi-Fi and Ethernet are counted, as in the Network chart: loopback
/// is left out, and traffic through a VPN counts for the VPN's process.
///
/// nettop only keeps a process's total while it runs, so it runs all the time (about 0.2% of a
/// core at this interval) and a sample is read every few seconds. What a process moves between
/// its last sample and its end is missed.
///
/// nettop needs a terminal: on a pipe it holds its output back for minutes, and with no terminal
/// to read keys from, or with its terminal gone, it spins a core. So `/usr/bin/script` runs it:
/// script gives it a terminal of its own, passes its output on, and ends when its input closes,
/// which hangs nettop up. Its input is a pipe this app holds, so nettop also ends when the app is
/// killed or crashes.
final class NetTopSource {
    static let path = "/usr/bin/nettop"
    static let script = "/usr/bin/script"
    static let interval = 5 // seconds between samples

    private let queue = DispatchQueue(label: "MacMonIndicator.nettop", qos: .utility)
    private let lock = NSLock()
    private var pending: [String: NetTopParser.Bytes] = [:] // since the last `drain`; under `lock`

    // Everything below: queue only.
    private var process: Process?
    private var input: Pipe?    // held open and never written to
    private var parser = NetTopParser()
    private var generation = 0
    private var wantRunning = false
    private var retryDelay: TimeInterval = 5

    func start() {
        queue.async {
            guard !self.wantRunning else { return }
            self.wantRunning = true
            self.launch()
        }
    }

    func stop() {
        queue.sync {
            self.wantRunning = false
            self.terminate()
        }
    }

    /// What each program (by path) received and sent since the last call.
    func drain() -> [String: NetTopParser.Bytes] {
        lock.lock()
        defer { lock.unlock() }
        let out = pending
        pending = [:]
        return out
    }

    private func terminate() {
        generation += 1
        if let p = process {
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            try? input?.fileHandleForWriting.close() // script ends, and nettop with it
            if p.isRunning { p.terminate() }
        }
        process = nil
        input = nil
    }

    private func retry() {
        let gen = generation
        queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self, self.wantRunning, self.generation == gen else { return }
            self.launch()
        }
        retryDelay = min(retryDelay * 2, 300)
    }

    private func launch() {
        terminate()
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Self.path), fm.isExecutableFile(atPath: Self.script) else {
            log.error("nettop can't be started; process history has no network numbers")
            return retry()
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.script)
        p.arguments = ["-q", "/dev/null", Self.path, "-P", "-L", "0", "-x", "-J", "bytes_in,bytes_out",
                       "-s", String(Self.interval), "-t", "wifi", "-t", "wired"]
        let out = Pipe(), keys = Pipe()
        p.standardOutput = out
        p.standardInput = keys
        p.standardError = FileHandle.nullDevice

        let gen = generation
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil; return }
            self?.queue.async {
                guard let self, self.generation == gen else { return }
                self.retryDelay = 5
                let moved = self.parser.consume(data)
                guard !moved.isEmpty else { return }
                self.lock.lock()
                for (path, b) in moved {
                    self.pending[path, default: .init()].received += b.received
                    self.pending[path, default: .init()].sent += b.sent
                }
                self.lock.unlock()
            }
        }
        p.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self, self.generation == gen, self.wantRunning else { return }
                log.error("nettop exited unexpectedly, retrying in \(self.retryDelay) s")
                self.terminate()
                self.retry()
            }
        }
        do { try p.run() } catch { return retry() }
        process = p
        input = keys
        parser = NetTopParser() // totals start again with a new nettop
        log.notice("nettop started: pid \(p.processIdentifier), every \(Self.interval) s")
    }
}
