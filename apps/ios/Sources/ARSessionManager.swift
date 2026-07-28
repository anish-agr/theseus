// ARSessionManager — the perception provider for the no-LiDAR path
// (iPhone XR): horizontal plane anchors carve FREE floor, vertical
// planes and height-banded feature points mark OCCUPIED, a persistence
// filter keeps one noisy frame from inventing furniture. This is the
// on-device analog of the tested learning/depth_projection.py pipeline.
import ARKit
import Foundation
import NavCore
import RealityKit

final class ARSessionManager: NSObject, ARSessionDelegate {
    weak var engine: NavEngine?
    private(set) var floorY: Float = 0
    private var haveFloor = false
    private var frameCount = 0
    private var tick = 0
    // persistence: a cell must be point-hit in >= 3 of the last 12
    // ingest frames before it becomes an obstacle observation
    private var hitHistory: [Int32: [Int]] = [:]  // packed cell -> ticks

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        guard let engine else { return }

        // pose every frame (cheap), mapped ARKit -> floor plan
        let t = frame.camera.transform
        let px = Double(t.columns.3.x)
        let py = Double(-t.columns.3.z)
        let fwd = -t.columns.2
        let heading = atan2(Double(-fwd.z), Double(fwd.x))
        Task { @MainActor in
            engine.updatePose(x: px, y: py, heading: heading)
            engine.trackingLimited = !self.trackingNormal(frame.camera)
        }

        // ingest + tick at ~5 Hz (every 12th frame at 60 fps)
        guard frameCount % 12 == 0 else { return }
        tick += 1
        var obs: [(Cell, Bool)] = []

        // feature points: obstacle band vs floor band
        if haveFloor, let pts = frame.rawFeaturePoints {
            var hits = Set<Int32>()
            for p in pts.points {
                let h = p.y - floorY
                let wx = Double(p.x)
                let wy = Double(-p.z)
                let c = engine.grid.worldToCell(Vec(wx, wy))
                guard engine.grid.inBounds(c) else { continue }
                if h > 0.15 && h < 1.9 {
                    hits.insert(pack(c))
                } else if h > -0.1 && h < 0.1 {
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
        }

        let currentTick = tick
        Task { @MainActor in
            engine.observeCells(obs, tick: currentTick)
            engine.tick()
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        ingestPlanes(anchors)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        ingestPlanes(anchors)
    }

    private func ingestPlanes(_ anchors: [ARAnchor]) {
        guard let engine else { return }
        var obs: [(Cell, Bool)] = []
        for anchor in anchors {
            guard let plane = anchor as? ARPlaneAnchor else { continue }
            let world = anchor.transform
            if plane.alignment == .horizontal {
                let y = world.columns.3.y
                if !haveFloor || y < floorY - 0.05 {
                    floorY = y
                    haveFloor = true
                }
                // only the floor plane carves FREE space
                guard abs(y - floorY) < 0.15 else { continue }
                obs.append(contentsOf: rasterizePlane(
                    plane, transform: world, occupied: false,
                    grid: engine.grid))
            } else {
                obs.append(contentsOf: rasterizePlane(
                    plane, transform: world, occupied: true,
                    grid: engine.grid))
            }
        }
        if !obs.isEmpty {
            let currentTick = tick
            Task { @MainActor in
                engine.observeCells(obs, tick: currentTick)
            }
        }
    }

    /// Sample the plane's extent rectangle in its own frame and project
    /// each sample to the floor plan.
    private func rasterizePlane(_ plane: ARPlaneAnchor,
                                transform: simd_float4x4, occupied: Bool,
                                grid: OccupancyGrid) -> [(Cell, Bool)] {
        var out: [(Cell, Bool)] = []
        let ext = plane.planeExtent
        let step: Float = 0.05
        let cx = plane.center
        var u: Float = -ext.width / 2
        while u <= ext.width / 2 {
            var v: Float = -ext.height / 2
            while v <= ext.height / 2 {
                // extent rotation is about the plane's y axis
                let ru = u * cos(ext.rotationOnYAxis)
                    - v * sin(ext.rotationOnYAxis)
                let rv = u * sin(ext.rotationOnYAxis)
                    + v * cos(ext.rotationOnYAxis)
                let local = SIMD4<Float>(cx.x + ru, cx.y, cx.z + rv, 1)
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

    private func trackingNormal(_ camera: ARCamera) -> Bool {
        if case .normal = camera.trackingState {
            return true
        }
        return false
    }

    private func pack(_ c: Cell) -> Int32 {
        c.y &* 1024 &+ c.x
    }

    private func unpack(_ k: Int32) -> Cell {
        Cell(k % 1024, k / 1024)
    }
}
