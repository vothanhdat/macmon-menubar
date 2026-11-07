import AppKit

/// The standard macOS About panel, with an icon drawn in code and credits with links.
enum About {
    static let repo = URL(string: "https://github.com/vothanhdat/macmon-menubar")!
    static let macmonRepo = URL(string: "https://github.com/vladkens/macmon")!

    static func show(macmonVersion: String?) {
        NSApp.orderFrontStandardAboutPanel(options: options(macmonVersion: macmonVersion))
    }

    static func options(macmonVersion: String?) -> [NSApplication.AboutPanelOptionKey: Any] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        return [
            .applicationIcon: icon(size: 128),
            .applicationVersion: version,
            .version: "", // CFBundleVersion is the same number; don't show it twice
            .credits: credits(macmonVersion: macmonVersion),
        ]
    }

    static func credits(macmonVersion: String?) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]
        let s = NSMutableAttributedString()
        func add(_ text: String, link: URL? = nil) {
            var a = base
            if let link { a[.link] = link }
            s.append(NSAttributedString(string: text, attributes: a))
        }
        add("A small menu bar monitor for Apple Silicon Macs.\n")
        add("github.com/vothanhdat/macmon-menubar", link: repo)
        add("\nSensor data: ")
        add("macmon" + (macmonVersion.map { " " + $0 } ?? ""), link: macmonRepo)
        add(" by vladkens (MIT)")
        return s
    }

    /// The app icon (also built into AppIcon.icns): a rounded square with a blue gradient and
    /// filled bars, like the menu's charts. Follows the macOS icon grid: an 824/1024 shape with
    /// a 185/1024 corner radius and a soft shadow below.
    static func icon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let u = size / 1024
            let box = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
            let shape = NSBezierPath(roundedRect: box, xRadius: 185 * u, yRadius: 185 * u)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
            shadow.shadowBlurRadius = 20 * u
            shadow.set()
            NSColor(srgbRed: 0.10, green: 0.30, blue: 0.80, alpha: 1).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: NSColor(srgbRed: 0.30, green: 0.62, blue: 1.00, alpha: 1),
                       ending: NSColor(srgbRed: 0.10, green: 0.30, blue: 0.80, alpha: 1))?
                .draw(in: shape, angle: -90)

            // Stepped bars: a faint "peak" layer behind solid "average" bars.
            let inner = box.insetBy(dx: box.width * 0.16, dy: box.height * 0.2)
            let avg: [CGFloat] = [0.30, 0.45, 0.38, 0.70, 0.55, 0.82, 0.60]
            let peak: [CGFloat] = [0.42, 0.60, 0.50, 0.88, 0.70, 0.96, 0.74]
            let w = inner.width / CGFloat(avg.count)
            for (i, (a, p)) in zip(avg, peak).enumerated() {
                let x = inner.minX + CGFloat(i) * w
                NSColor.white.withAlphaComponent(0.3).setFill()
                NSRect(x: x, y: inner.minY, width: w + 0.5, height: inner.height * p).fill()
                NSColor.white.withAlphaComponent(0.95).setFill()
                NSRect(x: x, y: inner.minY, width: w + 0.5, height: inner.height * a).fill()
            }
            return true
        }
    }
}
