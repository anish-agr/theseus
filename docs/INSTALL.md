# Getting Theseus onto the phone

Two routes. Both build on GitHub's macOS runners, so neither needs a
Mac. They differ in how the build is *signed* and *delivered*.

| | Sideloadly (free) | TestFlight ($99/yr) |
|---|---|---|
| Signing | free Apple ID, on your PC | Apple Distribution cert, in CI |
| Delivery | USB cable | over the air |
| Expires | 7 days, re-sign by cable | 90 days |
| Apps installed at once | 3 | unlimited |
| Depends on | Apple's Windows DLL stack | nothing local |

Sideloadly is free and was the plan of record. Its weak point is
**anisette** — the Apple-ID authentication it performs by loading
Apple's own iTunes DLLs on Windows. When that breaks it is unfixable
from our side, because nothing about it is our code. TestFlight exists
in this repo as the route that removes every local dependency.

## Route A — Sideloadly

`ios.yml` produces an unsigned `Theseus.ipa` artifact on every push to
`main`. Download it from the run page, point Sideloadly at it, sign in
with an Apple ID, install over USB. Then on the phone: Settings →
General → VPN & Device Management → trust the developer.

### If anisette fails

The tell is a dialog naming `iTunesCore.dll`, "Local Anisette", or
`Login failed: 404`. Before reinstalling anything, check whether the
machine is actually at fault:

```bash
powershell -File tools/diagnose/anisette.ps1
```

**If it reports the bundle missing or incomplete**, Sideloadly's own
download died part-way — it fetches the DLLs from `sideloadly.io` and
its retry does not reliably resume. Finish it in one shot:

```bash
powershell -File tools/sideloadly/fix-anisette.ps1
```

That picks the bundle matching your Sideloadly's bitness (a 64-bit app
cannot load 32-bit DLLs — switching builds without clearing `an\` leaves
exactly that mismatch), closes the app to release file locks, extracts,
and verifies `iTunesCore.dll` is present and the right architecture. The
zip is cached, so repeat runs are instant.

**Then do not let Sideloadly download anisette again.** Its retry
*deletes the folder first* and then fails at the same point, so
answering Yes to the update prompt destroys a working set and puts you
back where you started — the same three files, every time. Answer No.

If it wipes them anyway, make them undeletable:

```bash
powershell -File tools/sideloadly/fix-anisette.ps1 -Protect
```

Reverse it with `-Unprotect`. If the 64-bit build still refuses, the
32-bit Sideloadly is worth trying: this machine has had a complete,
healthy 32-bit bundle before, so that downloader has worked here. The
script picks the matching bundle automatically.

It loads every DLL Sideloadly needs, in a 32-bit process, in the same
search order, and reports the first that fails. It also checks the VC++
runtimes, stray Apple installs, PATH pollution, and whether the daemon
can see the phone. If it reports everything healthy, reinstalling
iTunes, the redists, or Sideloadly cannot help — the fault is in
Sideloadly's build or in Apple's auth endpoints. In that case:

1. **Get the current Sideloadly, 64-bit**, and delete
   `%LOCALAPPDATA%\Sideloadly\an` first so the anisette DLLs are
   re-fetched to match the new binary. A stale build talking to moved
   Apple endpoints produces exactly the 404.
2. **Remote Anisette** (Sideloadly's Patreon setting) skips the local
   DLL path entirely, which is the part that breaks.
3. Otherwise, route B.

## Route A2 — AltServer / AltStore Classic

A separate implementation of the same free-Apple-ID signing, worth
trying when Sideloadly's own login fails. Its prerequisite is iTunes
**and iCloud** installed from Apple directly — the Microsoft Store
builds are rejected. AltServer needs `AOSKit.dll`, which ships with
iCloud, not iTunes.

If a cleanup ever deleted iCloud's files while leaving it registered
with Windows Installer, repair fails asking for `iCloud64.msi` from a
temp folder that no longer exists. Fix:

```bash
powershell -File tools/altserver/fix-icloud.ps1
```

It fetches the exact build AltStore's guide specifies from Apple's CDN,
unpacks the MSI, and reinstalls with `REINSTALLMODE=vomus` so the
deleted files are actually rewritten. It exits early if `AOSKit.dll` is
already present. Then: AltServer tray icon → Install AltStore → trust
the developer on the phone → sideload the IPA from AltStore itself.
AltStore re-signs over WiFi every 7 days, so the cable stops being
needed after setup.

## Route B — TestFlight

`testflight.yml`, run by hand from the Actions tab. It signs with a
certificate you generate on Windows, uploads to App Store Connect, and
the phone installs from the TestFlight app. No cable, no Sideloadly, no
Apple software on the PC.

### One-time Apple setup

Everything below happens in a browser and Git Bash. About 30 minutes,
most of it waiting for Apple.

1. **Join the Apple Developer Program** — developer.apple.com/programs,
   $99/yr. Approval is usually same-day but can take 48 h.

2. **Signing certificate.** In Git Bash:

   ```bash
   bash tools/appledev/signing-cert.sh csr
   ```

   Upload the generated `.csr` at developer.apple.com → Certificates →
   **+** → Apple Distribution. Download the `.cer` to
   `tools/appledev/out/distribution.cer`, then:

   ```bash
   bash tools/appledev/signing-cert.sh p12
   ```

   That folder is gitignored. The private key never leaves the PC
   except as an encrypted `.p12` in a GitHub secret.

3. **API key.** App Store Connect → Users and Access → Integrations →
   App Store Connect API → **+**, role **App Manager**. Download the
   `.p8` once (Apple will not show it again) and note the Key ID and
   Issuer ID. Base64 it:

   ```bash
   base64 -w0 AuthKey_XXXXXXXX.p8 > key.b64
   ```

4. **App record.** App Store Connect → Apps → **+** → New App. Bundle
   ID `dev.anish.theseus` (it appears in the list once the first
   archive registers it, so if it is missing, run the workflow once and
   come back). Platform iOS, SKU anything.

5. **Secrets.** Repo → Settings → Secrets and variables → Actions:

   | Secret | Value |
   |---|---|
   | `APPLE_TEAM_ID` | 10 characters, top-right of developer.apple.com |
   | `ASC_KEY_ID` | from step 3 |
   | `ASC_ISSUER_ID` | from step 3 |
   | `ASC_KEY_P8` | contents of `key.b64` |
   | `SIGNING_CERT_P12` | contents of `distribution.p12.base64` |
   | `SIGNING_CERT_PASSWORD` | the password from step 2 |

### Every build after that

Actions → **testflight** → Run workflow. Roughly 4 minutes to build,
then 5–15 for Apple to process. Install from TestFlight on the phone.
Build numbers come from the workflow run number, so they never collide.

## Notes

- The app icon is generated by `tools/icon/generate.ps1`, not stored as
  a hand-made asset. TestFlight rejects uploads without one.
- Route A and route B share the same source and the same XcodeGen spec;
  only signing differs. `ios.yml` stays unsigned so it keeps working
  with no Apple account at all.
