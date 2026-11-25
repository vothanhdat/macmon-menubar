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

    /// Another Mac's charts end now, like this Mac's: the buckets after its copy's last one are the
    /// part not synced yet.
    @Test func unsyncedPartStartsAfterTheCopysLastBucket() {
        let tier1m = 0, tier1h = 2, tier30d = 5
        let cap1h = HistoryStore.tiers[tier1h].capacity
        // This Mac's charts, and a copy from the bucket that is now: nothing is after it.
        #expect(ChartsView.firstUnsynced(tier: tier1h, syncedUntil: nil, now: t0) == cap1h)
        #expect(ChartsView.firstUnsynced(tier: tier1h, syncedUntil: t0, now: t0 + 5) == cap1h)
        // 10 minutes ago on 1h (10 s buckets): the last 60 buckets. Partway through a bucket, that
        // bucket still has the copy's data.
        #expect(ChartsView.firstUnsynced(tier: tier1h, syncedUntil: t0, now: t0 + 600) == cap1h - 60)
        #expect(ChartsView.firstUnsynced(tier: tier1h, syncedUntil: t0 + 9, now: t0 + 600) == cap1h - 60)
        // Older than the whole 1m window; and on 30d one 2-hour bucket holds both times.
        #expect(ChartsView.firstUnsynced(tier: tier1m, syncedUntil: t0, now: t0 + 600) == 0)
        #expect(ChartsView.firstUnsynced(tier: tier30d, syncedUntil: t0, now: t0 + 600) == HistoryStore.tiers[tier30d].capacity)
        // That Mac's clock is ahead of this one's: nothing is after its copy.
        #expect(ChartsView.firstUnsynced(tier: tier1h, syncedUntil: t0 + 30, now: t0) == cap1h)
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

    /// Process history goes along when a publish has it, stays with one that doesn't, and goes
    /// away when the Mac turns it off.
    @Test func processHistoryGoesAlongAndCanBeRemoved() throws {
        let tracker = ProcessTracker(directory: local.url.appendingPathComponent(UUID().uuidString))
        func scan(_ wall: Double, cpu: Double) {
            let p = ProcessTracker.Seen(start: 1_000_000, path: "/usr/bin/a", cpu: cpu, mem: 100, maxMem: 100, detail: true)
            tracker.queue.sync { tracker.record([7: p], nowWall: wall, nowUp: UInt64(wall * 1e9), ticks: [1000, 0, 0]) }
        }
        scan(t0, cpu: 100)
        scan(t0 + 300, cpu: 130)
        let packed = try #require(tracker.queue.sync { tracker.makeCopy(now: t0 + 310) })
        var i = info("mini", published: t0 + 310)
        i.processHistory = t0 + 310
        try mini.publish(i, history: history().fileData(), processHistory: .write(packed))

        let e = try #require(book.scan(known: [:])["mini"])
        #expect(e.info?.processHistory == t0 + 310)
        #expect(e.processDate != nil)
        let copy = try #require(book.loadProcessHistory("mini"))
        #expect(copy.copy?.lastScan == t0 + 300)
        let a = copy.queue.sync { copy.summarize(.last24h, now: t0 + 300) }.programs.first { $0.path == "/usr/bin/a" }
        #expect(a?.stats.cpu == 30)

        // An hourly publish without it leaves it there.
        var hourly = info("mini", published: t0 + 3600)
        hourly.processHistory = t0 + 310
        try mini.publish(hourly, history: history().fileData())
        #expect(book.loadProcessHistory("mini") != nil)

        // Process history turned off on the Mac mini.
        try mini.publish(info("mini", published: t0 + 7200), history: history().fileData(), processHistory: .remove)
        let off = try #require(book.scan(known: [:])["mini"])
        #expect(off.processDate == nil && off.info?.processHistory == nil)
        #expect(book.loadProcessHistory("mini") == nil)
        #expect(book.loadHistory("mini") != nil)
    }

    @Test func processHistoryIsAskedForByItsOwnAge() throws {
        var i = info("mini", published: t0 + 3000)
        i.processHistory = t0
        #expect(!ShareFolder.shouldAsk(info: i, asked: nil, now: t0 + 3100))                    // charts are recent
        #expect(ShareFolder.shouldAsk(info: i, asked: nil, now: t0 + 3100, processHistory: true)) // process history isn't
        #expect(!ShareFolder.shouldAsk(info: i, asked: ShareFolder.Request(token: "t", time: t0 + 3050), now: t0 + 3100,
                                       processHistory: true)) // asked already
        // None there (off, or an app from before): asking may bring it.
        #expect(ShareFolder.shouldAsk(info: info("mini", published: t0 + 3000), asked: nil, now: t0 + 3100, processHistory: true))
        // An info.json from before has no process history; one with it reads back.
        let old = try ShareFolder.decoder.decode(ShareFolder.Info.self, from: ShareFolder.encoder.encode(info("mini", published: t0)))
        #expect(old.processHistory == nil)
        #expect(try ShareFolder.decoder.decode(ShareFolder.Info.self, from: ShareFolder.encoder.encode(i)).processHistory == t0)
    }

    @Test func processHistoryCopyLine() {
        let made = t0, now = t0 + 40 * 60 + 5
        let line = ProcessHistoryWindowController.copyLine(name: "Mac mini", made: made, status: "40 min ago", loaded: true, now: now)
        #expect(line.hasPrefix("Mac mini’s copy from ") && line.hasSuffix(" · 40 min ago."))
        #expect(ProcessHistoryWindowController.copyLine(name: "Mac mini", made: made, status: "", loaded: true, now: now)
            .hasSuffix(" · 40 min ago."))
        #expect(ProcessHistoryWindowController.copyLine(name: "Mac mini", made: made, status: "updating…", loaded: true, now: now)
            .hasSuffix(" · updating…"))
        #expect(ProcessHistoryWindowController.copyLine(name: "Mac mini", made: nil, status: "", loaded: false, now: now)
            == "Getting Mac mini’s process history…")
        #expect(ProcessHistoryWindowController.copyLine(name: "Mac mini", made: nil, status: "updating…", loaded: true, now: now)
            == "Getting Mac mini’s process history…")
        #expect(ProcessHistoryWindowController.copyLine(name: "Mac mini", made: nil, status: "", loaded: true, now: now)
            .hasPrefix("Mac mini has no process history"))
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
