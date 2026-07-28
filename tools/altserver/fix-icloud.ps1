# Restores the iCloud install that AltServer needs, after a wipe left
# the product registered with Windows Installer but deleted from disk.
#
#   powershell -File tools/altserver/fix-icloud.ps1
#
# AltServer authenticates with Apple using DLLs that ship with iCloud
# for Windows - AOSKit.dll above all. It requires the standalone build
# from Apple, not the Microsoft Store one. When the files are gone but
# the registration remains, "repair" fails asking for iCloud64.msi from
# a temp folder that no longer exists; supplying the original package
# is what actually fixes it.
#
# The URL below is Apple's own CDN, and is the build AltStore's install
# guide specifies. It matches product code {8808B208-...}, i.e. the
# version already registered on this machine, so it repairs in place.
param([switch]$Force)
$ErrorActionPreference = 'Stop'

$url = 'https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe'
$cacheDir = "$env:LOCALAPPDATA\Theseus\apple-cache"
$setup = Join-Path $cacheDir 'iCloudSetup.exe'
$sevenZip = "$env:ProgramFiles\7-Zip\7z.exe"

function Find-AOSKit {
    $roots = @("${env:ProgramFiles(x86)}\Common Files\Apple",
               "$env:ProgramFiles\Common Files\Apple")
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        $hit = Get-ChildItem $r -Recurse -Filter AOSKit.dll -Force `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

$existing = Find-AOSKit
if ($existing -and -not $Force) {
    Write-Host "iCloud already provides $existing" -ForegroundColor Green
    Write-Host "Nothing to do. Start AltServer and try again."
    exit 0
}

# ---- fetch --------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
if ((Test-Path $setup) -and ((Get-Item $setup).Length -gt 50MB) -and -not $Force) {
    Write-Host ("Using cached installer ({0:N0} MB)." -f `
        ((Get-Item $setup).Length / 1MB)) -ForegroundColor Cyan
} else {
    Write-Host "Downloading iCloudSetup.exe from updates.cdn-apple.com"
    Write-Host "  (Apple's CDN; the build AltStore's guide specifies)"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $sw = [Diagnostics.Stopwatch]::StartNew()
    (New-Object Net.WebClient).DownloadFile($url, "$setup.part")
    $sw.Stop()
    # read the PE magic without -Encoding Byte, which only exists in 5.1
    $fs = [IO.File]::OpenRead("$setup.part")
    $sig = New-Object byte[] 2
    $fs.Read($sig, 0, 2) | Out-Null
    $fs.Close()
    if ($sig[0] -ne 0x4D -or $sig[1] -ne 0x5A) {
        Remove-Item "$setup.part" -Force
        throw "That download is not a Windows executable."
    }
    Move-Item "$setup.part" $setup -Force
    Write-Host ("  got {0:N0} MB in {1:N0}s" -f `
        ((Get-Item $setup).Length / 1MB), $sw.Elapsed.TotalSeconds)
}

# ---- unpack the MSI out of the self-extractor ---------------------------
# Running the .exe works too, but extracting lets us drive msiexec
# directly with REINSTALL flags, which is what forces the deleted files
# back rather than leaving the broken registration alone.
$msi = $null
if (Test-Path $sevenZip) {
    $stage = Join-Path $env:TEMP "icloud-stage-$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Write-Host "Extracting with 7-Zip..."
    & $sevenZip x $setup "-o$stage" -y | Out-Null
    $want = if ([Environment]::Is64BitOperatingSystem) { 'iCloud64.msi' } else { 'iCloud.msi' }
    $found = Get-ChildItem $stage -Recurse -Filter $want -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) {
        $msi = $found.FullName
        Write-Host "  found $want"
    } else {
        Write-Host "  $want not found inside the installer" -ForegroundColor Yellow
    }
} else {
    Write-Host "7-Zip not installed; falling back to the GUI installer." -ForegroundColor Yellow
}

# ---- install (needs elevation) ------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($msi) {
    # REINSTALLMODE=vomus rewrites every file even when the installer
    # believes the current version is already present.
    # not $args - that is an automatic variable
    $msiArgs = "/i `"$msi`" REINSTALL=ALL REINSTALLMODE=vomus /qb"
    Write-Host "Running: msiexec $msiArgs"
    if ($isAdmin) {
        $p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    } else {
        Write-Host "Accept the admin prompt when it appears." -ForegroundColor Yellow
        $p = Start-Process msiexec.exe -ArgumentList $msiArgs -Verb RunAs -Wait -PassThru
    }
    Write-Host "msiexec exit code: $($p.ExitCode)"
} else {
    Write-Host "Launching the iCloud installer - follow its prompts." -ForegroundColor Yellow
    Start-Process $setup -Wait
}

# ---- verify --------------------------------------------------------------
Write-Host ""
$aos = Find-AOSKit
if ($aos) {
    Write-Host "AOSKit.dll restored: $aos" -ForegroundColor Green
    Write-Host ""
    Write-Host "Start AltServer and click Install AltStore again." -ForegroundColor Green
    exit 0
}

Write-Host "AOSKit.dll is still missing." -ForegroundColor Red
Write-Host "Run the installer by hand and choose Repair:"
Write-Host "  $setup"
exit 1
