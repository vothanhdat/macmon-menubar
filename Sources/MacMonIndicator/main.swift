import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--layout-previews") {
    SnapshotMode.layoutPreviews(to: i + 1 < args.count ? args[i + 1] : "layout-previews.png")
}
if let i = args.firstIndex(of: "--bar-previews") {
    SnapshotMode.barPreviews(to: i + 1 < args.count ? args[i + 1] : "bar-previews.png")
}
if let i = args.firstIndex(of: "--iconset") {
    SnapshotMode.writeIconset(to: i + 1 < args.count ? args[i + 1] : "AppIcon.iconset")
}
if let i = args.firstIndex(of: "--settings") {
    SnapshotMode.settingsPreview(to: i + 1 < args.count ? args[i + 1] : "settings")
}
if let i = args.firstIndex(of: "--about") {
    SnapshotMode.aboutPreview(to: i + 1 < args.count ? args[i + 1] : "about")
}
if let i = args.firstIndex(of: "--process-history") {
    SnapshotMode.processHistoryPreview(to: i + 1 < args.count ? args[i + 1] : "process-history")
}
if let i = args.firstIndex(of: "--snapshot") {
    SnapshotMode.run(outputDir: i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : "snapshots",
                     demoProcesses: args.contains("--demo"))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
