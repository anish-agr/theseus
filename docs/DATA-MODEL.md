# Data model & storage

Everything lives on the device. There is no server, no account, and no
network call in the core loop. This document is the contract for what
is stored, where, and why.

## 1. Three storage tiers

| Tier | Technology | Holds | Why there |
|---|---|---|---|
| **Structured** | SwiftData (SQLite underneath) | places, rooms, things, sightings, sessions | needs querying, sorting, relationships, and live SwiftUI updates |
| **Blobs** | files in Application Support | ARWorldMaps, occupancy grids, photos, traces | large, opaque, written whole; would bloat the DB and its migrations |
| **Preferences** | UserDefaults | voice on/off, units, last room | trivial scalars |

Rule of thumb: **if you'd want to `WHERE` or `ORDER BY` it, it goes in
SwiftData; if it's more than ~50 KB and you always read all of it, it's
a file.** SwiftData rows then hold a filename, not the bytes.

Why SwiftData rather than raw SQLite or Core Data: it's first-party (no
dependency to sideload), gives `@Query` bindings that keep the
inventory list live as the scanner finds things, and its store is a
plain SQLite file we can still inspect and export.

## 2. Entities

```
Place  1───*  Room  1───*  Thing  1───*  Sighting
                │
                └───*  ScanSession
```

### Place
A building. "Home", "Mum's flat", "Office".

| field | type | notes |
|---|---|---|
| `id` | UUID | |
| `name` | String | |
| `createdAt` | Date | |
| `rooms` | [Room] | cascade delete |

### Room
One contiguous mapped space with **its own coordinate frame**. This is
the unit of relocalization, because ARKit can load exactly one
`ARWorldMap` at a time.

| field | type | notes |
|---|---|---|
| `id` | UUID | also the blob directory name |
| `name` | String | "Kitchen" |
| `createdAt` / `lastScannedAt` | Date | |
| `cellSize` | Double | metres per grid cell (0.05) |
| `gridWidth` / `gridHeight` | Int | |
| `originX` / `originY` | Double | world coords of grid cell (0,0) |
| `coverage` | Double | 0–1, fraction of reachable floor mapped |
| `floorAreaM2` | Double | derived, cached for the room list |
| `hasWorldMap` | Bool | whether `worldmap.bin` exists |
| `doorways` | [Doorway] | links to neighbouring rooms (house graph) |
| `things` | [Thing] | cascade delete |

### Doorway
An edge in the house graph. v1 stores it; cross-room metric routing is
a later milestone, so v1 uses it to say *"the Kitchen is through that
door"*.

| field | type | notes |
|---|---|---|
| `id` | UUID | |
| `positionX` / `positionY` | Double | in the owning room's frame |
| `connectsToRoomID` | UUID? | nil until the far side is scanned |

### Thing
An object in the world. The heart of the app.

| field | type | notes |
|---|---|---|
| `id` | UUID | also the thumbnail filename |
| `displayName` | String | what the user sees; user-edited wins |
| `autoLabel` | String | what the classifier said |
| `autoConfidence` | Double | classifier confidence 0–1 |
| `userNamed` | Bool | true once edited — never auto-overwritten |
| `category` | String | coarse bucket for grouping/filtering |
| `recognizedText` | String | OCR from the object (searchable!) |
| `barcode` | String? | if one was seen |
| `positionX` / `positionY` | Double | floor-plan position, room frame |
| `heightM` | Double | height above the floor of the object centre |
| `widthM` / `sizeHeightM` | Double | **measured physical size** |
| `sizeConfidence` | Double | degrades when depth was estimated poorly |
| `featurePrint` | Data | Vision visual fingerprint for re-identification |
| `clipEmbedding` | Data? | set when the CLIP model is installed |
| `confidence` | Double | registry confidence (merge/promote/decay) |
| `hits` | Int | how many times observed |
| `promoted` | Bool | passed the promotion threshold → a real target |
| `firstSeenAt` / `lastSeenAt` | Date | |
| `isMissing` | Bool | was expected in view and wasn't there |
| `sightings` | [Sighting] | cascade delete |

### Sighting
An observation event. This is what makes *history* possible — "your
keys were on the hall table yesterday, the desk today".

| field | type | notes |
|---|---|---|
| `id` | UUID | |
| `at` | Date | |
| `positionX` / `positionY` | Double | |
| `confidence` | Double | |
| `movedSincePrevious` | Bool | > 0.4 m from the last sighting |

### ScanSession
One scanning run — for coverage stats and diagnostics.

| field | type | notes |
|---|---|---|
| `id` | UUID | also the trace filename |
| `startedAt` / `endedAt` | Date | |
| `coverageDelta` | Double | how much new floor this session revealed |
| `thingsAdded` | Int | |
| `traceFilename` | String? | JSONL replayable in tools/viewer |

## 3. Blob layout

```
Application Support/Theseus/
  rooms/<room-uuid>/
    worldmap.bin        ARWorldMap, NSKeyedArchiver (1–15 MB)
    grid.bin            RLE occupancy snapshot (a few KB)
    grid-<iso8601>.bin  previous scans, for change detection
    plan.png            rendered floor plan (regenerated on demand)
  things/<thing-uuid>.jpg   cropped object photo, ~40 KB
  traces/<session-uuid>.jsonl
```

`grid.bin` uses the **same run-length format the Python engine's
`serialize.py` writes** (`theseus-grid/1`), so a phone scan can be
opened by the desktop tooling and vice versa. Keeping one format across
both languages is deliberate: it is how a phone bug gets debugged on a
laptop.

## 4. Lifecycle

**First run** → create a default `Place` ("Home"). No rooms.

**New room** → create `Room`, run ARKit fresh, sweep. On finish: save
`ARWorldMap` + `grid.bin`, compute coverage and floor area, stamp
`lastScannedAt`.

**Re-entering a room** → user picks the room (v1) → load its
`ARWorldMap` into the session → ARKit relocalizes when it recognizes
the space → the saved grid and all its Things snap back into place.

**Capturing a thing** → Vision produces label/text/size/fingerprint →
the `WaypointRegistry` decides new-vs-merge → insert or update `Thing`,
append a `Sighting`, write the thumbnail.

**Re-scanning a room** → the previous `grid.bin` is copied to
`grid-<date>.bin` first, so the diff engine has a "yesterday" to
compare against; Things not re-sighted where expected get
`isMissing = true` rather than being deleted (never silently lose the
user's data).

**Deleting** → deleting a `Room` cascades its Things and Sightings and
removes its blob directory. Settings has a "delete everything" that
drops the store and the whole `Theseus/` directory.

## 5. Size budget (a 3-bedroom home, generously furnished)

| item | count | each | total |
|---|---|---|---|
| ARWorldMaps | 8 rooms | ~8 MB | ~64 MB |
| grids (current + 3 history) | 32 | 5 KB | 160 KB |
| thing photos | 400 | 40 KB | ~16 MB |
| SwiftData rows | ~2,500 | — | ~2 MB |
| **total** | | | **~82 MB** |

Comfortable. ARWorldMaps dominate; the history-pruning policy (keep 3
grid snapshots per room, drop world maps for rooms untouched in a year)
exists to keep it that way.

## 6. Privacy stance

- No networking is required for any core feature. The only network call
  in the app is the **optional, user-initiated** CLIP model download.
- Photos captured for objects are crops stored in the app's sandbox;
  they are not written to the system photo library.
- Export is explicit and produces a file the user hands somewhere
  themselves.
- "Delete everything" really does — store file and blob tree both.

This matters more than usual: an occupancy map of your home, with a
photo inventory of your possessions and timestamps, is a burglar's
dream document. Local-only is not a marketing line here, it's the
design constraint.
