import Foundation
import Testing
@testable import MacMonIndicator

private typealias Window = ProcessHistoryWindowController

@Suite struct RootHelperTests {
    @Test func version4HasChildrenCPU() throws {
        let r = try #require(RootHelper.parse("v4\n12\t5000\t1000\t4096\t10\t20\t1800000000000000\t77\t3000\t8192\t250000\tzsh\t/bin/zsh\n"))
        #expect(r.version == 4)
        let p = try #require(r.processes[12])
        #expect(p.name == "zsh")
        #expect(p.path == "/bin/zsh")
        #expect(p.cpuNs == 5000)
        #expect(p.kernelNs == 1000)
        #expect(p.energyNj == 77)
        #expect(p.pcoreNs == 3000)
        #expect(p.maxMem == 8192)
        #expect(p.childNs == 250000)
    }

    @Test func olderVersionsStillRead() throws {
        // Version 3 (installed before this version): everything but the children's CPU time. A
        // name with spaces, and no path.
        let v3 = try #require(RootHelper.parse("v3\n12\t5000\t1000\t4096\t10\t20\t1800000000000000\t77\t3000\t8192\tFoo Helper\t\n"))
        #expect(v3.version == 3)
        let p = try #require(v3.processes[12])
        #expect(p.name == "Foo Helper")
        #expect(p.path == nil)
        #expect(p.energyNj == 77)
        #expect(p.maxMem == 8192)
        #expect(p.childNs == nil)
        let v2 = try #require(RootHelper.parse("v2\n12\t5000\t1000\t4096\t10\t20\tzsh\n"))
        #expect(v2.processes[12]?.name == "zsh")
        #expect(v2.processes[12]?.kernelNs == 1000)
        #expect(v2.processes[12]?.diskWritten == 20)
        let v1 = try #require(RootHelper.parse("v1\n12\t5000\t4096\t10\t20\tzsh\n"))
        #expect(v1.processes[12]?.name == "zsh")
        #expect(v1.processes[12]?.kernelNs == nil)
        #expect(v1.processes[12]?.mem == 4096)
        #expect(RootHelper.parse("something else\n") == nil)
    }
}

@Suite struct ProcessChartTests {
    private func series(_ stats: [ProcStats], hourly: Bool = true) -> ProcessTracker.Series {
        ProcessTracker.Series(hourly: hourly, points: stats.enumerated().map { (Double($0.offset) * 3600, $0.element) })
    }

    @Test func cpuHasALineForChildrenOnlyWhenThereAreAny() throws {
        let quiet = series([ProcStats(running: 300, cpu: 12, detail: true), ProcStats()])
        let m = try #require(Window.chartModel(quiet, .cpu))
        #expect(m.bars == [12, nil])            // no column where it wasn't running
        #expect(m.line == nil)
        #expect(m.starts == [0, 3600])

        let busy = series([ProcStats(running: 300, cpu: 12, detail: true, childCpu: 40), ProcStats(running: 300, cpu: 1, detail: true)])
        let b = try #require(Window.chartModel(busy, .cpu))
        #expect(b.line == [40, 0])
        #expect(b.lineName != nil)
        #expect(b.extra(0).count == 1)
    }

    @Test func whatIsNotKnownIsNotDrawn() throws {
        // A system process without the root helper: CPU time and memory only.
        let sys = series([ProcStats(running: 300, cpu: 12, ramTime: 300 * 5e8, ramPeak: 6e8, childCpu: 0)])
        #expect(try #require(Window.chartModel(sys, .cpu)).line == nil)
        #expect(Window.chartModel(sys, .energy) == nil)
        #expect(Window.chartModel(sys, .disk) == nil)
        let mem = try #require(Window.chartModel(sys, .memory))
        #expect(mem.bars == [5e8])
        #expect(mem.line == [6e8])
        // Never seen running: nothing to draw at all.
        #expect(Window.chartModel(series([ProcStats(), ProcStats()]), .cpu) == nil)
    }

    private func row(_ path: String, cpu: Double = 0, written: Double = 0) -> Window.Row {
        Window.Row(name: ProcKey.name(path), path: path, s: ProcStats(running: 60, cpu: cpu, diskWritten: written, detail: true))
    }

    @Test func topIsTheBiggestEightWithAtLeastOnePercent() {
        // 12 programs with 100, 90 … 10 CPU seconds, then two small ones: 0.9% and 0.1% of the total.
        var rows = (1...10).map { row("/usr/bin/p\($0)", cpu: Double($0) * 10) }
        rows += [row("/usr/bin/small", cpu: 5), row("/usr/bin/tiny", cpu: 0.5), row("/usr/bin/idle")]
        #expect(Window.top(rows, .cpu) == (3...10).reversed().map { "/usr/bin/p\($0)" })
        // Fewer than eight are big enough: the 1% line decides.
        let few = [row("/usr/bin/a", cpu: 500), row("/usr/bin/b", cpu: 6), row("/usr/bin/c", cpu: 4)]
        #expect(Window.top(few, .cpu) == ["/usr/bin/a", "/usr/bin/b"])
        // Ranked by what the chart shows, not always CPU.
        let disk = [row("/usr/bin/a", cpu: 500, written: 1e9), row("/usr/bin/b", cpu: 6, written: 9e9)]
        #expect(Window.top(disk, .disk) == ["/usr/bin/b", "/usr/bin/a"])
        #expect(Window.top([row("/usr/bin/idle")], .cpu).isEmpty)
        #expect(Window.top([], .cpu).isEmpty)
    }

    @Test func programsKeepTheirColourWhileTheyStayOnTop() {
        let first = Window.slots([:], top: ["a", "b", "c"])
        #expect(first == ["a": 0, "b": 1, "c": 2])
        // b is gone, d and e are new: a and c stay where they were, the new ones take what is free.
        let next = Window.slots(first, top: ["d", "c", "a", "e"])
        #expect(next == ["a": 0, "c": 2, "d": 1, "e": 3])
        // Never more than the palette has.
        let many = Window.slots([:], top: (0..<12).map { "p\($0)" })
        #expect(Set(many.values) == Set(0..<8))
    }

    @Test func stackHasTheRestAndForCPUWhatNoScanSaw() throws {
        func stats(_ cpu: Double, ram: Double = 0, energy: Double = 0) -> ProcStats {
            ProcStats(running: 300, cpu: cpu, energy: energy, ramTime: ram, detail: true)
        }
        let o = ProcessTracker.Overview(hourly: true, starts: [0, 3600],
                                        programs: [("/Applications/Foo.app", [stats(6, ram: 300e6), stats(0)]), ("/usr/bin/tool", [stats(1), stats(2, ram: 60e6)])],
                                        total: [stats(10, ram: 600e6), stats(2, ram: 60e6)], unseen: [ProcStats(cpu: 3), ProcStats()],
                                        awake: [300, 600])
        let colors = Array(ProcessHistoryChartView.palette.prefix(2))
        let cpu = try #require(Window.stackModel(o, .cpu, colors: colors, rest: "Other"))
        #expect(cpu.stack.map(\.name) == ["Foo", "tool", "Other", "Unseen"])
        #expect(cpu.stack.map(\.values) == [[6, 0], [1, 2], [3, 0], [3, 0]])
        #expect(cpu.stack[0].color == colors[0])
        #expect(cpu.starts == [0, 3600])
        // Memory: averaged over the time the scans covered, so the parts add up; no "unseen".
        let mem = try #require(Window.stackModel(o, .memory, colors: colors, rest: "Everything else"))
        #expect(mem.stack.map(\.name) == ["Foo", "tool", "Everything else"])
        #expect(mem.stack.map(\.values) == [[1e6, 0], [0, 1e5], [1e6, 0]])
        // Nothing left over: no "Other". Nothing at all: no chart.
        var exact = o
        exact.total = [stats(7), stats(2)]
        exact.unseen = [ProcStats(), ProcStats()]
        #expect(try #require(Window.stackModel(exact, .cpu, colors: colors, rest: "Other")).stack.map(\.name) == ["Foo", "tool"])
        #expect(Window.stackModel(o, .energy, colors: colors, rest: "Other") == nil)
    }

    @Test func scalesEndOnRoundNumbers() {
        #expect(ProcessHistoryChartView.roundUp(0.7) == 1)
        #expect(ProcessHistoryChartView.roundUp(1) == 1)
        #expect(ProcessHistoryChartView.roundUp(101) == 200)
        #expect(ProcessHistoryChartView.roundUp(3.2e9) == 5e9)
        #expect(ProcessHistoryChartView.roundUp(6e9) == 1e10)
        #expect(ProcessHistoryChartView.roundUpTime(42) == 60)
        #expect(ProcessHistoryChartView.roundUpTime(61) == 120)
        #expect(ProcessHistoryChartView.roundUpTime(3000) == 3600)
        #expect(ProcessHistoryChartView.roundUpTime(3 * 86400.0 + 5) == 5 * 86400)
        #expect(ProcessHistoryChartView.roundUpTime(0.03) == 0.1)
    }
}
