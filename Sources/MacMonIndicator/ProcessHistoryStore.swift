import Foundation
import SQLite3
import os

/// What one program used: in one hour or day, or added up over a range.
struct ProcStats {
    var running = 0.0      // seconds (awake) with at least one copy running
    var copyTime = 0.0     // seconds summed over its copies; ÷ running = average number of copies
    var peakCopies = 0     // most copies seen at once
    var launches = 0       // copies seen starting
    var exits = 0          // copies seen ending
    var lifetime = 0.0     // seconds from start to end, summed over the copies that ended
    var cpu = 0.0          // CPU seconds
    var pcore = 0.0        // of those, on performance cores
    var energy = 0.0       // CPU energy, joules
    var ramTime = 0.0      // memory footprint × seconds; ÷ running = average
    var ramPeak = 0.0      // bytes, all copies together
    var ramOnePeak = 0.0   // bytes, the biggest single copy
    var diskRead = 0.0     // bytes
    var diskWritten = 0.0  // bytes
    var detail = false     // energy, P-core time, disk bytes and children's CPU are known (not for system processes without root)
    /// CPU seconds of the processes it started that ended and were collected by it, with theirs
    /// (as macOS counts them: `ri_child_*`). Children the scans saw also count under their own
    /// names, so this is not to be added to `cpu`.
    var childCpu = 0.0
    /// Of `energy`, the joules used while the Mac ran on its battery.
    var batteryEnergy = 0.0
    /// Bytes received and sent over Wi-Fi and Ethernet (see NetTopSource). Known for every
    /// process, also without root; 0 in history from before this was counted.
    var netIn = 0.0
    var netOut = 0.0

    /// Adds a later stretch of time: totals add up, peaks keep the highest.
    mutating func add(_ o: ProcStats) {
        running += o.running
        peakCopies = max(peakCopies, o.peakCopies)
        ramPeak = max(ramPeak, o.ramPeak)
        addCommon(o)
    }

    /// Adds another copy over the same stretch of time: the program ran as long as its longest
    /// copy, and copies and their memory add up.
    mutating func addCopy(_ o: ProcStats) {
        running = max(running, o.running)
        peakCopies += o.peakCopies
        ramPeak += o.ramPeak
        addCommon(o)
    }

    private mutating func addCommon(_ o: ProcStats) {
        copyTime += o.copyTime
        launches += o.launches
        exits += o.exits
        lifetime += o.lifetime
        cpu += o.cpu
        pcore += o.pcore
        energy += o.energy
        ramTime += o.ramTime
        ramOnePeak = max(ramOnePeak, o.ramOnePeak)
        diskRead += o.diskRead
        diskWritten += o.diskWritten
        childCpu += o.childCpu
        batteryEnergy += o.batteryEnergy
        netIn += o.netIn
        netOut += o.netOut
        detail = detail || o.detail
    }
}

/// A process running at the last scan, with its counters then (the next scan's starting point).
struct TrackedProcess {
    var start: Double      // seconds since 1970
    var exe: Int64         // key id of its executable
    var app: Int64         // key id of the app it belongs to, 0 for none
    var cpu: Double
    var pcore: Double
    var energy: Double
    var diskRead: Double
    var diskWritten: Double
    var detail: Bool
    var childCpu = -1.0    // negative: not known (system processes without root, or an older helper)
}

/// Process history on disk, in `process-history.sqlite` next to `history.bin`:
/// - `stats`: one row per program per hour (span 0, kept 48 h) or per day (span 1, kept 90 days).
///   A program is a key: an executable's path, or an app bundle's path (".app") for all of its
///   executables together.
/// - `keys`: the paths, by id.
/// - `live`: the counters of the processes running at the last save, so a restart continues
///   where the last run stopped.
/// - `meta`: a few numbers (see ProcessTracker).
/// Only used from the tracker's queue.
final class ProcessHistoryStore {
    private var db: OpaquePointer?
    private static let log = Logger(subsystem: "local.MacMonIndicator", category: "process-history")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let columns = "running, copy_time, peak_copies, launches, exits, lifetime, cpu, pcore, energy, " +
        "ram_time, ram_peak, ram_one_peak, disk_read, disk_written, detail, child_cpu, battery_energy, net_in, net_out"
    private static let totals = "sum(running), sum(copy_time), max(peak_copies), sum(launches), sum(exits), " +
        "sum(lifetime), sum(cpu), sum(pcore), sum(energy), sum(ram_time), max(ram_peak), max(ram_one_peak), " +
        "sum(disk_read), sum(disk_written), max(detail), sum(child_cpu), sum(battery_energy), sum(net_in), sum(net_out)"

    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            Self.log.error("can't open \(url.path, privacy: .public): \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            sqlite3_close(db)
            return nil
        }
        let ok = run("pragma journal_mode = wal") && run("pragma synchronous = normal") && run("""
            create table if not exists meta (k text primary key, v integer) without rowid;
            create table if not exists keys (id integer primary key, path text not null unique);
            create table if not exists stats (span integer not null, bucket integer not null, key integer not null,
                running real, copy_time real, peak_copies integer, launches integer, exits integer, lifetime real,
                cpu real, pcore real, energy real, ram_time real, ram_peak real, ram_one_peak real,
                disk_read real, disk_written real, detail integer, primary key (span, bucket, key)) without rowid;
            create table if not exists live (pid integer primary key, start real, exe integer, app integer, cpu real,
                pcore real, energy real, disk_read real, disk_written real, detail integer);
            """)
        guard ok else { sqlite3_close(db); return nil }
        // Added later (files from before have no value there: 0 in `stats`, not known in `live`).
        for table in ["stats", "live"] where !hasColumn(table, "child_cpu") {
            run("alter table \(table) add column child_cpu real")
        }
        if !hasColumn("stats", "battery_energy") { run("alter table stats add column battery_energy real") }
        for column in ["net_in", "net_out"] where !hasColumn("stats", column) { run("alter table stats add column \(column) real") }
    }

    private func hasColumn(_ table: String, _ column: String) -> Bool {
        var found = false
        run("select 1 from pragma_table_info(?) where name = ?", [table, column]) { _ in found = true }
        return found
    }

    deinit { sqlite3_close(db) }

    // MARK: - SQL

    private func bind(_ st: OpaquePointer, _ args: [Any?]) {
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case let v as Int64: sqlite3_bind_int64(st, n, v)
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Bool: sqlite3_bind_int64(st, n, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(st, n, v)
            case let v as String: sqlite3_bind_text(st, n, v, -1, Self.transient)
            default: sqlite3_bind_null(st, n)
            }
        }
    }

    /// Runs one statement (or, without arguments, several), calling `row` for each result row.
    @discardableResult
    private func run(_ sql: String, _ args: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        if args.isEmpty && row == nil {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return fail(sql) }
            return true
        }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return fail(sql) }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        while true {
            switch sqlite3_step(st) {
            case SQLITE_ROW: row?(st)
            case SQLITE_DONE: return true
            default: return fail(sql)
            }
        }
    }

    /// Runs one statement once per argument list.
    private func runMany(_ sql: String, _ rows: [[Any?]]) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { fail(sql); return }
        defer { sqlite3_finalize(st) }
        for args in rows {
            bind(st, args)
            if sqlite3_step(st) != SQLITE_DONE { fail(sql); return }
            sqlite3_reset(st)
            sqlite3_clear_bindings(st)
        }
    }

    @discardableResult
    private func fail(_ sql: String) -> Bool {
        let msg = String(cString: sqlite3_errmsg(db))
        Self.log.error("\(msg, privacy: .public) in: \(sql.prefix(80), privacy: .public)")
        return false
    }

    func transaction(_ body: () -> Void) {
        run("begin")
        body()
        run("commit")
    }

    private static func values(_ s: ProcStats) -> [Any?] {
        [s.running, s.copyTime, s.peakCopies, s.launches, s.exits, s.lifetime, s.cpu, s.pcore, s.energy,
         s.ramTime, s.ramPeak, s.ramOnePeak, s.diskRead, s.diskWritten, s.detail, s.childCpu, s.batteryEnergy,
         s.netIn, s.netOut]
    }

    /// Reads the 19 stats columns starting at column `i`.
    private static func stats(_ st: OpaquePointer, from i: Int32) -> ProcStats {
        func d(_ c: Int32) -> Double { sqlite3_column_double(st, i + c) }
        func n(_ c: Int32) -> Int { Int(sqlite3_column_int64(st, i + c)) }
        return ProcStats(running: d(0), copyTime: d(1), peakCopies: n(2), launches: n(3), exits: n(4), lifetime: d(5),
                         cpu: d(6), pcore: d(7), energy: d(8), ramTime: d(9), ramPeak: d(10), ramOnePeak: d(11),
                         diskRead: d(12), diskWritten: d(13), detail: n(14) != 0, childCpu: d(15), batteryEnergy: d(16),
                         netIn: d(17), netOut: d(18))
    }

    // MARK: - Meta and keys

    func meta(_ k: String) -> Int64? {
        var v: Int64?
        run("select v from meta where k = ?", [k]) { v = sqlite3_column_int64($0, 0) }
        return v
    }

    func setMeta(_ k: String, _ v: Int64) {
        run("insert or replace into meta (k, v) values (?, ?)", [k, v])
    }

    func keys() -> [Int64: String] {
        var out: [Int64: String] = [:]
        run("select id, path from keys", []) { st in
            out[sqlite3_column_int64(st, 0)] = String(cString: sqlite3_column_text(st, 1))
        }
        return out
    }

    func addKey(_ path: String) -> Int64? {
        guard run("insert or ignore into keys (path) values (?)", [path]) else { return nil }
        var id: Int64?
        run("select id from keys where path = ?", [path]) { id = sqlite3_column_int64($0, 0) }
        return id
    }

    // MARK: - Stats

    /// The rows of one bucket, by key.
    func stats(span: Int, bucket: Int64) -> [Int64: ProcStats] {
        var out: [Int64: ProcStats] = [:]
        run("select key, \(Self.columns) from stats where span = ? and bucket = ?", [span, bucket]) { st in
            out[sqlite3_column_int64(st, 0)] = Self.stats(st, from: 1)
        }
        return out
    }

    /// Replaces the rows of one bucket.
    func write(span: Int, bucket: Int64, _ rows: [Int64: ProcStats]) {
        runMany("insert or replace into stats (span, bucket, key, \(Self.columns)) values (?, ?, ?\(String(repeating: ", ?", count: 19)))",
                rows.map { [span, bucket, $0.key] + Self.values($0.value) })
    }

    /// Each key's totals over the buckets in `from..<to`, leaving out bucket `excluding`.
    func sum(span: Int, from: Int64, to: Int64, excluding: Int64 = -1) -> [Int64: ProcStats] {
        var out: [Int64: ProcStats] = [:]
        guard from < to else { return out }
        run("select key, \(Self.totals) from stats where span = ? and bucket >= ? and bucket < ? and bucket != ? group by key",
            [span, from, to, excluding]) { st in
            out[sqlite3_column_int64(st, 0)] = Self.stats(st, from: 1)
        }
        return out
    }

    /// One key's rows in the buckets `from..<to`, oldest first.
    func series(span: Int, key: Int64, from: Int64, to: Int64) -> [(bucket: Int64, stats: ProcStats)] {
        var out: [(bucket: Int64, stats: ProcStats)] = []
        guard from < to else { return out }
        run("select bucket, \(Self.columns) from stats where span = ? and bucket >= ? and bucket < ? and key = ? order by bucket",
            [span, from, to, key]) { st in
            out.append((sqlite3_column_int64(st, 0), Self.stats(st, from: 1)))
        }
        return out
    }

    /// Every row in the buckets `from..<to`: bucket, key, stats.
    func each(span: Int, from: Int64, to: Int64, _ body: (Int64, Int64, ProcStats) -> Void) {
        guard from < to else { return }
        withoutActuallyEscaping(body) { body in
            _ = run("select bucket, key, \(Self.columns) from stats where span = ? and bucket >= ? and bucket < ?", [span, from, to]) { st in
                body(sqlite3_column_int64(st, 0), sqlite3_column_int64(st, 1), Self.stats(st, from: 2))
            }
        }
    }

    /// Each key's CPU seconds over the buckets in `from..<to` (leaving out bucket `excluding`):
    /// their sum, how many buckets it has a row in, and the most in one.
    func cpu(span: Int, from: Int64, to: Int64, excluding: Int64 = -1) -> [Int64: (sum: Double, rows: Int, most: Double)] {
        var out: [Int64: (sum: Double, rows: Int, most: Double)] = [:]
        guard from < to else { return out }
        run("select key, sum(cpu), count(*), max(cpu) from stats where span = ? and bucket >= ? and bucket < ? and bucket != ? group by key",
            [span, from, to, excluding]) { st in
            out[sqlite3_column_int64(st, 0)] = (sqlite3_column_double(st, 1), Int(sqlite3_column_int64(st, 2)), sqlite3_column_double(st, 3))
        }
        return out
    }

    /// Adds up the hours of the day `day..<next` into one row per key.
    func rollUp(day: Int64, next: Int64) {
        run("""
            insert or replace into stats (span, bucket, key, \(Self.columns))
            select 1, ?, key, \(Self.totals) from stats where span = 0 and bucket >= ? and bucket < ? group by key
            """, [day, day, next])
    }

    func prune(hourlyBefore: Int64, dailyBefore: Int64) {
        run("delete from stats where span = 0 and bucket < ?", [hourlyBefore])
        run("delete from stats where span = 1 and bucket < ?", [dailyBefore])
    }

    /// The oldest bucket with data, or nil when there is none.
    func firstBucket() -> Int64? {
        var v: Int64?
        run("select min(bucket) from stats", []) { st in
            if sqlite3_column_type(st, 0) != SQLITE_NULL { v = sqlite3_column_int64(st, 0) }
        }
        return v
    }

    // MARK: - Live processes

    func live() -> [pid_t: TrackedProcess] {
        var out: [pid_t: TrackedProcess] = [:]
        run("select pid, start, exe, app, cpu, pcore, energy, disk_read, disk_written, detail, child_cpu from live", []) { st in
            func d(_ c: Int32) -> Double { sqlite3_column_double(st, c) }
            out[pid_t(sqlite3_column_int64(st, 0))] = TrackedProcess(
                start: d(1), exe: sqlite3_column_int64(st, 2), app: sqlite3_column_int64(st, 3), cpu: d(4), pcore: d(5),
                energy: d(6), diskRead: d(7), diskWritten: d(8), detail: sqlite3_column_int64(st, 9) != 0,
                childCpu: sqlite3_column_type(st, 10) == SQLITE_NULL ? -1 : d(10))
        }
        return out
    }

    func setLive(_ procs: [pid_t: TrackedProcess]) {
        run("delete from live")
        runMany("insert into live (pid, start, exe, app, cpu, pcore, energy, disk_read, disk_written, detail, child_cpu) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                procs.map { [Int64($0.key), $0.value.start, $0.value.exe, $0.value.app, $0.value.cpu, $0.value.pcore,
                             $0.value.energy, $0.value.diskRead, $0.value.diskWritten, $0.value.detail, $0.value.childCpu] })
    }

    /// Deletes all process history.
    func clear() {
        transaction {
            run("delete from stats; delete from live; delete from keys; delete from meta")
        }
        run("vacuum")
    }
}
