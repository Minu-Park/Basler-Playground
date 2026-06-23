param(
    [string]$PlaygroundRoot = "C:\Users\minwoo\Documents\Playground-ifw-components",
    [string]$MetadataUrl = "https://github.com/Minu-Park/Basler-Playground/releases/download/updater-validation-v0.1.3-20260624/latest.json",
    [string]$InstallRoot = "C:\Program Files\Basler Playground Validation",
    [string]$ReleaseRepository = "Minu-Park/Basler-Playground",
    [switch]$Cleanup,
    [switch]$ElevatedInstall,
    [string]$BaselineInstaller,
    [string]$Probe
)

$ErrorActionPreference = "Stop"

if ($ElevatedInstall) {
    if (-not $BaselineInstaller -or -not $Probe) { throw "Elevated installation inputs are missing." }
    if (Test-Path $InstallRoot) { throw "Validation install root already exists: $InstallRoot" }
    & $BaselineInstaller --verbose --root $InstallRoot --accept-licenses --reject-messages `
        --no-default-installations --confirm-command install Playground
    if ($LASTEXITCODE -ne 0) { throw "Elevated baseline installation failed with exit code $LASTEXITCODE." }
    Copy-Item -LiteralPath $Probe -Destination (Join-Path $InstallRoot "Playground.exe") -Force
    exit 0
}

if ($Cleanup) {
    $maintenanceTool = Join-Path $InstallRoot "MaintenanceTool.exe"
    if (-not (Test-Path $maintenanceTool)) { throw "Validation MaintenanceTool was not found: $maintenanceTool" }
    $process = Start-Process -FilePath $maintenanceTool -Verb RunAs -ArgumentList @("--confirm-command", "purge") -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Elevated validation cleanup failed with exit code $($process.ExitCode)." }
    Write-Host "Program Files validation installation removed."
    exit 0
}

$PlaygroundRoot = (Resolve-Path $PlaygroundRoot).Path
$Probe = Join-Path $PlaygroundRoot "build/installer-validation/app-probe-0.1.2/Playground.exe"
if (-not (Test-Path $Probe)) { throw "Application probe is missing. Run Invoke-ApplicationUpdateValidation.ps1 first." }
if (Test-Path $InstallRoot) { throw "Validation install root already exists; inspect or clean it first: $InstallRoot" }

$release = gh release view --repo $ReleaseRepository --json tagName,assets | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Failed to resolve the stable baseline release." }
$asset = @($release.assets | Where-Object { $_.name -match 'windows-x64\.exe$' -and $_.name -notmatch '\.sha256$' }) | Select-Object -First 1
if (-not $asset) { throw "Stable release has no Windows x64 installer." }
$cacheRoot = Join-Path (Split-Path $PSScriptRoot -Parent) "build/installer-validation/cache/$($release.tagName)"
$BaselineInstaller = Join-Path $cacheRoot $asset.name
if (-not (Test-Path $BaselineInstaller)) {
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    gh release download $release.tagName --repo $ReleaseRepository --pattern $asset.name --dir $cacheRoot
    if ($LASTEXITCODE -ne 0) { throw "Failed to download the baseline installer." }
}

$arguments = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath,
    "-ElevatedInstall", "-InstallRoot", $InstallRoot,
    "-BaselineInstaller", $BaselineInstaller, "-Probe", $Probe
)
$elevated = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList ($arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -Wait -PassThru
if ($elevated.ExitCode -ne 0) { throw "Elevated fixture preparation failed with exit code $($elevated.ExitCode)." }

$env:PLAYGROUND_UPDATE_TEST_METADATA_URL = $MetadataUrl
try {
    Start-Process -FilePath (Join-Path $InstallRoot "Playground.exe") -WorkingDirectory $InstallRoot | Out-Null
}
finally {
    Remove-Item Env:\PLAYGROUND_UPDATE_TEST_METADATA_URL -ErrorAction SilentlyContinue
}

Write-Host "Playground opened from the isolated Program Files fixture."
Write-Host "Choose Help > Check for Updates... > Install Update and approve the updater UAC prompt."
Write-Host "After confirming version 0.1.3, clean up with:"
Write-Host ".\installer-validation\Start-ProgramFilesUpdateValidation.ps1 -Cleanup"
