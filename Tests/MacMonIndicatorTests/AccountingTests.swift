import Foundation
import SQLite3
import Testing
@testable import MacMonIndicator

/// Key ids as the tracker hands them out: one per path, starting at 1.
private final class Keys {
    private(set) var ids: [String: Int64] = [:]
    func id(_ path: String) -> Int64 {
        if let i = ids[path] { return i }
        ids[path] = Int64(ids.count + 1)
        return ids[path]!
    }
    subscript(_ path: String) -> Int64 { ids[path] ?? -1 }
}

private typealias Seen = ProcessTracker.Seen

private let last = 1_800_000_000.0  // the last scan
private let dt = 300.0              // 5 minutes later
private let now = last + dt

private func seen(_ path: String, start: Double = last - 1000, cpu: Double = 0, pcore: Double = 0, energy: Double = 0,
                  read: Double = 0, written: Double = 0, child: Double = -1, mem: Double = 0, maxMem: Double = 0,
                  detail: Bool = true) -> Seen {
    Seen(start: start, path: path, cpu: cpu, pcore: pcore, energy: energy, diskRead: read, diskWritten: written,
         childCpu: child, mem: mem, maxMem: maxMem, detail: detail)
}

/// Two scans 5 minutes apart: `before` then `after`. Returns the second scan's result.
private func twoScans(_ before: [pid_t: Seen], _ after: [pid_t: Seen], keys: Keys = Keys())
    -> (stats: [Int64: ProcStats], next: [pid_t: TrackedProcess], found: Double, keys: Keys) {
    let first = ProcessTracker.account(before, since: [:], lastWall: 0, nowWall: last, dt: 0, fresh: true, keyID: keys.id)
    let r = ProcessTracker.account(after, since: first.next, lastWall: last, nowWall: now, dt: dt, fresh: false, keyID: keys.id)
    return (r.stats, r.next, r.found, keys)
}

@Suite struct AccountingTests {
    @Test func firstScanOnlySetsTheStartingPoint() {
        let keys = Keys()
        let r = ProcessTracker.account([7: seen("/usr/bin/a", cpu: 500, energy: 90)], since: [:], lastWall: 0, nowWall: last,
                                       dt: 0, fresh: true, keyID: keys.id)
        #expect(r.stats.isEmpty) // CPU used before the first scan can't be placed in time
        #expect(r.found == 0)
        #expect(r.next[7]?.cpu == 500)
        #expect(r.next[7]?.energy == 90)
        #expect(r.next[7]?.exe == keys["/usr/bin/a"])
        #expect(r.next[7]?.app == 0)
    }

    @Test func runningProcessCountsWhatChanged() throws {
        let r = twoScans([7: seen("/usr/bin/a", cpu: 500, pcore: 300, energy: 90, read: 1e6, written: 2e6)],
                         [7: seen("/usr/bin/a", cpu: 512, pcore: 304, energy: 95, read: 4e6, written: 2e6, mem: 100, maxMem: 400)])
        let s = try #require(r.stats[r.keys["/usr/bin/a"]])
        #expect(s.cpu == 12)
        #expect(s.pcore == 4)
        #expect(s.energy == 5)
        #expect(s.diskRead == 3e6)
        #expect(s.diskWritten == 0)
        #expect(s.running == dt)
        #expect(s.copyTime == dt)
        #expect(s.ramTime == 100 * dt)
        #expect(s.ramPeak == 100)
        #expect(s.ramOnePeak == 400) // the highest footprint macOS recorded, not just what the scan saw
        #expect(s.peakCopies == 1)
        #expect(s.launches == 0)
        #expect(s.exits == 0)
        #expect(r.found == 12)
        #expect(r.next[7]?.cpu == 512) // the next scan measures from here
    }

    @Test func countersNeverGoNegative() throws {
        let r = twoScans([7: seen("/usr/bin/a", cpu: 500, energy: 90, read: 9e6)],
                         [7: seen("/usr/bin/a", cpu: 499, energy: 80, read: 1e6)])
        let s = try #require(r.stats[r.keys["/usr/bin/a"]])
        #expect(s.cpu == 0)
        #expect(s.energy == 0)
        #expect(s.diskRead == 0)
    }

    @Test func newProcessCountsEverythingSinceItStarted() throws {
        let r = twoScans([:], [9: seen("/usr/bin/new", start: now - 60, cpu: 8, energy: 3, read: 5e6, mem: 50)])
        let s = try #require(r.stats[r.keys["/usr/bin/new"]])
        #expect(s.launches == 1)
        #expect(s.cpu == 8)
        #expect(s.energy == 3)
        #expect(s.diskRead == 5e6)
        #expect(s.running == 60) // since it started, not the whole interval
        #expect(s.ramTime == 50 * 60)
        #expect(r.found == 8)
    }

    @Test func processFromBeforeThatTheLastScanMissed() throws {
        // Running since long before the last scan, but not in it (it couldn't be read then):
        // its CPU so far can't be placed in this interval.
        let r = twoScans([:], [9: seen("/usr/bin/old", start: last - 5000, cpu: 800)])
        let s = try #require(r.stats[r.keys["/usr/bin/old"]])
        #expect(s.launches == 0)
        #expect(s.cpu == 0)
        #expect(s.running == dt)
        #expect(r.found == 0)
    }

    @Test func endedProcessCountsAsAnExit() throws {
        let r = twoScans([7: seen("/usr/bin/a", start: last - 1000, cpu: 500)], [:])
        let s = try #require(r.stats[r.keys["/usr/bin/a"]])
        #expect(s.exits == 1)
        #expect(s.running == dt / 2)            // it ended somewhere in between
        #expect(s.lifetime == 1000 + dt / 2)
        #expect(s.cpu == 0)                     // what it used after the last scan is "unseen"
        #expect(s.peakCopies == 0)
        #expect(r.next.isEmpty)
    }

    @Test func reusedPidIsAnExitAndALaunch() throws {
        let r = twoScans([7: seen("/usr/bin/a", start: last - 1000, cpu: 500)],
                         [7: seen("/usr/bin/b", start: now - 30, cpu: 2)])
        let a = try #require(r.stats[r.keys["/usr/bin/a"]])
        let b = try #require(r.stats[r.keys["/usr/bin/b"]])
        #expect(a.exits == 1)
        #expect(a.cpu == 0)
        #expect(b.launches == 1)
        #expect(b.cpu == 2) // not 2 − 500 clamped to 0, and not −498
        #expect(b.running == 30)
    }

    @Test func startTimeMayDifferByASecond() throws {
        // /bin/ps gives running time to the second, so the start it implies moves a little.
        let r = twoScans([7: seen("/usr/sbin/sys", start: last - 1000, cpu: 500, detail: false)],
                         [7: seen("/usr/sbin/sys", start: last - 999, cpu: 510, detail: false)])
        let s = try #require(r.stats[r.keys["/usr/sbin/sys"]])
        #expect(s.cpu == 10)
        #expect(s.launches == 0)
        #expect(s.exits == 0)
    }

    @Test func systemProcessWithoutRootHasOnlyCPUAndMemory() throws {
        let r = twoScans([7: seen("/usr/sbin/sys", cpu: 500, detail: false)],
                         [7: seen("/usr/sbin/sys", cpu: 510, energy: 77, read: 1e6, mem: 10, detail: false)])
        let s = try #require(r.stats[r.keys["/usr/sbin/sys"]])
        #expect(s.cpu == 10)
        #expect(s.energy == 0)
        #expect(s.diskRead == 0)
        #expect(!s.detail)
    }

    @Test func rootModeTurnedOnBetweenScans() throws {
        // The earlier scan had no energy or disk numbers to measure from.
        let r = twoScans([7: seen("/usr/sbin/sys", cpu: 500, detail: false)],
                         [7: seen("/usr/sbin/sys", cpu: 510, energy: 9000, read: 8e9, detail: true)])
        let s = try #require(r.stats[r.keys["/usr/sbin/sys"]])
        #expect(s.cpu == 10)
        #expect(s.energy == 0)
        #expect(s.diskRead == 0)
    }

    @Test func childrenCountWhatTheyUsedSinceTheLastScan() throws {
        // A shell whose children (collected when they ended) had used 40 s, then 55 s.
        let r = twoScans([7: seen("/bin/zsh", cpu: 3, child: 40)], [7: seen("/bin/zsh", cpu: 3.5, child: 55)])
        let s = try #require(r.stats[r.keys["/bin/zsh"]])
        #expect(s.childCpu == 15)
        #expect(s.cpu == 0.5)
        #expect(r.found == 0.5)                 // children's CPU is not the shell's own
        #expect(r.next[7]?.childCpu == 55)
    }

    @Test func newProcessCountsAllItsChildren() throws {
        let r = twoScans([:], [9: seen("/usr/bin/make", start: now - 60, cpu: 1, child: 20)])
        #expect(try #require(r.stats[r.keys["/usr/bin/make"]]).childCpu == 20)
    }

    @Test func childrenNotKnownBeforeAreNotCounted() throws {
        // The earlier scan had no number to measure from (an older helper, or /bin/ps): all the
        // children since the process started would land in this one interval.
        let r = twoScans([7: seen("/usr/sbin/sys", cpu: 500)], [7: seen("/usr/sbin/sys", cpu: 510, child: 9000)])
        let s = try #require(r.stats[r.keys["/usr/sbin/sys"]])
        #expect(s.childCpu == 0)
        #expect(r.next[7]?.childCpu == 9000)    // the next scan measures from here
        // And not known now: nothing, and nothing to measure the next scan from.
        let gone = twoScans([7: seen("/usr/sbin/sys", cpu: 500, child: 40)], [7: seen("/usr/sbin/sys", cpu: 510)])
        #expect(gone.stats[gone.keys["/usr/sbin/sys"]]?.childCpu == 0)
        #expect(gone.next[7]?.childCpu == -1)
    }

    @Test func childrenAddUpUnderTheApp() throws {
        let main = "/Applications/Foo.app/Contents/MacOS/Foo"
        let helper = "/Applications/Foo.app/Contents/MacOS/foo-helper"
        let r = twoScans([1: seen(main, child: 10), 2: seen(helper, child: 0)], [1: seen(main, child: 12), 2: seen(helper, child: 5)])
        #expect(r.stats[r.keys["/Applications/Foo.app"]]?.childCpu == 7)
        #expect(r.stats[r.keys[helper]]?.childCpu == 5)
    }

    @Test func helpersAddUpUnderTheirApp() throws {
        let main = "/Applications/Foo.app/Contents/MacOS/Foo"
        let helper = "/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper"
        let r = twoScans([1: seen(main, cpu: 100), 2: seen(helper, cpu: 10), 3: seen(helper, cpu: 20)],
                         [1: seen(main, cpu: 105, mem: 300, maxMem: 300),
                          2: seen(helper, cpu: 11, mem: 100, maxMem: 150),
                          3: seen(helper, cpu: 22, mem: 200, maxMem: 200),
                          4: seen(helper, start: now - 100, cpu: 4, mem: 50, maxMem: 50)])
        let h = try #require(r.stats[r.keys[helper]])
        #expect(h.cpu == 1 + 2 + 4)
        #expect(h.peakCopies == 3)
        #expect(h.running == dt)                // as long as its longest copy
        #expect(h.copyTime == dt + dt + 100)    // ÷ running = copies at once, on average
        #expect(h.ramPeak == 350)               // all copies together
        #expect(h.ramOnePeak == 200)            // the biggest single copy
        #expect(h.launches == 1)

        let app = try #require(r.stats[r.keys["/Applications/Foo.app"]])
        #expect(app.cpu == 5 + 7)
        #expect(app.peakCopies == 4)
        #expect(app.running == dt)
        #expect(app.ramPeak == 650)
        #expect(app.ramOnePeak == 300)
        #expect(r.found == 12)                  // each process once, not once more for its app
        #expect(r.next[2]?.app == r.keys["/Applications/Foo.app"])
        #expect(r.stats.count == 3)             // two executables and the app
    }

    @Test func manyScansAddUpToTheCounter() {
        // However the 5-minute scans cut it, a process's deltas add up to what its counter gained.
        let keys = Keys()
        var live: [pid_t: TrackedProcess] = [:]
        var total = ProcStats()
        var t = last
        let counters = [100.0, 100.5, 130, 130, 131.25, 500]
        for (i, cpu) in counters.enumerated() {
            let r = ProcessTracker.account([7: seen("/usr/bin/a", cpu: cpu)], since: live, lastWall: t - dt, nowWall: t,
                                           dt: i == 0 ? 0 : dt, fresh: i == 0, keyID: keys.id)
            for (_, s) in r.stats { total.add(s) }
            live = r.next
            t += dt
        }
        #expect(total.cpu == 400)
        #expect(total.running == dt * 5)
        #expect(total.peakCopies == 1)
    }
}

@Suite struct ProcStatsTests {
    @Test func laterTimeAddsTotalsAndKeepsPeaks() {
        var a = ProcStats(running: 10, copyTime: 20, peakCopies: 2, launches: 1, exits: 1, lifetime: 5, cpu: 3, pcore: 1,
                          energy: 4, ramTime: 100, ramPeak: 50, ramOnePeak: 30, diskRead: 7, diskWritten: 8, detail: false,
                          childCpu: 6)
        a.add(ProcStats(running: 5, copyTime: 5, peakCopies: 1, launches: 2, exits: 0, lifetime: 1, cpu: 1, pcore: 1,
                        energy: 1, ramTime: 10, ramPeak: 80, ramOnePeak: 20, diskRead: 1, diskWritten: 1, detail: true,
                        childCpu: 1.5))
        #expect(a.childCpu == 7.5)
        #expect(a.running == 15)
        #expect(a.copyTime == 25)
        #expect(a.peakCopies == 2)
        #expect(a.launches == 3)
        #expect(a.exits == 1)
        #expect(a.lifetime == 6)
        #expect(a.cpu == 4)
        #expect(a.pcore == 2)
        #expect(a.energy == 5)
        #expect(a.ramTime == 110)
        #expect(a.ramPeak == 80)
        #expect(a.ramOnePeak == 30)
        #expect(a.diskRead == 8)
        #expect(a.diskWritten == 9)
        #expect(a.detail)
    }

    @Test func anotherCopyRunsAtTheSameTime() {
        var a = ProcStats(running: 10, copyTime: 10, peakCopies: 1, cpu: 3, ramPeak: 50, ramOnePeak: 50)
        a.addCopy(ProcStats(running: 4, copyTime: 4, peakCopies: 1, cpu: 1, ramPeak: 80, ramOnePeak: 80))
        #expect(a.running == 10)    // not 14: they overlap
        #expect(a.copyTime == 14)
        #expect(a.peakCopies == 2)
        #expect(a.cpu == 4)
        #expect(a.ramPeak == 130)
        #expect(a.ramOnePeak == 80)
    }
}

@Suite struct ProcKeyTests {
    @Test func homebrewUpgradesKeepOneProgram() {
        #expect(ProcKey.normalize("/opt/homebrew/Cellar/node/22.1.0/bin/node") == "/opt/homebrew/Cellar/node/*/bin/node")
        #expect(ProcKey.normalize("/opt/homebrew/Cellar/node/23.0.0_1/bin/node") == "/opt/homebrew/Cellar/node/*/bin/node")
        #expect(ProcKey.normalize("/usr/bin/python3") == "/usr/bin/python3")
    }

    @Test func translocatedAppKeepsOneProgram() {
        let p = "/private/var/folders/ab/T/AppTranslocation/1B2C-3D/d/Foo.app/Contents/MacOS/Foo"
        #expect(ProcKey.normalize(p) == "/private/var/folders/ab/T/AppTranslocation/*/d/Foo.app/Contents/MacOS/Foo")
    }

    @Test func appIsTheOutermostBundle() {
        #expect(ProcKey.app(of: "/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper")
            == "/Applications/Foo.app")
        #expect(ProcKey.app(of: "/usr/bin/python3") == nil)
        #expect(ProcKey.app(of: "/Applications/Foo.app") == nil) // a path to the bundle itself is not inside it
    }

    @Test func names() {
        #expect(ProcKey.name("/Applications/Google Chrome.app") == "Google Chrome")
        #expect(ProcKey.name("/usr/bin/python3") == "python3")
        #expect(ProcKey.isApp("/Applications/Foo.app"))
        #expect(!ProcKey.isApp("/Applications/Foo.app/Contents/MacOS/Foo"))
    }

    @Test func psTimes() {
        #expect(ProcessMonitor.parseCPUTime("0:01.50") == 1_500_000_000)
        #expect(ProcessMonitor.parseCPUTime("12:05.00") == 725_000_000_000)
        #expect(ProcessMonitor.parseCPUTime("01:02:03") == 3_723_000_000_000)
        #expect(ProcessMonitor.parseCPUTime("2-01:00:00") == UInt64((2 * 86400 + 3600) * 1e9))
    }
}

@Suite struct ProcessHistoryStoreTests {
    let dir = TempDir()
    private var url: URL { dir.url.appendingPathComponent("process-history.sqlite") }
    private let hour: Int64 = 1_800_000_000 / 3600 * 3600

    private func stats(cpu: Double, peak: Double = 0) -> ProcStats {
        ProcStats(running: 60, copyTime: 90, peakCopies: 2, launches: 3, exits: 1, lifetime: 12.5, cpu: cpu, pcore: 0.5,
                  energy: 2.25, ramTime: 1e9, ramPeak: peak, ramOnePeak: peak / 2, diskRead: 1e6, diskWritten: 2e6, detail: true,
                  childCpu: cpu / 4, netIn: 3e6, netOut: 4e5)
    }

    @Test func keysGetOneIdPerPath() throws {
        let store = try #require(ProcessHistoryStore(url: url))
        let a = try #require(store.addKey("/usr/bin/a"))
        let b = try #require(store.addKey("/usr/bin/b"))
        #expect(a != b)
        #expect(store.addKey("/usr/bin/a") == a)
        #expect(store.keys() == [a: "/usr/bin/a", b: "/usr/bin/b"])
    }

    @Test func everyColumnComesBack() throws {
        let store = try #require(ProcessHistoryStore(url: url))
        let s = stats(cpu: 7.5, peak: 4e8)
        store.write(span: 0, bucket: hour, [1: s])
        let back = try #require(store.stats(span: 0, bucket: hour)[1])
        #expect(back.running == s.running)
        #expect(back.copyTime == s.copyTime)
        #expect(back.peakCopies == s.peakCopies)
        #expect(back.launches == s.launches)
        #expect(back.exits == s.exits)
        #expect(back.lifetime == s.lifetime)
        #expect(back.cpu == s.cpu)
        #expect(back.pcore == s.pcore)
        #expect(back.energy == s.energy)
        #expect(back.ramTime == s.ramTime)
        #expect(back.ramPeak == s.ramPeak)
        #expect(back.ramOnePeak == s.ramOnePeak)
        #expect(back.diskRead == s.diskRead)
        #expect(back.diskWritten == s.diskWritten)
        #expect(back.detail == s.detail)
        #expect(back.childCpu == s.childCpu)
        #expect(back.netIn == 3e6)
        #expect(back.netOut == 4e5)
    }

    @Test func seriesIsOneKeysRowsOldestFirst() throws {
        let store = try #require(ProcessHistoryStore(url: url))
        store.write(span: 0, bucket: hour + 7200, [1: stats(cpu: 9)])
        store.write(span: 0, bucket: hour, [1: stats(cpu: 5), 2: stats(cpu: 1)])
        store.write(span: 0, bucket: hour + 3600, [2: stats(cpu: 2)])
        store.write(span: 1, bucket: hour, [1: stats(cpu: 1000)]) // a daily row: another span
        let all = store.series(span: 0, key: 1, from: 0, to: .max)
        #expect(all.map(\.bucket) == [hour, hour + 7200])
        #expect(all.map(\.stats.cpu) == [5, 9])
        #expect(all.map(\.stats.childCpu) == [1.25, 2.25])
        // `to` is not included.
        #expect(store.series(span: 0, key: 1, from: hour, to: hour + 7200).map(\.stats.cpu) == [5])
        #expect(store.series(span: 1, key: 1, from: 0, to: .max).map(\.stats.cpu) == [1000])
        #expect(store.series(span: 0, key: 3, from: 0, to: .max).isEmpty)
    }

    /// A file written before children's CPU time was kept: it opens, its rows read back with no
    /// children's CPU, its saved counters say "not known", and new rows keep theirs.
    @Test func fileFromBeforeChildCpuStillWorks() throws {
        var db: OpaquePointer?
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let old = """
            create table meta (k text primary key, v integer) without rowid;
            create table keys (id integer primary key, path text not null unique);
            create table stats (span integer not null, bucket integer not null, key integer not null,
                running real, copy_time real, peak_copies integer, launches integer, exits integer, lifetime real,
                cpu real, pcore real, energy real, ram_time real, ram_peak real, ram_one_peak real,
                disk_read real, disk_written real, detail integer, primary key (span, bucket, key)) without rowid;
            create table live (pid integer primary key, start real, exe integer, app integer, cpu real,
                pcore real, energy real, disk_read real, disk_written real, detail integer);
            insert into stats values (0, \(hour), 1, 60, 60, 1, 0, 0, 0, 7.5, 1, 2, 100, 50, 50, 10, 20, 1);
            insert into live values (77, 1799999000, 3, 4, 12.5, 2, 9, 1000, 2000, 1);
            """
        #expect(sqlite3_exec(db, old, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        for _ in 0..<2 { // opening it a second time changes nothing more
            let store = try #require(ProcessHistoryStore(url: url))
            let row = try #require(store.stats(span: 0, bucket: hour)[1])
            #expect(row.cpu == 7.5)
            #expect(row.diskWritten == 20)
            #expect(row.detail)
            #expect(row.childCpu == 0)
            #expect(row.netIn == 0 && row.netOut == 0) // from before network was counted
            #expect(store.sum(span: 0, from: 0, to: .max)[1]?.childCpu == 0)
            #expect(store.live()[77]?.childCpu == -1)
            #expect(store.live()[77]?.cpu == 12.5)
        }
        let store = try #require(ProcessHistoryStore(url: url))
        store.write(span: 0, bucket: hour + 3600, [1: stats(cpu: 8)])
        #expect(store.sum(span: 0, from: 0, to: .max)[1]?.childCpu == 2)
        store.rollUp(day: hour, next: hour + 86400)
        #expect(store.stats(span: 1, bucket: hour)[1]?.childCpu == 2)
        #expect(store.stats(span: 1, bucket: hour)[1]?.netIn == 3e6)
        #expect(store.sum(span: 0, from: 0, to: .max)[1]?.netOut == 4e5)
    }

    @Test func writingAnHourAgainReplacesIt() throws {
        // The current hour is saved several times (sleep, quit): it must not count twice.
        let store = try #require(ProcessHistoryStore(url: url))
        store.write(span: 0, bucket: hour, [1: stats(cpu: 5)])
        store.write(span: 0, bucket: hour, [1: stats(cpu: 8)])
        #expect(store.stats(span: 0, bucket: hour)[1]?.cpu == 8)
        #expect(store.sum(span: 0, from: hour, to: hour + 3600)[1]?.cpu == 8)
    }

    @Test func sumAddsTotalsAndKeepsPeaks() throws {
        let store = try #require(ProcessHistoryStore(url: url))
        store.write(span: 0, bucket: hour, [1: stats(cpu: 5, peak: 100), 2: stats(cpu: 1)])
        store.write(span: 0, bucket: hour + 3600, [1: stats(cpu: 7, peak: 300)])
        store.write(span: 0, bucket: hour + 7200, [1: stats(cpu: 100, peak: 900)])
        store.write(span: 1, bucket: hour, [1: stats(cpu: 1000)]) // a daily row: another span

        let all = store.sum(span: 0, from: hour, to: .max)
        #expect(all[1]?.cpu == 112)
        #expect(all[2]?.cpu == 1)
        // `to` is not included.
        let two = try #require(store.sum(span: 0, from: hour, to: hour + 7200)[1])
        #expect(two.cpu == 12)
        #expect(two.running == 120)
        #expect(two.launches == 6)
        #expect(two.ramPeak == 300)
        #expect(two.peakCopies == 2)
        // The hour still in memory is left out, so it isn't counted twice.
        #expect(store.sum(span: 0, from: hour, to: .max, excluding: hour + 7200)[1]?.cpu == 12)
        #expect(store.sum(span: 0, from: hour, to: hour).isEmpty)
    }

    @Test func dayRollUpThenPrune() throws {
        let store = try #require(ProcessHistoryStore(url: url))
        let day = hour - 10 * 3600, next = day + 86400
        store.write(span: 0, bucket: day, [1: stats(cpu: 5, peak: 100)])
        store.write(span: 0, bucket: day + 23 * 3600, [1: stats(cpu: 7, peak: 300), 2: stats(cpu: 2)])
        store.write(span: 0, bucket: next, [1: stats(cpu: 40)]) // the next day's first hour
        store.rollUp(day: day, next: next)

        let daily = store.stats(span: 1, bucket: day)
        #expect(daily[1]?.cpu == 12)
        #expect(daily[1]?.ramPeak == 300)
        #expect(daily[2]?.cpu == 2)
        // Rolling the same day up again (after a crash before the marker was saved) changes nothing.
        store.rollUp(day: day, next: next)
        #expect(store.stats(span: 1, bucket: day)[1]?.cpu == 12)
        #expect(store.firstBucket() == day)

        // Hours of the rolled-up day go; the next day's hours and the daily row stay.
        store.prune(hourlyBefore: next, dailyBefore: day)
        #expect(store.sum(span: 0, from: 0, to: .max)[1]?.cpu == 40)
        #expect(store.stats(span: 1, bucket: day)[1]?.cpu == 12)
        // 90 days later the daily row goes too.
        store.prune(hourlyBefore: next, dailyBefore: day + 1)
        #expect(store.stats(span: 1, bucket: day).isEmpty)
    }

    @Test func countersSurviveARestart() throws {
        let p = TrackedProcess(start: 1_799_999_000.25, exe: 3, app: 4, cpu: 12.5, pcore: 2, energy: 9, diskRead: 1e6,
                               diskWritten: 2e6, detail: true, childCpu: 4.5)
        do {
            let store = try #require(ProcessHistoryStore(url: url))
            store.transaction {
                store.setLive([77: p, 78: p])
                store.setLive([77: p]) // 78 ended: replaced, not added to
                store.setMeta("hour", hour)
                store.setMeta("hour", hour + 3600)
            }
        }
        let store = try #require(ProcessHistoryStore(url: url))
        #expect(store.meta("hour") == hour + 3600)
        #expect(store.meta("nothing") == nil)
        let live = store.live()
        #expect(live.count == 1)
        let back = try #require(live[77])
        #expect(back.start == p.start)
        #expect(back.exe == 3)
        #expect(back.app == 4)
        #expect(back.cpu == 12.5)
        #expect(back.pcore == 2)
        #expect(back.energy == 9)
        #expect(back.diskRead == 1e6)
        #expect(back.diskWritten == 2e6)
        #expect(back.detail)
        #expect(back.childCpu == 4.5)
    }

    @Test func clearRemovesEverything() throws {
        let store = try #require(ProcessHistoryStore(url: url))
        _ = store.addKey("/usr/bin/a")
        store.write(span: 0, bucket: hour, [1: stats(cpu: 5)])
        store.setMeta("hour", hour)
        store.clear()
        #expect(store.keys().isEmpty)
        #expect(store.firstBucket() == nil)
        #expect(store.meta("hour") == nil)
        #expect(store.live().isEmpty)
    }
}
