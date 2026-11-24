import AppKit
import ScreenCaptureKit

public enum CaptureError: LocalizedError {
    case permissionRequired, displayUnavailable, invalidSelection, allocationFailed, scrollNeedsSingleDisplay

    public var errorDescription: String? {
        switch self {
        case .permissionRequired: return "请在系统设置 → 隐私与安全性 → 屏幕与系统录音中允许 SuperTools，然后重试。"
        case .displayUnavailable: return "显示器已改变，请重新截图。"
        case .invalidSelection: return "选区为空或过大，请缩小选区。"
        case .allocationFailed: return "无法创建截图图像。"
        case .scrollNeedsSingleDisplay: return "滚动长截图的选区需完整位于一台显示器内，请调整选区后重试。"
        }
    }
}

public struct DisplayFrame {
    public let frame: CGRect
    public let image: CGImage
}

@MainActor
public final class ScreenGrabber {
    public init() {}

    public func capture() async throws -> [DisplayFrame] {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw CaptureError.permissionRequired
        }
        let screens = NSScreen.screens
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var frames: [DisplayFrame] = []
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                throw CaptureError.displayUnavailable
            }
            let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            // A Retina display reports its *point* size through CGDisplayPixelsWide.
            // Asking ScreenCaptureKit for that count halves the resolution on every
            // 2x screen, so the overlay preview and the cropped result are both
            // upscaled and look blurry. Capture at real backing pixels instead.
            let scale = max(screen.backingScaleFactor, 1)
            configuration.width = Int((CGFloat(display.width) * scale).rounded())
            configuration.height = Int((CGFloat(display.height) * scale).rounded())
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            Diagnostics.log("grabber: display=\(display.displayID) points=\(display.width)x\(display.height) scale=\(scale) captured=\(image.width)x\(image.height)")
            frames.append(DisplayFrame(frame: screen.frame, image: image))
        }
        guard screens.map(\.frame) == NSScreen.screens.map(\.frame) else {
            throw CaptureError.displayUnavailable
        }
        return frames
    }
}
