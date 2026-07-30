# Building Theseus without a Mac

This playbook was written as a plan; it is now a report. The entire
app — engine port, iOS app, seven on-device field-test cycles, six
releases — happened from a Windows machine and free cloud macOS
runners. No Mac was touched.

## What needs what (the honest table, updated as things shipped)

| work | needs a Mac? | how it was done Mac-less |
|---|---|---|
| Engine (Python) — done | no | this machine |
| ML lanes (train/eval/export) — done | no | this machine |
| **NavCore Swift port** — done | **no** | Swift toolchain on Windows (`apps/navcore`), verified against parity fixtures + golden traces |
| CI: tests on every push | no | GitHub Actions, free for public repos (`.github/workflows/ci.yml`) |
| Compiling the iOS app — live | macOS, not OURS | GitHub Actions `macos-*` runners build an unsigned `Theseus.ipa` per push (`ios.yml`) |
| Installing on the iPhone XR — live | no | **AltServer** on Windows + free Apple ID (7-day resign, 3-app cap). Sideloadly was the first plan; its anisette layer broke and AltServer worked — both routes plus a TestFlight path are in docs/INSTALL.md |
| Debugging on-device | mostly no | field-test cycles: build in the cloud, sideload, observe, fix — plus the app's own trace/report exports instead of Xcode's instruments |
| ARKit look-and-feel iteration | **eventually** | the one true Mac need, for M4's Core ML depth work: used M1 Mini (~$300–400) or cloud rental, for that phase only |

## 1. Swift on Windows (the port happens HERE)

Install once (official swift.org build):

```bash
winget install --id Swift.Toolchain -e
```

Then, from the repo root:

```bash
swift test --package-path apps/navcore
```

Port order, rules, and landmines: docs/PORT.md. The parity contract is
mechanized: `engine/scripts/gen_swift_fixtures.py` makes the Python
engine emit (input, expected) batteries into the Swift test target, so
the port is tested against the reference's actual numbers, ulp-aware.
End state of the port (still on Windows): NavCore replays the golden
scenarios frame-for-frame.

## 2. Push → free cloud verification

The repo is public, so GitHub Actions minutes are free. On every push,
ci.yml runs the Python engine suite AND builds + tests NavCore on Linux
— which also proves the port never quietly grows an Apple-only
dependency. Nothing to configure; push and watch the Actions tab.

## 3. Cloud Macs build the app

GitHub Actions offers macOS runners with Xcode preinstalled — same free
allowance. `ios.yml` regenerates the Xcode project from `project.yml`
(XcodeGen — no generated project files in the repo), builds, and
archives an unsigned .ipa artifact on every push that touches `apps/`.

## 4. Getting builds onto the phone, from Windows

[AltServer](https://altstore.io) (Windows) signs the .ipa with a free
Apple ID and installs it over USB — Shift-click its tray icon →
Sideload .ipa. Same bundle id updates in place, so app data survives
every reinstall.

- free-account limits: app expires after 7 days (re-sideload weekly),
  max 3 sideloaded apps, and the bundle id gets prefixed
- the $99/yr Apple Developer account removes those limits and adds
  TestFlight over-the-air installs — an option, never a requirement
- full walkthrough, plus the TestFlight route and what broke with
  Sideloadly's anisette layer: docs/INSTALL.md

## 5. Debugging without Xcode

The plan of record: the app records the SAME trace JSONL the engine
does (roadmap M1 "on-device trace recorder") and exports it via the
share sheet; tools/viewer replays it on Windows. The golden-trace
discipline that verifies the port doubles as the no-Xcode debugger.
Live logs, if ever needed: `idevicesyslog` from libimobiledevice runs
on Windows.

## 6. The residual Mac need, and the cheap ways to meet it

Tuning how AR *feels* — overlay latency, anchor drift response, haptic
timing — wants the tight Xcode↔device loop. Options, in order of
preference when that day comes:

1. **Used/refurb M1 Mac Mini** (~$300–400, holds resale): best
   $/iteration, fully offline.
2. **Cloud Mac rental** (MacinCloud ~$35/mo, Scaleway M1 ~€0.10/hr):
   fine for a focused month; device attaches via USB-over-network
   tooling or TestFlight round-trips.
3. GitHub Actions only: workable but each UI tweak is a ~15-min
   build-sideload cycle — acceptable for polish, painful for
   exploration.

Everything upstream of that day — the NavCore port, all CI, every
build the phone has ever run — cost $0.
