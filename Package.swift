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
        ),
        // `swift test` (or `make test`). Swift Testing, which the Command Line Tools include.
        .testTarget(
            name: "MacMonIndicatorTests",
            dependencies: ["MacMonIndicator"],
            path: "Tests/MacMonIndicatorTests"
        ),
    ]
)
