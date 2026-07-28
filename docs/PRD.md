# Theseus — product requirements

Status: written 2026-07-28, retroactively covering what already exists
(marked ✅) and forward-specifying the rest. This is the document that
decides what gets built; ROADMAP.md decides when.

---

## 1. The problem

Your phone remembers your photos, your messages, your passwords, your
steps, your heart rate. It has **no idea where anything physically is**.

Concretely, three everyday failures:

1. **"Where did I put it?"** People lose keys, passports, chargers,
   medication, the good scissors. The existing fix is a $29 Bluetooth
   tag per object, which caps you at the ~10 things you predicted you'd
   lose. Nobody tags their scissors.
2. **"What's actually in this room?"** Moving out, filing a renters
   insurance claim, listing an Airbnb, clearing a relative's house,
   packing for a trip — all require an inventory that today means
   walking around typing a list, or a shoebox of receipts.
3. **"Can I get there / will it fit?"** Navigating a cluttered space
   without full sight, in the dark, or carrying something bulky. Or
   buying a couch that can't make the hallway turn.

All three are the *same missing primitive*: a persistent, metric,
private memory of your space and the things in it.

## 2. What Theseus is

**A spatial memory for the places you live and work.** You sweep your
phone around a room once. Theseus builds a measured floor plan, and
every object you point at gets logged with a photo, its real-world
dimensions, and its position. From then on the map answers questions:

> *Where are my keys?* · *What's in the garage?* · *What changed since
> yesterday?* · *Will this couch fit through there?* · *Walk me to the
> fridge.*

Two things make it defensible rather than a toy:

- **It runs on a phone with no LiDAR** (iPhone XR, 2018 hardware). The
  perception stack was built no-LiDAR-first, not degraded down to it.
- **Everything is on-device.** This app maps the inside of your home.
  That data never leaves the phone.

### 2.1 Why the pathfinding matters (the honest argument)

Pathfinding alone *is* a toy. It becomes load-bearing the moment
objects are in the map, because then routes are answers to real
questions:

| Without objects | With objects |
|---|---|
| "route from A to B" | **"take me to my keys"** |
| "here's a floor plan" | **"here's an inventory with photos, sizes, and where each thing is"** |
| "this corridor is 0.6 m" | **"that couch will not make this turn — pinch at the hall corner"** |
| "cells changed" | **"the walker path to the bathroom is blocked since yesterday"** |

The engine (A\*, D\* Lite, clearance fields, flow fields) is the
machinery that turns a static scan into a thing you can *ask*.

## 3. Users

| Persona | Core need | Killer feature |
|---|---|---|
| **Everyday forgetful person** (primary) | find things fast | Point-and-log + "where is X" |
| **Someone moving / insuring / hosting** | prove and organize what they own | Inventory export with photos + sizes |
| **Low-vision or blind user** (aspirational, real) | traverse space safely | Ariadne guidance (voice + haptics) |
| **Carer / family** | is the space still safe and unchanged | Change detection on paths |
| **Anyone buying furniture** | will it fit | Fit-through with pinch points |

## 4. Requirements

Legend: ✅ built · 🔨 building now · 📋 specified, later · 💤 someday.

### 4.1 Perception & mapping

| ID | Requirement | Status |
|---|---|---|
| P1 | Build an occupancy map of a room from a handheld phone with **no LiDAR**, using plane detection + filtered feature points | ✅ |
| P2 | Bounded log-odds occupancy so a moved object is forgotten in ~3 observations, not 50 | ✅ |
| P3 | Clearance field (distance to nearest obstacle) maintained for the whole map | ✅ |
| P4 | Unknown space is untraversable by default; mapping modes opt in | ✅ |
| P5 | Temporal persistence filter — a cell needs repeat hits before becoming an obstacle | ✅ |
| P6 | Monocular-depth pseudo-LiDAR path (validated offline on real footage) | ✅ offline / 📋 on-device (M4) |
| P7 | LiDAR fast path on 12 Pro+ where available | 📋 |
| P8 | Live coverage feedback: "62% of this room's floor is mapped", with guidance to unscanned frontier | 🔨 |
| P9 | Relocalize into a previously-scanned room via `ARWorldMap` | 🔨 |

### 4.2 Objects ("point at anything long enough")

| ID | Requirement | Status |
|---|---|---|
| O1 | **Dwell capture**: hold the reticle on an object ~1.2 s → it is captured. No buttons, no menus | 🔨 |
| O2 | Subject isolation — crop the actual object, not the whole frame | 🔨 |
| O3 | Automatic classification across **~1,300 categories** (not 80) via on-device Vision | 🔨 |
| O4 | **Text reading** on the object (book spines, medicine boxes, cables, product labels) | 🔨 |
| O5 | **Barcode capture** for packaged goods | 🔨 |
| O6 | **Visual fingerprint** so *that specific mug* can be re-recognized later | 🔨 |
| O7 | **Physical size estimate** (W × H in cm) from the crop + depth | 🔨 |
| O8 | **Photo thumbnail** stored per object | 🔨 |
| O9 | User can rename anything; the name sticks and outranks the classifier | 🔨 |
| O10 | Anything unrecognized is still capturable — you name it once | 🔨 |
| O11 | Merge/promote/decay registry so jitter doesn't create duplicates and moved objects expire | ✅ engine / 🔨 wired |
| O12 | **Natural-language search** ("blue ceramic mug") via a bundled CLIP model | 📋 seam built now, model on-demand |
| O13 | Sighting history — *where* an object was seen and *when*, over time | 🔨 |

### 4.3 Inventory & documentation

| ID | Requirement | Status |
|---|---|---|
| I1 | Browsable inventory per room and per home, with photos | 🔨 |
| I2 | Search by name, category, or text found on the object | 🔨 |
| I3 | Per-object detail: photo, size, room, position on the floor plan, first/last seen | 🔨 |
| I4 | Room summary: object count, floor area, mapped coverage, last scanned | 🔨 |
| I5 | Export a room or whole home (JSON + photos) for insurance/moving | 📋 |
| I6 | Printable/shareable floor plan image | 📋 |
| I7 | Share a map with another person | 💤 (explicitly deferred) |

### 4.4 Finding & navigation

| ID | Requirement | Status |
|---|---|---|
| N1 | A\* optimal planning over the canonical cost model | ✅ |
| N2 | D\* Lite incremental replanning in milliseconds when the world changes | ✅ |
| N3 | Guidance cues (straight / turn L / turn R / off-route / arrive) with tested turn signs | ✅ |
| N4 | Voice + haptic guidance on the **phone speaker** (no AirPods required) | ✅ built, 🔨 tuning |
| N5 | On-screen arrow + distance + corridor-width feedback | ✅ |
| N6 | "Take me to <object>" from the inventory | 🔨 |
| N7 | Flow-field routing to the *nearest* instance of a category ("nearest chair") | ✅ engine / 🔨 wired |
| N8 | Cross-room routing via a house graph | 📋 (v1: routes within a room, points at the connecting door) |
| N9 | Continuous walk mode (no destination, longest clear vector) with safety gates | ✅ |
| N10 | Frontier auto-exploration | ✅ engine (used for scan guidance, P8) |

### 4.5 Space queries

| ID | Requirement | Status |
|---|---|---|
| S1 | Fit-through: "will a 0.9 m object make this route", with the pinch point located | ✅ engine / 🔨 UI |
| S2 | Corridor width profile along a route | ✅ |
| S3 | Point-to-point distance and clearance measurement | 🔨 |
| S4 | Accessibility audit: flag corridors below a wheelchair-width threshold | 📋 |
| S5 | Coverage/patrol sweep route | ✅ engine |

### 4.6 Change detection

| ID | Requirement | Status |
|---|---|---|
| C1 | Grid diff between two scans of the same room | ✅ engine / 🔨 UI |
| C2 | "What changed since <date>": objects appeared, vanished, moved | 🔨 |
| C3 | Path-blockage alerts on routes you care about | 📋 |

### 4.7 Platform, privacy, trust

| ID | Requirement | Status |
|---|---|---|
| T1 | All processing and storage **on-device**; no network calls for core function | 🔨 |
| T2 | Works fully offline | 🔨 |
| T3 | Runs on iPhone XR (A12, no LiDAR) | 🔨 |
| T4 | Diagnostic trace recorder in the same JSONL schema the desktop viewer replays | ✅ |
| T5 | VoiceOver labels and Dynamic Type throughout (this app has blind users in its thesis — it cannot be inaccessible) | 🔨 |
| T6 | Clear data deletion: delete a room, delete everything | 🔨 |

### 4.8 Engine quality bars (already met, must stay met)

| ID | Requirement | Status |
|---|---|---|
| Q1 | D\* Lite provably equals fresh A\* under random world edits | ✅ property-tested |
| Q2 | A\* provably optimal vs Dijkstra | ✅ property-tested |
| Q3 | One canonical cost model shared by every solver | ✅ enforced |
| Q4 | Golden scenario traces frozen; Swift port reproduces them frame-for-frame | ✅ |
| Q5 | Zero collisions in all guidance and walk demos | ✅ |

## 5. Explicitly out of scope

- **Virtual agent / robot simulation in the app.** Removed. It was a
  fun demo of the engine, not a user feature. The simulator stays in
  the repo as test infrastructure.
- Cloud accounts, social features, sharing (T7 deferred).
- Outdoor / GPS navigation.
- Multi-floor with stairs (💤).

## 6. Success criteria for v1

1. Scan a real room in under 3 minutes and get a floor plan whose
   corridor widths are within ~10 cm of a tape measure.
2. Log 20 objects by pointing, with correct-enough names that fewer
   than half need renaming, and size estimates within ~20%.
3. Ask for any logged object and be walked to it, with the route
   re-bending live when someone steps into the path.
4. Come back a day later, relocalize, and see what changed.
5. All of it offline, on an iPhone XR, with nothing leaving the device.
