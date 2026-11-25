import CoreGraphics
import Foundation
import Testing
@testable import MacMonIndicator

/// Zooming the charts in time (ChartZoom.swift).
@Suite struct ChartZoomTests {
    /// On a boundary of every tier's bucket (a multiple of 7200 s), and 5 s into the next 10 s.
    let t0: TimeInterval = 1_800_000_000
    var now: TimeInterval { t0 + 5 }
    let tier1m = 0, tier1h = 2, tier24h = 3, tier30d = 5

    private func live(span: TimeInterval) -> ChartZoom.Current { .init(start: now - span, span: span, live: true) }

    @Test func tabWindowIsDrawnAsBefore() {
        let vp = Viewport(tier: tier1h, zoom: nil, now: now)
        let rect = CGRect(x: 10, y: 0, width: 360, height: 30)
        #expect(vp.tier == tier1h && vp.first == 0 && vp.last == 359)
        #expect(vp.x(index: 0, in: rect) == 10 && abs(vp.x(index: 100, in: rect) - 110) < 1e-9)
        #expect(vp.bucketWidth(in: rect) == 1)
        #expect(vp.index(atX: 110.5, in: rect) == 100 && vp.index(atX: 0, in: rect) == 0 && vp.index(atX: 999, in: rect) == 359)
    }

    @Test func tabsKeepTheirGridlines() {
        let steps = HistoryStore.tiers.indices.map { Viewport.tickStep(span: ChartZoom.tierSpan($0)) }
        #expect(steps == [10, 60, 600, 4 * 3600, 86400, 5 * 86400])
        #expect(Viewport.tickStep(span: 20 * 60) == 300)
    }

    @Test func zoomingIntoTheLastHourOf24hShows10SecondBuckets() {
        let r = ChartZoom.selected(from: now - 3000, to: now, now: now)
        guard case .zoom(let z) = r else { Issue.record("\(r)"); return }
        #expect(z.live && z.span == 3000)
        let vp = Viewport(tier: tier24h, zoom: z, now: now)
        #expect(vp.tier == tier1h && vp.bucket == 10)
        #expect(vp.first == 59 && vp.last == 359)
    }

    @Test func zoomingIntoThePastKeepsItsBucketsAndStaysPut() {
        // 10 minutes 3 hours ago: only 4-minute buckets are stored then, so at least 12 of them.
        let mid = now - 3 * 3600 - 300
        let r = ChartZoom.selected(from: mid - 300, to: mid + 300, now: now)
        #expect(r == .zoom(ChartZoom(span: 12 * 240, fixedStart: mid - 6 * 240, live: false)))
        if case .zoom(let z) = r {
            #expect(z.start(now: now + 600) == z.start(now: now))
            #expect(Viewport(tier: tier1h, zoom: z, now: now).tier == tier24h)
        }
    }

    @Test func wheelZoomKeepsThePointersTime() {
        // Around the middle of a live hour: it leaves now, so it stays where it is.
        #expect(ChartZoom.zoomed(live(span: 3600), by: 0.5, around: now - 1800, now: now)
                == .zoom(ChartZoom(span: 1800, fixedStart: now - 2700, live: false)))
        // At the right edge it stays live.
        #expect(ChartZoom.zoomed(live(span: 3600), by: 0.5, around: now, now: now)
                == .zoom(ChartZoom(span: 1800, fixedStart: now - 1800, live: true)))
        // No narrower than 12 buckets: 12 seconds in the last minute.
        #expect(ChartZoom.zoomed(live(span: 60), by: 0.001, around: now, now: now)
                == .zoom(ChartZoom(span: 12, fixedStart: now - 12, live: true)))
    }

    @Test func zoomingOutStopsAtEachTab() {
        #expect(ChartZoom.zoomed(live(span: 3600), by: 2, around: now, now: now)
                == .zoom(ChartZoom(span: 7200, fixedStart: now - 7200, live: true)))
        // Past 24h on the way out: that tab, and from there on to the next.
        #expect(ChartZoom.zoomed(live(span: 3600), by: 30, around: now - 1800, now: now) == .tier(tier24h))
        #expect(ChartZoom.zoomed(live(span: ChartZoom.longest / 2), by: 3, around: now, now: now) == .tier(tier30d))
    }

    @Test func panningStopsAtNowAndAtTheOldestData() {
        // Back to now: live again, and as long as a tab, that tab.
        let past = ChartZoom.Current(start: now - 3 * 3600, span: 3600, live: false)
        #expect(ChartZoom.panned(past, by: 3 * 3600, now: now) == .tier(tier1h))
        // Before the oldest data (30 days): there, 12 two-hour buckets at least.
        let oldest = Viewport.windowStart(tier: tier30d, now: now)
        #expect(ChartZoom.panned(live(span: 3600), by: -40 * 86400, now: now)
                == .zoom(ChartZoom(span: 12 * 7200, fixedStart: oldest, live: false)))
    }

    @Test func rangeText() {
        let t = Date().timeIntervalSince1970
        #expect(Dashboard.rangeText(ChartZoom(span: 1200, fixedStart: 0, live: true), now: t).hasSuffix("–now"))
        #expect(!Dashboard.rangeText(ChartZoom(span: 1200, fixedStart: t - 3600, live: false), now: t).hasSuffix("–now"))
    }
}
