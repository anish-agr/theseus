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

@MainActor
final class ARSessionManager: NSObject, ObservableObject, ARSessionDelegate {
    weak var engine: NavEngine?
    var capture: ObjectCapture?

    @Published var relocalizing = false
    @Published var trackingState: String = "starting"
    @Published var floorFound = false
    /// Set when a dwell completes; ScanView consumes it.
    @Published var pendingCapture: CapturedObject?

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
        session?.run(configuration(worldMap: worldMap),
                     options: [.resetTracking, .removeExistingAnchors])
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

        // dwell -> capture (heavy Vision work off the main actor)
        if let capture, capture.updateDwell(frame: frame) {
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
                            "Couldn't measure that — move a little closer"
                    }
                }
            }
        }

        // ingest + engine tick at ~5 Hz
        guard frameCount % 12 == 0 else { return }
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
            for key in hits {
                var hist = hitHistory[key, default: []]
                hist.append(tick)
                hist.removeAll { tick - $0 >= 12 }
                hitHistory[key] = hist
                if hist.count >= 3 {
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
                // only the floor itself carves walkable space; a table
                // top is horizontal too and is emphatically not floor
                guard abs(y - floorY) < 0.15 else { continue }
                obs += rasterize(plane, transform: world, occupied: false,
                                 grid: engine.grid)
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
