import Foundation
import Vision
import CoreGraphics

public enum OCRFailure: LocalizedError {
    case empty
    public var errorDescription: String? { "选区中未识别到文字，剪贴板未改变。" }
}

// An actor serializes expensive Vision work; the host accepts only one image job
// at a time, so full-resolution images cannot accumulate behind this actor.
public actor OCRService {
    public init() {}

    public func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        // `.fast` is not an option here: on a full-resolution screenshot it turns
        // Chinese into gibberish (measured 315 nonsense chars against 834 correct
        // ones), so every call needs the accurate recogniser.
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        // The languages are already listed, so detection only reshuffles candidates;
        // it also makes the cold-start model load slower (27 s against 14 s).
        request.automaticallyDetectsLanguage = false
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch let error as NSError where error.domain.contains("TextRecognition") {
            // Vision reports "nothing readable here" as a CRImageReaderError instead
            // of returning an empty result list. That is a normal outcome for a
            // screenshot of a blank area, not a failure worth surfacing as-is.
            throw OCRFailure.empty
        }
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Load the recogniser before the first screenshot needs it.
    ///
    /// The recogniser costs ~13 s to load the first time a process uses it, against
    /// ~0.3 s per call afterwards. Every screenshot runs OCR to index its text, so
    /// that load used to land on the first capture after each launch. Paying it in
    /// the background at launch keeps the capture path at ~0.3 s.
    public func warmUp() {
        let side = 64
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        if let image = context.makeImage() {
            let start = Date()
            _ = try? recognize(image)
            Diagnostics.log("ocr: warm-up \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        }
    }
}
