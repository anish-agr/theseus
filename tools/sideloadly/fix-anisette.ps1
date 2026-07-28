# Repairs the anisette bundle Sideloadly cannot download for itself.
#
#   powershell -File tools/sideloadly/fix-anisette.ps1
#   powershell -File tools/sideloadly/fix-anisette.ps1 -Protect
#   powershell -File tools/sideloadly/fix-anisette.ps1 -Force
#
# Sideloadly fetches its anisette DLLs from its own site into
# %LOCALAPPDATA%\Sideloadly\an. When that transfer dies part-way it
# reports "Local Anisette should be updated ... cannot find the file
# specified", and its retry deletes whatever is already there before
# failing again the same way - so a working set can be destroyed by
# answering Yes to the prompt.
#
#   -Protect  marks the DLLs read-only afterwards, so Sideloadly's
#             cleanup cannot delete them. Use it if the bundle keeps
#             disappearing. Undo with -Unprotect.
#   -Force    re-downloads even if the cached zip is present.
param(
    [switch]$Protect,
    [switch]$Unprotect,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

$root = "$env:LOCALAPPDATA\Sideloadly"
$an = "$root\an"
$exe = "$root\sideloadly.exe"
$cacheDir = "$env:LOCALAPPDATA\Theseus\anisette-cache"

if (-not (Test-Path $exe)) { throw "Sideloadly is not installed at $root" }

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

if ($Unprotect) {
    Get-ChildItem $an -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $_.IsReadOnly = $false }
    Write-Host "Cleared the read-only flag on $an" -ForegroundColor Green
    exit 0
}

$arch = Get-PEArch $exe
$url = if ($arch -eq 'x64') { 'https://sideloadly.io/anis-64.zip' }
       else { 'https://sideloadly.io/anis.zip' }

# ---- get the bundle, from cache when we already have it ------------------
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
$zip = Join-Path $cacheDir ("anis-$arch.zip")

$haveCache = (Test-Path $zip) -and ((Get-Item $zip).Length -gt 10MB) -and -not $Force
if ($haveCache) {
    Write-Host ("Using cached bundle ({0:N1} MB) - pass -Force to refetch." -f `
        ((Get-Item $zip).Length / 1MB)) -ForegroundColor Cyan
} else {
    Write-Host "Sideloadly is $arch, fetching $url"
    Write-Host "Downloading..." -NoNewline
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        (New-Object Net.WebClient).DownloadFile($url, "$zip.part")
    } catch {
        Write-Host ""
        Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    $sw.Stop()
    $sig = [byte[]](Get-Content "$zip.part" -Encoding Byte -TotalCount 2)
    if ($sig[0] -ne 0x50 -or $sig[1] -ne 0x4B) {
        Remove-Item "$zip.part" -Force
        throw "That download is not a zip - the server returned something else."
    }
    Move-Item "$zip.part" $zip -Force
    Write-Host (" got {0:N1} MB in {1:N0}s (cached for next time)" -f `
        ((Get-Item $zip).Length / 1MB), $sw.Elapsed.TotalSeconds)
}

# ---- what is actually in the bundle -------------------------------------
# Printed because a marker or manifest file would explain why Sideloadly
# decides a complete folder still "should be updated".
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
$entries = $archive.Entries | ForEach-Object { $_.FullName }
$archive.Dispose()
$nonDll = $entries | Where-Object { $_ -notmatch '\.dll$' -and $_ -notmatch '/$' }
Write-Host "Bundle contains $($entries.Count) entries"
if ($nonDll) {
    Write-Host "  non-DLL entries (possible version markers):"
    $nonDll | ForEach-Object { Write-Host "    $_" }
}

# ---- install -------------------------------------------------------------
$running = Get-Process -Name 'sideloadly', 'sideloadlydaemon' -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "Closing Sideloadly first ($($running.Count) process(es))..."
    $running | Stop-Process -Force
    Start-Sleep -Seconds 2
}

# Clear read-only from a previous -Protect run, or the copy below fails.
Get-ChildItem $an -Force -ErrorAction SilentlyContinue |
    ForEach-Object { $_.IsReadOnly = $false }

$stage = Join-Path $env:TEMP "anisette-stage-$(Get-Random)"
Expand-Archive -Path $zip -DestinationPath $stage -Force

# Some builds wrap everything in one folder inside the zip.
$src = $stage
$top = @(Get-ChildItem $stage -Force)
if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $src = $top[0].FullName }

New-Item -ItemType Directory -Force -Path $an | Out-Null
# -Force on Get-ChildItem so hidden marker files are not silently skipped.
Get-ChildItem $src -Force | Copy-Item -Destination $an -Recurse -Force
Remove-Item $stage -Recurse -Force

# ---- verify --------------------------------------------------------------
$dlls = @(Get-ChildItem $an -Filter *.dll -Force -ErrorAction SilentlyContinue)
Write-Host ""
Write-Host "Installed $($dlls.Count) DLLs into $an"

$core = Join-Path $an 'iTunesCore.dll'
if (-not (Test-Path $core)) {
    Write-Host "iTunesCore.dll is missing - the bundle did not contain it." `
        -ForegroundColor Red
    exit 1
}
$coreArch = Get-PEArch $core
if ($coreArch -ne $arch) {
    Write-Host "MISMATCH: Sideloadly is $arch, DLLs are $coreArch." -ForegroundColor Red
    exit 1
}
Write-Host "iTunesCore.dll present, $coreArch" -ForegroundColor Green

if ($Protect) {
    Get-ChildItem $an -Force | ForEach-Object { $_.IsReadOnly = $true }
    Write-Host "Marked read-only so Sideloadly cannot delete them." -ForegroundColor Green
    Write-Host "Undo with: -Unprotect"
}

Write-Host ""
Write-Host "Now start Sideloadly." -ForegroundColor Green
Write-Host "If it offers to download or update anisette, answer NO." -ForegroundColor Yellow
Write-Host "Saying yes deletes this working set and re-runs the broken"
Write-Host "download, which is the loop you have been stuck in."
