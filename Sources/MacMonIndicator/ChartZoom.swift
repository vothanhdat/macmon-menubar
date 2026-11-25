import CoreGraphics
import Foundation

/// A zoomed-in time range of the charts, instead of a range tab's whole window: from the mouse
/// wheel, a pinch, a sideways scroll or a drag across a chart (see ChartsView). Every chart shows
/// the same range, focused or not, and so do other Macs' charts, which end now too.
///
/// The buckets drawn come from the finest tier whose window reaches back to the range's start,
/// so zooming into the last hour of the 24h tab shows 10-second buckets, while yesterday stays at
/// the 4 minutes that are stored for it. Plain arithmetic, for ChartsView and the tests.
struct ChartZoom: Equatable {
    /// Seconds shown.
    var span: TimeInterval
    /// The left edge (seconds since 1970), while not `live`.
    var fixedStart: TimeInterval
    /// The range ends now and moves on with the clock. A zoom that leaves the right edge at now
    /// stays live; one into the past stays where it is.
    var live: Bool

    func start(now: TimeInterval) -> TimeInterval { live ? now - span : fixedStart }

    /// What a gesture leads to: a zoomed-in range, or a range tab's whole window.
    enum Result: Equatable { case zoom(ChartZoom), tier(Int) }

    /// The range shown before a gesture: a tab's window counts as live.
    struct Current { var start: TimeInterval; var span: TimeInterval; var live: Bool }

    /// The narrowest zoom shows this many buckets of the tier drawn.
    static let minBuckets = 12.0
    /// A range ending this close to now (a share of its span) ends now: it is live.
    static let liveSlack = 0.03

    static func tierSpan(_ t: Int) -> TimeInterval { HistoryStore.tiers[t].bucket * Double(HistoryStore.tiers[t].capacity) }
    static var longest: TimeInterval { tierSpan(HistoryStore.tiers.count - 1) }

    /// The finest tier whose window reaches back to `start`: its buckets are drawn.
    static func tier(start: TimeInterval, now: TimeInterval) -> Int {
        HistoryStore.tiers.indices.first { Viewport.windowStart(tier: $0, now: now) <= start + 0.001 } ?? HistoryStore.tiers.count - 1
    }

    /// `span` seconds from `start`, made to fit: no narrower than `minBuckets` of the tier it
    /// would draw (widened around `anchor`), not past now or before the oldest data. Live when it
    /// ends at now; then a tab's whole window, if it is as long as one.
    static func fit(start: TimeInterval, span: TimeInterval, anchor: TimeInterval, now: TimeInterval) -> Result {
        guard span < longest * 0.999 else { return .tier(HistoryStore.tiers.count - 1) }
        var start = start, span = max(1, span)
        // A wider range can start in a coarser tier, which needs a wider range again: a few rounds.
        for _ in HistoryStore.tiers.indices {
            let least = minBuckets * HistoryStore.tiers[tier(start: start, now: now)].bucket
            guard span < least else { break }
            let share = min(1, max(0, (anchor - start) / span))
            start = anchor - share * least
            span = least
        }
        if start + span > now { start = now - span }
        let oldest = Viewport.windowStart(tier: HistoryStore.tiers.count - 1, now: now)
        if start < oldest { start = oldest; span = min(span, now - oldest) }
        let live = start + span >= now - span * liveSlack
        if live, let t = HistoryStore.tiers.indices.first(where: { abs(tierSpan($0) - span) <= tierSpan($0) * 0.005 }) {
            return .tier(t)
        }
        return .zoom(ChartZoom(span: span, fixedStart: live ? now - span : start, live: live))
    }

    /// `factor` times the span (under 1 zooms in), keeping the time at `anchor` in place.
    /// Zooming out of a live range stops at each tab's window on the way, and shows that tab.
    static func zoomed(_ c: Current, by factor: Double, around anchor: TimeInterval, now: TimeInterval) -> Result {
        var f = factor
        if factor > 1, c.live,
           let t = HistoryStore.tiers.indices.first(where: { c.span < tierSpan($0) * 0.999 && tierSpan($0) < c.span * factor }) {
            f = tierSpan(t) / c.span
        }
        return fit(start: anchor - (anchor - c.start) * f, span: c.span * f, anchor: anchor, now: now)
    }

    /// The same span, `seconds` later (earlier when negative).
    static func panned(_ c: Current, by seconds: TimeInterval, now: TimeInterval) -> Result {
        fit(start: c.start + seconds, span: c.span, anchor: c.start + seconds, now: now)
    }

    /// The range dragged across, from `a` to `b` in either order.
    static func selected(from a: TimeInterval, to b: TimeInterval, now: TimeInterval) -> Result {
        fit(start: min(a, b), span: abs(b - a), anchor: (a + b) / 2, now: now)
    }
}

/// Where the buckets go on screen: the tier whose buckets are drawn, the range shown, and which
/// of the tier's window (HistoryStore.window, ending now) it covers. Unzoomed it is the tab's
/// whole window: bucket `i` at `i / capacity` of the width, as always.
struct Viewport: Equatable {
    let tier: Int
    /// The range shown: its left edge (seconds since 1970) and length.
    let start: TimeInterval
    let span: TimeInterval
    /// Where bucket 0 of the tier's window starts.
    let windowStart: TimeInterval
    /// Window indices of the first and last bucket on screen (either may be partly off it).
    let first: Int, last: Int

    var bucket: TimeInterval { HistoryStore.tiers[tier].bucket }

    init(tier: Int, zoom: ChartZoom?, now: TimeInterval) {
        guard let zoom else {
            self.tier = tier
            windowStart = Self.windowStart(tier: tier, now: now)
            start = windowStart
            span = ChartZoom.tierSpan(tier)
            first = 0
            last = HistoryStore.tiers[tier].capacity - 1
            return
        }
        let s = zoom.start(now: now), t = ChartZoom.tier(start: s, now: now)
        let ws = Self.windowStart(tier: t, now: now), b = HistoryStore.tiers[t].bucket
        let cap = HistoryStore.tiers[t].capacity
        self.tier = t
        start = s
        span = zoom.span
        windowStart = ws
        first = min(cap - 1, max(0, Int(((s - ws) / b).rounded(.down))))
        last = min(cap - 1, max(first, Int(((s + zoom.span - ws) / b).rounded(.up)) - 1))
    }

    /// Where bucket 0 of tier `t`'s window ending at `now` starts (HistoryStore.bucketStart).
    static func windowStart(tier t: Int, now: TimeInterval) -> TimeInterval {
        let tier = HistoryStore.tiers[t]
        return ((now / tier.bucket).rounded(.down) - Double(tier.capacity - 1)) * tier.bucket
    }

    func x(_ time: TimeInterval, in rect: CGRect) -> CGFloat { rect.minX + CGFloat((time - start) / span) * rect.width }
    func time(atX x: CGFloat, in rect: CGRect) -> TimeInterval { start + Double((x - rect.minX) / rect.width) * span }
    /// The left edge of window bucket `i`.
    func x(index i: Int, in rect: CGRect) -> CGFloat { x(windowStart + Double(i) * bucket, in: rect) }
    func bucketWidth(in rect: CGRect) -> CGFloat { CGFloat(bucket / span) * rect.width }
    /// The window index of the bucket at `x`, kept to the buckets on screen.
    func index(atX x: CGFloat, in rect: CGRect) -> Int {
        min(last, max(first, Int(((time(atX: x, in: rect) - windowStart) / bucket).rounded(.down))))
    }

    /// The gridline step for a range `span` long: the shortest that gives at most 7 lines. The
    /// tabs get 10 s (1m), 1 min (5m), 10 min (1h), 4 h (24h), a day (7d) and 5 days (30d).
    static func tickStep(span: TimeInterval) -> TimeInterval {
        let steps: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 14400,
                                     21600, 43200, 86400, 2 * 86400, 5 * 86400]
        return steps.first { span / $0 <= 7 } ?? steps[steps.count - 1]
    }
}
