// swift-tools-version: 5.9
import Foundation
import PackageDescription

let cltTestingPluginPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let hasXcodeApp = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [])
    .contains { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? ""
let needsCLTTestingPlugin = (developerDir.contains("CommandLineTools") || !hasXcodeApp)
    && FileManager.default.fileExists(atPath: cltTestingPluginPath)
let testSwiftSettings: [SwiftSetting] = needsCLTTestingPlugin
    ? [.unsafeFlags(["-plugin-path", cltTestingPluginPath])]
    : []

let package = Package(
    name: "SuperTools",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SuperCapture", targets: ["SuperCapture"]),
        .library(name: "SuperClipboard", targets: ["SuperClipboard"]),
        .executable(name: "SuperTools", targets: ["SuperTools"])
    ],
    targets: [
        .target(name: "SuperCapture"),
        .target(name: "SuperClipboard"),
        .executableTarget(name: "SuperTools", dependencies: ["SuperCapture", "SuperClipboard"]),
        .testTarget(
            name: "SuperCaptureTests",
            dependencies: ["SuperCapture"],
            swiftSettings: testSwiftSettings
        ),
        .testTarget(
            name: "SuperClipboardTests",
            dependencies: ["SuperClipboard", "SuperTools"],
            swiftSettings: testSwiftSettings
        )
    ]
)
