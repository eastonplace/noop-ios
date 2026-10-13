#if os(iOS)
import Foundation
import ImageIO
import Vision

enum LocalCoachAttachmentError: LocalizedError, Equatable {
    case emptyImage, imageTooLarge, invalidImage, noText, tooMuchText, recognitionFailed
    var errorDescription: String? {
        switch self {
        case .emptyImage: "Choose a workout photo or screenshot."
        case .imageTooLarge: "This photo is too large. Crop it to one workout or choose a smaller image under 20 MB."
        case .invalidImage: "This file could not be read as a photo. Choose a supported photo or screenshot."
        case .noText: "No readable workout text was found. Try a sharper photo, crop the text, or type it yourself."
        case .tooMuchText: "This image contains too much text. Crop it to one workout and try again."
        case .recognitionFailed: "Text could not be read on this device. Try another photo or enter the workout text yourself."
        }
    }
}

/// Local OCR only, not multimodal model vision. The caller owns PhotosPicker and an editable
/// review step. Cancel its Task on disappearance or source/privacy changes; never auto-send the
/// returned string or save a workout without review. This service does not save/upload images.
@MainActor
enum LocalCoachAttachment {
    static let maximumImageBytes = 20 * 1_024 * 1_024
    static let maximumTextBytes = 6_000

    static func extractWorkoutText(from data: Data) async throws -> String {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw LocalCoachAttachmentError.emptyImage }
        guard data.count <= maximumImageBytes else { throw LocalCoachAttachmentError.imageTooLarge }
        let operation = LocalCoachOCRTask(maximumTextBytes: maximumTextBytes)
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool { try operation.recognize(data) }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let text = try await worker.value
            try Task.checkCancellation()
            return text
        } onCancel: {
            operation.cancel()
            worker.cancel()
        }
    }
}

/// The worker owns ImageIO/Vision objects. Only the request reference and cancellation bit cross
/// executors, protected by the lock. VNRequest.cancel is the concurrent cancellation entry point.
private final class LocalCoachOCRTask: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var activeRequest: VNRecognizeTextRequest?
    private let maximumTextBytes: Int
    init(maximumTextBytes: Int) { self.maximumTextBytes = maximumTextBytes }

    func cancel() {
        lock.lock()
        cancelled = true
        let request = activeRequest
        lock.unlock()
        request?.cancel()
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        lock.lock()
        let cancelled = cancelled
        lock.unlock()
        if cancelled { throw CancellationError() }
    }

    func recognize(_ data: Data) throws -> String {
        try checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0, height > 0 else {
            throw LocalCoachAttachmentError.invalidImage
        }
        guard width <= 40_000, height <= 40_000, width * height <= 100_000_000 else {
            throw LocalCoachAttachmentError.imageTooLarge
        }
        try checkCancellation()
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3_200,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LocalCoachAttachmentError.invalidImage
        }
        try checkCancellation()
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = false
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { activeRequest = request }
        lock.unlock()
        guard !alreadyCancelled else { throw CancellationError() }
        defer {
            lock.lock()
            activeRequest = nil
            lock.unlock()
        }
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        } catch {
            try checkCancellation()
            throw LocalCoachAttachmentError.recognitionFailed
        }
        try checkCancellation()
        var lines: [String] = []
        var byteCount = 0
        for observation in request.results ?? [] {
            try checkCancellation()
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            byteCount += line.utf8.count + (lines.isEmpty ? 0 : 1)
            guard byteCount <= maximumTextBytes, lines.count < 100 else {
                throw LocalCoachAttachmentError.tooMuchText
            }
            lines.append(line)
        }
        guard !lines.isEmpty else { throw LocalCoachAttachmentError.noText }
        return lines.joined(separator: "\n")
    }
}
#endif
