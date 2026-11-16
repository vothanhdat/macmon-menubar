import Foundation
import Testing
@testable import MacMonIndicator

/// The messages between the app (TerminalServer.swift) and the terminal view (Terminal/src/proto.rs)
/// are written out in Tests/protocol/, and both sides are tested against those files:
///
/// - `live.json`, `history.json`: replies as the app encodes them. Here: the app still encodes
///   exactly this. In proto.rs: the terminal view reads every field of it.
/// - `request-live.json`, `request-history.json`: requests as the terminal view encodes them.
///   In proto.rs: it still encodes exactly this. Here: the app reads every field of it.
///
/// So a field renamed, added or removed on one side fails that side's test until the file is
/// updated, and then the other side's test until it follows. After changing a reply on purpose,
/// write the files again with `MMI_UPDATE_FIXTURES=1 swift test`, then run `make test`.
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("protocol", isDirectory: true)

/// A live reply with every field filled in (optional ones too), with values no field shares.
private let live = TerminalServer.Live(
    app: "9.8.7", host: "mac-mini", time: 1_800_000_000.5, intervalMs: 2000, problem: "macmon was not found",
    tiers: ["1m", "5m", "1h"], tier: 1, columns: 2,
    charts: [
        TerminalServer.Chart(id: "disk", title: "Disk", shape: "mirrored", color: "blue", color2: "pink", main: "12M",
                             detail: "R 8M  W 4M", hot: true, lo: 0.5, hi: 100, lo2: 0.25, hi2: 50, warnStart: 65, limit: 90,
                             avg: [1.5, nil, 3], max: [2, nil, 4], avg2: [0.75, nil], max2: [1.25, nil]),
        TerminalServer.Chart(id: "cpu", title: "CPU", shape: "up", color: "indigo", color2: nil, main: "42%", detail: nil,
                             hot: false, lo: 0, hi: 100, avg: [], max: []),
    ],
    values: ["cpu_pct": 42, "gpu_pct": nil],
    processes: TerminalServer.Processes(
        columns: [TerminalServer.Column(title: "CPU", sort: 3)], sort: 3,
        rows: [TerminalServer.ProcessRow(pid: 4321, name: "node", cells: ["12.5%"], strong: 1)],
        note: "System processes: 3% CPU"),
    processHistory: true)

private let history = TerminalServer.History(
    tracking: true, ranges: ["Today", "24 Hours"], range: 1, byExecutable: true,
    columns: [TerminalServer.HistoryColumn(id: "cpu", title: "CPU time", tip: "CPU seconds used")],
    sortBy: "cpu", ascending: true, total: 77,
    rows: [TerminalServer.HistoryRow(name: "node", path: "/opt/homebrew/Cellar/node/*/bin/node", cells: ["3h 12m"], unknown: [true])],
    footer: ["Unseen: 4.0s", "Last scan 10:05"],
    chart: TerminalServer.HistoryChart(
        metrics: ["CPU", "Energy"], metric: 1, title: "node and everything else · per hour",
        path: "/opt/homebrew/Cellar/node/*/bin/node", rest: true, message: "Nothing recorded in this range.",
        labels: ["14:00", "15:00"], times: ["Sun 15 Nov, 14:00–15:00", "Sun 15 Nov, 15:00–16:00"], top: 3600,
        scale: ["1h 00m", "30m 00s"],
        segments: [TerminalServer.HistorySegment(name: "node", color: "#3987e5", values: [725, 0.5], cells: ["12m 05s · 20%", "0.5s · 1.0%"])],
        totals: ["1h 00m", "48s"], line: TerminalServer.HistoryLine(name: "Peak", cells: ["1.2G", "–"]),
        notes: ["Running 42m 00s", ""]))

private let export = TerminalServer.Export(
    tracking: true, columns: ["start", "name", "cpu_s", "energy_j", "launches"],
    rows: [["2027-01-15T14:00:00+07:00", #"Tool, "the" one"#, .number(12.5), .unknown, .count(3)],
           ["2027-01-15T15:00:00+07:00", "node", .number(0.25), .number(40.5), .count(0)]])

private func json(_ data: Data) throws -> NSObject {
    try #require(try JSONSerialization.jsonObject(with: data) as? NSObject)
}

/// Checks that `value` encodes to what `file` holds (as JSON, whatever the spacing or key order).
/// With MMI_UPDATE_FIXTURES=1 it writes the file instead.
private func check<T: Encodable>(_ value: T, _ file: String) throws {
    let url = fixtures.appendingPathComponent(file)
    if ProcessInfo.processInfo.environment["MMI_UPDATE_FIXTURES"] == "1" {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try (e.encode(value) + Data("\n".utf8)).write(to: url)
    }
    let saved = try json(Data(contentsOf: url))
    // As the app sends it.
    #expect(try json(TerminalServer.encode(value)) == saved,
            "\(file) is not what the app encodes now. If the change is meant: MMI_UPDATE_FIXTURES=1 swift test, then make test")
}

@Suite struct ProtocolTests {
    @Test func liveReply() throws { try check(live, "live.json") }
    @Test func historyReply() throws { try check(history, "history.json") }
    @Test func exportReply() throws { try check(export, "export.json") }

    @Test func exportRequest() throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("request-export.json"))
        let r = try JSONDecoder().decode(TerminalServer.Request.self, from: data)
        #expect(r.cmd == .export)
        #expect(r.range == 3)
        #expect(try #require(try json(data) as? [String: Any]).keys.sorted() == ["cmd", "range"])
    }

    @Test func repliesCarryTheVersion() throws {
        // The terminal view reads `version` first and stops when it isn't the one it knows.
        let l = try #require(try json(TerminalServer.encode(live)) as? [String: Any])
        let h = try #require(try json(TerminalServer.encode(history)) as? [String: Any])
        #expect(l["version"] as? Int == TerminalServer.version)
        #expect(h["version"] as? Int == TerminalServer.version)
        #expect(l["kind"] as? String == "live")
        #expect(h["kind"] as? String == "history")
    }

    @Test func liveRequest() throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("request-live.json"))
        let r = try JSONDecoder().decode(TerminalServer.Request.self, from: data)
        #expect(r.cmd == .live)
        #expect(r.tier == 2)
        #expect(r.points == 120)
        #expect(r.sort == 3)
        #expect(r.rows == 15)
        // Nothing in the file that the app doesn't read.
        let keys = try #require(try json(data) as? [String: Any]).keys.sorted()
        #expect(keys == ["cmd", "points", "rows", "sort", "tier"])
    }

    @Test func historyRequest() throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("request-history.json"))
        let r = try JSONDecoder().decode(TerminalServer.Request.self, from: data)
        #expect(r.cmd == .history)
        #expect(r.range == 4)
        #expect(r.byExecutable == true)
        #expect(r.sortBy == "energy")
        #expect(r.ascending == true)
        #expect(r.filter == "chrome")
        #expect(r.limit == 250)
        #expect(r.chart == 2)
        #expect(r.chartPath == "/Applications/Google Chrome.app")
        #expect(r.chartRest == true)
        let keys = try #require(try json(data) as? [String: Any]).keys.sorted()
        #expect(keys == ["ascending", "byExecutable", "chart", "chartPath", "chartRest", "cmd", "filter", "limit", "range", "sortBy"])
    }

    /// The chart a request asks for, built as the window builds its own.
    @Test func historyChart() throws {
        func request(_ json: String) throws -> TerminalServer.Request {
            try JSONDecoder().decode(TerminalServer.Request.self, from: Data(json.utf8))
        }
        func stats(_ cpu: Double, child: Double = 0) -> ProcStats { ProcStats(running: 300, cpu: cpu, ramTime: 300 * 2e9, ramPeak: 3e9, detail: true, childCpu: child) }
        let app = "/Applications/Foo.app", tool = "/usr/bin/tool"
        let summary = ProcessTracker.Summary(programs: [(app, stats(600)), (tool, stats(100)), ("/usr/bin/tiny", stats(1))])
        // 14:00 and 15:00 on some day, in this Mac's time zone.
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).timeIntervalSince1970
        let starts = [day + 14 * 3600, day + 15 * 3600]

        // No chart asked for (an older terminal view): none read, none sent.
        let plain = try request(#"{"cmd":"history"}"#)
        #expect(TerminalServer.chartPlan(plain, summary: summary) == nil)
        #expect(TerminalServer.history(plain, summary: summary).chart == nil)

        // All programs: those with at least 1%, stacked, with the rest and what no scan saw.
        let all = try request(#"{"cmd":"history","chart":0}"#)
        guard case .stack(let paths, pinned: nil)? = TerminalServer.chartPlan(all, summary: summary) else {
            Issue.record("not a stack of all programs")
            return
        }
        #expect(Set(paths) == [app, tool])
        let o = ProcessTracker.Overview(hourly: true, starts: starts, programs: paths.map { ($0, [stats($0 == app ? 600 : 100), ProcStats()]) },
                                        total: [stats(701), ProcStats()], unseen: [ProcStats(cpu: 99), ProcStats()], awake: [300, 0])
        let c = try #require(TerminalServer.history(all, summary: summary, chart: .stack(o, pinned: nil)).chart)
        #expect(c.metrics == ["CPU", "Energy", "Memory", "Disk", "Network"])
        #expect(c.metric == 0)
        #expect(c.title == "All apps · per hour")
        #expect(c.path == nil)
        #expect(!c.rest)
        #expect(c.message == nil)
        #expect(c.labels == ["14:00", "15:00"])
        #expect(c.times.first?.hasSuffix(", 14:00–15:00") == true)
        #expect(Set(c.segments.prefix(2).map(\.name)) == ["Foo", "tool"])
        #expect(c.segments.dropFirst(2).map(\.name) == ["Other", "Unseen"])
        #expect(c.segments.dropFirst(2).map(\.color) == ["#8e8e93", "#636366"])
        #expect(Set(c.segments.prefix(2).map(\.color)).count == 2)
        #expect(c.segments.prefix(2).allSatisfy { $0.color.count == 7 && $0.color.hasPrefix("#") })
        let foo = try #require(c.segments.first { $0.name == "Foo" })
        #expect(foo.values == [600, 0])
        #expect(foo.cells == ["10m 00s · 75%", "–"])
        #expect(c.totals == ["13m 20s", "0.0s"])
        #expect(c.top == 900)
        #expect(c.scale == ["15m 00s", "7m 30s"])
        #expect(c.line == nil)
        #expect(c.notes == ["", ""])

        // One program with everything else, and alone (with its children's CPU time as numbers).
        let rest = try request(#"{"cmd":"history","chart":0,"chartPath":"/usr/bin/tool","chartRest":true}"#)
        guard case .stack([tool], pinned: tool)? = TerminalServer.chartPlan(rest, summary: summary) else {
            Issue.record("not one program with the rest")
            return
        }
        let one = ProcessTracker.Overview(hourly: false, starts: starts, programs: [(tool, [stats(100), ProcStats()])],
                                          total: [stats(701), ProcStats()], unseen: [ProcStats(), ProcStats()], awake: [300, 0])
        let r = try #require(TerminalServer.history(rest, summary: summary, chart: .stack(one, pinned: tool)).chart)
        #expect(r.title == "tool and everything else · per day")
        #expect(r.path == tool)
        #expect(r.rest)
        #expect(r.segments.map(\.name) == ["tool", "Everything else"])

        let alone = try request(#"{"cmd":"history","chart":0,"chartPath":"/usr/bin/tool"}"#)
        guard case .alone(tool)? = TerminalServer.chartPlan(alone, summary: summary) else {
            Issue.record("not one program alone")
            return
        }
        let series = ProcessTracker.Series(hourly: true, points: [(starts[0], stats(100, child: 40)), (starts[1], ProcStats())])
        let a = try #require(TerminalServer.history(alone, summary: summary, chart: .alone(tool, series)).chart)
        #expect(a.title == "tool · per hour")
        #expect(!a.rest)
        #expect(a.segments.map(\.name) == ["CPU time"])
        #expect(a.segments[0].values == [100, 0])
        #expect(a.segments[0].cells == ["1m 40s", "–"])
        #expect(a.totals == ["1m 40s", "–"])
        #expect(a.line?.name == "Children’s CPU time")
        #expect(a.line?.cells == ["40s", "–"])
        #expect(a.notes[0].hasPrefix("Running 5m 00s"))
        #expect(a.notes[1] == "")
        // Memory of a program alone has its peak; nothing known: a message, nothing to draw.
        let mem = try #require(TerminalServer.history(try request(#"{"cmd":"history","chart":2,"chartPath":"/usr/bin/tool"}"#),
                                                      summary: summary, chart: .alone(tool, series)).chart)
        #expect(mem.metric == 2)
        #expect(mem.line?.cells == ["3.0G", "–"])
        let none = ProcessTracker.Series(hourly: true, points: [(starts[0], ProcStats())])
        let n = try #require(TerminalServer.history(alone, summary: summary, chart: .alone(tool, none)).chart)
        #expect(n.message == "Not seen running in this range.")
        #expect(n.segments.isEmpty && n.labels.isEmpty)
    }

    @Test func shortestRequests() throws {
        // What `--once` sends: only the command. Everything else has a default.
        let r = try JSONDecoder().decode(TerminalServer.Request.self, from: Data(#"{"cmd":"live"}"#.utf8))
        #expect(r.cmd == .live)
        #expect(r.tier == nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TerminalServer.Request.self, from: Data(#"{"cmd":"quit"}"#.utf8))
        }
    }
}
