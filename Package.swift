// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacMonIndicator",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacMonIndicator",
            path: "Sources/MacMonIndicator",
            swiftSettings: [.unsafeFlags(["-Osize"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
