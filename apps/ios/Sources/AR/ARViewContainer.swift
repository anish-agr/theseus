// The AR camera view plus world-space overlays: breadcrumbs along the
// route, a destination pin, and small markers on remembered objects so
// you can see your inventory in place. Entities are rebuilt only when
// the content key changes — dozens of small meshes, cheap for v0.
import ARKit
import NavCore
import RealityKit
import SwiftUI

struct ARViewContainer: UIViewRepresentable {
    @EnvironmentObject var engine: NavEngine
    let sessionManager: ARSessionManager
    var thingPins: [(id: UUID, x: Double, y: Double, height: Double)] = []

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        sessionManager.attach(view.session)
        view.session.run(sessionManager.configuration())
        let overlay = AnchorEntity(world: .zero)
        overlay.name = "overlay"
        view.scene.addAnchor(overlay)
        context.coordinator.overlay = overlay
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        guard let overlay = context.coordinator.overlay else { return }
        context.coordinator.rebuild(
            overlay: overlay, path: engine.smoothedPath,
            goal: engine.goal, pins: thingPins,
            floorY: sessionManager.floorY)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var overlay: AnchorEntity?
        private var lastKey = ""

        func rebuild(overlay: AnchorEntity, path: [Vec], goal: Vec?,
                     pins: [(id: UUID, x: Double, y: Double,
                             height: Double)],
                     floorY: Float) {
            let key = "\(path.count)|\(path.last?.x ?? 0)|"
                + "\(goal?.x ?? 0),\(goal?.y ?? 0)|\(pins.count)"
            guard key != lastKey else { return }
            lastKey = key
            overlay.children.removeAll()

            if path.count >= 2 {
                let mesh = MeshResource.generateSphere(radius: 0.035)
                let mat = SimpleMaterial(color: .cyan, isMetallic: false)
                let total = polylineLength(path)
                var s = 0.0
                while s < total {
                    let p = pointAlong(path, startI: 0, startT: 0,
                                       ahead: s)
                    let e = ModelEntity(mesh: mesh, materials: [mat])
                    e.position = SIMD3<Float>(Float(p.x), floorY + 0.05,
                                              Float(-p.y))
                    overlay.addChild(e)
                    s += 0.3
                }
            }
            if let goal {
                let pin = ModelEntity(
                    mesh: MeshResource.generateBox(width: 0.07,
                                                   height: 0.5,
                                                   depth: 0.07),
                    materials: [SimpleMaterial(color: .green,
                                               isMetallic: false)])
                pin.position = SIMD3<Float>(Float(goal.x), floorY + 0.25,
                                            Float(-goal.y))
                overlay.addChild(pin)
            }
            // remembered objects, floating where they were logged
            let pinMesh = MeshResource.generateSphere(radius: 0.045)
            let pinMat = SimpleMaterial(color: .systemYellow,
                                        isMetallic: false)
            for pin in pins.prefix(120) {
                let e = ModelEntity(mesh: pinMesh, materials: [pinMat])
                e.position = SIMD3<Float>(
                    Float(pin.x), floorY + Float(max(0.05, pin.height)),
                    Float(-pin.y))
                overlay.addChild(e)
            }
        }
    }
}
