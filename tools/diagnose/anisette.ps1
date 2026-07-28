# Tells you whether a Sideloadly anisette failure is your machine's
# fault. It is worth running BEFORE reinstalling anything, because the
# usual advice (reinstall iTunes, reinstall the VC++ redists, wipe every
# trace of Apple) fixes none of the failures it can actually detect.
#
#   powershell -File tools/diagnose/anisette.ps1
#
# Anisette is the Apple-ID authentication Sideloadly performs by loading
# Apple's iTunes DLLs. Those DLLs are 32-bit, so the interesting test
# has to run in a 32-bit process; this script re-launches itself into
# one if needed.
$ErrorActionPreference = 'Stop'

if ([IntPtr]::Size -eq 8) {
    $wow = "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $wow) {
        & $wow -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
    Write-Host "No 32-bit PowerShell found; DLL checks will be skipped." `
        -ForegroundColor Yellow
}

$root = "$env:LOCALAPPDATA\Sideloadly"
$an = "$root\an"
$problems = @()
$verdicts = @()

function Section($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }

# ---- 1. is Sideloadly even installed -----------------------------------
Section "Sideloadly install"
if (-not (Test-Path $an)) {
    Write-Host "  no anisette folder at $an"
    Write-Host "  Sideloadly has never downloaded the DLLs. Launch it and"
    Write-Host "  accept the download prompt."
    exit 1
}
Get-ChildItem $root -Filter *.exe -Force | ForEach-Object {
    "  {0,-24} built {1}" -f $_.Name, $_.LastWriteTime.ToString('yyyy-MM-dd')
}
$exe = Get-Item "$root\sideloadly.exe" -ErrorAction SilentlyContinue
if ($exe -and $exe.LastWriteTime -lt (Get-Date).AddMonths(-6)) {
    $problems += ("Sideloadly binary is from {0}. Apple moves its auth " +
        "endpoints; a stale build is the most common cause of " +
        "'Login failed: 404'.") -f $exe.LastWriteTime.ToString('MMMM yyyy')
}

# ---- 2. the DLLs themselves --------------------------------------------
Section "Anisette DLL load test (32-bit)"
if ([IntPtr]::Size -ne 4) {
    Write-Host "  skipped (not running 32-bit)"
} else {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Loader {
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr LoadLibraryExW(string f, IntPtr h, uint flags);
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool SetDllDirectoryW(string p);
}
"@
    [Loader]::SetDllDirectoryW($an) | Out-Null
    Set-Location $an

    # dependency order: the first failure is the real one, everything
    # after it fails only as a consequence
    $order = @(
        'pthreadVC2.dll', 'zlib1.dll', 'libcache.dll', 'objc.dll',
        'libdispatch.dll', 'icudt55.dll', 'libicuuc.dll', 'libicuin.dll',
        'CoreFoundation.dll', 'ASL.dll', 'Foundation.dll', 'SQLite3.dll',
        'CoreGraphics.dll', 'CoreText.dll', 'QuartzCore.dll',
        'CoreVideo.dll', 'CoreMedia.dll', 'CoreAudioToolbox.dll',
        'AVFoundationCF.dll', 'MediaAccessibility.dll', 'libxml2.dll',
        'libxslt.dll', 'libtidy.dll', 'WTF.dll', 'JavaScriptCore.dll',
        'WebKit.dll', 'CFNetwork.dll', 'ApplePushService.dll',
        'CoreFP.dll', 'CoreADI.dll', 'iTunesCore.dll')

    $failed = @()
    foreach ($d in $order) {
        $full = Join-Path $an $d
        if (-not (Test-Path $full)) {
            Write-Host ("  {0,-24} MISSING" -f $d) -ForegroundColor Red
            $failed += $d
            continue
        }
        # LOAD_WITH_ALTERED_SEARCH_PATH so siblings resolve from an\
        $h = [Loader]::LoadLibraryExW($full, [IntPtr]::Zero, 8)
        if ($h -eq [IntPtr]::Zero) {
            $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $msg = (New-Object ComponentModel.Win32Exception($e)).Message
            Write-Host ("  {0,-24} FAIL err={1} {2}" -f $d, $e, $msg) `
                -ForegroundColor Red
            $failed += $d
        }
    }
    if ($failed.Count -eq 0) {
        Write-Host "  all $($order.Count) DLLs loaded clean" `
            -ForegroundColor Green
        $verdicts += "the anisette DLL set is complete and healthy"
    } else {
        $problems += "these DLLs will not load: $($failed -join ', ')"
    }
}

# ---- 3. VC++ runtimes ---------------------------------------------------
Section "Visual C++ runtimes"
$need = @{
    'VC++ 2013 x86' = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\12.0\VC\Runtimes\x86'
    'VC++ 2010 x86' = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\10.0\VC\VCRedist\x86'
}
foreach ($k in $need.Keys | Sort-Object) {
    $p = $need[$k]
    if (Test-Path $p) {
        Write-Host ("  {0,-16} installed {1}" -f $k,
            (Get-ItemProperty $p).Version) -ForegroundColor Green
    } else {
        Write-Host ("  {0,-16} MISSING" -f $k) -ForegroundColor Red
        $problems += "$k is not installed (the x86 build is the one that matters)"
    }
}
foreach ($dll in @('msvcr120.dll', 'msvcr100.dll')) {
    $ok = Test-Path "$env:WINDIR\SysWOW64\$dll"
    Write-Host ("  SysWOW64\{0,-14} {1}" -f $dll, $(if ($ok) { 'present' } else { 'MISSING' }))
    if (-not $ok) { $problems += "SysWOW64\$dll is missing" }
}

# ---- 4. things that shadow Apple's DLLs ---------------------------------
Section "Interference"
$stray = @(
    "$env:ProgramFiles\Common Files\Apple\Apple Application Support",
    "${env:ProgramFiles(x86)}\Common Files\Apple\Apple Application Support")
$anyStray = $false
foreach ($p in $stray) {
    if (Test-Path $p) {
        Write-Host "  installed Apple Application Support: $p"
        $anyStray = $true
    }
}
$applePath = ($env:PATH -split ';') | Where-Object { $_ -match 'Apple|iTunes' }
if ($applePath) {
    $applePath | ForEach-Object { Write-Host "  PATH entry: $_" }
    $anyStray = $true
}
if (-not $anyStray) {
    Write-Host "  nothing shadowing the bundled DLLs" -ForegroundColor Green
    $verdicts += "no stray Apple install or PATH entry is interfering"
}

# ---- 5. can the daemon see the phone ------------------------------------
Section "Device visibility"
$svc = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "  Apple Mobile Device Service: $($svc.Status)"
} else {
    Write-Host "  Apple Mobile Device Service not installed" -ForegroundColor Yellow
}
$log = "$root\sideloadlydaemon.log"
if (Test-Path $log) {
    $line = Get-Content $log -Tail 400 |
        Where-Object { $_ -match 'Udid:' } | Select-Object -Last 1
    if ($line -and $line -match 'Udid:(\S+)\s+Name:(.+?)\s+IsM1') {
        Write-Host ("  daemon sees: {0} ({1})" -f $matches[2], $matches[1]) `
            -ForegroundColor Green
        if ($line -match 'LastError:\s*FailuresCount:0') {
            $verdicts += "the phone is detected, paired and error-free"
        }
    } else {
        Write-Host "  no device in the recent daemon log" -ForegroundColor Yellow
        $problems += "the daemon has not seen a device - check cable and 'Trust'"
    }
} else {
    Write-Host "  no daemon log yet"
}

# ---- verdict -------------------------------------------------------------
Section "Verdict"
foreach ($v in $verdicts) { Write-Host "  OK   $v" -ForegroundColor Green }
foreach ($p in $problems) { Write-Host "  BAD  $p" -ForegroundColor Red }
Write-Host ""
if ($problems.Count -eq 0) {
    Write-Host "Nothing on this machine is broken." -ForegroundColor Green
    Write-Host "Reinstalling iTunes, the redists or Sideloadly will not"
    Write-Host "change anything. If sideloading still fails, the fault is"
    Write-Host "in the Sideloadly build or Apple's servers - see"
    Write-Host "docs/INSTALL.md, 'If anisette fails'."
} else {
    Write-Host "Fix the BAD lines above, in order." -ForegroundColor Yellow
}
