import Foundation
import Testing
@testable import MacMonIndicator

/// A tracker fed with made-up scans at made-up times. Nothing here reads real processes or the
/// real clock, so days of scans run in a moment.
private final class Sim {
    let dir: TempDir
    private(set) var tracker: ProcessTracker
    var wall: Double
    private var up: UInt64 = 5_000_000_000_000
    private var ticks: UInt32 = 1000

    init(at wall: Double, dir: TempDir = TempDir()) {
        self.dir = dir
        self.wall = wall
        tracker = ProcessTracker(directory: dir.url)
    }

    /// Time passes. Asleep, the wall clock moves and the uptime clock doesn't.
    func advance(_ seconds: Double, asleep: Bool = false) {
        wall += seconds
        if !asleep { up += UInt64(seconds * 1e9) }
    }

    func setClock(_ t: Double) { wall = t }

    /// One scan now; `busy` is the CPU seconds the whole Mac used since the last one.
    func scan(_ procs: [pid_t: ProcessTracker.Seen], busy: Double = 0, net: [String: NetTopParser.Bytes] = [:]) {
        ticks += UInt32(busy * Double(sysconf(Int32(_SC_CLK_TCK))))
        tracker.queue.sync { tracker.record(procs, nowWall: wall, nowUp: up, ticks: [ticks, 0, 0], net: net) }
    }

    /// `/usr/bin/a` (pid 7, started long ago) with `cpu` CPU seconds so far, and half as much
    /// used by its children.
    func scan(cpu: Double, busy: Double = 0, net: [String: NetTopParser.Bytes] = [:]) {
        scan([7: ProcessTracker.Seen(start: 1_000_000, path: Self.a, cpu: cpu, childCpu: cpu / 2, mem: 100, maxMem: 100, detail: true)],
             busy: busy, net: net)
    }

    /// `/usr/bin/a` over `range`, a point per hour or day.
    func points(_ range: ProcessTracker.Range) -> ProcessTracker.Series {
        tracker.queue.sync { tracker.points(Self.a, range, now: wall) }
    }

    func summary(_ range: ProcessTracker.Range) -> ProcessTracker.Summary {
        tracker.queue.sync { tracker.summarize(range, now: wall) }
    }

    /// `/usr/bin/a`'s totals over `range`.
    func a(_ range: ProcessTracker.Range) -> ProcStats {
        summary(range).programs.first { $0.path == Self.a }?.stats ?? ProcStats()
    }

    /// Quit and start again, as the app does (`saving`), or as after a crash.
    func restart(saving: Bool = true) {
        if saving { tracker.save() }
        tracker = ProcessTracker(directory: dir.url)
    }

    /// What is on disk now: `/usr/bin/a`'s row in one bucket, read through a second connection.
    func saved(span: Int, bucket: Int64) throws -> ProcStats? {
        tracker.save()
        let store = try #require(ProcessHistoryStore(url: dir.url.appendingPathComponent("process-history.sqlite")))
        let id = try #require(store.keys().first { $0.value == Self.a }?.key)
        return store.stats(span: span, bucket: bucket)[id]
    }

    static let a = "/usr/bin/a"
}

private let cal = Calendar.current
/// The start of a day in this Mac's time zone, well after 1970 and `days` days after the first.
private func day(_ days: Int = 0) -> Double {
    let first = cal.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    return cal.date(byAdding: .day, value: days, to: first)!.timeIntervalSince1970
}
/// The start of an hour (hours are counted from 1970, as the tracker does).
private let hour: Double = (day() / 3600).rounded(.down) * 3600 + 10 * 3600

@Suite struct ProcessTrackerTests {
    @Test func networkBytesGoToTheProgramAndItsApp() {
        let helper = "/Applications/B.app/Contents/Frameworks/B Helper.app/Contents/MacOS/B Helper"
        let sim = Sim(at: hour + 100)
        // Collected before the first scan: there is no interval to put it in.
        sim.scan(cpu: 100, net: [Sim.a: .init(received: 999, sent: 999)])
        sim.advance(300)
        // `helper` ended before this scan: it has bytes but was never seen running.
        sim.scan(cpu: 110, net: [Sim.a: .init(received: 5000, sent: 300), helper: .init(received: 70, sent: 8)])
        sim.advance(300)
        sim.scan(cpu: 120, net: [Sim.a: .init(received: 1000, sent: 0)])
        #expect(sim.a(.today).netIn == 6000)
        #expect(sim.a(.today).netOut == 300)
        #expect(sim.a(.today).peakCopies == 1) // the bytes are not another copy
        #expect(sim.a(.today).running == 600)
        let programs = sim.summary(.today).programs
        for path in [helper, "/Applications/B.app"] {
            let s = programs.first { $0.path == path }?.stats
            #expect(s?.netIn == 70, "\(path)")
            #expect(s?.netOut == 8, "\(path)")
            #expect(s?.running == 0, "\(path)")
        }
        // Saved and read back by a new tracker.
        sim.restart()
        #expect(sim.a(.today).netIn == 6000)
        let p = sim.points(.today).points.map(\.stats)
        #expect(p.reduce(0) { $0 + $1.netIn } == 6000)
    }

    @Test func intervalBelongsToTheHourItsMiddleFallsIn() throws {
        let sim = Sim(at: hour - 400)
        sim.scan(cpu: 100)          // the first scan only sets the starting point
        sim.advance(300)
        sim.scan(cpu: 110)          // middle at hour − 250: the hour before
        sim.advance(300)
        sim.scan(cpu: 125)          // middle at hour + 50: this hour
        #expect(try sim.saved(span: 0, bucket: Int64(hour) - 3600)?.cpu == 10)
        #expect(try sim.saved(span: 0, bucket: Int64(hour))?.cpu == 15)
        #expect(sim.a(.last24h).cpu == 25)
        #expect(sim.a(.last24h).running == 600)
        #expect(sim.summary(.last24h).lastScan == Date(timeIntervalSince1970: sim.wall))
    }

    @Test func pointsAreOnePerHourAndAddUpToTheSummary() {
        let sim = Sim(at: hour - 400)
        sim.scan(cpu: 100)
        sim.advance(300)
        sim.scan(cpu: 110)          // the hour before
        sim.advance(300)
        sim.scan(cpu: 125)          // this hour, still in memory
        sim.advance(3 * 3600)       // two hours later, with nothing seen in between
        sim.scan(cpu: 125)
        sim.advance(300)
        sim.scan(cpu: 126)
        let s = sim.points(.last24h)
        #expect(s.hourly)
        #expect(s.points.count == 24)
        #expect(s.points.last?.start == (sim.wall / 3600).rounded(.down) * 3600)
        #expect(zip(s.points, s.points.dropFirst()).allSatisfy { $1.start - $0.start == 3600 })
        #expect(s.points.suffix(5).map(\.stats.cpu) == [10, 15, 0, 0, 1])
        #expect(s.points.suffix(5).map(\.stats.childCpu) == [5, 7.5, 0, 0, 0.5])
        #expect(s.points.suffix(5).map(\.stats.running) == [300, 300, 0, 0, 300])
        #expect(s.points.reduce(0) { $0 + $1.stats.cpu } == sim.a(.last24h).cpu)
        #expect(sim.a(.last24h).childCpu == 13)
        // After a restart the hour that was in memory comes from the file.
        sim.restart()
        #expect(sim.points(.last24h).points.suffix(5).map(\.stats.cpu) == [10, 15, 0, 0, 1])
        // A program never seen: every hour, empty.
        let none = sim.tracker.queue.sync { sim.tracker.points("/usr/bin/none", .last24h, now: sim.wall) }
        #expect(none.points.count == 24)
        #expect(none.points.allSatisfy { $0.stats.running == 0 })
    }

    /// An app with two executables, a tool outside any app, and CPU no scan saw.
    @Test func stackIsSomeProgramsNextToAllOfThem() {
        let main = "/Applications/Foo.app/Contents/MacOS/Foo", helper = "/Applications/Foo.app/Contents/MacOS/foo-helper"
        let tool = "/usr/bin/tool", app = "/Applications/Foo.app"
        func procs(_ a: Double, _ b: Double, _ c: Double) -> [pid_t: ProcessTracker.Seen] {
            [1: .init(start: 1_000_000, path: main, cpu: a, mem: 100, maxMem: 100, detail: true),
             2: .init(start: 1_000_000, path: helper, cpu: b, mem: 50, maxMem: 50, detail: true),
             3: .init(start: 1_000_000, path: tool, cpu: c, mem: 10, maxMem: 10, detail: true)]
        }
        let sim = Sim(at: hour - 400)
        sim.scan(procs(0, 0, 0))
        sim.advance(300)
        sim.scan(procs(4, 2, 1), busy: 10)      // the hour before: 7 s found of 10
        sim.advance(300)
        sim.scan(procs(10, 3, 1), busy: 7)      // this hour
        func stack(_ paths: [String], byExecutable: Bool, _ range: ProcessTracker.Range = .last24h) -> ProcessTracker.Overview {
            sim.tracker.queue.sync { sim.tracker.stack(paths, range, byExecutable: byExecutable, now: sim.wall) }
        }

        // Apps: the app (its executables together) and the tool; the executables don't count again.
        let apps = stack([app, "/usr/bin/none"], byExecutable: false)
        #expect(apps.hourly)
        #expect(apps.starts.count == 24)
        #expect(apps.programs.map(\.path) == [app, "/usr/bin/none"])
        #expect(apps.programs[0].points.suffix(2).map(\.cpu) == [6, 7])
        #expect(apps.programs[1].points.allSatisfy { $0.cpu == 0 })
        #expect(apps.total.suffix(2).map(\.cpu) == [7, 7])
        #expect(apps.total.dropLast(2).allSatisfy { $0.cpu == 0 })
        #expect(apps.unseen.suffix(2).map(\.cpu) == [3, 0])
        #expect(apps.awake.suffix(2) == [300, 300])
        let ram: [Double] = apps.total.suffix(2).map(\.ramTime)
        #expect(ram == [48000, 48000])                 // 100 + 50 + 10 bytes for 300 s
        // Executables: each one, and not the app on top of them.
        let exes = stack([helper, tool], byExecutable: true)
        #expect(exes.programs[0].points.suffix(2).map(\.cpu) == [2, 1])
        #expect(exes.programs[1].points.suffix(2).map(\.cpu) == [1, 0])
        #expect(exes.total.suffix(2).map(\.cpu) == [7, 7])
        // The parts add up to the table's rows, per day too and after a restart.
        sim.restart()
        let week = stack([app], byExecutable: false, .week)
        #expect(!week.hourly)
        #expect(week.starts.count == 7)
        #expect(week.programs[0].points.last?.cpu == 13)
        #expect(week.total.last?.cpu == 14)
        #expect(week.unseen.last?.cpu == 3)
        #expect(week.awake.last == 600)
        let rows = sim.summary(.week).programs.filter { $0.path == app || $0.path == tool }
        #expect(rows.reduce(0) { $0 + $1.stats.cpu } == 14)
    }

    @Test func savingAgainDoesNotCountTwice() throws {
        let sim = Sim(at: hour + 100)
        sim.scan(cpu: 100)
        sim.advance(300)
        sim.scan(cpu: 110)
        sim.tracker.save()
        sim.tracker.save()          // sleep, then quit
        #expect(sim.a(.today).cpu == 10)
        #expect(try sim.saved(span: 0, bucket: Int64(hour))?.cpu == 10)
    }

    @Test func restartGoesOnCounting() {
        let sim = Sim(at: hour + 100)
        sim.scan(cpu: 100)
        sim.advance(300)
        sim.scan(cpu: 110)
        sim.restart()
        #expect(sim.a(.today).cpu == 10)        // what was counted is still there
        sim.advance(300)
        sim.scan(cpu: 117)                      // and the 7 s used across the restart count too
        #expect(sim.a(.today).cpu == 17)
        #expect(sim.a(.today).running == 600)
        #expect(sim.a(.today).launches == 0)
        #expect(sim.a(.today).exits == 0)
    }

    @Test func afterACrashTheFirstScanOnlySetsTheStartingPoint() {
        let sim = Sim(at: hour + 100)
        sim.scan(cpu: 100)
        sim.advance(300)
        sim.scan(cpu: 110)
        sim.restart(saving: false)              // nothing was written
        sim.advance(300)
        sim.scan(cpu: 117)
        #expect(sim.a(.today).cpu == 0)
        sim.advance(300)
        sim.scan(cpu: 120)
        #expect(sim.a(.today).cpu == 3)
        #expect(sim.a(.today).exits == 0)
    }

    @Test func sleepIsNotRunningTime() {
        let sim = Sim(at: hour + 100)
        sim.scan(cpu: 100)
        sim.advance(200)
        sim.advance(2 * 3600, asleep: true)
        sim.advance(100)
        sim.scan(cpu: 104)
        #expect(sim.a(.today).cpu == 4)
        #expect(sim.a(.today).running == 300)   // awake time only
    }

    @Test func longGapOnlySetsTheStartingPoint() {
        // Awake for an hour without a scan (scanning was off): that CPU can't be placed in time.
        let sim = Sim(at: hour + 100)
        sim.scan(cpu: 100)
        sim.advance(300)
        sim.scan(cpu: 110)
        sim.advance(3600)
        sim.scan(cpu: 900)
        sim.advance(300)
        sim.scan(cpu: 901)
        #expect(sim.a(.today).cpu == 11)
        #expect(sim.a(.today).running == 600)
    }

    @Test func clockSetBackKeepsTheCurrentHour() throws {
        let sim = Sim(at: hour + 100)
        sim.scan(cpu: 100)
        sim.advance(300)
        sim.scan(cpu: 110)
        let before = sim.wall
        sim.advance(300)
        sim.setClock(hour - 3000)               // set back by almost an hour
        sim.scan(cpu: 150)                      // can't be placed in time
        sim.advance(300)
        sim.scan(cpu: 155)                      // its hour would be the one before: kept in the current one
        #expect(try sim.saved(span: 0, bucket: Int64(hour))?.cpu == 15)
        #expect(try sim.saved(span: 0, bucket: Int64(hour) - 3600) == nil)
        sim.setClock(before)
        #expect(sim.a(.today).cpu == 15)
    }

    @Test func cpuNoScanSawIsUnseen() {
        let sim = Sim(at: hour + 100)
        sim.scan(cpu: 100)
        sim.advance(300)
        sim.scan(cpu: 110, busy: 30)            // the Mac used 30 s; the scan found 10
        #expect(sim.summary(.today).unseen.cpu == 20)
        sim.advance(300)
        sim.scan(cpu: 115, busy: 4)             // found more than the Mac's ticks say (rounding): not negative
        #expect(sim.summary(.today).unseen.cpu == 20)
        #expect(!sim.summary(.today).programs.contains { $0.path == ProcessTracker.unseenKey })
    }

    @Test func appAndItsExecutablesAreBothKept() {
        let exe = "/Applications/Foo.app/Contents/MacOS/Foo"
        func foo(_ cpu: Double) -> [pid_t: ProcessTracker.Seen] {
            [9: ProcessTracker.Seen(start: 1_000_000, path: exe, cpu: cpu, mem: 1, maxMem: 1, detail: true)]
        }
        let sim = Sim(at: hour + 100)
        sim.scan(foo(1))
        sim.advance(300)
        sim.scan(foo(3))
        let programs = Dictionary(uniqueKeysWithValues: sim.summary(.today).programs.map { ($0.path, $0.stats) })
        #expect(programs[exe]?.cpu == 2)
        #expect(programs["/Applications/Foo.app"]?.cpu == 2)
        #expect(programs.count == 2)
    }

    /// Four days of scans every 10 minutes: days are added up into daily rows and hours older
    /// than 48 h are dropped, and through all of it every range still adds up exactly.
    @Test func totalsSurviveRollUpAndPrune() throws {
        let start = day() + 12 * 3600, step = 600.0, scans = 4 * 144
        let sim = Sim(at: start)
        var cpu = 100.0
        var hours: [Int64] = []                 // the hour each interval was counted in
        sim.scan(cpu: cpu)
        for _ in 1..<scans {
            sim.advance(step)
            cpu += 2
            sim.scan(cpu: cpu)
            hours.append(Int64(((sim.wall - step / 2) / 3600).rounded(.down)) * 3600)
        }
        let now = sim.wall
        func expected(from t: Double) -> Double { Double(hours.filter { Double($0) >= t }.count) * 2 }

        #expect(sim.a(.week).cpu == Double(scans - 1) * 2)
        #expect(sim.a(.week).running == Double(scans - 1) * step)
        #expect(sim.a(.month).cpu == Double(scans - 1) * 2)
        #expect(sim.a(.today).cpu == expected(from: cal.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970))
        #expect(sim.a(.last24h).cpu == expected(from: (now / 3600).rounded(.down) * 3600 - 23 * 3600))
        #expect(sim.a(.week).peakCopies == 1)
        #expect(sim.a(.week).ramPeak == 100)
        #expect(sim.summary(.week).since == Date(timeIntervalSince1970: day()))

        // Per day: days that have ended from their daily rows, today from its hours, and the
        // points add up to the totals. Per hour: the same for the last 24.
        let week = sim.points(.week)
        #expect(!week.hourly)
        #expect(week.points.map(\.start) == (-2...4).map { day($0) })
        #expect(week.points.map(\.stats.cpu) == (-2...4).map { d in
            Double(hours.filter { Double($0) >= day(d) && Double($0) < day(d + 1) }.count) * 2
        })
        #expect(week.points.reduce(0) { $0 + $1.stats.cpu } == sim.a(.week).cpu)
        #expect(week.points.reduce(0) { $0 + $1.stats.childCpu } == sim.a(.week).childCpu)
        #expect(sim.a(.week).childCpu == Double(scans - 1))
        #expect(sim.points(.quarter).points.count == 90)
        #expect(sim.points(.last24h).points.reduce(0) { $0 + $1.stats.cpu } == sim.a(.last24h).cpu)
        #expect(sim.points(.today).points.reduce(0) { $0 + $1.stats.cpu } == sim.a(.today).cpu)
        #expect(sim.points(.today).points.first?.start == day(4))

        // On disk: one daily row for each day that has ended, and no hours older than 48 h.
        for d in 0..<4 { #expect(try sim.saved(span: 1, bucket: Int64(day(d))) != nil, "day \(d)") }
        #expect(try sim.saved(span: 1, bucket: Int64(day(4))) == nil)
        #expect(try sim.saved(span: 0, bucket: hours[0]) == nil)
        #expect(try sim.saved(span: 0, bucket: hours.last!) != nil)

        // And after a restart.
        sim.restart()
        #expect(sim.a(.week).cpu == Double(scans - 1) * 2)
        #expect(sim.a(.today).cpu == expected(from: cal.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970))
    }

    /// 100 days with 1 CPU second counted each day at noon.
    @Test func rangesCountWholeDaysAndOldDaysAreDropped() throws {
        let sim = Sim(at: day() + 12 * 3600)
        var cpu = 0.0
        for d in 0..<100 {
            sim.setClock(day(d) + 12 * 3600)
            sim.advance(3600)                   // a long gap since yesterday's scans: a new starting point
            sim.scan(cpu: cpu)
            sim.advance(300)
            cpu += 1
            sim.scan(cpu: cpu)
        }
        #expect(sim.a(.today).cpu == 1)
        #expect(sim.a(.last24h).cpu == 1)
        #expect(sim.a(.week).cpu == 7)
        #expect(sim.a(.month).cpu == 30)
        #expect(sim.a(.quarter).cpu == 90)
        #expect(sim.a(.quarter).running == 90 * 300)
        #expect(sim.summary(.quarter).since == Date(timeIntervalSince1970: day(10)))
        // Days older than 90 are gone from the file.
        #expect(try sim.saved(span: 1, bucket: Int64(day(8))) == nil)
        #expect(try sim.saved(span: 1, bucket: Int64(day(9))) != nil)
        #expect(try sim.saved(span: 1, bucket: Int64(day(98))) != nil)
    }

    /// The copy your other Macs read (OtherMacs.swift) gives the same numbers for every range:
    /// days that have ended, the last 24 hours and the hour not saved yet.
    @Test func copyForOtherMacsReadsTheSame() throws {
        let sim = Sim(at: day() + 12 * 3600)
        var cpu = 100.0
        sim.scan(cpu: cpu)
        for i in 1..<(3 * 144 + 5) {
            sim.advance(600)
            cpu += 2
            sim.scan(cpu: cpu, busy: 3, net: i % 7 == 0 ? [Sim.a: .init(received: 1000, sent: 10)] : [:])
        }
        let packed = try #require(sim.tracker.queue.sync { sim.tracker.makeCopy(now: sim.wall + 30) })
        let data = try #require((packed as NSData).decompressed(using: .lzfse) as Data?)
        let store = try #require(ProcessHistoryStore(copy: data))
        #expect(store.live().isEmpty)
        let copy = ProcessTracker(copy: store)
        #expect(copy.copy?.made == sim.wall + 30)
        #expect(copy.copy?.lastScan == sim.wall)
        #expect(copy.copy?.asOf == sim.wall)
        #expect(copy.copy?.helper == .notUsed)
        #expect(copy.copy?.batteryWh.map { ($0 * 1000).rounded() } == Battery.capacityWh.map { ($0 * 1000).rounded() })

        func same(_ x: ProcStats, _ y: ProcStats) -> Bool {
            [\ProcStats.cpu, \.running, \.copyTime, \.ramTime, \.childCpu, \.netIn, \.netOut].allSatisfy { abs(x[keyPath: $0] - y[keyPath: $0]) < 1e-6 }
                && x.peakCopies == y.peakCopies && x.launches == y.launches
        }
        for range in ProcessTracker.Range.allCases {
            let mine = sim.summary(range), theirs = copy.queue.sync { copy.summarize(range, now: sim.wall) }
            #expect(theirs.lastScan == mine.lastScan)
            #expect(theirs.programs.count == mine.programs.count, "\(range)")
            for p in mine.programs {
                let t = try #require(theirs.programs.first { $0.path == p.path }?.stats, "\(p.path) \(range)")
                #expect(same(p.stats, t), "\(p.path) \(range)")
            }
            #expect(same(mine.unseen, theirs.unseen))
            let a = sim.points(range), b = copy.queue.sync { copy.points(Sim.a, range, now: sim.wall) }
            #expect(a.points.map(\.start) == b.points.map(\.start))
            #expect(zip(a.points, b.points).allSatisfy { same($0.stats, $1.stats) }, "\(range)")
        }
        #expect(sim.a(.week).cpu > sim.a(.last24h).cpu) // daily rows count, not only hours

        // Hours that daily rows have and Today and 24 Hours don't need stay out of the copy.
        var hours: [Int64] = []
        store.each(span: 0, from: 0, to: .max) { b, _, _ in hours.append(b) }
        let first = try #require(hours.min())
        #expect(Double(first) >= (sim.wall / 3600).rounded(.down) * 3600 - 23 * 3600)

        // A copy never scans or makes copies of its own.
        copy.start()
        #expect(copy.queue.sync { copy.makeCopy(now: sim.wall) } == nil)
        // Not a copy, or one cut short: nil.
        #expect(ProcessHistoryStore(copy: Data("not a process history file".utf8)) == nil)
        #expect(ProcessHistoryStore(copy: data.prefix(data.count / 2)) == nil)
    }

    /// A copy made before the first scan has no last scan; its ranges end when it was made.
    @Test func copyBeforeAnyScan() throws {
        let sim = Sim(at: hour + 100)
        let packed = try #require(sim.tracker.queue.sync { sim.tracker.makeCopy(now: sim.wall) })
        let data = try #require((packed as NSData).decompressed(using: .lzfse) as Data?)
        let copy = ProcessTracker(copy: try #require(ProcessHistoryStore(copy: data)))
        #expect(copy.copy?.lastScan == nil)
        #expect(copy.copy?.asOf == sim.wall)
        #expect(copy.queue.sync { copy.summarize(.today, now: sim.wall) }.programs.isEmpty)
    }

    @Test func clearStartsOver() {
        let sim = Sim(at: hour + 100)
        sim.scan(cpu: 100)
        sim.advance(300)
        sim.scan(cpu: 110)
        sim.tracker.queue.sync {}               // (clear is asynchronous: let it finish below)
        sim.tracker.clear {}
        #expect(sim.summary(.week).programs.isEmpty)
        sim.advance(300)
        sim.scan(cpu: 120)                      // a starting point again
        #expect(sim.a(.week).cpu == 0)
        sim.advance(300)
        sim.scan(cpu: 121)
        #expect(sim.a(.week).cpu == 1)
    }
}
