// On-device recognition for a single captured frame region.
//
// Everything here is Apple's Vision framework: no bundled model, no
// network, ~1,300 classes instead of COCO's 80, plus text, barcodes and
// a visual fingerprint that can re-identify THAT specific object later.
// The CLIP embedder (Embedder.swift) layers natural-language search on
// top of this; it is optional and this pipeline never waits for it.
//
// Coordinate discipline (the part that silently breaks if you're
// careless): geometry requests run on the raw sensor buffer with
// orientation .up, so every box comes back in sensor-normalized coords
// that map straight onto the ARKit camera intrinsics. Label requests
// run with orientation .right (upright for a portrait device) because
// classification and OCR care which way up the world is — and we only
// consume their text, never their coordinates.
import CoreImage
import Foundation
import UIKit
import Vision

struct RecognitionResult {
    var label: String = ""
    var confidence: Double = 0
    var category: String = "object"
    var text: String = ""
    var barcode: String?
    var featurePrint: Data?
    /// Bounding box of the subject, sensor-normalized (origin bottom-left).
    var box: CGRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
    var image: UIImage?
}

enum VisionPipeline {
    private static let ciContext = CIContext(options: nil)

    /// Categories we never want as an object name — they describe the
    /// scene, not a thing you'd go find.
    private static let sceneWords: Set<String> = [
        "indoor", "outdoor", "room", "interior", "floor", "wall",
        "ceiling", "structure", "material", "surface", "light",
        "architecture", "building", "home", "house", "furniture_room",
    ]

    /// Find the subject the user is pointing at: the salient region
    /// nearest the reticle (screen centre), falling back to a centred
    /// box when saliency finds nothing.
    static func subjectBox(pixelBuffer: CVPixelBuffer) -> CGRect {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up)
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let fallback = CGRect(x: 0.32, y: 0.32, width: 0.36, height: 0.36)
        do {
            try handler.perform([request])
        } catch {
            return fallback
        }
        guard let obs = request.results?.first as? VNSaliencyImageObservation,
              let objects = obs.salientObjects, !objects.isEmpty else {
            return fallback
        }
        let centre = CGPoint(x: 0.5, y: 0.5)
        // prefer a salient box that actually contains the reticle;
        // otherwise the one whose centre is closest to it
        let containing = objects.filter { $0.boundingBox.contains(centre) }
        let pool = containing.isEmpty ? objects : containing
        let best = pool.min { a, b in
            hypot(a.boundingBox.midX - 0.5, a.boundingBox.midY - 0.5)
                < hypot(b.boundingBox.midX - 0.5, b.boundingBox.midY - 0.5)
        }
        guard var box = best?.boundingBox else { return fallback }
        // saliency boxes hug tightly; pad a little so the crop reads well
        box = box.insetBy(dx: -box.width * 0.06, dy: -box.height * 0.06)
        return box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Classify / read / fingerprint the cropped subject.
    static func analyze(pixelBuffer: CVPixelBuffer,
                        box: CGRect) -> RecognitionResult {
        var out = RecognitionResult()
        out.box = box

        let full = CIImage(cvPixelBuffer: pixelBuffer)
        let w = full.extent.width
        let h = full.extent.height
        // Vision normalized (y up) -> CoreImage pixel rect (y up too)
        let cropRect = CGRect(x: box.minX * w, y: box.minY * h,
                              width: box.width * w, height: box.height * h)
            .integral
            .intersection(full.extent)
        guard !cropRect.isNull, cropRect.width > 16, cropRect.height > 16
        else {
            return out
        }
        let cropped = full.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX,
                                               y: -cropRect.minY))
        // portrait device: sensor is landscape, rotate for upright labels
        let upright = cropped.oriented(.right)
        guard let cg = ciContext.createCGImage(upright,
                                               from: upright.extent) else {
            return out
        }
        out.image = UIImage(cgImage: cg)

        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        let barcodes = VNDetectBarcodesRequest()
        let print = VNGenerateImageFeaturePrintRequest()

        try? handler.perform([classify, text, barcodes, print])

        if let results = classify.results {
            let usable = results
                .filter { $0.confidence > 0.12 }
                .filter { !sceneWords.contains($0.identifier.lowercased()) }
                .sorted { $0.confidence > $1.confidence }
            if let top = usable.first {
                out.label = prettify(top.identifier)
                out.confidence = Double(top.confidence)
                out.category = usable.dropFirst().first
                    .map { prettify($0.identifier) } ?? out.label
            }
        }
        if let lines = text.results {
            out.text = lines
                .compactMap { $0.topCandidates(1).first?.string }
                .filter { $0.count >= 2 }
                .prefix(4)
                .joined(separator: " ")
        }
        if let code = barcodes.results?.first?.payloadStringValue {
            out.barcode = code
        }
        if let fp = print.results?.first as? VNFeaturePrintObservation {
            // archive the OBSERVATION, not its raw descriptor: only a
            // rehydrated observation can computeDistance(_:to:)
            out.featurePrint = try? NSKeyedArchiver.archivedData(
                withRootObject: fp, requiringSecureCoding: true)
        }
        return out
    }

    /// Distance between two stored feature prints; smaller is more
    /// similar. Used to recognise the same physical object again.
    static func distance(_ a: Data, _ b: Data) -> Float? {
        guard let obsA = featurePrint(from: a),
              let obsB = featurePrint(from: b) else { return nil }
        var d = Float.greatestFiniteMagnitude
        try? obsA.computeDistance(&d, to: obsB)
        return d
    }

    private static func featurePrint(
        from data: Data) -> VNFeaturePrintObservation? {
        // A feature print observation round-trips through secure coding.
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self, from: data)
    }

    /// Vision identifiers look like "coffee_mug"; humans don't.
    static func prettify(_ identifier: String) -> String {
        let spaced = identifier
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
