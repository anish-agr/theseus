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
    var thingPins: [(id: UUID, x: Double, y: Double, height: Double,
                     highlighted: Bool)] = []

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
                             height: Double, highlighted: Bool)],
                     floorY: Float) {
            // include floorY: entities placed before the floor was
            // found would otherwise float at the wrong height forever
            let litID = pins.first(where: \.highlighted)?.id
            let key = "\(path.count)|\(path.last?.x ?? 0)|"
                + "\(goal?.x ?? 0),\(goal?.y ?? 0)|\(pins.count)|"
                + "\(floorY)|\(litID?.uuidString ?? "-")"
            guard key != lastKey else { return }
            lastKey = key
            overlay.children.removeAll()

            if path.count >= 2 {
                let mesh = MeshResource.generateSphere(radius: 0.035)
                // route dots wear the brand thread blue (#33A8FF)
                let mat = SimpleMaterial(
                    color: UIColor(red: 0.2, green: 0.66, blue: 1,
                                   alpha: 1),
                    isMetallic: false)
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
            // brand colors in world space: warm destination white,
            // used sparingly — field test 2 called the old fat green
            // beacon and chunky yellow spheres "big and ugly"
            let warm = UIColor(red: 1.0, green: 0.965, blue: 0.91,
                               alpha: 1)
            if let goal {
                let pin = ModelEntity(
                    mesh: MeshResource.generateBox(
                        width: 0.02, height: 0.7, depth: 0.02,
                        cornerRadius: 0.01),
                    materials: [SimpleMaterial(color: warm,
                                               isMetallic: false)])
                pin.position = SIMD3<Float>(Float(goal.x), floorY + 0.35,
                                            Float(-goal.y))
                overlay.addChild(pin)
            }
            // remembered objects wear tiny warm dots — quiet marks of
            // "this is in your memory", not traffic cones. The located
            // thing gets a slim light-pillar plus a small dot at its
            // own height.
            let pinMesh = MeshResource.generateSphere(radius: 0.014)
            let pinMat = SimpleMaterial(
                color: warm.withAlphaComponent(0.75),
                isMetallic: false)
            for pin in pins.prefix(120) {
                if pin.highlighted {
                    let beacon = ModelEntity(
                        mesh: MeshResource.generateBox(
                            width: 0.016, height: 1.5, depth: 0.016,
                            cornerRadius: 0.008),
                        materials: [SimpleMaterial(
                            color: warm.withAlphaComponent(0.9),
                            isMetallic: false)])
                    beacon.position = SIMD3<Float>(
                        Float(pin.x), floorY + 0.75, Float(-pin.y))
                    overlay.addChild(beacon)
                    let orb = ModelEntity(
                        mesh: MeshResource.generateSphere(
                            radius: 0.04),
                        materials: [SimpleMaterial(
                            color: warm, isMetallic: false)])
                    orb.position = SIMD3<Float>(
                        Float(pin.x),
                        floorY + Float(max(0.15, pin.height)),
                        Float(-pin.y))
                    overlay.addChild(orb)
                } else {
                    let e = ModelEntity(mesh: pinMesh,
                                        materials: [pinMat])
                    e.position = SIMD3<Float>(
                        Float(pin.x),
                        floorY + Float(max(0.05, pin.height)),
                        Float(-pin.y))
                    overlay.addChild(e)
                }
            }
        }
    }
}
