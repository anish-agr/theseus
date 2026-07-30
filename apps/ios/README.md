# apps/ios — the Theseus app (SwiftUI, iOS 17)

A home-inventory app with a spatial memory: scan a room with ARKit,
capture the things in it, let batch AI name and value everything, and
walk out with insurance dossiers, move-in/out condition evidence, and
QR-labeled storage boxes. Navigation (locate-in-camera, guidance,
measuring) is a supporting tool that lives in Tools — the *record* is
the product.

Built and shipped without a Mac: `project.yml` (XcodeGen) is the whole
project definition, `.github/workflows/ios.yml` compiles it on GitHub's
macOS runners into an unsigned `Theseus.ipa`, and AltServer sideloads
it onto the phone from Windows. Full install story: `docs/INSTALL.md`.

## Layout

```
Sources/
  TheseusApp.swift   entry point, SwiftData container, deep links
  AR/                ARSession lifecycle (30 Hz frame budget, pause when
                     not scanning — an A12 will thermal-throttle if you
                     let ARKit run at 60 fps forever), saliency subject
                     tracking, RealityKit overlay (cached meshes,
                     quantized rebuild keys)
  Nav/               bridge to the NavCore engine: occupancy ingest from
                     planes + feature points, pose publishing
                     (on-change only, never per-frame), A* locate hints
  Model/             SwiftData models (Thing, Room, StorageSpot,
                     ConditionRecord…) + blob store (LZFSE-compressed
                     ARWorldMaps, NSCache'd thumbnails)
  Intelligence/      the AI layer (Gemini/Claude/OpenAI-compatible with
                     a self-healing retry loop), Vision classifier +
                     OCR, receipt reader, voice control, PDF/ZIP
                     report builders, Spotlight indexing
  Brand/             the thread design system — launch ritual, loading
                     and success states (no spinners, no checkmarks)
  Views/             the five tabs: Home, Scan, Stuff, Rooms, Tools
```

## Rules the field tests wrote

These came from real scans on an iPhone XR and are enforced in code —
see the pedagogical comments at each site:

- **Scan completion is a state, never a percentage.** Raw coverage
  fractions stall around 77% and read as failure. Progress shows m².
- **A capture is never dropped** because a measurement failed. Photo +
  name are the product; size is a bonus.
- **Nothing interrupts a scan.** No naming popups, no live AI calls
  mid-scan; the ✨ batch pass identifies everything afterwards.
- **Capture is a lock-on**, not a hair trigger: 2.2 s dwell within ~5°,
  3 s cooldown, point away to re-arm.
- **Elevated horizontal planes (0.15–1.8 m) are obstacles.** Tables are
  invisible to a planner that only ingests the floor.
- **Publish pose on change (2 cm / 1° / 250 ms), not per frame** — one
  @Published at 60 Hz re-renders every subscribed view and turns the
  whole app choppy.
- **The minimap is one CGImage blit**, not thousands of Canvas paths.

## Building

Pushes to `main` that touch `apps/` build automatically. Locally
there's nothing to build on Windows — the Swift that *can* compile
here (the engine) lives in `apps/navcore` with its own test suite:

```
swift test --package-path apps/navcore
```
