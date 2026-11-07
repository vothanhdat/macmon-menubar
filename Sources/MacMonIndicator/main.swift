import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--layout-previews") {
    SnapshotMode.layoutPreviews(to: i + 1 < args.count ? args[i + 1] : "layout-previews.png")
}
if let i = args.firstIndex(of: "--bar-previews") {
    SnapshotMode.barPreviews(to: i + 1 < args.count ? args[i + 1] : "bar-previews.png")
}
if let i = args.firstIndex(of: "--snapshot") {
    SnapshotMode.run(outputDir: i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : "snapshots",
                     demoProcesses: args.contains("--demo"))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
