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
    func scan(_ procs: [pid_t: ProcessTracker.Seen], busy: Double = 0) {
        ticks += UInt32(busy * Double(sysconf(Int32(_SC_CLK_TCK))))
        tracker.queue.sync { tracker.record(procs, nowWall: wall, nowUp: up, ticks: [ticks, 0, 0]) }
    }

    /// `/usr/bin/a` (pid 7, started long ago) with `cpu` CPU seconds so far.
    func scan(cpu: Double, busy: Double = 0) {
        scan([7: ProcessTracker.Seen(start: 1_000_000, path: Self.a, cpu: cpu, mem: 100, maxMem: 100, detail: true)], busy: busy)
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
