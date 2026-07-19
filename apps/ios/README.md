# apps/ios — arrives at milestone M1

The Xcode project lands here once a Mac is available. Planned shape:

```
Theseus.xcodeproj
  NavCore/            Swift package: line-by-line port of engine/
                      (tests ported first; must reproduce fixtures/golden hashes)
  Perception/         ARKit providers -> SpatialUpdate stream
    PlanePointProvider   (iPhone XR path: planes + filtered feature points)
    LiDARMeshProvider    (.meshWithClassification, 12 Pro+)
    DepthMLProvider      (M4: Core ML monocular depth pseudo-LiDAR)
    DetectionProvider    (M4: detection -> waypoint proposals)
  WorldStore/         ARWorldMap blob + sidecar (grid chunks, room graph,
                      waypoints keyed by anchor UUID)
  GuidanceKit/        cues -> CoreHaptics patterns, PHASE beacon, AVSpeech
  HUD/                SwiftUI + RealityKit diagnostic overlay
                      (grid decal, path tube, agent entity, A/B toggles)
  TraceRecorder/      on-device JSONL traces (same schema as the sim)
```

Concurrency: ARSession delegate → AsyncStream (coalesced ≤10 Hz) →
WorldModel actor → Planner actor (D* Lite) → cues at 15–30 Hz → MainActor
rendering. The camera/render loop never blocks on planning.

Capability detection at launch:

```swift
if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
    // LiDAR path
} else {
    // XR path: planes + points (+ DepthML from M4)
}
```

See docs/ARCHITECTURE.md §7–§9 for the full contracts.
