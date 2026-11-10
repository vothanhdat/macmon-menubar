import Foundation

/// A history tier: fixed number of buckets of fixed duration (a round-robin buffer).
struct Tier {
    let label: String
    let bucket: TimeInterval
    let capacity: Int
}

/// Fixed-size history kept in one memory-mapped file (~248 KB, never grows).
/// Each bucket stores avg + max per series. Updating history is just writing memory;
/// the kernel writes dirty pages back to disk, and we nudge it once a minute.
/// Partially filled buckets live in the file too, so a restart continues where it left off.
/// Main thread only.
final class HistoryStore {
    /// Display order is array order. The file records each tier's shape and the series count, so
    /// tiers can be added or reordered and series appended later: matching tiers are copied over
    /// when the layout changes (see `migrate`). The 64-byte header has room for 6 tiers.
    static let tiers = [
        Tier(label: "1m", bucket: 1, capacity: 60),        // 1 s buckets
        Tier(label: "5m", bucket: 5, capacity: 60),        // 5 s
        Tier(label: "1h", bucket: 10, capacity: 360),      // 10 s
        Tier(label: "24h", bucket: 240, capacity: 360),    // 4 min
        Tier(label: "7d", bucket: 1800, capacity: 336),    // 30 min
        Tier(label: "30d", bucket: 7200, capacity: 360),   // 2 h
    ]
    static let defaultTierLabel = "5m"
    private static let magic: UInt32 = 0x4D4D_4931 // "MMI1"
    private static let version: UInt32 = 1
    private static let nSeries = Series.allCases.count

    /// Byte layout for a list of tier shapes. Header (64 bytes): magic, version, series count,
    /// tier count, then (bucket seconds, capacity) per tier.
    private struct Layout: Equatable {
        struct Shape: Equatable { let bucket: Int; let capacity: Int }
        let tiers: [Shape]
        let nSeries: Int
        var stateOffset: Int { 64 }                                   // per tier: lastIndex, accIndex (Int64)
        var accOffset: Int { stateOffset + tiers.count * 16 }         // per tier/series: sum f64, count u32, max f32
        func ringOffset(_ t: Int) -> Int {                            // per tier: capacity × series × (avg, max) f32
            tiers.prefix(t).reduce(accOffset + tiers.count * nSeries * 16) { $0 + $1.capacity * nSeries * 8 }
        }
        var fileSize: Int { ringOffset(tiers.count) }

        /// The layout recorded in an existing file, if the file is one of ours and complete.
        static func read(from d: Data) -> Layout? {
            guard d.count >= 64 else { return nil }
            func u32(_ o: Int) -> Int { Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }) }
            guard u32(0) == Int(HistoryStore.magic), u32(4) == Int(HistoryStore.version) else { return nil }
            let ns = u32(8), tc = u32(12)
            guard ns > 0, ns < 1024, tc > 0, 16 + tc * 8 <= 64 else { return nil }
            let shapes = (0..<tc).map { Shape(bucket: u32(16 + $0 * 8), capacity: u32(20 + $0 * 8)) }
            guard shapes.allSatisfy({ $0.bucket > 0 && $0.capacity > 0 && $0.capacity < 100_000 }) else { return nil }
            let l = Layout(tiers: shapes, nSeries: ns)
            return d.count >= l.fileSize ? l : nil
        }
    }
    private static let layout = Layout(tiers: tiers.map { .init(bucket: Int($0.bucket), capacity: $0.capacity) }, nSeries: nSeries)
    private static let stateOffset = layout.stateOffset
    private static let accOffset = layout.accOffset
    private static let ringOffsets = (0..<tiers.count).map { layout.ringOffset($0) }
    private static let fileSize = layout.fileSize

    private let base: UnsafeMutableRawPointer
    private let mapped: Bool
    private var lastFlush = Date().timeIntervalSince1970

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.bin").path
        // Read the existing file first: if its layout differs, its tiers are copied after the resize.
        let old = FileManager.default.contents(atPath: path)
        let oldLayout = old.flatMap(Layout.read(from:))
        let size = Self.fileSize
        var ptr: UnsafeMutableRawPointer?
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        if fd >= 0 {
            var st = stat()
            if fstat(fd, &st) == 0, st.st_size != off_t(size) { _ = ftruncate(fd, off_t(size)) }
            let m = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
            close(fd) // the mapping keeps the file open
            if let m, m != MAP_FAILED { ptr = m }
        }
        if let ptr {
            base = ptr
            mapped = true
        } else {
            base = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16) // memory only fallback
            mapped = false
        }
        if oldLayout != Self.layout {
            reset()
            if let old, let oldLayout { migrate(from: old, layout: oldLayout) }
        }
    }

    /// Copies every tier that exists in both layouts (same bucket and capacity) from an old file.
    /// Series are only ever appended, so the old file's series are the first ones here; series it
    /// doesn't have start empty (and series it has beyond ours, from a newer version, are dropped).
    private func migrate(from old: Data, layout ol: Layout) {
        let n = Self.nSeries, on = ol.nSeries, common = min(n, on)
        var copied: [String] = []
        old.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let s = src.baseAddress else { return }
            for (t, shape) in Self.layout.tiers.enumerated() {
                guard let o = ol.tiers.firstIndex(of: shape) else { continue }
                memcpy(base + Self.stateOffset + t * 16, s + ol.stateOffset + o * 16, 16)
                memcpy(base + Self.accOffset + t * n * 16, s + ol.accOffset + o * on * 16, common * 16)
                for k in common..<n { accPtr(t, k).storeBytes(of: -Float.infinity, toByteOffset: 12, as: Float.self) }
                for slot in 0..<shape.capacity {
                    memcpy(base + Self.ringOffsets[t] + slot * n * 8, s + ol.ringOffset(o) + slot * on * 8, common * 8)
                }
                copied.append(Self.tiers[t].label)
            }
        }
        flush(sync: true)
        log.notice("history file layout changed (\(on) → \(n) series); kept tiers: \(copied.joined(separator: ", "), privacy: .public)")
    }

    deinit { flush(sync: true) }

    // MARK: - Layout helpers

    private func reset() {
        memset(base, 0, Self.fileSize)
        base.storeBytes(of: Self.magic, toByteOffset: 0, as: UInt32.self)
        base.storeBytes(of: Self.version, toByteOffset: 4, as: UInt32.self)
        base.storeBytes(of: UInt32(Self.nSeries), toByteOffset: 8, as: UInt32.self)
        base.storeBytes(of: UInt32(Self.tiers.count), toByteOffset: 12, as: UInt32.self)
        for (i, t) in Self.tiers.enumerated() {
            base.storeBytes(of: UInt32(t.bucket), toByteOffset: 16 + i * 8, as: UInt32.self)
            base.storeBytes(of: UInt32(t.capacity), toByteOffset: 20 + i * 8, as: UInt32.self)
            setLast(i, -1)
            setAccIndex(i, -1)
            let ring = (base + Self.ringOffsets[i]).bindMemory(to: Float.self, capacity: t.capacity * Self.nSeries * 2)
            ring.initialize(repeating: .nan, count: t.capacity * Self.nSeries * 2)
        }
        flush(sync: true)
    }

    private func last(_ t: Int) -> Int64 { base.load(fromByteOffset: Self.stateOffset + t * 16, as: Int64.self) }
    private func setLast(_ t: Int, _ v: Int64) { base.storeBytes(of: v, toByteOffset: Self.stateOffset + t * 16, as: Int64.self) }
    private func accIndex(_ t: Int) -> Int64 { base.load(fromByteOffset: Self.stateOffset + t * 16 + 8, as: Int64.self) }
    private func setAccIndex(_ t: Int, _ v: Int64) { base.storeBytes(of: v, toByteOffset: Self.stateOffset + t * 16 + 8, as: Int64.self) }

    private func accPtr(_ t: Int, _ s: Int) -> UnsafeMutableRawPointer { base + Self.accOffset + (t * Self.nSeries + s) * 16 }

    private func slotPtr(_ t: Int, _ bucket: Int64) -> UnsafeMutablePointer<Float> {
        let cap = Int64(Self.tiers[t].capacity)
        let slot = Int(((bucket % cap) + cap) % cap)
        return (base + Self.ringOffsets[t] + slot * Self.nSeries * 8).assumingMemoryBound(to: Float.self)
    }

    private func accValues(_ t: Int, _ s: Int) -> (avg: Float, max: Float) {
        let p = accPtr(t, s)
        let count = p.load(fromByteOffset: 8, as: UInt32.self)
        guard count > 0 else { return (.nan, .nan) }
        return (Float(p.load(as: Double.self) / Double(count)), p.load(fromByteOffset: 12, as: Float.self))
    }

    // MARK: - Writing

    func add(_ sample: Sample) {
        var values = [Float](repeating: .nan, count: Self.nSeries)
        for s in Series.allCases { values[s.rawValue] = sample.value(s) }

        for (t, tier) in Self.tiers.enumerated() {
            let idx = Int64((sample.time / tier.bucket).rounded(.down))
            if accIndex(t) != idx {
                if accIndex(t) >= 0 { commit(t) }
                for s in 0..<Self.nSeries {
                    let p = accPtr(t, s)
                    p.storeBytes(of: 0.0, as: Double.self)
                    p.storeBytes(of: 0, toByteOffset: 8, as: UInt32.self)
                    p.storeBytes(of: -Float.infinity, toByteOffset: 12, as: Float.self)
                }
                setAccIndex(t, idx)
            }
            for s in 0..<Self.nSeries where values[s].isFinite {
                let p = accPtr(t, s)
                p.storeBytes(of: p.load(as: Double.self) + Double(values[s]), as: Double.self)
                p.storeBytes(of: p.load(fromByteOffset: 8, as: UInt32.self) + 1, toByteOffset: 8, as: UInt32.self)
                p.storeBytes(of: max(p.load(fromByteOffset: 12, as: Float.self), values[s]), toByteOffset: 12, as: Float.self)
            }
        }
        if sample.time - lastFlush >= 60 { flush(sync: false) }
    }

    /// Moves the finished accumulator of tier `t` into its ring slot.
    private func commit(_ t: Int) {
        let a = accIndex(t)
        let cap = Int64(Self.tiers[t].capacity)
        var lastIdx = last(t)
        if a > lastIdx {
            // Mark buckets we skipped (Mac asleep, app not running) as gaps.
            var g = max(lastIdx + 1, a - cap + 1)
            while g < a {
                slotPtr(t, g).update(repeating: .nan, count: Self.nSeries * 2)
                g += 1
            }
            lastIdx = a
            setLast(t, a)
        }
        guard a > lastIdx - cap else { return }
        let slot = slotPtr(t, a)
        for s in 0..<Self.nSeries {
            let v = accValues(t, s)
            slot[s * 2] = v.avg
            slot[s * 2 + 1] = v.max
        }
    }

    func flush(sync: Bool) {
        lastFlush = Date().timeIntervalSince1970
        if mapped { msync(base, Self.fileSize, sync ? MS_SYNC : MS_ASYNC) }
    }

    // MARK: - Reading

    /// Values for the whole window of tier `t` ending now, oldest first. NaN = no data.
    func window(tier t: Int, series s: Series, now: TimeInterval, avg: inout [Float], max mx: inout [Float]) {
        let tier = Self.tiers[t]
        let cap = tier.capacity
        if avg.count != cap { avg = [Float](repeating: .nan, count: cap) }
        if mx.count != cap { mx = [Float](repeating: .nan, count: cap) }
        let nowIdx = Int64((now / tier.bucket).rounded(.down))
        let start = nowIdx - Int64(cap) + 1
        let lastIdx = last(t), acc = accIndex(t)
        for i in 0..<cap {
            let b = start + Int64(i)
            if b == acc {
                let v = accValues(t, s.rawValue)
                avg[i] = v.avg; mx[i] = v.max
            } else if b <= lastIdx && b > lastIdx - Int64(cap) {
                let p = slotPtr(t, b)
                avg[i] = p[s.rawValue * 2]; mx[i] = p[s.rawValue * 2 + 1]
            } else {
                avg[i] = .nan; mx[i] = .nan
            }
        }
        // Holes shorter than `maxHole` buckets are filled from the left neighbour (see there);
        // longer gaps (sleep) stay visible.
        let maxHole = Self.maxHole(t)
        var i = 1
        while i < cap {
            guard !avg[i].isFinite, avg[i - 1].isFinite else { i += 1; continue }
            var j = i
            while j < cap && !avg[j].isFinite { j += 1 }
            if j - i <= maxHole { for k in i..<j { avg[k] = avg[i - 1]; mx[k] = mx[i - 1] } }
            i = j
        }
    }

    /// The longest run of empty buckets that counts as a hole, not a gap. Samples come every 1 to
    /// 10 s (the slowest battery setting, and while the displays sleep), so 1 s buckets miss
    /// several between samples while the menu is closed, and longer buckets can miss one by timing
    /// jitter. Holes up to 11 s are filled (at least one bucket); sleep leaves far longer gaps.
    private static func maxHole(_ t: Int) -> Int { max(1, Int(11 / tiers[t].bucket)) }

    /// Average of one series in bucket `b`, NaN when it holds no data.
    private func avgValue(_ t: Int, _ s: Int, _ b: Int64) -> Float {
        if b == accIndex(t) { return accValues(t, s).avg }
        let lastIdx = last(t)
        guard b <= lastIdx && b > lastIdx - Int64(Self.tiers[t].capacity) else { return .nan }
        return slotPtr(t, b)[s * 2]
    }

    /// Average of one series in bucket `i` of the window (for hover read-outs), with holes filled
    /// as in `window(tier:...)`.
    func value(tier t: Int, series s: Series, index i: Int, now: TimeInterval) -> Float {
        let tier = Self.tiers[t]
        let start = Int64((now / tier.bucket).rounded(.down)) - Int64(tier.capacity) + 1
        let end = start + Int64(tier.capacity), b = start + Int64(i)
        let v = avgValue(t, s.rawValue, b)
        guard !v.isFinite, b > start else { return v }
        let maxHole = Int64(Self.maxHole(t))
        var l = b - 1
        while l > start, b - l <= maxHole, !avgValue(t, s.rawValue, l).isFinite { l -= 1 }
        let left = avgValue(t, s.rawValue, l)
        guard left.isFinite else { return .nan }
        var r = b + 1
        while r < end, r - l - 1 <= maxHole, !avgValue(t, s.rawValue, r).isFinite { r += 1 }
        return r - l - 1 <= maxHole ? left : .nan
    }

    /// Start time of bucket `i` in the window used by `window(tier:...)`.
    func bucketStart(tier t: Int, index i: Int, now: TimeInterval) -> TimeInterval {
        let tier = Self.tiers[t]
        let nowIdx = (now / tier.bucket).rounded(.down)
        return (nowIdx - Double(tier.capacity - 1) + Double(i)) * tier.bucket
    }

    // MARK: - Export

    func exportCSV(to url: URL) throws {
        var out = "tier,time," + Series.allCases.flatMap { ["\($0.csvName)_avg", "\($0.csvName)_max"] }.joined(separator: ",") + "\n"
        let iso = ISO8601DateFormatter()
        for (t, tier) in Self.tiers.enumerated() {
            let lastIdx = last(t)
            guard lastIdx >= 0 else { continue }
            var b = lastIdx - Int64(tier.capacity) + 1
            while b <= lastIdx {
                let p = slotPtr(t, b)
                if (0..<Self.nSeries * 2).contains(where: { p[$0].isFinite }) {
                    let cols = (0..<Self.nSeries * 2).map { p[$0].isFinite ? String(format: "%.3f", p[$0]) : "" }
                    out += "\(tier.label),\(iso.string(from: Date(timeIntervalSince1970: Double(b) * tier.bucket))),"
                        + cols.joined(separator: ",") + "\n"
                }
                b += 1
            }
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }
}
