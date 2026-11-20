// swift-tools-version: 5.9
import PackageDescription

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
        .testTarget(name: "SuperCaptureTests", dependencies: ["SuperCapture"], swiftSettings: [
            .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])
        ]),
        .testTarget(name: "SuperClipboardTests", dependencies: ["SuperClipboard", "SuperTools"], swiftSettings: [
            .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])
        ])
    ]
)
