// "Point at it long enough and it's remembered."
//
// Dwell: hold the reticle steady on something for ~1.2 s. Steadiness is
// measured by camera *rotation*, not position — you can walk toward an
// object while dwelling, but swinging the phone away restarts the ring.
//
// Capture: subject box -> classify/read/fingerprint -> measure physical
// size -> place on the floor plan -> merge-or-create a Thing.
//
// SIZE MEASUREMENT is the part worth reading. There is no depth sensor
// on an XR, so depth comes from ARKit's sparse feature points that fall
// inside the subject box (median, robust to the odd flyer), with a
// plane raycast as fallback. Then the pinhole relation converts the
// box's angular size into metres: extent = pixels * depth / focal.
// Everything is done in SENSOR space so the ARKit intrinsics apply
// directly; the portrait swap happens once, at the end.
import ARKit
import Foundation
import SwiftData
import SwiftUI
import Vision

struct CapturedObject {
    var recognition: RecognitionResult
    var worldX: Double          // floor-plan coords (x, -z)
    var worldY: Double
    var heightM: Double         // centre height above the floor
    var widthM: Double          // physical horizontal extent
    var physicalHeightM: Double // physical vertical extent
    var sizeConfidence: Double
    var depthM: Double
}

@MainActor
final class ObjectCapture: ObservableObject {
    /// 0-1 ring progress shown around the reticle.
    @Published var dwellProgress: Double = 0
    @Published var busy = false
    @Published var lastCaptured: Thing?
    @Published var hint: String = ""

    var dwellSeconds: Double = 1.2
    private var dwellAccum: Double = 0
    private var lastFrameTime: TimeInterval = 0
    private var dwellForward: SIMD3<Float>?
    private var cooldownUntil: Date = .distantPast

    /// Called every AR frame. Returns true when a capture should fire.
    func updateDwell(frame: ARFrame) -> Bool {
        guard !busy, Date() > cooldownUntil else {
            dwellProgress = 0
            return false
        }
        let now = frame.timestamp
        let dt = lastFrameTime == 0 ? 0 : min(0.1, now - lastFrameTime)
        lastFrameTime = now

        let t = frame.camera.transform
        let forward = simd_normalize(SIMD3<Float>(-t.columns.2.x,
                                                  -t.columns.2.y,
                                                  -t.columns.2.z))
        if let anchorForward = dwellForward {
            // ~7 degrees of swing resets the dwell
            if simd_dot(anchorForward, forward) < 0.992 {
                dwellForward = forward
                dwellAccum = 0
            }
        } else {
            dwellForward = forward
        }
        guard case .normal = frame.camera.trackingState else {
            dwellAccum = 0
            dwellProgress = 0
            hint = "Move slowly — tracking is limited"
            return false
        }
        dwellAccum += dt
        dwellProgress = min(1, dwellAccum / dwellSeconds)
        if dwellProgress >= 1 {
            dwellAccum = 0
            dwellForward = nil
            dwellProgress = 0
            cooldownUntil = Date().addingTimeInterval(0.8)
            return true
        }
        return false
    }

    func resetDwell() {
        dwellAccum = 0
        dwellProgress = 0
        dwellForward = nil
    }

    // ---- capture ---------------------------------------------------------

    /// Heavy work: Vision + geometry. Returns nil if the frame was
    /// unusable (no subject, no depth).
    nonisolated static func analyze(frame: ARFrame,
                                    floorY: Float) -> CapturedObject? {
        let buffer = frame.capturedImage
        let box = VisionPipeline.subjectBox(pixelBuffer: buffer)
        let recognition = VisionPipeline.analyze(pixelBuffer: buffer,
                                                 box: box)

        let camera = frame.camera
        let intrinsics = camera.intrinsics
        let fx = Double(intrinsics[0][0])
        let fy = Double(intrinsics[1][1])
        let cx = Double(intrinsics[2][0])
        let cy = Double(intrinsics[2][1])
        let imgW = Double(camera.imageResolution.width)
        let imgH = Double(camera.imageResolution.height)

        // --- depth + 3D centroid from feature points inside the box ---
        var depths: [Double] = []
        var points: [SIMD3<Float>] = []
        let inv = simd_inverse(camera.transform)
        if let cloud = frame.rawFeaturePoints {
            for p in cloud.points {
                let local = inv * SIMD4<Float>(p.x, p.y, p.z, 1)
                let depth = Double(-local.z)
                guard depth > 0.15, depth < 8 else { continue }
                let u = fx * (Double(local.x) / depth) + cx
                let v = fy * (Double(-local.y) / depth) + cy
                let nx = u / imgW
                let ny = 1 - v / imgH        // Vision y is up
                if box.contains(CGPoint(x: nx, y: ny)) {
                    depths.append(depth)
                    points.append(p)
                }
            }
        }

        // A missing measurement must never cost the capture itself: for
        // an inventory, the photo and the name ARE the product; size and
        // exact position are bonuses. Field-tested the strict version on
        // the XR — plain objects routinely have <5 feature points in the
        // box and the whole capture silently vanished. Never again.
        var depth: Double?
        var sizeConfidence = 0.0
        var centroid: SIMD3<Float>?
        if depths.count >= 4 {
            depth = median(depths)
            sizeConfidence = min(1.0, 0.42 + Double(depths.count) * 0.03)
            var sum = SIMD3<Float>(repeating: 0)
            for p in points { sum += p }
            centroid = sum / Float(points.count)
        } else if let hit = raycastDepth(frame: frame) {
            depth = hit
            sizeConfidence = 0.35     // plane hit, not the object itself
        }

        // --- pinhole: angular size at that depth -> metres -------------
        var widthM = 0.0
        var physicalHeightM = 0.0
        if let depth {
            let boxPxW = box.width * imgW      // along sensor x
            let boxPxH = box.height * imgH     // along sensor y
            let extentSensorX = boxPxW * depth / fx
            let extentSensorY = boxPxH * depth / fy
            // Portrait device: the sensor's x axis runs down the
            // screen, so on-screen width is the sensor-y extent.
            widthM = extentSensorY
            physicalHeightM = extentSensorX
            // implausible measurements are worse than none — drop the
            // SIZE, keep the capture
            if widthM < 0.005 || widthM > 4.0
                || physicalHeightM < 0.005 || physicalHeightM > 4.0 {
                widthM = 0
                physicalHeightM = 0
                sizeConfidence = 0
            }
        }

        // --- world placement -------------------------------------------
        // With no depth at all, place it ~0.9 m ahead (typical pointing
        // distance) at low confidence; a better re-look merges onto the
        // same Thing by fingerprint and pulls the pin to the truth.
        let placeDepth = depth ?? 0.9
        let world: SIMD3<Float>
        if let centroid {
            world = centroid
        } else {
            let t = camera.transform
            let fwd = simd_normalize(SIMD3<Float>(-t.columns.2.x,
                                                  -t.columns.2.y,
                                                  -t.columns.2.z))
            let origin = SIMD3<Float>(t.columns.3.x, t.columns.3.y,
                                      t.columns.3.z)
            world = origin + fwd * Float(placeDepth)
        }

        return CapturedObject(
            recognition: recognition,
            worldX: Double(world.x),
            worldY: Double(-world.z),          // floor-plan convention
            heightM: Double(world.y - floorY),
            widthM: widthM,
            physicalHeightM: physicalHeightM,
            sizeConfidence: sizeConfidence,
            depthM: depth ?? 0)
    }

    private nonisolated static func raycastDepth(frame: ARFrame) -> Double? {
        let query = frame.raycastQuery(
            from: CGPoint(x: 0.5, y: 0.5),
            allowing: .estimatedPlane, alignment: .any)
        // ARFrame.raycastQuery gives the query; the session performs it,
        // but hit-testing the frame directly avoids a session round-trip
        let results = frame.hitTest(CGPoint(x: 0.5, y: 0.5),
                                    types: [.existingPlaneUsingExtent,
                                            .estimatedHorizontalPlane,
                                            .featurePoint])
        _ = query
        guard let first = results.first else { return nil }
        let d = Double(first.distance)
        return d > 0.15 && d < 8 ? d : nil
    }

    private nonisolated static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    // ---- persistence ------------------------------------------------------

    /// Merge into an existing Thing when this is plainly the same object
    /// (same spot AND same visual fingerprint), otherwise create one.
    @discardableResult
    func commit(_ captured: CapturedObject, room: Room,
                context: ModelContext) -> Thing {
        let name = suggestedName(captured.recognition)
        if let existing = matchExisting(captured, room: room) {
            existing.hits += 1
            existing.confidence = min(6.0, existing.confidence + 1.0)
            existing.promoted = existing.confidence >= 2.0
            existing.lastSeenAt = Date()
            existing.isMissing = false
            let moved = hypot(existing.positionX - captured.worldX,
                              existing.positionY - captured.worldY) > 0.4
            // confidence-weighted position mean, same rule the engine's
            // registry uses, so repeated looks converge on the truth
            let w = existing.confidence
            existing.positionX = (existing.positionX * w + captured.worldX)
                / (w + 1)
            existing.positionY = (existing.positionY * w + captured.worldY)
                / (w + 1)
            if captured.sizeConfidence > existing.sizeConfidence {
                existing.widthM = captured.widthM
                existing.sizeHeightM = captured.physicalHeightM
                existing.sizeConfidence = captured.sizeConfidence
            }
            if !existing.userNamed,
               captured.recognition.confidence > existing.autoConfidence {
                existing.autoLabel = captured.recognition.label
                existing.autoConfidence = captured.recognition.confidence
                existing.displayName = name
            }
            let sighting = Sighting(positionX: captured.worldX,
                                    positionY: captured.worldY,
                                    confidence: existing.confidence,
                                    movedSincePrevious: moved)
            sighting.thing = existing
            context.insert(sighting)
            lastCaptured = existing
            SpotlightIndex.index(existing)
            return existing
        }

        let thing = Thing(
            displayName: name,
            autoLabel: captured.recognition.label,
            autoConfidence: captured.recognition.confidence,
            category: captured.recognition.category,
            positionX: captured.worldX,
            positionY: captured.worldY,
            heightM: captured.heightM,
            widthM: captured.widthM,
            sizeHeightM: captured.physicalHeightM,
            sizeConfidence: captured.sizeConfidence)
        // Naming cascade, step 2: when the classifier is unsure, check
        // whether this LOOKS like something the user already named —
        // every rename becomes training data. Step 1 was the classifier;
        // step 3 is text read off the object; only after all three fail
        // does the app ask.
        if captured.recognition.confidence < 0.45,
           let print = captured.recognition.featurePrint,
           let borrowed = ObjectCapture.borrowName(print: print,
                                                   context: context) {
            thing.displayName = borrowed
        }
        thing.recognizedText = captured.recognition.text
        thing.barcode = captured.recognition.barcode
        thing.featurePrint = captured.recognition.featurePrint
        thing.confidence = 1.0
        thing.hits = 1
        thing.promoted = true      // an explicit point IS the promotion
        thing.room = room
        context.insert(thing)

        let sighting = Sighting(positionX: captured.worldX,
                                positionY: captured.worldY,
                                confidence: 1.0,
                                movedSincePrevious: false)
        sighting.thing = thing
        context.insert(sighting)

        if let image = captured.recognition.image {
            Store.saveThumb(image, thingID: thing.id)
            if let embedding = EmbedderManager.shared.embedImage(image) {
                thing.clipEmbedding = embedding
            }
        }
        lastCaptured = thing
        SpotlightIndex.index(thing)
        return thing
    }

    private func matchExisting(_ captured: CapturedObject,
                               room: Room) -> Thing? {
        var best: Thing?
        var bestDistance = Float.greatestFiniteMagnitude
        for thing in room.things {
            let apart = hypot(thing.positionX - captured.worldX,
                              thing.positionY - captured.worldY)
            guard apart < 0.7 else { continue }
            guard let a = thing.featurePrint,
                  let b = captured.recognition.featurePrint,
                  let d = VisionPipeline.distance(a, b) else {
                // no fingerprints to compare: fall back to proximity +
                // matching label, which is how the engine's registry
                // has always merged
                if thing.autoLabel == captured.recognition.label,
                   apart < 0.4 {
                    return thing
                }
                continue
            }
            if d < bestDistance {
                bestDistance = d
                best = thing
            }
        }
        // Vision feature-print distances: < ~0.6 is "same object" in
        // practice for a re-look from a similar angle
        return bestDistance < 0.6 ? best : nil
    }

    /// Nearest-neighbour over the user's own named things: the personal
    /// classifier that gets smarter with every rename.
    private static func borrowName(print: Data,
                                   context: ModelContext) -> String? {
        let descriptor = FetchDescriptor<Thing>(
            predicate: #Predicate { $0.userNamed == true })
        guard let named = try? context.fetch(descriptor),
              !named.isEmpty else { return nil }
        var bestName: String?
        var bestDistance = Float.greatestFiniteMagnitude
        for candidate in named {
            guard let fp = candidate.featurePrint,
                  let d = VisionPipeline.distance(fp, print) else {
                continue
            }
            if d < bestDistance {
                bestDistance = d
                bestName = candidate.displayName
            }
        }
        // looser than the same-object merge threshold (0.6): borrowing
        // a NAME from a lookalike is cheap to correct, merging two
        // distinct objects is not
        return bestDistance < 0.75 ? bestName : nil
    }

    private func suggestedName(_ r: RecognitionResult) -> String {
        if !r.label.isEmpty, r.confidence > 0.2 {
            return r.label
        }
        // nothing confident? the text on the object is often the best
        // name a human would pick anyway ("NESCAFÉ", "IBUPROFEN")
        if !r.text.isEmpty {
            return String(r.text.prefix(28))
        }
        return "Unnamed object"
    }
}
