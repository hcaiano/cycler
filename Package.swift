// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cycler",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Auto-updates. Binary XCFramework target; embedded + re-signed by Scripts/build-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure, testable logic (cycle-order math, binding config model). No AppKit-only state
        // here so it runs cleanly under `swift run cycler-tests`.
        .target(name: "CyclerCore"),
        // Thin executable: AppKit agent, AX window enumeration/raise, Carbon hotkeys.
        .executableTarget(
            name: "cycler",
            dependencies: [
                "CyclerCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // The bundled app loads Sparkle.framework from Contents/Frameworks; SwiftPM only
            // adds an rpath into .build, so add the bundle-relative one for the shipped app.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        // Dependency-free test runner so the suite runs under Command Line Tools
        // (no full Xcode / XCTest needed). Run: `swift run cycler-tests`.
        .executableTarget(
            name: "cycler-tests",
            dependencies: ["CyclerCore"]
        ),
    ]
)
