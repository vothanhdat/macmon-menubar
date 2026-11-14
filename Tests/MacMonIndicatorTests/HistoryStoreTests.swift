import Foundation
import Testing
@testable import MacMonIndicator

/// A throwaway folder for one test's history file.
final class TempDir {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mmi-tests-\(UUID().uuidString)", isDirectory: true)
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private let tier1m = 0, tier5m = 1, tier1h = 2
/// A time on a boundary of every tier's bucket (a multiple of 7200 s).
private let t0: TimeInterval = 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 7200)

private func sample(_ time: TimeInterval, cpu: Float = .nan, gpu: Float = .nan) -> Sample {
    var s = Sample()
    s.time = time
    s.cpu = cpu
    s.gpu = gpu
    return s
}

/// The window of one series, oldest first.
private func window(_ h: HistoryStore, _ tier: Int, _ series: Series = .cpu, now: TimeInterval) -> (avg: [Float], max: [Float]) {
    var avg: [Float] = [], mx: [Float] = []
    h.window(tier: tier, series: series, now: now, avg: &avg, max: &mx)
    return (avg, mx)
}

@Suite struct HistoryStoreTests {
    let dir = TempDir()

    @Test func tierShapesAreTheFileFormat() {
        // Changing a tier's bucket or capacity drops that tier's history on update (see migrate).
        #expect(HistoryStore.tiers.map(\.label) == ["1m", "5m", "1h", "24h", "7d", "30d"])
        #expect(HistoryStore.tiers.map { Int($0.bucket) } == [1, 5, 10, 240, 1800, 7200])
        #expect(HistoryStore.tiers.map(\.capacity) == [60, 60, 360, 360, 336, 360])
        // Series are part of the format too: append only.
        #expect(Series.cpu.rawValue == 0)
        #expect(Series.diskWriteOps.rawValue == 19)
        #expect(Series.allCases.count == 20)
    }

    @Test func bucketKeepsAverageAndPeak() {
        let h = HistoryStore(directory: dir.url)
        // Three samples in one 5 s bucket.
        h.add(sample(t0, cpu: 10))
        h.add(sample(t0 + 1, cpu: 20))
        h.add(sample(t0 + 2, cpu: 60))
        var w = window(h, tier5m, now: t0 + 2)
        #expect(w.avg.count == 60)
        #expect(w.avg.last == 30)   // the bucket still being filled shows too
        #expect(w.max.last == 60)

        // The next bucket starts: the first one is finished and keeps its values.
        h.add(sample(t0 + 5, cpu: 4))
        w = window(h, tier5m, now: t0 + 5)
        #expect(w.avg[58] == 30)
        #expect(w.max[58] == 60)
        #expect(w.avg[59] == 4)
        #expect(w.avg[57].isNaN)    // nothing before the first sample
    }

    @Test func seriesAreKeptApart() {
        let h = HistoryStore(directory: dir.url)
        h.add(sample(t0, cpu: 10, gpu: 70))
        h.add(sample(t0 + 1, cpu: 30))  // no GPU reading this time
        #expect(window(h, tier5m, .cpu, now: t0 + 1).avg.last == 20)
        #expect(window(h, tier5m, .gpu, now: t0 + 1).avg.last == 70) // a missing reading doesn't count as 0
        #expect(window(h, tier5m, .ram, now: t0 + 1).avg.last?.isNaN == true)
    }

    @Test func everyTierGetsEverySample() {
        let h = HistoryStore(directory: dir.url)
        h.add(sample(t0, cpu: 10))
        h.add(sample(t0 + 1, cpu: 30))
        for t in HistoryStore.tiers.indices.dropFirst() {
            #expect(window(h, t, now: t0 + 1).avg.last == 20, "tier \(HistoryStore.tiers[t].label)")
        }
        // 1 s buckets: one sample each.
        let w = window(h, tier1m, now: t0 + 1)
        #expect(w.avg[58] == 10)
        #expect(w.avg[59] == 30)
    }

    @Test func shortHolesAreFilledAndLongGapsStay() {
        let h = HistoryStore(directory: dir.url)
        // 10 s buckets (1h tier). A sample, one missed bucket, a sample: a hole (sampling jitter).
        h.add(sample(t0, cpu: 10))
        h.add(sample(t0 + 20, cpu: 30))
        // Then 10 minutes of sleep: a gap.
        h.add(sample(t0 + 620, cpu: 50))
        let w = window(h, tier1h, now: t0 + 620)
        let last = w.avg.count - 1
        #expect(w.avg[last] == 50)
        #expect(w.avg[last - 62] == 10)
        #expect(w.avg[last - 61] == 10)  // the hole takes its left neighbour's value
        #expect(w.avg[last - 60] == 30)
        #expect(w.avg[(last - 59)..<last].allSatisfy { $0.isNaN }) // a gap stays empty from its first bucket on

        // Hover reads the same values.
        for i in 0...last {
            let v = h.value(tier: tier1h, series: .cpu, index: i, now: t0 + 620)
            #expect(v == w.avg[i] || (v.isNaN && w.avg[i].isNaN), "bucket \(i)")
        }
    }

    @Test func ringKeepsOnlyTheLastWindow() {
        let h = HistoryStore(directory: dir.url)
        // 5 s buckets, capacity 60: write 100 buckets, each with its own number.
        for i in 0..<100 { h.add(sample(t0 + Double(i) * 5, cpu: Float(i))) }
        let w = window(h, tier5m, now: t0 + 99 * 5)
        #expect(w.avg == (40..<100).map(Float.init))
    }

    @Test func oldDataLeavesTheWindowWithTime() {
        let h = HistoryStore(directory: dir.url)
        h.add(sample(t0, cpu: 10))
        h.add(sample(t0 + 5, cpu: 20))
        // Nothing arrives for longer than the 5m window: asking later shows nothing, not old values.
        #expect(window(h, tier5m, now: t0 + 400).avg.allSatisfy { $0.isNaN })
        // The 1h tier still has them.
        #expect(window(h, tier1h, now: t0 + 400).avg.contains(15))
    }

    @Test func sleepLongerThanTheRingClearsIt() {
        let h = HistoryStore(directory: dir.url)
        for i in 0..<60 { h.add(sample(t0 + Double(i) * 5, cpu: 99)) }
        // Asleep for an hour (far more than 60 × 5 s), then two samples.
        h.add(sample(t0 + 3600, cpu: 1))
        h.add(sample(t0 + 3605, cpu: 2))
        let w = window(h, tier5m, now: t0 + 3605)
        #expect(w.avg[58] == 1)
        #expect(w.avg[59] == 2)
        #expect(w.avg[..<58].allSatisfy { $0.isNaN }) // none of the 99s from before the sleep
    }

    @Test func clockSetBackDoesNotLoseNewerBuckets() {
        let h = HistoryStore(directory: dir.url)
        h.add(sample(t0 + 100, cpu: 10))
        h.add(sample(t0 + 105, cpu: 20))
        h.add(sample(t0 + 50, cpu: 5))  // the clock went back 55 s
        h.add(sample(t0 + 55, cpu: 6))
        let w = window(h, tier5m, now: t0 + 105)
        #expect(w.avg[58] == 10)
        #expect(w.avg[59] == 20)
        #expect(w.avg[59 - 11] == 5)    // the bucket at t0 + 50
    }

    @Test func restartContinuesWhereItStopped() {
        do {
            let h = HistoryStore(directory: dir.url)
            h.add(sample(t0, cpu: 10))
            h.add(sample(t0 + 5, cpu: 20))
            h.add(sample(t0 + 6, cpu: 40)) // a bucket that is only partly filled at quit
        }
        let h = HistoryStore(directory: dir.url)
        var w = window(h, tier5m, now: t0 + 6)
        #expect(w.avg[58] == 10)
        #expect(w.avg[59] == 30)
        // The partly filled bucket goes on filling.
        h.add(sample(t0 + 7, cpu: 60))
        w = window(h, tier5m, now: t0 + 7)
        #expect(w.avg[59] == 40)
        #expect(w.max[59] == 60)
    }

    @Test func fileSizeIsFixed() throws {
        let path = dir.url.appendingPathComponent("history.bin").path
        func size() throws -> Int { try #require(FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) }
        let h = HistoryStore(directory: dir.url)
        let empty = try size()
        for i in 0..<5000 { h.add(sample(t0 + Double(i) * 7, cpu: 1)) }
        h.flush(sync: true)
        #expect(try size() == empty)
        #expect(empty < 300_000) // "about 248 KB" in the README
    }

    @Test func fileThatIsNotOursStartsEmpty() throws {
        let file = dir.url.appendingPathComponent("history.bin")
        try Data(repeating: 0xAB, count: 5000).write(to: file)
        let h = HistoryStore(directory: dir.url)
        #expect(window(h, tier5m, now: t0).avg.allSatisfy { $0.isNaN })
        h.add(sample(t0, cpu: 10))
        #expect(window(h, tier5m, now: t0).avg.last == 10)
    }

    @Test func truncatedFileStartsEmpty() throws {
        let file = dir.url.appendingPathComponent("history.bin")
        do {
            let h = HistoryStore(directory: dir.url)
            h.add(sample(t0, cpu: 10))
        }
        let whole = try Data(contentsOf: file)
        try whole.prefix(whole.count / 2).write(to: file)
        let h = HistoryStore(directory: dir.url)
        #expect(window(h, tier5m, now: t0).avg.allSatisfy { $0.isNaN })
    }

    /// A file as an older version would have written it: fewer series, and a tier this version
    /// doesn't have. The tier both have keeps its history; everything else starts empty.
    @Test func olderLayoutKeepsMatchingTiers() throws {
        let nSeries = 2
        let tiers: [(bucket: Int, capacity: Int)] = [(7, 10), (5, 60)] // only "5m" exists today
        let accOffset = 64 + tiers.count * 16
        let ring0 = accOffset + tiers.count * nSeries * 16
        let ring1 = ring0 + tiers[0].capacity * nSeries * 8
        var d = Data(count: ring1 + tiers[1].capacity * nSeries * 8)
        func put<T>(_ v: T, at o: Int) { withUnsafeBytes(of: v) { d.replaceSubrange(o..<(o + $0.count), with: $0) } }
        put(UInt32(0x4D4D_4931), at: 0)  // "MMI1"
        put(UInt32(1), at: 4)
        put(UInt32(nSeries), at: 8)
        put(UInt32(tiers.count), at: 12)
        for (i, t) in tiers.enumerated() {
            put(UInt32(t.bucket), at: 16 + i * 8)
            put(UInt32(t.capacity), at: 20 + i * 8)
            put(Int64(-1), at: 64 + i * 16)      // last finished bucket
            put(Int64(-1), at: 64 + i * 16 + 8)  // bucket being filled
        }
        for o in stride(from: ring0, to: d.count, by: 4) { put(Float.nan, at: o) }
        // The 5 s tier: bucket b finished with cpu avg 42 / max 50, and ecpu avg 7 / max 8.
        let b = Int64(t0 / 5)
        put(b, at: 64 + 16)
        let slot = ring1 + Int(b % 60) * nSeries * 8
        put(Float(42), at: slot)
        put(Float(50), at: slot + 4)
        put(Float(7), at: slot + 8)
        put(Float(8), at: slot + 12)
        try d.write(to: dir.url.appendingPathComponent("history.bin"))

        let h = HistoryStore(directory: dir.url)
        #expect(window(h, tier5m, .cpu, now: t0).avg.last == 42)
        #expect(window(h, tier5m, .cpu, now: t0).max.last == 50)
        #expect(window(h, tier5m, .ecpu, now: t0).avg.last == 7)
        #expect(window(h, tier5m, .ecpu, now: t0).max.last == 8)
        #expect(window(h, tier5m, .gpu, now: t0).avg.allSatisfy { $0.isNaN })  // a series the old file didn't have
        #expect(window(h, tier1h, .cpu, now: t0).avg.allSatisfy { $0.isNaN })  // a tier the old file didn't have

        // It goes on from there, also for the new series.
        h.add(sample(t0 + 5, cpu: 1, gpu: 2))
        #expect(window(h, tier5m, .cpu, now: t0 + 5).avg.suffix(2) == [42, 1])
        #expect(window(h, tier5m, .gpu, now: t0 + 5).avg.last == 2)

        // And the file now has today's layout: a second start changes nothing.
        let again = HistoryStore(directory: dir.url)
        #expect(window(again, tier5m, .cpu, now: t0 + 5).avg.suffix(2) == [42, 1])
    }

    @Test func bucketStartsLineUpWithTheWindow() {
        let h = HistoryStore(directory: dir.url)
        let now = t0 + 3
        #expect(h.bucketStart(tier: tier5m, index: 59, now: now) == t0)
        #expect(h.bucketStart(tier: tier5m, index: 0, now: now) == t0 - 59 * 5)
    }

    @Test func csvHasOneRowPerFinishedBucket() throws {
        let h = HistoryStore(directory: dir.url)
        h.add(sample(t0, cpu: 12.5, gpu: 3))
        h.add(sample(t0 + 5, cpu: 1))
        let file = dir.url.appendingPathComponent("out.csv")
        try h.exportCSV(to: file)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines[0].hasPrefix("tier,time,cpu_pct_avg,cpu_pct_max,ecpu_pct_avg,"))
        #expect(lines[0].split(separator: ",").count == 2 + Series.allCases.count * 2)
        let row = try #require(lines.first { $0.hasPrefix("5m,") })
        let cells = row.split(separator: ",", omittingEmptySubsequences: false)
        #expect(cells.count == 2 + Series.allCases.count * 2)
        #expect(cells[1] == Substring(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: t0))))
        #expect(cells[2] == "12.500")
        #expect(cells[3] == "12.500")
        #expect(cells[4] == "")                                  // no E-core reading
        #expect(cells[2 + Series.gpu.rawValue * 2] == "3.000")
    }
}
