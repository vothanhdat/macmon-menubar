import AppKit
import Darwin

/// Where the app keeps its data, and where `macmon-indicator` (the terminal view in Terminal/)
/// finds the app's socket. Terminal/src/main.rs works out the same paths: keep them in step.
enum AppPaths {
    /// History, process history and the socket. MACMON_INDICATOR_HISTORY_DIR: for testing a build
    /// without touching the real history.
    static var dataDirectory: URL {
        ProcessInfo.processInfo.environment["MACMON_INDICATOR_HISTORY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMonIndicator", isDirectory: true)
    }

    /// `terminal.sock` in the data folder; when that path is too long for a socket address, the
    /// per-user temporary folder (which only you can open) instead.
    static func socketPath(in dir: URL) -> String {
        let p = dir.appendingPathComponent("terminal.sock").path
        if p.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) { return p }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let tmp = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 ? String(cString: buf) : NSTemporaryDirectory()
        return (tmp as NSString).appendingPathComponent("macmon-indicator.sock")
    }
}

/// Serves the app's live state to `macmon-indicator` in a terminal (e.g. over SSH) on a Unix
/// socket in the data folder: one JSON request per line, one JSON reply per line. Only your user
/// can connect: the socket file is yours alone (mode 0600), and each connection's user is checked.
/// While a terminal is connected the app samples every second and scans processes, as it does
/// while the menu is open (see AppDelegate).
///
/// The app computes and formats everything (chart scales, labels, which processes to show), so
/// the terminal shows the same numbers as the menu and only has to draw them.
final class TerminalServer {
    /// Bumped when a reply changes in a way an older terminal view can't read.
    static let version = 1
    /// More connections than anyone needs (each costs a socket and a few KB), but a bound.
    private static let maxClients = 64

    /// Main queue: the number of connected terminals changed.
    var onClientsChanged: ((Int) -> Void)?
    /// Main queue: answers a request by calling `reply` once, from any queue.
    var handle: ((Request, @escaping (Data) -> Void) -> Void)?

    private let queue = DispatchQueue(label: "MacMonIndicator.terminal", qos: .utility)
    private var listener: DispatchSourceRead?
    private var clients: [Int32: Client] = [:] // queue only

    private final class Client {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        init(fd: Int32) { self.fd = fd }
    }

    @discardableResult
    func start(path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        // A socket left by an earlier run, or by the copy a quiet restart replaces (it is about
        // to quit; its terminals reconnect to this one).
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        guard bound, chmod(path, 0o600) == 0, listen(fd, SOMAXCONN) == 0 else {
            log.error("terminal socket \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return false
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept(fd) }
        src.setCancelHandler { close(fd) }
        src.resume()
        listener = src
        return true
    }

    private func accept(_ listenFD: Int32) {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            guard fd >= 0 else { return } // EAGAIN: no more waiting
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), clients.count < Self.maxClients else {
                close(fd)
                continue
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Replies are written blocking; a terminal that stops reading is dropped after 2 s.
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            let c = Client(fd: fd)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.read(c) } // `drop` breaks the cycle
            src.setCancelHandler { close(fd) }
            c.source = src
            clients[fd] = c
            src.resume()
            countChanged()
        }
    }

    private func read(_ c: Client) {
        guard clients[c.fd] === c else { return } // dropped already
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(c.fd, &buf, buf.count)
        guard n > 0 else { drop(c); return }
        c.buffer.append(contentsOf: buf[0..<n])
        while let nl = c.buffer.firstIndex(of: 0x0A) {
            let line = Data(c.buffer[c.buffer.startIndex..<nl])
            c.buffer.removeSubrange(c.buffer.startIndex...nl)
            guard let req = try? JSONDecoder().decode(Request.self, from: line) else { drop(c); return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let handle = self.handle else { return }
                handle(req) { data in self.queue.async { self.send(data, to: c) } }
            }
        }
        if c.buffer.count > 64 << 10 { drop(c) } // requests are tiny
    }

    private func send(_ data: Data, to c: Client) {
        guard clients[c.fd] === c else { return } // gone meanwhile
        var out = data
        out.append(0x0A)
        let ok = out.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            var sent = 0
            while sent < p.count {
                let n = write(c.fd, p.baseAddress! + sent, p.count - sent)
                if n < 0 { if errno == EINTR { continue }; return false }
                sent += n
            }
            return true
        }
        if !ok { drop(c) }
    }

    private func drop(_ c: Client) {
        guard clients[c.fd] === c else { return }
        clients[c.fd] = nil
        c.source?.cancel() // closes the socket
        c.source = nil
        countChanged()
    }

    private func countChanged() {
        let n = clients.count
        DispatchQueue.main.async { [weak self] in self?.onClientsChanged?(n) }
    }

    // MARK: - Messages

    struct Request: Decodable {
        enum Command: String, Decodable { case live, history }
        let cmd: Command
        // live
        var tier: Int?          // HistoryStore.tiers index
        var points: Int?        // data points per chart: the chart's width in the terminal
        var sort: Int?          // ProcessListView.Sort raw value; none: the top few by each column
        var rows: Int?          // process rows
        // history
        var range: Int?         // ProcessTracker.Range raw value
        var byExecutable: Bool?
        var sortBy: String?     // column id
        var ascending: Bool?
        var filter: String?
        var limit: Int?
    }

    struct Live: Encodable {
        var kind = "live"
        var version = TerminalServer.version
        var app: String
        var host: String
        var time: Double
        var intervalMs: Int
        var problem: String?        // macmon missing or failing
        var tiers: [String]
        var tier: Int
        var columns: Int            // the menu's chart columns (Settings)
        var charts: [Chart]
        var values: [String: Float?] // the latest reading, for --json
        var processes: Processes
        var processHistory: Bool    // process history is kept
    }

    struct Chart: Encodable {
        var id: String
        var title: String
        var shape: String           // "up", "mirrored" (second series downward), "signed" (centered)
        var color: String
        var color2: String?
        var main: String
        var detail: String?
        var hot: Bool               // over the warning limit now
        var lo: Float, hi: Float    // visible range; the lower half's own for mirrored charts
        var lo2: Float?, hi2: Float?
        var warnStart: Float?, limit: Float? // bars blend toward red from warnStart, red from limit
        var avg: [Float?], max: [Float?]
        var avg2: [Float?]?, max2: [Float?]?
    }

    struct Processes: Encodable {
        var columns: [Column]
        var sort: Int?
        var rows: [ProcessRow]?     // nil while the first scans run
        var note: String
    }

    struct Column: Encodable {
        var title: String
        var sort: Int
    }

    struct ProcessRow: Encodable {
        var pid: Int32
        var name: String
        var cells: [String]
        var strong: Int             // the column it was picked for
    }

    struct History: Encodable {
        var kind = "history"
        var version = TerminalServer.version
        var tracking: Bool
        var ranges: [String]
        var range: Int
        var byExecutable: Bool
        var columns: [HistoryColumn]
        var sortBy: String
        var ascending: Bool
        var total: Int              // rows matching, before the limit
        var rows: [HistoryRow]
        var footer: [String]
    }

    struct HistoryColumn: Encodable {
        var id: String
        var title: String
        var tip: String
    }

    struct HistoryRow: Encodable {
        var name: String
        var path: String
        var cells: [String]
        var unknown: [Bool]         // the value can't be known (system processes without root)
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    }
}

// MARK: - Building replies

extension TerminalServer {
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    /// "mac-mini" (gethostname, without ".local"; Host and ProcessInfo can wait on DNS).
    static let hostName: String = {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "" }
        let name = String(cString: buf)
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
    }()

    /// Charts as the menu shows them, the latest reading, and the top processes.
    static func live(_ req: Request, history: HistoryStore, latest: Sample?, hasBattery: Bool, intervalMs: Int,
                     problem: String?, processes: ProcSnapshot?, processHistory: Bool) -> Live {
        let tier = min(max(req.tier ?? 1, 0), HistoryStore.tiers.count - 1)
        let t = HistoryStore.tiers[tier]
        let points = min(max(req.points ?? t.capacity, 8), t.capacity)
        let now = Date().timeIntervalSince1970
        let s = Settings.shared
        let thresholds = s.thresholds, fit = s.zoomCharts
        let value: (Series) -> Float = { latest?.value($0) ?? .nan }

        var avg: [Float] = [], mx: [Float] = [], avg2: [Float] = [], mx2: [Float] = []
        var charts: [Chart] = []
        for row in ChartsView.rows(for: s.chartIDs, hasBattery: hasBattery, fanCount: latest?.fanCount ?? 0) {
            history.window(tier: tier, series: row.series, now: now, avg: &avg, max: &mx)
            let r = ChartsView.range(row.scale, avg, mx, latest: latest, fit: fit)
            let text = row.text(value, latest)
            let limit = row.limit?(thresholds, latest)
            var c = Chart(id: row.id.rawValue, title: row.title, shape: "up", color: colorName(row.color),
                          color2: row.color2.map(colorName), main: text.main, detail: text.detail,
                          hot: limit.map { value(row.series) >= $0 } ?? false, lo: r.lo, hi: r.hi,
                          avg: downsample(avg, points, max: false), max: downsample(mx, points, max: true))
            switch row.shape {
            case .up:
                if let limit, limit > 0 {
                    var full = row.scale
                    if case .smart(_, let otherwise) = full { full = otherwise }
                    c.warnStart = max(0, limit - ChartsView.warnBand * ChartsView.range(full, avg, mx, latest: latest, fit: false).hi)
                    c.limit = limit
                }
            case .signed:
                c.shape = "signed"
            case .mirrored(let down):
                c.shape = "mirrored"
                history.window(tier: tier, series: down, now: now, avg: &avg2, max: &mx2)
                let r2 = ChartsView.range(row.scale, avg2, mx2, latest: latest, fit: fit)
                c.lo2 = r2.lo; c.hi2 = r2.hi
                c.avg2 = downsample(avg2, points, max: false)
                c.max2 = downsample(mx2, points, max: true)
            }
            charts.append(c)
        }

        var values: [String: Float?] = [:]
        if let l = latest {
            for s in Series.allCases { values[s.csvName] = finite(l.value(s)) }
            values["ram_total_gb"] = finite(l.ramTotalGB)
            values["mem_pressure"] = Float(l.memPressure)
            values["fan_max_rpm"] = finite(l.fanMax)
            values["on_ac"] = l.onAC ? 1 : 0
        }

        let sort = req.sort.flatMap(ProcessListView.Sort.init(rawValue:))
        let columns = ProcessListView.sortOrder
        let procs = Processes(
            columns: columns.map { Column(title: ProcessListView.title(of: $0), sort: $0.rawValue) },
            sort: sort?.rawValue,
            rows: processes.map { snap in
                ProcessListView.pick(snap.rows, sort: sort, count: min(max(req.rows ?? ProcessListView.defaultRows, 1), 50)).map { p in
                    ProcessRow(pid: p.row.pid, name: p.row.name, cells: columns.map { ProcessListView.text(p.row, $0) },
                               strong: columns.firstIndex(of: p.reason) ?? 0)
                }
            },
            note: ProcessListView.note(processes))

        return Live(app: appVersion, host: hostName, time: now, intervalMs: intervalMs, problem: problem,
                    tiers: HistoryStore.tiers.map(\.label), tier: tier, columns: s.chartLayout.columns,
                    charts: charts, values: values, processes: procs, processHistory: processHistory)
    }

    /// Process history over a range, sorted and filtered as the Process History window does.
    static func history(_ req: Request, summary: ProcessTracker.Summary?) -> History {
        let range = ProcessTracker.Range(rawValue: req.range ?? 0) ?? .today
        let byExecutable = req.byExecutable ?? false
        let columns = ProcessHistoryWindowController.columns
        let sortBy = columns.contains { $0.id == req.sortBy } ? req.sortBy! : "cpu"
        let ascending = req.ascending ?? (sortBy == "name")
        var rows: [ProcessHistoryWindowController.Row] = []
        if let summary {
            rows = ProcessHistoryWindowController.rows(summary, byExecutable: byExecutable,
                                                       filter: (req.filter ?? "").trimmingCharacters(in: .whitespaces))
            ProcessHistoryWindowController.sort(&rows, by: sortBy, ascending: ascending)
        }
        let limit = min(max(req.limit ?? 300, 1), 2000)
        let footer = summary.map {
            ProcessHistoryWindowController.footer($0, range: range, empty: $0.programs.isEmpty)
        } ?? ["Process history is off. Turn it on in Settings."]
        return History(tracking: summary != nil, ranges: ProcessTracker.Range.allCases.map(\.title), range: range.rawValue,
                       byExecutable: byExecutable,
                       columns: columns.map { HistoryColumn(id: $0.id, title: $0.title, tip: $0.tip) },
                       sortBy: sortBy, ascending: ascending, total: rows.count,
                       rows: rows.prefix(limit).map { r in
                           HistoryRow(name: r.name, path: r.path, cells: columns.map { $0.text(r) },
                                      unknown: columns.map { $0.id != "name" && $0.value(r) < 0 })
                       },
                       footer: footer)
    }

    private static func finite(_ v: Float) -> Float? { v.isFinite ? v : nil }

    /// `values` in `points` groups (or as they are when there are no more than `points`): each
    /// group's average, or with `max` its highest value. Empty buckets don't count; a group with
    /// none is nil.
    private static func downsample(_ values: [Float], _ points: Int, max useMax: Bool) -> [Float?] {
        let n = values.count
        guard n > points else { return values.map(finite) }
        return (0..<points).map { i in
            var sum: Float = 0, count = 0, top = -Float.infinity
            for v in values[(i * n / points)..<((i + 1) * n / points)] where v.isFinite {
                sum += v; count += 1; top = Swift.max(top, v)
            }
            guard count > 0 else { return nil }
            return useMax ? top : sum / Float(count)
        }
    }

    private static func colorName(_ c: NSColor) -> String {
        let names: [(NSColor, String)] = [(.systemIndigo, "indigo"), (.systemGreen, "green"), (.systemOrange, "orange"),
                                          (.systemBlue, "blue"), (.systemPink, "pink"), (.systemRed, "red")]
        return names.first { $0.0 == c }?.1 ?? "gray"
    }
}
