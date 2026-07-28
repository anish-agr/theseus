"""Validates a built .ipa before anyone tries to install it.

Every check here exists because the failure it catches is invisible in a
green build log: xcodebuild happily produces an app with no icon, no
camera permission string, or a missing Info.plist key, and you only find
out when the phone refuses it or App Store Connect rejects the upload
with a numeric code.

Stdlib only, so it runs anywhere.

    python tools/ci/validate_ipa.py Theseus.ipa
"""
import plistlib
import struct
import sys
import zipfile

MACHO_64 = 0xFEEDFACF
CPU_ARM64 = 0x0100000C

# key -> why it matters if absent
REQUIRED = {
    "CFBundleIdentifier": "the phone cannot install an app without one",
    "CFBundleExecutable": "the bundle would have no entry point",
    "CFBundleShortVersionString": "TestFlight shows this as the version",
    "CFBundleVersion": "uploads are rejected if two builds share one",
    "CFBundleIconName": "App Store Connect rejects with ITMS-90713",
    "MinimumOSVersion": "iOS uses it to refuse incompatible installs",
    "NSCameraUsageDescription": "the app crashes the instant AR starts",
    "UILaunchScreen": "without it iOS letterboxes the app",
}


def fail(msg, problems):
    problems.append(msg)


def main(path):
    problems = []
    notes = []

    try:
        zf = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as exc:
        print(f"FAIL  {path} is not a readable ipa: {exc}")
        return 1

    names = zf.namelist()
    apps = {n.split("/")[1] for n in names
            if n.startswith("Payload/") and n.count("/") >= 2}
    apps = {a for a in apps if a.endswith(".app")}
    if len(apps) != 1:
        print(f"FAIL  expected exactly one .app in Payload/, found {apps}")
        return 1
    app = apps.pop()
    notes.append(f"bundle: {app}")

    # ---- Info.plist ------------------------------------------------------
    plist_path = f"Payload/{app}/Info.plist"
    if plist_path not in names:
        print(f"FAIL  no {plist_path}")
        return 1
    try:
        info = plistlib.loads(zf.read(plist_path))
    except Exception as exc:                       # noqa: BLE001
        print(f"FAIL  Info.plist does not parse: {exc}")
        return 1

    for key, why in REQUIRED.items():
        if key not in info:
            fail(f"Info.plist is missing {key} - {why}", problems)

    # A usage string that is present but empty is worse than missing: it
    # passes a key check and still shows the user a blank prompt.
    usage = info.get("NSCameraUsageDescription", "")
    if isinstance(usage, str) and len(usage.strip()) < 10:
        fail("NSCameraUsageDescription is empty or too short to be shown",
             problems)

    # ---- the icon actually compiled in -----------------------------------
    icon_name = info.get("CFBundleIconName")
    if icon_name:
        has_car = f"Payload/{app}/Assets.car" in names
        has_png = any(n.startswith(f"Payload/{app}/AppIcon")
                      and n.endswith(".png") for n in names)
        if not (has_car or has_png):
            fail(f"CFBundleIconName is {icon_name!r} but the bundle "
                 "contains no compiled icon", problems)
        else:
            notes.append("icon: compiled in"
                         + (" (Assets.car)" if has_car else " (loose png)"))

    # ---- the binary is real, and for the right CPU -----------------------
    exe_name = info.get("CFBundleExecutable")
    exe_path = f"Payload/{app}/{exe_name}" if exe_name else None
    if exe_path and exe_path in names:
        head = zf.read(exe_path)[:16]
        if len(head) >= 8:
            magic, cputype = struct.unpack("<II", head[:8])
            if magic != MACHO_64:
                fail(f"{exe_name} is not a 64-bit Mach-O "
                     f"(magic 0x{magic:08X})", problems)
            elif cputype != CPU_ARM64:
                fail(f"{exe_name} is not arm64 - it will not run on a "
                     f"phone (cputype 0x{cputype:08X})", problems)
            else:
                notes.append("binary: arm64 Mach-O")
    elif exe_path:
        fail(f"Info.plist names {exe_name} but it is not in the bundle",
             problems)

    # ---- report ----------------------------------------------------------
    size_mb = sum(zf.getinfo(n).file_size for n in names) / 1e6
    notes.append(f"uncompressed size: {size_mb:.1f} MB")
    for n in notes:
        print(f"      {n}")
    print()
    if problems:
        for p in problems:
            print(f"FAIL  {p}")
        print(f"\n{len(problems)} problem(s). This build is not installable.")
        return 1
    print(f"OK    {len(REQUIRED)} required keys present, icon and binary "
          "verified.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
