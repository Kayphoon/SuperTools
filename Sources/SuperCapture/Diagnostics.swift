import AppKit

/// Append-only runtime log at ~/Library/Logs/SuperTools/runtime.log.
///
/// The app is an accessory (menu bar) process with no console, and `open -a`
/// swallows stdout, so this log is the only way to observe launch-time hotkey
/// registration, permission state, and panel presentation on a real machine.
public enum Diagnostics {
    public static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SuperTools", isDirectory: true)

    public static let logURL: URL = directory.appendingPathComponent("runtime.log")

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let byteLimit = 256 * 1024

    public static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let size = (try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > byteLimit {
            try? FileManager.default.removeItem(at: logURL)
        }

        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}

/// A panel that can take keyboard focus even though it does not activate the app.
public final class KeyablePanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}
