import Vision
import UIKit

struct QuickAnalysis {
    var animals: [String] = []
    var faceCount: Int = 0
    var humanCount: Int = 0
    var ocrText: String = ""
    var sceneLabels: [String] = []
    var barcodes: [String] = []

    var structuredDescription: String {
        var parts: [String] = []
        if !animals.isEmpty {
            parts.append("Animals: \(animals.joined(separator: ", "))")
        }
        if faceCount > 0 {
            parts.append("\(faceCount) \(faceCount == 1 ? "person" : "people") with visible face")
        } else if humanCount > 0 {
            parts.append("\(humanCount) \(humanCount == 1 ? "person" : "people") in frame")
        }
        if !sceneLabels.isEmpty {
            parts.append("Scene: \(sceneLabels.joined(separator: ", "))")
        }
        if !ocrText.isEmpty {
            parts.append("Text visible: \(ocrText)")
        }
        if !barcodes.isEmpty {
            parts.append("Barcodes: \(barcodes.joined(separator: ", "))")
        }
        return parts.isEmpty ? "No specific subjects detected." : parts.joined(separator: ". ")
    }
}

final class QuickVisionService {
    func analyze(image: UIImage) throws -> QuickAnalysis {
        guard let cgImage = image.cgImage else { return QuickAnalysis() }

        var result = QuickAnalysis()
        let group = DispatchGroup()
        let handler = VNImageRequestHandler(cgImage: cgImage)

        // Animals
        let animalReq = VNRecognizeAnimalsRequest { req, _ in
            result.animals = (req.results as? [VNRecognizedObjectObservation])?
                .compactMap { $0.labels.first?.identifier }
                .map { $0.capitalized } ?? []
        }

        // Faces
        let faceReq = VNDetectFaceRectanglesRequest { req, _ in
            result.faceCount = (req.results as? [VNFaceObservation])?.count ?? 0
        }

        // Human bodies (catches people from behind)
        let humanReq = VNDetectHumanRectanglesRequest { req, _ in
            result.humanCount = (req.results as? [VNHumanObservation])?.count ?? 0
        }

        // OCR
        let ocrReq = VNRecognizeTextRequest { req, _ in
            result.ocrText = (req.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ") ?? ""
        }
        ocrReq.recognitionLevel = .accurate
        ocrReq.usesLanguageCorrection = true

        // Scene classification — high threshold, top 4 only
        let sceneReq = VNClassifyImageRequest { req, _ in
            result.sceneLabels = (req.results as? [VNClassificationObservation])?
                .filter { $0.confidence > 0.6 }
                .prefix(4)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") } ?? []
        }

        // Barcodes / QR codes
        let barcodeReq = VNDetectBarcodesRequest { req, _ in
            result.barcodes = (req.results as? [VNBarcodeObservation])?
                .compactMap { $0.payloadStringValue } ?? []
        }

        try handler.perform([animalReq, faceReq, humanReq, ocrReq, sceneReq, barcodeReq])

        return result
    }
}
