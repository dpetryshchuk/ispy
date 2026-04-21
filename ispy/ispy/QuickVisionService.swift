import Vision
import UIKit

struct QuickAnalysis {
    let labels: [String]
    let ocrText: String

    var formattedDescription: String {
        var parts: [String] = []
        if !labels.isEmpty {
            parts.append("Scene: \(labels.prefix(5).joined(separator: ", "))")
        }
        if !ocrText.isEmpty {
            parts.append("Text visible: \(ocrText)")
        }
        return parts.isEmpty ? "No details detected." : parts.joined(separator: ". ") + "."
    }
}

enum QuickVisionError: Error, LocalizedError {
    case invalidImage
    case analysisFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Could not read image data"
        case .analysisFailure(let msg): return msg
        }
    }
}

final class QuickVisionService {
    func analyze(image: UIImage) throws -> QuickAnalysis {
        guard let cgImage = image.cgImage else { throw QuickVisionError.invalidImage }

        var labels: [String] = []
        var ocrText = ""
        var classifyError: Error?
        var ocrError: Error?

        let group = DispatchGroup()

        // Classification
        group.enter()
        let classifyRequest = VNClassifyImageRequest { request, error in
            defer { group.leave() }
            if let error { classifyError = error; return }
            labels = (request.results as? [VNClassificationObservation])?
                .filter { $0.confidence > 0.3 }
                .prefix(8)
                .map { $0.identifier }
                ?? []
        }

        // OCR
        group.enter()
        let ocrRequest = VNRecognizeTextRequest { request, error in
            defer { group.leave() }
            if let error { ocrError = error; return }
            ocrText = (request.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
                ?? ""
        }
        ocrRequest.recognitionLevel = .accurate
        ocrRequest.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([classifyRequest, ocrRequest])
        group.wait()

        if let err = classifyError { throw QuickVisionError.analysisFailure(err.localizedDescription) }
        _ = ocrError // OCR failure is non-fatal

        return QuickAnalysis(labels: labels, ocrText: ocrText)
    }
}
