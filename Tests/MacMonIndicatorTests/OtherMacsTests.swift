import Foundation
import Testing
@testable import MacMonIndicator

/// Two Macs sharing one folder, as they would in iCloud Drive (see ShareFolder in OtherMacs.swift).
@Suite struct OtherMacsTests {
    let dir = TempDir()
    /// Each Mac's own history files, outside the shared folder.
    let local = TempDir()
    var mini: ShareFolder { ShareFolder(root: dir.url, me: "mini") }
    var book: ShareFolder { ShareFolder(root: dir.url, me: "book") }
    let t0: Double = 1_800_000_000

    private func info(_ id: String, published: Double, answered: [String: String] = [:]) -> ShareFolder.Info {
        var s = Sample()
        s.cpu = 42
        s.ramTotalGB = 16
        s.fanCount = 1
        return ShareFolder.Info(id: id, name: id == "mini" ? "Mac mini" : "MacBook", model: "Mac16,10", app: "test",
                                published: published, hasBattery: id == "book", latest: s.values,
                                processes: nil, processesTime: nil, answered: answered)
    }

    private func history() -> HistoryStore {
        let h = HistoryStore(directory: local.url.appendingPathComponent(UUID().uuidString))
        for i in 0..<30 {
            var s = Sample()
            s.time = t0 + Double(i)
            s.cpu = Float(i)
            h.add(s)
        }
        return h
    }

    @Test func sampleValuesRoundTrip() {
        var s = Sample()
        for (i, series) in Series.allCases.enumerated() { s[keyPath: series.keyPath] = Float(i) + 0.5 }
        s.ramTotalGB = 24; s.fanMax = 5000; s.memPressure = 2; s.fanCount = 2; s.onAC = false
        // The key path and value(_:) agree for every series.
        for series in Series.allCases { #expect(s.value(series) == s[keyPath: series.keyPath]) }
        let back = Sample(values: s.values, time: t0)
        for series in Series.allCases { #expect(back.value(series) == s.value(series)) }
        #expect(back.time == t0)
        #expect(back.ramTotalGB == 24 && back.fanMax == 5000 && back.memPressure == 2 && back.fanCount == 2 && !back.onAC)
        // What isn't available stays out, and comes back as not available.
        #expect(Sample().values["cpu_pct"] == nil)
        #expect(Sample(values: [:], time: t0).cpu.isNaN)
    }

    @Test func historyCopyReadsTheSame() throws {
        let h = history()
        let copy = try #require(HistoryStore(copy: h.fileData()))
        var a: [Float] = [], am: [Float] = [], b: [Float] = [], bm: [Float] = []
        for tier in HistoryStore.tiers.indices {
            h.window(tier: tier, series: .cpu, now: t0 + 30, avg: &a, max: &am)
            copy.window(tier: tier, series: .cpu, now: t0 + 30, avg: &b, max: &bm)
            #expect(a.map(\.bitPattern) == b.map(\.bitPattern))
            #expect(am.map(\.bitPattern) == bm.map(\.bitPattern))
        }
        #expect(HistoryStore(copy: Data("not a history file".utf8)) == nil)
        #expect(HistoryStore(copy: h.fileData().prefix(1000)) == nil) // cut short in transfer
    }

    @Test func publishedCopyShowsOnTheOtherMac() throws {
        let h = history()
        try mini.publish(info("mini", published: t0), history: h.fileData())
        #expect(mini.scan(known: [:]).isEmpty) // a Mac doesn't list itself
        let found = book.scan(known: [:])
        let e = try #require(found["mini"])
        #expect(e.info?.name == "Mac mini")
        #expect(e.info?.latest["cpu_pct"] == 42)
        #expect(e.historyDate != nil)
        let copy = try #require(book.loadHistory("mini"))
        #expect(copy.value(tier: 0, series: .cpu, index: 59, now: t0 + 29) == 29)

        // Unchanged files aren't read again: the scan keeps what it had.
        var known = found
        known["mini"]?.info?.name = "kept"
        #expect(book.scan(known: known)["mini"]?.info?.name == "kept")
    }

    @Test func requestIsAnsweredByTheNextPublish() throws {
        try mini.publish(info("mini", published: t0), history: history().fileData())
        // The MacBook looks at the Mac mini 10 minutes later: its copy is old, so it asks.
        let now = t0 + 600
        let miniInfo = try #require(book.scan(known: [:])["mini"]?.info)
        #expect(ShareFolder.shouldAsk(info: miniInfo, asked: nil, now: now))
        let ask = ShareFolder.Request(token: "t1", time: now)
        try book.writeRequests(ShareFolder.Requests(asks: ["mini": ask]))
        #expect(book.readOwnRequests()?.asks["mini"] == ask)
        #expect(book.status(miniInfo, asked: ask, now: now + 10) == .asking)
        #expect(!ShareFolder.shouldAsk(info: miniInfo, asked: ask, now: now + 10)) // asked already

        // The Mac mini sees the request, once.
        let seen = mini.scan(known: [:])
        #expect(mini.newRequests(seen, answered: [:], now: now + 20) == ["book": "t1"])
        #expect(mini.newRequests(seen, answered: ["book": "t1"], now: now + 20).isEmpty)
        // Too old (the MacBook stopped waiting), or meant for another Mac: nothing to do.
        #expect(mini.newRequests(seen, answered: [:], now: now + ShareFolder.requestLifetime + 1).isEmpty)
        #expect(book.newRequests(mini.scan(known: [:]), answered: [:], now: now).isEmpty)

        // It publishes with the answer; the MacBook stops waiting.
        try mini.publish(info("mini", published: now + 30, answered: ["book": "t1"]), history: history().fileData())
        let fresh = try #require(book.scan(known: [:])["mini"]?.info)
        #expect(book.status(fresh, asked: ask, now: now + 40) == .updated)
        #expect(!ShareFolder.shouldAsk(info: fresh, asked: ask, now: now + 40))
    }

    @Test func unansweredRequestShowsNoReply() {
        let old = info("mini", published: t0)
        let ask = ShareFolder.Request(token: "t1", time: t0 + 600)
        #expect(book.status(old, asked: ask, now: t0 + 600 + ShareFolder.replyWait - 1) == .asking)
        #expect(book.status(old, asked: ask, now: t0 + 600 + ShareFolder.replyWait + 1) == .noReply)
        #expect(book.status(old, asked: ask, now: t0 + 600 + ShareFolder.requestLifetime + 1) == .updated)
        // An answer to an older request isn't an answer to this one.
        #expect(book.status(info("mini", published: t0, answered: ["book": "t0"]), asked: ask, now: t0 + 610) == .asking)
        // Asking again after a while.
        #expect(ShareFolder.shouldAsk(info: old, asked: ask, now: t0 + 600 + ShareFolder.staleAfter + 1))
        // A recent copy needs no asking; a Mac with no copy yet does.
        #expect(!ShareFolder.shouldAsk(info: info("mini", published: t0), asked: nil, now: t0 + 60))
        #expect(ShareFolder.shouldAsk(info: nil, asked: nil, now: t0))
    }

    @Test func statusTexts() {
        #expect(ShareFolder.ago(20) == "just now")
        #expect(ShareFolder.ago(40 * 60 + 5) == "40 min ago")
        #expect(ShareFolder.ago(2 * 3600 + 100) == "2 h ago")
        #expect(ShareFolder.ago(86400 + 100) == "1 day ago")
        #expect(ShareFolder.ago(3 * 86400) == "3 days ago")
        #expect(ShareFolder.ago(-5) == "just now") // clocks a little apart
        #expect(ShareFolder.text(.updated, published: t0, now: t0 + 600) == "10 min ago")
        #expect(ShareFolder.text(.asking, published: t0, now: t0 + 600) == "updating…")
        #expect(ShareFolder.text(.noReply, published: t0, now: t0 + 600) == "no reply · 10 min ago")
    }

    @Test func forgettingRemovesTheFolder() throws {
        try mini.publish(info("mini", published: t0), history: history().fileData())
        #expect(book.scan(known: [:])["mini"] != nil)
        book.remove("mini")
        #expect(book.scan(known: [:])["mini"] == nil)
    }

    @Test func trimKeepsTheTopOfEachColumn() {
        var snap = ProcSnapshot()
        for i in 0..<200 {
            // CPU rises with i, memory falls: the top by each are at opposite ends.
            snap.rows.append(ProcRow(pid: pid_t(i), name: "p\(i)", cpu: Double(i), cpuTime: 1, mem: Double(1000 - i), disk: nil))
        }
        let t = ShareFolder.trim(snap, perColumn: 5)
        let pids = Set(t.rows.map(\.pid))
        #expect(pids.isSuperset(of: Set((195..<200).map { pid_t($0) }))) // CPU
        #expect(pids.isSuperset(of: Set((0..<5).map { pid_t($0) })))     // RAM
        #expect(t.rows.count < 30)
    }
}
