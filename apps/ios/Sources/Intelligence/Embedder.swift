// Natural-language search seam.
//
// Vision (VisionPipeline) already names ~1,300 things, reads text off
// them and fingerprints them — that ships in the binary and works
// offline on an A12. What it cannot do is answer "the blue ceramic mug"
// for an object it never had a class for.
//
// CLIP does. It is behind this protocol because it is a ~60 MB download
// the user opts into, and everything else must keep working without it.
// Embeddings are stored per Thing when available, so installing the
// model later only requires re-embedding stored thumbnails, not
// re-scanning the house.
import CoreML
import Foundation
import UIKit

protocol TextImageEmbedder {
    var isReady: Bool { get }
    func embedImage(_ image: UIImage) -> [Float]?
    func embedText(_ text: String) -> [Float]?
}

enum EmbedderState: Equatable {
    case notInstalled
    case downloading(Double)
    case ready
    case failed(String)
}

/// Cosine similarity for unit-ish vectors; higher is more similar.
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    var na: Float = 0
    var nb: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    let denom = (na.squareRoot() * nb.squareRoot())
    return denom > 0 ? dot / denom : 0
}

func encodeEmbedding(_ v: [Float]) -> Data {
    v.withUnsafeBufferPointer { Data(buffer: $0) }
}

func decodeEmbedding(_ d: Data) -> [Float] {
    d.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Float.self))
    }
}

/// Manages the optional on-demand CLIP model. Until a model is
/// installed `isReady` is false and semantic search is hidden in the UI
/// rather than silently returning nothing.
@MainActor
final class EmbedderManager: ObservableObject {
    static let shared = EmbedderManager()

    @Published private(set) var state: EmbedderState = .notInstalled
    private var embedder: TextImageEmbedder?

    private var modelDir: URL {
        Store.root.appendingPathComponent("models", isDirectory: true)
    }

    var isReady: Bool { embedder?.isReady ?? false }

    private init() {
        loadIfPresent()
    }

    func loadIfPresent() {
        let imageModel = modelDir
            .appendingPathComponent("clip_image.mlmodelc")
        let textModel = modelDir
            .appendingPathComponent("clip_text.mlmodelc")
        guard FileManager.default.fileExists(atPath: imageModel.path),
              FileManager.default.fileExists(atPath: textModel.path)
        else {
            state = .notInstalled
            return
        }
        do {
            embedder = try CoreMLCLIPEmbedder(imageModelURL: imageModel,
                                              textModelURL: textModel)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func embedImage(_ image: UIImage) -> Data? {
        guard let v = embedder?.embedImage(image) else { return nil }
        return encodeEmbedding(v)
    }

    func embedText(_ text: String) -> [Float]? {
        embedder?.embedText(text)
    }
}

/// Core ML backed CLIP. Compiled models are expected at
/// models/clip_image.mlmodelc and models/clip_text.mlmodelc — the
/// download flow (Settings) fetches and compiles them.
final class CoreMLCLIPEmbedder: TextImageEmbedder {
    private let imageModel: MLModel
    private let textModel: MLModel

    var isReady: Bool { true }

    init(imageModelURL: URL, textModelURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all       // Neural Engine on A12
        imageModel = try MLModel(contentsOf: imageModelURL,
                                 configuration: config)
        textModel = try MLModel(contentsOf: textModelURL,
                                configuration: config)
    }

    func embedImage(_ image: UIImage) -> [Float]? {
        guard let buffer = image.pixelBuffer(width: 256, height: 256),
              let input = try? MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]),
              let out = try? imageModel.prediction(from: input)
        else { return nil }
        return firstVector(in: out)
    }

    func embedText(_ text: String) -> [Float]? {
        // Tokenization is model-specific; the download bundle ships the
        // vocabulary alongside the weights. Until that lands this
        // returns nil and the UI keeps semantic search hidden.
        _ = text
        return nil
    }

    private func firstVector(in provider: MLFeatureProvider) -> [Float]? {
        for name in provider.featureNames {
            guard let value = provider.featureValue(for: name),
                  let array = value.multiArrayValue else { continue }
            var out = [Float](repeating: 0, count: array.count)
            for i in 0..<array.count {
                out[i] = array[i].floatValue
            }
            return out
        }
        return nil
    }
}

extension UIImage {
    func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
              let cg = cgImage else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
