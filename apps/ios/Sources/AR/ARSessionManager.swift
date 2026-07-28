// The perception provider for the no-LiDAR path (iPhone XR).
//
// Floor and vertical plane anchors carve free space and walls; feature
// points in the 0.15-1.9 m height band become obstacles, but only after
// a persistence filter sees them repeatedly — one noisy frame must not
// invent furniture. This is the on-device analogue of the pipeline
// validated offline in learning/depth_projection.py.
//
// It also owns room persistence: saving an ARWorldMap on finish and
// reloading it to relocalize when you walk back in.
import ARKit
import Combine
import Foundation
import NavCore
import UIKit

/// Touched only on ARKit's serial delegate queue: every SECOND camera
/// frame is forwarded to the main actor. 30 Hz is indistinguishable
/// for pose/dwell and halves the per-frame main-thread work — the
/// camera-side stutter of field test 5 was this hop at 60 Hz.
private var frameDecimator = 0

@MainActor
final class ARSessionManager: NSObject, ObservableObject, ARSessionDelegate {
    weak var engine: NavEngine?
    var capture: ObjectCapture?

    @Published var relocalizing = false
    @Published var trackingState: String = "starting"
    @Published var floorFound = false
    /// Set when a dwell completes; ScanView consumes it.
    @Published var pendingCapture: CapturedObject?
    /// The lock-on frame: screen-space rect of the object the camera
    /// is actually looking at (saliency, ~5 Hz), nil when there isn't
    /// one. The dwell only arms while this is fresh — that is what
    /// stops captures of walls and things off to the side.
    @Published var subjectBox: CGRect?
    private var subjectAt = Date.distantPast
    private var saliencyBusy = false

    var subjectFresh: Bool {
        subjectBox != nil && Date().timeIntervalSince(subjectAt) < 0.9
    }

    private(set) var floorY: Float = 0
    private(set) var session: ARSession?

    private var frameCount = 0
    private var tick = 0
    private var hitHistory: [Int64: [Int]] = [:]

    // ---- session lifecycle -----------------------------------------------

    func attach(_ session: ARSession) {
        self.session = session
        session.delegate = self
    }

    func configuration(worldMap: ARWorldMap? = nil)
        -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.worldAlignment = .gravity
        config.environmentTexturing = .none
        // LiDAR phones (12 Pro+) get dense mesh reconstruction — the
        // map fills in near-instantly and far more accurately. The XR
        // path below (planes + feature points) remains the baseline.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if let worldMap {
            config.initialWorldMap = worldMap
            relocalizing = true
        }
        return config
    }

    private(set) var activeRoomID: UUID?

    /// Switch the AR session to a room. No-op when it's already active,
    /// so tab hopping never resets tracking mid-scan.
    func activateRoom(id: UUID, worldMap: ARWorldMap?) {
        guard activeRoomID != id else { return }
        activeRoomID = id
        restart(worldMap: worldMap)
    }

    func restart(worldMap: ARWorldMap?) {
        hitHistory.removeAll()
        floorFound = false
        tick = 0
        paused = false
        session?.run(configuration(worldMap: worldMap),
                     options: [.resetTracking, .removeExistingAnchors])
    }

    // ---- thermal discipline ----------------------------------------------
    // The camera + tracking pipeline at 60 fps cooks an A12 in minutes;
    // field test 4's "glitchy until you restart the app" was thermal
    // throttling from the session running forever, even in other tabs.
    // Pause whenever the scanner isn't on screen; resume continues the
    // same session (no reset), so the map and tracking survive.

    private(set) var paused = false

    func pauseSession() {
        guard !paused else { return }
        paused = true
        session?.pause()
        subjectBox = nil
    }

    func resumeSession() {
        guard paused, let session else { return }
        paused = false
        session.run(configuration())
    }

    /// Save the current map for this room, reporting honestly whether
    /// it worked (ARKit refuses before it has mapped enough).
    func saveWorldMap(roomID: UUID,
                      completion: @escaping (Bool) -> Void) {
        guard let session else {
            completion(false)
            return
        }
        session.getCurrentWorldMap { map, _ in
            guard let map else {
                Task { @MainActor in completion(false) }
                return
            }
            let ok = (try? Store.saveWorldMap(map, roomID: roomID)) != nil
            Task { @MainActor in completion(ok) }
        }
    }

    // ---- ARSessionDelegate ------------------------------------------------

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameDecimator += 1
        guard frameDecimator % 2 == 0 else { return }
        Task { @MainActor in self.handle(frame: frame) }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        Task { @MainActor in self.ingestPlanes(anchors) }
    }

    nonisolated func session(_ session: ARSession,
                             didUpdate anchors: [ARAnchor]) {
        Task { @MainActor in self.ingestPlanes(anchors) }
    }

    private func handle(frame: ARFrame) {
        frameCount += 1
        guard let engine else { return }

        // pose every frame (cheap): ARKit -> floor-plan coords
        let t = frame.camera.transform
        let px = Double(t.columns.3.x)
        let py = Double(-t.columns.3.z)
        let fwd = -t.columns.2
        let heading = atan2(Double(-fwd.z), Double(fwd.x))
        engine.updatePose(x: px, y: py, heading: heading)

        switch frame.camera.trackingState {
        case .normal:
            trackingState = "normal"
            engine.trackingLimited = false
            if relocalizing { relocalizing = false }
        case .limited(let reason):
            engine.trackingLimited = true
            switch reason {
            case .initializing: trackingState = "starting up"
            case .relocalizing: trackingState = "finding the room"
            case .excessiveMotion: trackingState = "slow down"
            case .insufficientFeatures:
                trackingState = "needs more light or detail"
            @unknown default: trackingState = "limited"
            }
        case .notAvailable:
            trackingState = "unavailable"
            engine.trackingLimited = true
        }

        // dwell -> capture (heavy Vision work off the main actor).
        // Gated on the floor: without it, object heights and floor-plan
        // positions would be garbage.
        if let capture, !floorFound {
            capture.resetDwell()
            capture.hint = "Point at the floor first so Theseus can find it"
        } else if let capture {
            if capture.hint.hasPrefix("Point at the floor") {
                capture.hint = ""
            }
            // dwell capture can be turned off entirely in Settings —
            // the shutter and voice still work. It also only arms
            // while the lock-on frame sees an actual subject.
            let dwellOn = UserDefaults.standard
                .object(forKey: "dwellCapture") as? Bool ?? true
            if dwellOn, subjectFresh,
               capture.updateDwell(frame: frame) {
                fire(frame: frame, capture: capture)
            } else if !dwellOn || !subjectFresh {
                capture.dwellProgress = 0
            }
        }

        // the lock-on frame: saliency at ~2.5 Hz (any faster just adds
        // heat), off the main actor, offset from the ingest tick
        if frameCount % 12 == 3, floorFound, !saliencyBusy,
           capture?.busy != true {
            saliencyBusy = true
            let buffer = frame.capturedImage
            let viewport = UIScreen.main.bounds.size
            let transform = frame.displayTransform(
                for: .portrait, viewportSize: viewport)
            Task.detached(priority: .utility) { [weak self] in
                let vision = VisionPipeline.subjectBoxStrict(
                    pixelBuffer: buffer)
                let rect: CGRect? = vision.flatMap { v in
                    // Vision (origin bottom-left, y up) → ARKit image
                    // coords (top-left) → display transform → screen
                    let img = CGRect(x: v.minX, y: 1 - v.maxY,
                                     width: v.width, height: v.height)
                    let a = img.origin.applying(transform)
                    let b = CGPoint(x: img.maxX, y: img.maxY)
                        .applying(transform)
                    let x0 = min(a.x, b.x) * viewport.width
                    let y0 = min(a.y, b.y) * viewport.height
                    let x1 = max(a.x, b.x) * viewport.width
                    let y1 = max(a.y, b.y) * viewport.height
                    var out = CGRect(x: x0, y: y0, width: x1 - x0,
                                     height: y1 - y0)
                    // a frame swallowing most of the screen isn't a
                    // lock, it's saliency shrugging — treat as none
                    // (field test 5: "usually just a big box")
                    guard out.width < viewport.width * 0.72,
                          out.height < viewport.height * 0.58 else {
                        return nil
                    }
                    out = out.insetBy(dx: out.width * 0.04,
                                      dy: out.height * 0.04)
                    // quantize: a jittering frame reads as noise
                    return CGRect(x: (out.minX / 6).rounded() * 6,
                                  y: (out.minY / 6).rounded() * 6,
                                  width: (out.width / 6).rounded() * 6,
                                  height: (out.height / 6).rounded()
                                      * 6)
                }
                await MainActor.run {
                    guard let self else { return }
                    self.saliencyBusy = false
                    if let rect {
                        self.subjectBox = rect
                        self.subjectAt = Date()
                    } else {
                        self.subjectBox = nil
                    }
                }
            }
        }

        // ingest + engine tick at ~5 Hz (handle runs at 30 Hz)
        guard frameCount % 6 == 0 else { return }
        tick += 1
        var obs: [(Cell, Bool)] = []

        if floorFound, let cloud = frame.rawFeaturePoints {
            var hits = Set<Int64>()
            for p in cloud.points {
                let h = p.y - floorY
                let c = engine.grid.worldToCell(
                    Vec(Double(p.x), Double(-p.z)))
                guard engine.grid.inBounds(c) else { continue }
                if h > 0.15 && h < 1.9 {
                    hits.insert(pack(c))
                } else if h > -0.08 && h < 0.08 {
                    obs.append((c, false))
                }
            }
            // Sparse clouds (plain walls, low light — common on the XR)
            // rarely hit the same cell 3 times before the window slides
            // past, which under-detected obstacles in the first field
            // test. Two hits is still two independent observations.
            let needed = hits.count < 60 ? 2 : 3
            for key in hits {
                var hist = hitHistory[key, default: []]
                hist.append(tick)
                hist.removeAll { tick - $0 >= 12 }
                hitHistory[key] = hist
                if hist.count >= needed {
                    obs.append((unpack(key), true))
                }
            }
            if hitHistory.count > 20000 {
                hitHistory = hitHistory.filter { !$0.value.isEmpty }
            }
        }

        engine.observeCells(obs, tick: tick)
        engine.tick()
    }

    /// The shutter button: same pipeline as a completed dwell, fired
    /// deliberately. Backup for when holding steady is awkward.
    func captureNow() {
        guard let capture, !capture.busy, floorFound,
              let frame = session?.currentFrame else { return }
        capture.resetDwell()
        fire(frame: frame, capture: capture)
    }

    private func fire(frame: ARFrame, capture: ObjectCapture) {
        capture.busy = true
        let floor = floorY
        Task.detached(priority: .userInitiated) {
            let result = ObjectCapture.analyze(frame: frame,
                                               floorY: floor)
            await MainActor.run {
                capture.busy = false
                if let result {
                    self.pendingCapture = result
                } else {
                    capture.hint =
                        "Couldn't see that — try the shutter button"
                }
            }
        }
    }

    private func ingestPlanes(_ anchors: [ARAnchor]) {
        guard let engine else { return }
        var obs: [(Cell, Bool)] = []
        for anchor in anchors {
            if let mesh = anchor as? ARMeshAnchor {
                obs += ingestMesh(mesh, grid: engine.grid)
                continue
            }
            guard let plane = anchor as? ARPlaneAnchor else { continue }
            let world = anchor.transform
            if plane.alignment == .horizontal {
                let y = world.columns.3.y
                if !floorFound || y < floorY - 0.05 {
                    floorY = y
                    floorFound = true
                }
                let h = y - floorY
                if abs(h) < 0.15 {
                    // the floor itself carves walkable space
                    obs += rasterize(plane, transform: world,
                                     occupied: false, grid: engine.grid)
                } else if floorFound, h > 0.15, h < 1.8 {
                    // An elevated horizontal plane is a tabletop, seat
                    // or shelf — a real obstacle you would walk into.
                    // (First field test: tables were invisible because
                    // this branch didn't exist.) Ceilings are excluded.
                    obs += rasterize(plane, transform: world,
                                     occupied: true, grid: engine.grid)
                }
            } else {
                obs += rasterize(plane, transform: world, occupied: true,
                                 grid: engine.grid)
            }
        }
        if !obs.isEmpty {
            engine.observeCells(obs, tick: tick)
        }
    }

    private func rasterize(_ plane: ARPlaneAnchor,
                           transform: simd_float4x4, occupied: Bool,
                           grid: OccupancyGrid) -> [(Cell, Bool)] {
        var out: [(Cell, Bool)] = []
        let ext = plane.planeExtent
        let step: Float = 0.05
        let centre = plane.center
        let cosR = cos(ext.rotationOnYAxis)
        let sinR = sin(ext.rotationOnYAxis)
        var u = -ext.width / 2
        while u <= ext.width / 2 {
            var v = -ext.height / 2
            while v <= ext.height / 2 {
                let ru = u * cosR - v * sinR
                let rv = u * sinR + v * cosR
                let local = SIMD4<Float>(centre.x + ru, centre.y,
                                         centre.z + rv, 1)
                let w = transform * local
                let c = grid.worldToCell(Vec(Double(w.x), Double(-w.z)))
                if grid.inBounds(c) {
                    out.append((c, occupied))
                }
                v += step
            }
            u += step
        }
        return out
    }

    /// LiDAR mesh vertices, height-banded like feature points but
    /// trusted immediately — dense depth doesn't need the persistence
    /// filter that sparse, noisy points do. Sampled to bound cost.
    private func ingestMesh(_ mesh: ARMeshAnchor,
                            grid: OccupancyGrid) -> [(Cell, Bool)] {
        guard floorFound else { return [] }
        var out: [(Cell, Bool)] = []
        let verts = mesh.geometry.vertices
        let transform = mesh.transform
        let count = verts.count
        guard count > 0 else { return out }
        let step = max(1, count / 300)
        let base = verts.buffer.contents().advanced(by: verts.offset)
        for i in stride(from: 0, to: count, by: step) {
            let p = base.advanced(by: i * verts.stride)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            let w = transform * SIMD4<Float>(p.x, p.y, p.z, 1)
            let h = w.y - floorY
            let c = grid.worldToCell(Vec(Double(w.x), Double(-w.z)))
            guard grid.inBounds(c) else { continue }
            if h > 0.15 && h < 1.9 {
                out.append((c, true))
            } else if h > -0.08 && h < 0.08 {
                out.append((c, false))
            }
        }
        return out
    }

    private func pack(_ c: Cell) -> Int64 {
        Int64(c.y) * 4096 + Int64(c.x)
    }

    private func unpack(_ k: Int64) -> Cell {
        Cell(Int32(k % 4096), Int32(k / 4096))
    }
}
