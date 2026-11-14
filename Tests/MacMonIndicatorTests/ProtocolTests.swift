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
    footer: ["Unseen: 4.0s", "Last scan 10:05"])

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
        let keys = try #require(try json(data) as? [String: Any]).keys.sorted()
        #expect(keys == ["ascending", "byExecutable", "cmd", "filter", "limit", "range", "sortBy"])
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
