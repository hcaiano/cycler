import Foundation

// Compatibility entrypoint. The real Cycler icon generator lives beside the icon assets.
// Usage: swift Scripts/make-icon.swift Icon/icon-1024.png
let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let generator = root.appendingPathComponent("Icon/make-icon.swift").path
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", generator, outPath]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
