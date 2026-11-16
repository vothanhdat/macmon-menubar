import Foundation
import Testing
@testable import MacMonIndicator

/// What is made of the process history: energy used on battery, programs using far more CPU than
/// usual, and the export. Made-up scans at made-up times, as in ProcessTrackerTests.
private final class Sim {
    let dir = TempDir()
    let tracker: ProcessTracker
    var wall: Double
    private var up: UInt64 = 5_000_000_000_000

    init(at wall: Double) {
        self.wall = wall
        tracker = ProcessTracker(directory: dir.url)
    }

    func advance(_ seconds: Double) {
        wall += seconds
        up += UInt64(seconds * 1e9)
    }

    /// One scan now: each path (pid in the order given, started long ago) with its CPU seconds and
    /// joules so far.
    func scan(_ procs: [(path: String, cpu: Double, energy: Double)], onBattery: Bool = false) {
        var seen: [pid_t: ProcessTracker.Seen] = [:]
        for (i, p) in procs.enumerated() {
            seen[pid_t(i + 1)] = .init(start: 1_000_000, path: p.path, cpu: p.cpu, energy: p.energy, mem: 100, maxMem: 100, detail: true)
        }
        tracker.queue.sync { tracker.record(seen, nowWall: wall, nowUp: up, ticks: [0, 0, 0], onBattery: onBattery) }
    }

    func summary(_ range: ProcessTracker.Range = .today) -> ProcessTracker.Summary {
        tracker.queue.sync { tracker.summarize(range, now: wall) }
    }

    func stats(_ path: String, _ range: ProcessTracker.Range = .today) -> ProcStats {
        summary(range).programs.first { $0.path == path }?.stats ?? ProcStats()
    }
}

private let cal = Calendar.current
private func day(_ days: Int = 0) -> Double {
    let first = cal.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    return cal.date(byAdding: .day, value: days, to: first)!.timeIntervalSince1970
}

private let tool = "/usr/bin/tool"
private let app = "/Applications/Foo.app", appMain = "/Applications/Foo.app/Contents/MacOS/Foo"

@Suite struct ProcessInsightsTests {
    @Test func energyOnBatteryCountsByThePowerSourceAtBothScans() {
        let sim = Sim(at: day() + 10 * 3600 + 60)
        sim.scan([(tool, 0, 0)], onBattery: true)       // the first scan only sets the starting point
        sim.advance(300)
        sim.scan([(tool, 1, 100)], onBattery: true)     // on battery at both: all 100 J
        sim.advance(300)
        sim.scan([(tool, 2, 160)], onBattery: false)    // plugged in between: half of 60 J
        sim.advance(300)
        sim.scan([(tool, 3, 200)], onBattery: false)    // on the adapter: none of 40 J
        let s = sim.stats(tool)
        #expect(s.energy == 200)
        #expect(s.batteryEnergy == 130)
        // The column: a share of a full charge, known only with the energy.
        let row = ProcessHistoryWindowController.Row(name: "tool", path: tool, s: s)
        if let wh = Battery.capacityWh { #expect(abs(row.battery - 130.0 / 3600 / wh) < 1e-12) }
        #expect(ProcessHistoryWindowController.Row(name: "ps", path: "/bin/ps", s: ProcStats(cpu: 5)).battery < 0)
        #expect(ProcessHistoryWindowController.columns.contains { $0.id == "battery" } == (Battery.capacityWh != nil))
    }

    @Test func batteryCapacityIsWorkedOutFromTheCells() throws {
        // Three cells in series, whatever their charge: 11.4 V nominal.
        for mV in [10_000.0, 11_400, 12_309, 13_200] {
            #expect(abs(try #require(Battery.wattHours(mAh: 7883, mV: mV)) - 89.87) < 0.01)
        }
        #expect(Battery.wattHours(mAh: 0, mV: 12_000) == nil)
        #expect(Battery.wattHours(mAh: 5000, mV: 0) == nil)
    }

    @Test func farMoreThanUsualNeedsEnoughDaysAndEnoughCPU() {
        typealias T = ProcessTracker
        #expect(T.isUnusual(today: 900, sum: 500, days: 5, most: 150))
        #expect(!T.isUnusual(today: 590, sum: 50, days: 5, most: 15))       // under 10 minutes
        #expect(!T.isUnusual(today: 900, sum: 300, days: 2, most: 150))     // nothing is usual yet
        #expect(!T.isUnusual(today: 900, sum: 2000, days: 5, most: 450))    // under 3 times the average
        #expect(!T.isUnusual(today: 900, sum: 800, days: 5, most: 700))     // it has had days like this
    }

    /// Five days of about 100 s of CPU each for the tool and the app, then a day when the app
    /// uses much more.
    @Test func unusualTodayComparesWithTheDaysBefore() {
        let sim = Sim(at: day() + 10 * 3600 + 60)
        var cpu = 0.0
        for d in 0..<5 {
            sim.wall = day(d) + 10 * 3600 + 60
            sim.advance(0)
            sim.scan([(tool, cpu, 0), (appMain, cpu, 0)])   // after a night's gap: the starting point
            sim.advance(300)
            cpu += 100
            sim.scan([(tool, cpu, 0), (appMain, cpu, 0)])
        }
        sim.wall = day(5) + 10 * 3600 + 60
        sim.scan([(tool, cpu, 0), (appMain, cpu, 0)])
        sim.advance(300)
        sim.scan([(tool, cpu + 120, 0), (appMain, cpu + 500, 0)])
        #expect(sim.summary().unusual.isEmpty)                  // 500 s: not 10 minutes yet
        sim.advance(300)
        sim.scan([(tool, cpu + 240, 0), (appMain, cpu + 1000, 0)])
        // The app, not its executable as well; the tool is within what it does.
        #expect(sim.summary().unusual == [ProcessTracker.Unusual(path: app, today: 1000, usual: 100)])
        #expect(sim.summary(.week).unusual.count == 1)
        #expect(ProcessHistoryWindowController.footer(sim.summary(), range: .today, empty: false)
            .contains("Unusual today: Foo 16m 40s of CPU time (usually 1m 40s a day)."))
        let text = UsageAlerts.text(sim.summary().unusual[0])
        #expect(text.title == "Foo is using more CPU than usual")
        #expect(text.body == "16m 40s of CPU time today. It usually uses about 1m 40s a day.")
    }

    @Test func eachProgramIsToldAboutOnceADay() throws {
        let name = "mmi-tests-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        let a = ProcessTracker.Unusual(path: app, today: 1000, usual: 100)
        let b = ProcessTracker.Unusual(path: tool, today: 2000, usual: 100)
        #expect(UsageAlerts.fresh([a], day: 10, defaults: d) == [a])
        #expect(UsageAlerts.fresh([a], day: 10, defaults: d).isEmpty)
        #expect(UsageAlerts.fresh([a, b], day: 10, defaults: d) == [b])
        #expect(UsageAlerts.fresh([a, b], day: 10, defaults: d).isEmpty)
        #expect(UsageAlerts.fresh([a], day: 11, defaults: d) == [a])   // the next day, again
    }

    @Test func exportIsARowPerProgramPerHourOrDay() throws {
        let sim = Sim(at: day() + 10 * 3600 + 60)
        sim.scan([(tool, 0, 0), (appMain, 0, 0)])
        sim.advance(300)
        sim.scan([(tool, 3, 50), (appMain, 7, 90)], onBattery: true)
        sim.wall = day(1) + 10 * 3600 + 60
        sim.scan([(tool, 3, 50), (appMain, 7, 90)])
        sim.advance(300)
        sim.scan([(tool, 4, 60), (appMain, 9, 99)])

        let hours = sim.tracker.queue.sync { sim.tracker.rows(.today, now: sim.wall) }
        #expect(hours.hourly)
        #expect(hours.rows.map(\.path) == [app, appMain, tool])
        #expect(hours.rows.map(\.stats.cpu) == [2, 2, 1])
        #expect(hours.rows.allSatisfy { $0.start == day(1) + 10 * 3600 })

        let days = sim.tracker.queue.sync { sim.tracker.rows(.week, now: sim.wall) }
        #expect(!days.hourly)
        #expect(days.rows.map(\.start) == [day(), day(), day(), day(1), day(1), day(1)])
        #expect(days.rows.map(\.stats.cpu) == [7, 7, 3, 2, 2, 1])
        // The rows add up to the table's.
        #expect(days.rows.filter { $0.path == tool }.reduce(0) { $0 + $1.stats.cpu } == sim.stats(tool, .week).cpu)

        let e = TerminalServer.export(days)
        #expect(e.columns == TerminalServer.exportColumns)
        #expect(e.rows.allSatisfy { $0.count == e.columns.count })
        let rows = try #require(try JSONSerialization.jsonObject(with: TerminalServer.encode(e)) as? [String: Any])["rows"] as? [[Any]]
        let first = try #require(rows?.first)
        func value(_ column: String) -> Any { first[e.columns.firstIndex(of: column)!] }
        #expect(value("span") as? String == "day")
        #expect(value("kind") as? String == "app")
        #expect(value("name") as? String == "Foo")
        #expect(value("path") as? String == app)
        #expect(value("cpu_s") as? Double == 7)
        #expect(value("energy_j") as? Double == 90)
        #expect(value("battery_energy_j") as? Double == 45)     // on battery at one of the two scans
        #expect(ISO8601DateFormatter().date(from: try #require(value("start") as? String))?.timeIntervalSince1970 == day())
        // Without the detail (system processes without root): not known, not zero.
        let sys = TerminalServer.export(.init(hourly: true, rows: [(day(), "/bin/ps", ProcStats(running: 60, cpu: 5))]))
        let data = try #require(try JSONSerialization.jsonObject(with: TerminalServer.encode(sys)) as? [String: Any])
        let cells = try #require((data["rows"] as? [[Any]])?.first)
        #expect(cells[e.columns.firstIndex(of: "energy_j")!] is NSNull)
        #expect(cells[e.columns.firstIndex(of: "span")!] as? String == "hour")
        // Off: says so.
        #expect(!TerminalServer.export(nil).tracking)
    }
}
