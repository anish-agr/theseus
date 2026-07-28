# Requirements

The single flat list. Written retroactively 2026-07-28 (the product
grew before the paperwork did) and forward-binding from here: a change
to behaviour is a change to this file. Rationale lives in PRD.md;
screens in UX.md; storage in DATA-MODEL.md.

Legend: ✅ implemented · 🧪 implemented, not yet field-validated ·
📋 specified, not built · 💤 deferred.

## FR-1 Mapping

- **FR-1.1** 🧪 The app SHALL build a top-down occupancy map of a room
  from a handheld iPhone **without LiDAR** (planes + filtered feature
  points).
- **FR-1.2** ✅ Cells SHALL use bounded log-odds so a moved obstacle is
  forgotten after ~3 contrary observations.
- **FR-1.3** ✅ Unknown space SHALL be untraversable for guidance;
  mapping-mode planning MAY opt in.
- **FR-1.4** 🧪 Sparse obstacle evidence SHALL pass a persistence
  filter (≥3 hits in 12 ingest frames) before becoming occupied.
- **FR-1.5** 🧪 On LiDAR hardware the app SHALL use dense scene-mesh
  reconstruction automatically; mesh evidence bypasses FR-1.4.
- **FR-1.6** 🧪 The scanner SHALL show live coverage (% of reachable
  floor) and direct the user toward unmapped frontier.
- **FR-1.7** 🧪 A room's map SHALL persist (grid + ARWorldMap) and
  reload when the room is reopened, relocalizing automatically.
- **FR-1.8** ✅ Only the true floor plane carves walkable space; other
  horizontal planes (tables) SHALL NOT.

## FR-2 Object capture

- **FR-2.1** 🧪 Holding the aim reticle steady on an object for ~1.2 s
  SHALL capture it, with no button press. Swinging the phone > ~7°
  resets the dwell; walking toward the object does not.
- **FR-2.2** 🧪 Capture SHALL NOT fire before the floor is detected.
- **FR-2.3** 🧪 Each capture SHALL record: cropped photo, classifier
  label + confidence, text read off the object, barcode when present,
  visual fingerprint, floor-plan position, height, and **measured
  physical size (W × H)** with a confidence.
- **FR-2.4** 🧪 Size SHALL come from the subject's angular extent and
  the median depth of feature points inside its box; plane-raycast
  fallback is marked "rough". Implausible sizes (<5 mm, >4 m) are
  rejected.
- **FR-2.5** 🧪 Naming SHALL cascade, asking the user ONLY as the last
  resort: (1) classifier ≈1,300 categories → (2) visual match against
  things the user already named ("looks like your charging brick") →
  (3) text on the object → (4) prompt the user once.
- **FR-2.6** ✅ A user-entered name SHALL permanently outrank any
  automatic label.
- **FR-2.7** 🧪 A re-sighting of the same physical object (near-by AND
  fingerprint-matched) SHALL merge, converging its position, not
  duplicate. Name-borrowing (FR-2.5·2) uses a looser threshold than
  merging, because a wrong name is cheap and a wrong merge is not.
- **FR-2.8** ✅ Every observation SHALL append a Sighting (when +
  where + moved-flag) — the object's history.

## FR-3 Inventory & search

- **FR-3.1** ✅ All things SHALL be browsable per room and globally,
  with photo, size, room and last-seen.
- **FR-3.2** 🧪 Search SHALL be forgiving: question filler stripped
  ("where are my keys"), prefix/typo tolerance ("mugg"), and on-device
  word-vector synonyms ("sofa" finds "couch"). Exact-name hits rank
  first, then labels, then text-on-object.
- **FR-3.3** ✅ Filters: by room, missing, recently moved.
- **FR-3.4** ✅ Thing detail SHALL show photo, size (± quality note),
  positions on the floor plan, first/last seen, text found, sighting
  history, rename and delete.
- **FR-3.5** 📋 Natural-language description search ("blue ceramic
  mug") via optional on-demand CLIP model; UI hides semantic search
  until the model is installed.
- **FR-3.6** 📋 Export a room or home as JSON + photos (insurance /
  moving).

## FR-4 Finding & guidance

- **FR-4.1** ✅ "Take me there" from any thing SHALL plan an optimal
  route on the canonical cost model and guide with full-screen arrow,
  distance, voice (phone speaker — no headphones required) and
  haptics whose intensity rises as the corridor narrows.
- **FR-4.2** ✅ World changes SHALL reroute incrementally (D* Lite) in
  milliseconds, not via full replans.
- **FR-4.3** ✅ Off-route SHALL turn the screen red, say "stop", and
  replan from the user's actual position.
- **FR-4.4** ✅ Selecting a thing from another room SHALL activate that
  room's map before routing (v1 routes within the room).
- **FR-4.5** 📋 Cross-room routes via stored doorways.
- **FR-4.6** ✅ Guidance SHALL be fully usable through VoiceOver and
  haptics alone.

## FR-5 Measurement & space queries

- **FR-5.1** 🧪 Measure tool: two taps on the floor plan SHALL yield
  straight-line distance, walking distance, and the narrowest corridor
  along the walking route.
- **FR-5.2** 🧪 Fit-through: given a width and two endpoints, the app
  SHALL answer fits / does-not-fit **with the pinch point located**.
  This tool SHALL live behind the room Tools menu, not the main flow.
- **FR-5.3** ✅ Object dimensions per FR-2.3/2.4.
- **FR-5.4** 📋 Accessibility audit: flag corridors under a set width.

## FR-6 Change awareness

- **FR-6.1** ✅ Re-scanning a room SHALL archive the previous map
  (keep 3) before overwriting.
- **FR-6.2** ✅ "What changed" SHALL diff any archived scan against the
  room's current map: blocked/cleared floor, moved things, missing
  things.
- **FR-6.3** ✅ A thing expected in view but not re-sighted SHALL be
  flagged missing, never silently deleted.

## FR-7 Diagnostics

- **FR-7.1** ✅ The app SHALL record session traces in the same JSONL
  schema the desktop viewer replays, and export them by share sheet.

## NFR (non-functional)

- **NFR-1** ✅ All core function on-device and offline. The sole
  network call is the optional, user-initiated CLIP download.
- **NFR-2** ✅ Photos stay in the app sandbox (not the photo library).
  "Delete everything" removes the store and all blobs.
- **NFR-3** 🧪 Baseline hardware: iPhone XR (A12, no LiDAR), iOS 17+.
  Newer hardware upgrades automatically (FR-1.5), never required.
- **NFR-4** 🧪 Storage for a furnished multi-room home ≤ ~100 MB
  (history pruning enforces).
- **NFR-5** ✅ Engine invariants stay property-tested: D* Lite ≡ A*,
  A* optimal vs Dijkstra, one canonical cost model, golden traces
  reproduced frame-for-frame by the Swift port.
- **NFR-6** ✅ VoiceOver labels and Dynamic Type on every screen;
  colour never the only signal.
- **NFR-7** 🧪 Scan loop sustains camera frame rate on A12: ingest at
  5 Hz, clearance refresh ≤1 Hz, planning off the frame path.

## Out of scope (decided)

- Virtual agent simulation in the app (removed; sim remains as test
  infrastructure). Cloud accounts/social. Outdoor/GPS. Multi-floor 💤.
  Map sharing 💤 (revisit after field testing).
