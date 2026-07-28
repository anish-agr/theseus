# Theseus brand & motion

Spec set by Anish, 2026-07-28. The logo is a single continuous thread
ending in a glowing destination point. Everything should feel calm,
confident, and inevitable — the app already knows the way.

Implementation lives in `apps/ios/Sources/Brand/Brand.swift`
(ThreadShape, ThreadView, LaunchOverlay, ThreadLoadingView,
SuccessDot); the app icon is generated from the same path by
`tools/icon/generate.ps1`.

## Palette

| role        | color     | rule                                  |
| ----------- | --------- | ------------------------------------- |
| background  | `#0E1B4D` | deep indigo, the world                |
| thread      | `#33A8FF` | electric blue; never glows constantly |
| destination | `#FFF6E8` | warm white; the ONLY thing that glows |
| error dot   | cool blue | the destination gone cold             |

## Motion principles

- Smooth cubic easing. No bouncing, no elastic overshoot, no spinning.
- Every movement intentional — following a path that already exists.
- The logo never rotates or morphs.
- Glow appears only during interaction.

## The rituals

- **Launch** (700–900 ms): only the dot exists → the thread draws
  itself backward from the dot → one soft dot pulse → completely still.
- **Loading**: never a spinner. The thread draws itself start→dot,
  fades, begins again. Slow, almost meditative. The dot never leaves.
  (`ThreadLoadingView` replaces every `ProgressView()` spinner.)
- **Search/Find**: the thread draws itself toward the stationary dot;
  reaching it, the dot glows once. "I'm showing you the way", not
  "I'm loading".
- **Success**: never a checkmark. The dot grows ~15%, one warm glow,
  back to normal. (`SuccessDot`.)
- **Error**: never shake, never red. The thread retracts a little; the
  dot turns cool blue. (`Color.brandDotCool`.)
- **Scanning**: capture completion = the object joins the home's
  memory — brief glow, then out of the way.

## Restraint clause

Full indigo, but with reason (Anish: "don't overwhelm the user").
System components keep their materials; the brand shows up in the
launch ritual, loading states, success/error moments, accent color,
and the Home hub background — not as a re-skin of every control.
