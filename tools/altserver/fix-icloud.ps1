# Restores the iCloud install that AltServer needs, after a wipe left
# the product registered with Windows Installer but deleted from disk.
#
# Run from an ADMINISTRATOR PowerShell (or accept the elevation prompt):
#
#   powershell -File tools/altserver/fix-icloud.ps1
#
# AltServer authenticates with Apple using AOSKit.dll, which ships with
# iCloud for Windows - the standalone build from Apple, not the
# Microsoft Store one. Two things make this harder than it sounds:
#
#   1. If a cleanup deleted iCloud's files but left it registered,
#      repair fails asking for iCloud64.msi from a temp folder that no
#      longer exists. The stale registration has to go first.
#
#   2. iCloud64.msi cannot be installed on its own. Its custom actions
#      need Apple Application Support already present, and installing it
#      alone dies with "a program run as part of the setup did not
#      finish as expected". iCloudSetup.exe installs the prerequisites
#      first; this script reproduces that order.
#
# The URL is Apple's own CDN, and is the build AltStore's install guide
# specifies. It matches the product code already registered here.
param([switch]$Force)
$ErrorActionPreference = 'Stop'

$url = 'https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F448-11EA-8CC0-99D41950005E/iCloudSetup.exe'
$cacheDir = "$env:LOCALAPPDATA\Theseus\apple-cache"
$setup = Join-Path $cacheDir 'iCloudSetup.exe'
$sevenZip = "$env:ProgramFiles\7-Zip\7z.exe"
$staleProduct = '{8808B208-87D1-4725-8192-76D257E9DEAE}'

function Find-AOSKit {
    foreach ($r in @("${env:ProgramFiles(x86)}\Common Files\Apple",
                     "$env:ProgramFiles\Common Files\Apple")) {
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
    Write-Host "Nothing to do. Start AltServer and click Install AltStore."
    exit 0
}

# ---- elevate once, up front, rather than per-package ---------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Installing MSI packages needs administrator rights."
    Write-Host "Re-launching elevated - accept the prompt." -ForegroundColor Yellow
    $self = $MyInvocation.MyCommand.Path
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
                '-File', "`"$self`"")
    if ($Force) { $psArgs += '-Force' }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $psArgs
    } catch {
        Write-Host "Elevation was declined." -ForegroundColor Red
        Write-Host "Open PowerShell as administrator and run this script there."
        exit 1
    }
    exit 0
}

# ---- fetch ---------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
if ((Test-Path $setup) -and ((Get-Item $setup).Length -gt 50MB) -and -not $Force) {
    Write-Host ("Using cached installer ({0:N0} MB)." -f `
        ((Get-Item $setup).Length / 1MB)) -ForegroundColor Cyan
} else {
    Write-Host "Downloading iCloudSetup.exe from updates.cdn-apple.com"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (New-Object Net.WebClient).DownloadFile($url, "$setup.part")
    $fs = [IO.File]::OpenRead("$setup.part")
    $sig = New-Object byte[] 2
    $fs.Read($sig, 0, 2) | Out-Null
    $fs.Close()
    if ($sig[0] -ne 0x4D -or $sig[1] -ne 0x5A) {
        Remove-Item "$setup.part" -Force
        throw "That download is not a Windows executable."
    }
    Move-Item "$setup.part" $setup -Force
    Write-Host ("  got {0:N0} MB" -f ((Get-Item $setup).Length / 1MB))
}

# ---- unpack --------------------------------------------------------------
if (-not (Test-Path $sevenZip)) {
    Write-Host "7-Zip not found; running the GUI installer instead." -ForegroundColor Yellow
    Start-Process $setup -Wait
    $aos = Find-AOSKit
    if ($aos) { Write-Host "AOSKit.dll restored: $aos" -ForegroundColor Green; exit 0 }
    exit 1
}

$stage = Join-Path $cacheDir ("extract-" + (Get-Random))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Write-Host "Extracting packages..."
& $sevenZip x $setup "-o$stage" -y | Out-Null
Get-ChildItem $stage -Filter *.msi | ForEach-Object {
    "  {0,-32} {1:N1} MB" -f $_.Name, ($_.Length / 1MB)
}

# ---- install, in iCloudSetup.exe's own order -----------------------------
$logDir = Join-Path $cacheDir 'msi-logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Invoke-Msi($label, $msiArgs, $log) {
    $full = $msiArgs + @('/qn', '/norestart', '/l*v', "`"$log`"")
    $p = Start-Process msiexec.exe -ArgumentList $full -Wait -PassThru
    Write-Host ("  {0,-38} exit {1}" -f $label, $p.ExitCode)
    return $p.ExitCode
}

Write-Host ""
Write-Host "Clearing the stale registration..."
Invoke-Msi "uninstall stale iCloud" @('/x', $staleProduct) `
    (Join-Path $logDir '00-uninstall.log') | Out-Null

Write-Host "Installing, prerequisites first..."
$order = @(
    @{ file = 'AppleApplicationSupport64.msi'; label = 'Apple Application Support (x64)' },
    @{ file = 'AppleApplicationSupport.msi';   label = 'Apple Application Support (x86)' },
    @{ file = 'AppleSoftwareUpdate.msi';       label = 'Apple Software Update' },
    @{ file = 'Bonjour64.msi';                 label = 'Bonjour' },
    @{ file = 'iCloud64.msi';                  label = 'iCloud' }
)
$n = 1
$failures = @()
foreach ($item in $order) {
    $path = Join-Path $stage $item.file
    if (-not (Test-Path $path)) {
        Write-Host ("  {0,-38} MISSING from installer" -f $item.label) -ForegroundColor Yellow
        continue
    }
    $log = Join-Path $logDir ("{0:D2}-{1}.log" -f $n, ($item.file -replace '\.msi$', ''))
    $code = Invoke-Msi $item.label @('/i', "`"$path`"") $log
    # 0 = ok, 3010 = ok but wants a reboot
    if ($code -ne 0 -and $code -ne 3010) { $failures += "$($item.label) (exit $code, see $log)" }
    $n++
}

# ---- verify --------------------------------------------------------------
Write-Host ""
$aos = Find-AOSKit
if ($aos) {
    Write-Host "AOSKit.dll restored: $aos" -ForegroundColor Green
    Write-Host ""
    Write-Host "Start AltServer and click Install AltStore." -ForegroundColor Green
    exit 0
}

Write-Host "AOSKit.dll is still missing." -ForegroundColor Red
foreach ($f in $failures) { Write-Host "  failed: $f" -ForegroundColor Red }
Write-Host "Verbose MSI logs are in $logDir"
exit 1
