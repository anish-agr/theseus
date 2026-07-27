# Building Theseus without a Mac

Everything in this project needs macOS *eventually* — but far less of it
than you'd think, and none of it soon. This is the playbook for how far
Windows + free cloud machines take us, and exactly what the Mac is for.

## What needs what (the honest table)

| work | needs a Mac? | how we do it Mac-less |
|---|---|---|
| Engine (Python) — done | no | this machine |
| ML lanes (train/eval) — done | no | this machine |
| **NavCore Swift port** (M1's biggest chunk) | **no** | Swift toolchain on Windows (`apps/navcore`), verified against parity fixtures + golden traces |
| CI: tests on every push | no | GitHub Actions, free for public repos (`.github/workflows/ci.yml`) |
| Compiling the iOS app | macOS, not OURS | GitHub Actions `macos-*` runners build the .ipa in the cloud |
| Installing on the iPhone XR | no | Sideloadly on Windows + free Apple ID (7-day resign, 3-app cap) |
| Debugging on-device | mostly no | the app writes the same JSONL traces as the engine; replay them in tools/viewer — our own instrumentation instead of Xcode's |
| ARKit look-and-feel iteration | **yes** | the one true Mac need: rent (~$30–50/mo cloud) or used M1 Mini (~$300–400) for that phase only |

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

## 3. When the app exists (M1 ARKit shell): cloud Macs build it

GitHub Actions offers macOS runners with Xcode preinstalled — same free
allowance. The workflow (added when apps/ios exists) archives an
unsigned .ipa artifact per push. No Mac touched.

## 4. Getting builds onto the phone, from Windows

[Sideloadly](https://sideloadly.io) (Windows app) signs an .ipa with a
free Apple ID and installs it over USB to the XR.

- free-account limits: app expires after 7 days (re-sideload weekly),
  max 3 sideloaded apps, and the bundle id gets prefixed
- the $99/yr Apple Developer account removes those limits and adds
  TestFlight over-the-air installs — an option, never a requirement

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

Everything upstream of that day — the entire NavCore port, all CI, the
first sideloaded build — costs $0 and starts now.
