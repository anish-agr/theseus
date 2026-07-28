// The AR camera view plus world-space overlays: path breadcrumbs along
// the smoothed route, a goal pin, and the virtual agent. RealityKit
// entities are rebuilt when the route changes — dozens of small
// spheres, cheap enough for v0.
import ARKit
import NavCore
import RealityKit
import SwiftUI

struct ARViewContainer: UIViewRepresentable {
    @EnvironmentObject var engine: NavEngine
    let sessionManager: ARSessionManager

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.worldAlignment = .gravity
        view.session.delegate = sessionManager
        view.session.run(config)

        let overlay = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        overlay.name = "overlay"
        view.scene.addAnchor(overlay)
        context.coordinator.overlay = overlay
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        guard let overlay = context.coordinator.overlay else { return }
        let floorY = sessionManager.floorY
        context.coordinator.rebuild(
            overlay: overlay, path: engine.smoothedPath,
            goal: engine.goal, agent: engine.agentPos, floorY: floorY)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var overlay: AnchorEntity?
        private var lastKey = ""

        func rebuild(overlay: AnchorEntity, path: [Vec], goal: Vec?,
                     agent: Vec?, floorY: Float) {
            let key = "\(path.count)|\(String(describing: goal))|"
                + "\(String(describing: agent))"
            guard key != lastKey else { return }
            lastKey = key
            overlay.children.removeAll()

            // breadcrumbs every ~0.3 m along the smoothed path
            if path.count >= 2 {
                let mesh = MeshResource.generateSphere(radius: 0.035)
                let mat = SimpleMaterial(color: .cyan, isMetallic: false)
                var s = 0.0
                let total = polylineLength(path)
                while s < total {
                    let p = pointAlong(path, startI: 0, startT: 0.0,
                                       ahead: s)
                    let e = ModelEntity(mesh: mesh, materials: [mat])
                    e.position = SIMD3<Float>(
                        Float(p.x), floorY + 0.05, Float(-p.y))
                    overlay.addChild(e)
                    s += 0.3
                }
            }
            if let goal {
                let pin = ModelEntity(
                    mesh: MeshResource.generateBox(
                        width: 0.08, height: 0.5, depth: 0.08),
                    materials: [SimpleMaterial(color: .green,
                                               isMetallic: false)])
                pin.position = SIMD3<Float>(
                    Float(goal.x), floorY + 0.25, Float(-goal.y))
                overlay.addChild(pin)
            }
            if let agent {
                let bot = ModelEntity(
                    mesh: MeshResource.generateSphere(radius: 0.12),
                    materials: [SimpleMaterial(color: .orange,
                                               isMetallic: true)])
                bot.position = SIMD3<Float>(
                    Float(agent.x), floorY + 0.12, Float(-agent.y))
                overlay.addChild(bot)
            }
        }
    }
}
