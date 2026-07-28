# Tells you whether a Sideloadly anisette failure is your machine's
# fault. It is worth running BEFORE reinstalling anything, because the
# usual advice (reinstall iTunes, reinstall the VC++ redists, wipe every
# trace of Apple) fixes none of the failures it can actually detect.
#
#   powershell -File tools/diagnose/anisette.ps1
#
# Anisette is the Apple-ID authentication Sideloadly performs by loading
# Apple's iTunes DLLs. They must match the app's bitness, so the load
# test has to run in a process of the same architecture; this script
# works out which and re-launches itself if needed.
$ErrorActionPreference = 'Stop'

$root = "$env:LOCALAPPDATA\Sideloadly"
$an = "$root\an"
$problems = @()
$verdicts = @()

function Section($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }

function Get-PEArch($path) {
    $fs = [IO.File]::OpenRead($path)
    $br = New-Object IO.BinaryReader($fs)
    $fs.Seek(0x3C, 'Begin') | Out-Null
    $peOff = $br.ReadInt32()
    $fs.Seek($peOff + 4, 'Begin') | Out-Null
    $machine = $br.ReadUInt16()
    $br.Close(); $fs.Close()
    switch ($machine) { 0x014c { 'x86' } 0x8664 { 'x64' } default { 'unknown' } }
}

# ---- 0. is there anything to test at all -------------------------------
if (-not (Test-Path "$root\sideloadly.exe")) {
    Write-Host "Sideloadly is not installed at $root" -ForegroundColor Red
    exit 1
}
$exeArch = Get-PEArch "$root\sideloadly.exe"
$core = Join-Path $an 'iTunesCore.dll'
$dllArch = if (Test-Path $core) { Get-PEArch $core } else { $null }

if (-not $dllArch) {
    $n = @(Get-ChildItem $an -Filter *.dll -ErrorAction SilentlyContinue).Count
    Write-Host "`nThe anisette bundle is missing or incomplete " `
        -ForegroundColor Red -NoNewline
    Write-Host "($n DLLs, no iTunesCore.dll)." -ForegroundColor Red
    Write-Host "Sideloadly's own download did not finish. Run:"
    Write-Host "  powershell -File tools/sideloadly/fix-anisette.ps1"
    exit 1
}

# A 64-bit process cannot load 32-bit DLLs and vice versa; this mismatch
# is a real failure mode, usually left behind by switching builds.
if ($exeArch -ne $dllArch) {
    Write-Host "`nSideloadly is $exeArch but its anisette DLLs are $dllArch." `
        -ForegroundColor Red
    Write-Host "They can never load. Delete $an and run:"
    Write-Host "  powershell -File tools/sideloadly/fix-anisette.ps1"
    exit 1
}

# Re-launch into a host matching the DLLs so LoadLibrary is meaningful.
$hostArch = if ([IntPtr]::Size -eq 8) { 'x64' } else { 'x86' }
if ($hostArch -ne $dllArch) {
    if ($dllArch -eq 'x86') {
        $wow = "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
        if (Test-Path $wow) {
            & $wow -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
            exit $LASTEXITCODE
        }
    } else {
        $native = "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe"
        if (Test-Path $native) {
            & $native -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
            exit $LASTEXITCODE
        }
    }
    Write-Host "Cannot start a $dllArch PowerShell; skipping the load test." `
        -ForegroundColor Yellow
}

# ---- 1. the install ----------------------------------------------------
Section "Sideloadly install"
Get-ChildItem $root -Filter *.exe -Force | ForEach-Object {
    "  {0,-24} built {1}" -f $_.Name, $_.LastWriteTime.ToString('yyyy-MM-dd')
}
"  architecture: $exeArch (anisette DLLs: $dllArch)"
$exe = Get-Item "$root\sideloadly.exe"
if ($exe.LastWriteTime -lt (Get-Date).AddMonths(-6)) {
    # Deliberately not a failure. Sideloadly ships infrequently, so the
    # current release is often months old - the date alone proves
    # nothing, and calling it a fault sends you reinstalling for no
    # reason. It is only worth checking if you are seeing auth errors.
    $built = $exe.LastWriteTime.ToString('MMMM yyyy')
    Write-Host "  note: this build is from $built. Only relevant if you see" `
        -ForegroundColor DarkGray
    Write-Host "        'Login failed: 404' - then check sideloadly.io for" `
        -ForegroundColor DarkGray
    Write-Host "        a newer release." -ForegroundColor DarkGray
}

# ---- 2. the DLLs themselves --------------------------------------------
Section "Anisette DLL load test ($dllArch)"
if ($hostArch -ne $dllArch) {
    Write-Host "  skipped (host architecture does not match)"
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

    # Dependency order, so the FIRST failure is the real one - everything
    # after it fails only as a consequence. Anything the bundle does not
    # ship is skipped rather than reported: the set varies by version.
    $order = @(
        'pthreadVC2.dll', 'zlib1.dll', 'libcache.dll', 'objc.dll',
        'libdispatch.dll', 'icudt55.dll', 'libicuuc.dll', 'libicuin.dll',
        'CoreFoundation.dll', 'ASL.dll', 'Foundation.dll', 'SQLite3.dll',
        'CoreGraphics.dll', 'CoreText.dll', 'QuartzCore.dll',
        'CoreVideo.dll', 'CoreMedia.dll', 'CoreAudioToolbox.dll',
        'AVFoundationCF.dll', 'MediaAccessibility.dll', 'libxml2.dll',
        'libxslt.dll', 'libtidy.dll', 'WTF.dll', 'JavaScriptCore.dll',
        'WebKit.dll', 'CFNetwork.dll', 'ApplePushService.dll',
        'CoreFP.dll', 'CoreADI.dll', 'AuthKitWin.dll', 'iTunesCore.dll')

    $failed = @()
    $tested = 0
    foreach ($d in $order) {
        $full = Join-Path $an $d
        if (-not (Test-Path $full)) { continue }
        $tested++
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
        Write-Host "  all $tested DLLs loaded clean" -ForegroundColor Green
        $verdicts += "the anisette DLL set is complete and healthy"
    } else {
        $problems += "these DLLs will not load: $($failed -join ', ')"
    }
}

# ---- 3. VC++ runtimes ---------------------------------------------------
Section "Visual C++ runtimes"
$node = if ($dllArch -eq 'x86') { 'WOW6432Node\' } else { '' }
$need = @{
    'VC++ 2013' = "HKLM:\SOFTWARE\${node}Microsoft\VisualStudio\12.0\VC\Runtimes\$dllArch"
    'VC++ 2010' = "HKLM:\SOFTWARE\${node}Microsoft\VisualStudio\10.0\VC\VCRedist\$dllArch"
}
foreach ($k in $need.Keys | Sort-Object) {
    $p = $need[$k]
    if (Test-Path $p) {
        Write-Host ("  {0,-12} {1,-4} installed {2}" -f $k, $dllArch,
            (Get-ItemProperty $p).Version) -ForegroundColor Green
    } else {
        Write-Host ("  {0,-12} {1,-4} registry entry absent" -f $k, $dllArch) `
            -ForegroundColor Yellow
    }
}
$sysDir = if ($dllArch -eq 'x86') { 'SysWOW64' } else { 'System32' }
foreach ($dll in @('msvcr120.dll', 'msvcr100.dll')) {
    $ok = Test-Path "$env:WINDIR\$sysDir\$dll"
    Write-Host ("  {0}\{1,-14} {2}" -f $sysDir, $dll,
        $(if ($ok) { 'present' } else { 'MISSING' }))
    if (-not $ok) { $problems += "$sysDir\$dll is missing" }
}

# ---- 4. things that shadow Apple's DLLs ---------------------------------
Section "Interference"
$anyStray = $false
foreach ($p in @(
    "$env:ProgramFiles\Common Files\Apple\Apple Application Support",
    "${env:ProgramFiles(x86)}\Common Files\Apple\Apple Application Support")) {
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
if ((Test-Path $log) -and (Get-Item $log).Length -gt 0) {
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
    Write-Host "  no daemon log yet (fresh install)"
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
