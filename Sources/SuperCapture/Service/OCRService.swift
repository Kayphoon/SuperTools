import Foundation
import Vision
import CoreGraphics

public enum OCRFailure: LocalizedError {
    case empty
    case recognizerFailed(code: Int)

    public var errorDescription: String? {
        switch self {
        case .empty: return "选区中未识别到文字，剪贴板未改变。"
        case .recognizerFailed(let code): return "文字识别失败（错误码 \(code)），请重试。"
        }
    }
}

// An actor serializes expensive Vision work; the host accepts only one image job
// at a time, so full-resolution images cannot accumulate behind this actor.
public actor OCRService {
    /// Vision loads its recogniser and language model on the first request of the
    /// process and keeps them resident afterwards, so the host can tell a slow
    /// first capture apart from a broken one.
    private var hasLoadedModel = false

    public var isPrepared: Bool { hasLoadedModel }

    public init() {}

    public func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        // `.fast` is not an option here: on a full-resolution screenshot it turns
        // Chinese into gibberish (measured 315 nonsense chars against 834 correct
        // ones), so every call needs the accurate recogniser.
        request.recognitionLevel = .accurate
        // Simplified Chinese + English only, which is what this app is used for.
        // Dropping zh-Hant does not change the load time (measured 12.55 s with it and
        // 12.79 s without); it just stops Vision from offering Traditional candidates
        // for Simplified text. Keeping fewer curated languages also avoids the garbled
        // output seen when only en-US was listed.
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        // The languages are already listed, so detection only reshuffles candidates;
        // it also makes the cold-start model load slower (27 s against 14 s).
        request.automaticallyDetectsLanguage = false
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            // A picture or a blank area is not an error: Vision returns an empty
            // result list for those, and the caller turns that into `OCRFailure.empty`.
            // Anything thrown here is a real recogniser failure (error 1 is the E5RT /
            // Neural Engine path failing, not "no text"), so it must stay visible
            // instead of being reported as an empty selection.
            let code = (error as NSError).code
            Diagnostics.log("ocr: recogniser failed domain=\((error as NSError).domain) code=\(code)")
            throw OCRFailure.recognizerFailed(code: code)
        }
        try Task.checkCancellation()
        hasLoadedModel = true
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

}
