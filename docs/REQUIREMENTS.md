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
  filter before becoming occupied: ≥3 hits in 12 ingest frames,
  relaxed to ≥2 when the point cloud is sparse (<60 banded points) —
  the strict gate under-detected obstacles in the first field test.
- **FR-1.5** 🧪 On LiDAR hardware the app SHALL use dense scene-mesh
  reconstruction automatically; mesh evidence bypasses FR-1.4.
- **FR-1.6** 🧪 The scanner SHALL show live coverage and direct the
  user toward unmapped frontier. **Completion is a state, not a
  percentage**: the room is "Complete" when the frontier solver finds
  nothing reachable left, because a raw fraction stalls around 70-80%
  forever (frontier under furniture) and reads as failure.
- **FR-1.9** 🧪 Elevated horizontal planes (0.15-1.8 m above the
  floor: tabletops, seats, shelves) SHALL be obstacles. Field test
  found them invisible — neither walkable nor blocking.
- **FR-1.10** 🧪 First launch of the scanner SHALL teach the moves
  (sweep floor, walk edges, tilt over furniture, dwell to save);
  re-openable from the ? button.
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
- **FR-2.9** 🧪 A capture SHALL NOT be discarded because size or depth
  could not be measured — the photo and name are the product; size is
  a bonus recorded as "unknown". (First field test: the dwell ring
  completed, the spinner ran, and nothing happened. Never again.)
- **FR-2.10** 🧪 A manual shutter button SHALL back up the dwell for
  one-handed / awkward-angle captures.

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
- **FR-3.6** 🧪 Export the whole inventory as JSON; export any room as
  a **report PDF** (photos, sizes, values, floor plan) — the
  insurance/moving document.
- **FR-3.7** 🧪 Every thing SHALL be indexed in iOS Spotlight: typing
  "keys" in the iPhone's own search opens the app straight into
  locating them. A Shortcuts/Siri phrase opens search.
- **FR-3.8** 🧪 A thing MAY carry a value and a receipt photo; Home
  and reports show totals. (AI value estimation: future.)

## FR-4 Finding & guidance

- **FR-4.1** ✅ Turn-by-turn guidance SHALL plan an optimal route on
  the canonical cost model and guide with full-screen arrow, distance,
  haptics whose intensity rises as the corridor narrows, and voice
  (phone speaker) that is **muted until explicitly unmuted**.
- **FR-4.7** 🧪 The DEFAULT find experience is **locate-in-camera**:
  the item's pin becomes a green beacon in AR, a bar tracks live
  distance + direction arrow, haptic ticks quicken as you close in
  (geiger-counter). Turn-by-turn is one tap away from there.
- **FR-4.8** 🧪 A route that cannot exist yet SHALL surface as a toast
  ("scan the floor between you and it"), never as an empty full-screen
  guidance takeover.
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

## FR-8 AI (opt-in cloud brain)

- **FR-8.1** 🧪 All AI features SHALL work behind one provider switch:
  Gemini (recommended — the free AI Studio tier costs nothing),
  Anthropic, or any OpenAI-compatible endpoint. Key entered once in
  Settings, stored in the Keychain, sent as a header, never in a URL.
- **FR-8.2** 🧪 A photo SHALL leave the device ONLY when the user taps
  an explicitly-AI action; never in the background. Uploads are
  downscaled (≤1024 px).
- **FR-8.3** 🧪 AI actions: itemize a storage photo (FR-9.3), estimate
  replacement value (FR-10.4), identify an unknown object (FR-12.3).
  Every AI-derived value is labelled "AI estimate" and user-editable.
- **FR-8.4** 🧪 Without a key, every AI entry point degrades to its
  on-device equivalent or explains, in one line, what a free key adds.

## FR-9 Storage memory

- **FR-9.1** 🧪 A StorageSpot (box/bin/closet/drawer/shelf/cabinet)
  holds things and nests inside other spots. Deleting a spot never
  deletes its contents.
- **FR-9.2** 🧪 Things in spots are searchable from Home and iOS
  Spotlight, answering "in Moving Box 3" rather than a map pin.
  Contents can also be added by name, no camera required.
- **FR-9.3** 🧪 Photographing an open container with AI configured
  SHALL propose an itemized contents list (checklist, user confirms;
  nothing auto-saves).
- **FR-9.4** 🧪 Every spot can print a QR label (theseus://spot/id).
  The iPhone's own camera — or the in-app scanner — pointed at the
  label opens the contents list.

## FR-10 Insurance assistant

- **FR-10.1** 🧪 A thing MAY carry a serial number, captured by
  pointing the camera at the label: OCR runs on-device, candidate
  lines are ranked serial-first, the user picks one.
- **FR-10.2** 🧪 A thing MAY carry a warranty (expiry + note); the
  Insurance screen lists warranties passively — no notifications, no
  nagging.
- **FR-10.3** 🧪 The Insurance screen shows documented value, gaps
  (no value / valued-but-no-receipt), and exports the claim-ready PDF:
  every item with photo, location, size, serial, value, receipt and
  warranty status across all rooms and storage.
- **FR-10.4** 🧪 "Estimate value with AI" fills a thing's value from
  its photo + measured size, labelled as an estimate (FR-8.3).

## FR-11 Condition records (rental deposit)

- **FR-11.1** 🧪 A guided walkthrough (walls, floor, ceiling, windows,
  door, fixtures, damage close-ups + custom tags) captures dated,
  captioned photos per room; kinds: move-in, move-out, check-up.
- **FR-11.2** 🧪 Sealing a record computes a SHA-256 over every photo
  and caption; sealed records are immutable in the UI and the hash is
  printed on the export — tamper-evident evidence.
- **FR-11.3** 🧪 Export per record (photo grid PDF) and per pair
  (move-in vs move-out side-by-side by tag) — the "that scratch was
  always there" document.
- **FR-11.4** 💤 True 3D capture is a LiDAR-device upgrade later; the
  evidence artifact stays photos-first by design.

## FR-12 Lens, memory lane, voice

- **FR-12.1** 🧪 Lens mode in the scanner identifies WITHOUT saving:
  a capture is matched by visual fingerprint against everything saved
  and answers with name, home location, value, serial, warranty, and
  a Find button.
- **FR-12.2** 🧪 Memory lane: a month-grouped timeline of first
  captures, moves, scans and sealed records. No streaks, no guilt.
- **FR-12.3** 🧪 Lens + AI answers "what is this" for unknown objects
  (identify + value estimate + one-line summary) and can save the
  result straight into inventory.
- **FR-12.4** 🧪 Push-to-talk voice during scan (on-device speech):
  "mark this" captures, "what is this" runs the lens, "find my X"
  lights the beacon or answers with the storage spot. Mic hot only
  while the button shows it.
- **FR-12.5** 🧪 What-changed reads as a diff: +added, −missing,
  ~moved with photos, against a chosen archived scan.

## NFR (non-functional)

- **NFR-1** ✅ All core function on-device and offline. Network is
  used only for the optional CLIP download and explicit, user-tapped
  AI actions (FR-8.2) — never in the background.
- **NFR-8** 🧪 Motion follows docs/BRAND.md: the thread draws, it
  never spins; no spinners, no checkmarks, no shaking anywhere.
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
