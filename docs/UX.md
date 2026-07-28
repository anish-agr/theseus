# Frontend spec

Design stance: **the camera is the app**. Scanning and capturing happen
in a live AR view with almost no chrome; everything else (inventory,
search, history) is normal, fast, accessible SwiftUI on top of it.

Dark UI throughout — it sits over a camera feed, and it's used in dim
rooms.

## Navigation shell

A three-tab `TabView`:

```
┌──────────┬──────────┬──────────┐
│  Rooms   │   Scan   │  Things  │
└──────────┴──────────┴──────────┘
```

- **Rooms** — your places and rooms; entry point to re-open a map.
- **Scan** — the AR view. The verb tab.
- **Things** — the whole inventory, searchable across every room.

Guidance takes over the screen when active (it's a mode, not a tab).

---

## 1. Rooms tab

A list of `Place`s, each with its rooms as cards:

```
Home                                    + Room
┌────────────────────────────────────────────┐
│ [floor plan]  Kitchen                      │
│               34 things · 11.2 m² · 87% ✔  │
│               scanned 2 days ago           │
├────────────────────────────────────────────┤
│ [floor plan]  Bedroom                      │
│               19 things · 14.0 m² · 62% ⚠  │
│               scanned yesterday            │
└────────────────────────────────────────────┘
```

Card thumbnail is the rendered floor plan. Tapping opens **Room
detail**: bigger plan with object pins, the object list for that room,
"Continue scanning", "What changed", and a "Fit-through" tool.

Empty state is a single big button: **Scan your first room**.

## 2. Scan tab (the AR view)

```
┌──────────────────────────────────────┐
│  Kitchen · 62% mapped        ⏺ REC   │  ← thin status bar
│                                      │
│                                      │
│               ◯                      │  ← dwell reticle, centre
│                                      │
│                                      │
│                            ┌───────┐ │
│  "sweep left — unmapped"   │ mini  │ │  ← live minimap
│                            │ map   │ │
└────────────────────────────┴───────┘─┘
```

**The reticle is the entire capture interface.** Point it at something
and hold still. A ring fills over ~1.2 s; when it completes, the object
is captured, the phone taps once (haptic), and a compact card slides up
from the bottom:

```
┌────────────────────────────────────────┐
│ [photo]  Coffee mug            ✎ rename│
│          12 × 9 cm · on the counter    │
│                              Save  ✕   │
└────────────────────────────────────────┘
```

Auto-saves after 3 seconds if untouched — the common case is zero taps.
Rename opens a keyboard with the suggested name pre-filled and any text
the camera read on the object offered as alternatives ("NESCAFÉ").

**Coverage guidance.** The frontier solver already knows where the
unmapped space is. The status line turns that into a nudge: *"sweep
left — unmapped area"*, and the minimap dims mapped floor so the gaps
are obvious. Coverage % is honest (fraction of *reachable* floor).

**Tracking-loss banner** appears when ARKit degrades, with the actual
useful instruction ("move slowly, more light, avoid blank walls").

## 3. Things tab (inventory)

Search field pinned at the top. Results as rows: photo, name, room,
size, last-seen.

```
🔍 mug
┌──────────────────────────────────────┐
│ [img] Coffee mug                     │
│       Kitchen · 12×9 cm · seen today │
├──────────────────────────────────────┤
│ [img] Travel mug                     │
│       Bedroom · 20×8 cm · 3 days ago │
└──────────────────────────────────────┘
```

Search matches, in priority order: user name → auto label → text read
off the object (so "NESCAFÉ" finds the jar) → category. With the CLIP
model installed, a second section appears: **"Semantic matches"** for
descriptive queries like *blue ceramic mug*.

Filters: by room, by category, "missing", "recently moved".

## 4. Thing detail

```
┌────────────────────────────────────┐
│          [ large photo ]           │
│                                    │
│  Coffee mug                     ✎  │
│  Kitchen                           │
│                                    │
│  Size        12 × 9 cm  (±2 cm)    │
│  First seen  12 Jun                │
│  Last seen   today, 09:14          │
│  Text found  "NESCAFÉ"             │
│                                    │
│  ┌──────────────────────────────┐  │
│  │  [ floor plan with pin ]     │  │
│  └──────────────────────────────┘  │
│                                    │
│  ▶ Take me there                   │
│  ↺ History (4 sightings)           │
│  🗑 Delete                          │
└────────────────────────────────────┘
```

**Take me there** is the bridge from inventory to navigation — this is
the moment the pathfinding stops being a demo.

History is a small list of sightings with dates and positions, plus
"moved" flags: *"moved 1.4 m on 14 Jun"*.

## 5. Guidance (full screen, takes over)

Deliberately huge and glanceable — it's used while walking, sometimes
by someone who can barely see it.

```
┌────────────────────────────────────┐
│                                    │
│              ◀◀                    │  ← arrow, 120pt
│           TURN LEFT                │
│              43°                   │
│                                    │
│  ▓▓▓▓▓▓▓▓░░░░  corridor 0.9 m      │  ← width bar
│                                    │
│  to: Coffee mug · 4.2 m            │
│                     [ minimap ]    │
│                                    │
│           ✕  Stop                  │
└────────────────────────────────────┘
```

- **Voice** speaks each cue change through the phone speaker.
- **Haptics** run a continuous texture whose intensity rises as the
  corridor narrows, with a sharp tap at turns.
- **Off-route** turns the screen red and says "stop" — then reroutes
  from wherever you actually are.

Design constraint from the project's own thesis: this screen must be
fully usable with VoiceOver and at the largest Dynamic Type size.

## 6. Changes view

Reachable from a room. Compares the current map to a chosen earlier
scan:

```
Kitchen · since 2 days ago
  ▲ appeared   3 things      [thumbnails]
  ▼ gone       1 thing       Scissors
  ↔ moved      2 things      Kettle 0.8 m, Chair 1.6 m
  ■ floor      +2.1 m² newly blocked near the door
```

## 7. Fit-through tool

Pick two points on the floor plan (or "from me to X"), enter a width,
get a verdict with the pinch point marked on the plan and the narrowest
measurement called out.

## 8. Settings

Voice/haptics toggles · units (cm/in) · CLIP model install & size ·
export a room · delete a room · **delete everything** · diagnostics
(trace recording, share trace file).

## 9. Accessibility requirements

Not a nice-to-have here — a blind user is in the target personas.

- Every control has a VoiceOver label; the guidance screen announces
  cue changes via `UIAccessibility.post(notification: .announcement)`.
- Dynamic Type to accessibility sizes; nothing is fixed-height text.
- Colour is never the only signal (arrow shape + words + speech).
- Haptics carry the full cue set so the screen can be ignored entirely.
- The dwell reticle has an alternative explicit capture button for
  users who can't hold steady.
