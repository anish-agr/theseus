# Finishes the anisette download Sideloadly gives up on.
#
#   powershell -File tools/sideloadly/fix-anisette.ps1
#
# Sideloadly fetches its anisette DLLs from its own site and writes them
# to %LOCALAPPDATA%\Sideloadly\an. When that transfer dies part-way the
# app reports "Local Anisette should be updated ... cannot find the file
# specified" and its retry button does not reliably resume. This does the
# same download in one shot and verifies the result.
#
# The URL below is the one compiled into sideloadly.exe - this fetches
# exactly what the app would have fetched, from the same host.
$ErrorActionPreference = 'Stop'

$root = "$env:LOCALAPPDATA\Sideloadly"
$an = "$root\an"
$exe = "$root\sideloadly.exe"

if (-not (Test-Path $exe)) {
    throw "Sideloadly is not installed at $root"
}

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

# The bundle has to match the app's bitness: a 64-bit process cannot
# load 32-bit DLLs, and that mismatch is its own confusing failure.
$arch = Get-PEArch $exe
$url = if ($arch -eq 'x64') { 'https://sideloadly.io/anis-64.zip' }
       else { 'https://sideloadly.io/anis.zip' }
Write-Host "Sideloadly is $arch, so fetching $url" -ForegroundColor Cyan

# File locks: the app and its daemon both hold these DLLs open.
$running = Get-Process -Name 'sideloadly', 'sideloadlydaemon' -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "Closing Sideloadly first ($($running.Count) process(es))..."
    $running | Stop-Process -Force
    Start-Sleep -Seconds 2
}

$tmp = Join-Path $env:TEMP "anisette-$(Get-Random).zip"
Write-Host "Downloading..." -NoNewline
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    # WebClient rather than Invoke-WebRequest: no progress-bar overhead,
    # which matters for a bundle this size.
    (New-Object Net.WebClient).DownloadFile($url, $tmp)
} catch {
    Write-Host ""
    Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "If this is a network block, try a different connection;"
    Write-Host "the file is served over plain HTTPS from sideloadly.io."
    exit 1
}
$sw.Stop()
$size = (Get-Item $tmp).Length
Write-Host (" got {0:N1} MB in {1:N0}s" -f ($size / 1MB), $sw.Elapsed.TotalSeconds)

# Guard against a captive portal or error page saved as a .zip
$sig = [byte[]](Get-Content $tmp -Encoding Byte -TotalCount 2)
if ($sig[0] -ne 0x50 -or $sig[1] -ne 0x4B) {
    Remove-Item $tmp -Force
    throw "That download is not a zip file - the server returned something else."
}

$stage = Join-Path $env:TEMP "anisette-stage-$(Get-Random)"
Expand-Archive -Path $tmp -DestinationPath $stage -Force

# Some builds wrap everything in a single folder inside the zip.
$src = $stage
$top = @(Get-ChildItem $stage)
if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $src = $top[0].FullName }

New-Item -ItemType Directory -Force -Path $an | Out-Null
Copy-Item "$src\*" -Destination $an -Recurse -Force
Remove-Item $tmp, $stage -Recurse -Force

# ---- verify, rather than assume -----------------------------------------
$dlls = Get-ChildItem $an -Filter *.dll -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Installed $($dlls.Count) DLLs into $an"

$core = Join-Path $an 'iTunesCore.dll'
if (-not (Test-Path $core)) {
    Write-Host "iTunesCore.dll is STILL missing - the bundle did not " `
        -ForegroundColor Red -NoNewline
    Write-Host "contain it." -ForegroundColor Red
    exit 1
}
$coreArch = Get-PEArch $core
Write-Host "iTunesCore.dll present, $coreArch"
if ($coreArch -ne $arch) {
    Write-Host "MISMATCH: Sideloadly is $arch but the DLLs are $coreArch." `
        -ForegroundColor Red
    Write-Host "Delete $an and re-run; the wrong bundle was fetched."
    exit 1
}

Write-Host ""
Write-Host "Done. Start Sideloadly and try the install again." -ForegroundColor Green
Write-Host "To confirm the DLLs actually load:"
Write-Host "  powershell -File tools/diagnose/anisette.ps1"
