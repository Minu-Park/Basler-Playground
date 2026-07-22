param(
    [string]$PlaygroundRoot = "C:\Users\minwoo\Documents\Playground",
    [string]$MetadataUrl = "https://github.com/Minu-Park/Basler-Playground/releases/download/beta-channel/latest-beta.json",
    [string]$CandidateVersion = "0.1.3-beta.1",
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "BaslerPlaygroundUpdaterValidation"),
    [string]$ReleaseRepository = "Minu-Park/Basler-Playground"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-CheckedProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$Label, [string]$LogRoot)
    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '-'
    $stdout = Join-Path $LogRoot "$safeLabel.stdout.log"
    $stderr = Join-Path $LogRoot "$safeLabel.stderr.log"
    $quoted = @($ArgumentList | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
    $process = Start-Process -FilePath $FilePath -ArgumentList $quoted -Wait -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($process.ExitCode -ne 0) {
        throw "$Label failed with exit code $($process.ExitCode)."
    }
}

if ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -match "WDAGUtilityAccount") {
    throw "Host validation must not run inside Windows Sandbox."
}
if (Test-Path $InstallRoot) {
    throw "Dedicated validation install root already exists; inspect or remove it explicitly: $InstallRoot"
}

$PlaygroundRoot = (Resolve-Path $PlaygroundRoot).Path
$release = gh release view --repo $ReleaseRepository --json tagName,assets | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Failed to resolve the stable baseline release." }
$baselineVersion = $release.tagName.TrimStart("v")
$probe = Join-Path $PlaygroundRoot "build/installer-validation/app-probe-$baselineVersion/Playground.exe"
$candidateRepository = Join-Path $PlaygroundRoot "build/installer-validation/repository-$CandidateVersion"
if (-not (Test-Path $probe) -or -not (Test-Path (Join-Path $candidateRepository "Updates.xml"))) {
    throw "Run Invoke-ApplicationUpdateValidation.ps1 -CandidateVersion $CandidateVersion first."
}
$asset = @($release.assets | Where-Object { $_.name -match 'windows-x64\.exe$' -and $_.name -notmatch '\.sha256$' }) | Select-Object -First 1
if (-not $asset) { throw "Stable release has no Windows x64 installer." }
$cacheRoot = Join-Path (Split-Path $PSScriptRoot -Parent) "build/installer-validation/cache/$($release.tagName)"
$baselineInstaller = Join-Path $cacheRoot $asset.name
if (-not (Test-Path $baselineInstaller)) {
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    gh release download $release.tagName --repo $ReleaseRepository --pattern $asset.name --dir $cacheRoot
    if ($LASTEXITCODE -ne 0) { throw "Failed to download the baseline installer." }
}

$runRoot = Join-Path (Split-Path $PSScriptRoot -Parent) ("build/host-update-validation/" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$result = [ordered]@{ passed = $false; startedAt = (Get-Date).ToUniversalTime().ToString("o"); installRoot = $InstallRoot; metadataUrl = $MetadataUrl }
$maintenanceTool = Join-Path $InstallRoot "MaintenanceTool.exe"

try {
    Invoke-CheckedProcess $baselineInstaller @(
        "--verbose", "--root", $InstallRoot, "--accept-licenses", "--reject-messages",
        "--no-default-installations", "--confirm-command", "install", "Playground"
    ) "Baseline installation" $runRoot

    Copy-Item -LiteralPath $probe -Destination (Join-Path $InstallRoot "Playground.exe") -Force
    $updateResult = Join-Path $runRoot "app-update-exit.txt"
    $env:PLAYGROUND_UPDATE_TEST_METADATA_URL = $MetadataUrl
    $env:PLAYGROUND_UPDATE_TEST_RESULT = $updateResult
    $env:PLAYGROUND_UPDATE_TEST_AUTO_APPLY = "1"
    Start-Process -FilePath (Join-Path $InstallRoot "Playground.exe") -WorkingDirectory $InstallRoot | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    while (-not (Test-Path $updateResult) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 2 }
    if (-not (Test-Path $updateResult)) { throw "Application-driven HTTPS update timed out." }
    $exitCode = (Get-Content $updateResult -Raw).Trim()
    if ($exitCode -ne "0") { throw "MaintenanceTool update failed with exit code $exitCode." }

    $expectedXml = [xml](Get-Content (Join-Path $candidateRepository "Updates.xml") -Raw)
    $expected = [ordered]@{}
    foreach ($package in @($expectedXml.Updates.PackageUpdate)) { $expected[[string]$package.Name] = [string]$package.Version }
    $installedXml = [xml](Get-Content (Join-Path $InstallRoot "components.xml") -Raw)
    $actual = [ordered]@{}
    foreach ($package in @($installedXml.Packages.Package)) { $actual[[string]$package.Name] = [string]$package.Version }
    if ($actual.Count -ne $expected.Count) { throw "Installed component count does not match the HTTPS candidate repository." }
    foreach ($entry in $expected.GetEnumerator()) {
        if (-not $actual.Contains($entry.Key) -or $actual[$entry.Key] -ne $entry.Value) {
            throw "Installed component mismatch for $($entry.Key)."
        }
    }
    $actual | ConvertTo-Json | Set-Content (Join-Path $runRoot "components-after.json") -Encoding UTF8

    $productVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $InstallRoot "Playground.exe")).ProductVersion
    $productVersion | Set-Content (Join-Path $runRoot "application-version-after.txt") -Encoding UTF8
    if ($productVersion -ne $CandidateVersion) {
        throw "Updated executable version is not ${CandidateVersion}: $productVersion"
    }

    Remove-Item Env:\PLAYGROUND_UPDATE_TEST_METADATA_URL,Env:\PLAYGROUND_UPDATE_TEST_RESULT,Env:\PLAYGROUND_UPDATE_TEST_AUTO_APPLY -ErrorAction SilentlyContinue
    $smoke = Start-Process -FilePath (Join-Path $InstallRoot "Playground.exe") -WorkingDirectory $InstallRoot -PassThru
    Start-Sleep -Seconds 10
    if ($smoke.HasExited) { throw "Updated Playground exited during the smoke window with code $($smoke.ExitCode)." }
    Stop-Process -Id $smoke.Id -Force

    $repositoryUri = [System.Uri]::new($candidateRepository).AbsoluteUri
    $checkOutput = & $maintenanceTool "--lang" "en" "--set-temp-repository" $repositoryUri "check-updates" 2>&1 | Out-String
    $checkOutput | Set-Content (Join-Path $runRoot "check-updates.log") -Encoding UTF8
    if ($LASTEXITCODE -ne 0 -or $checkOutput -notmatch '(?i)no updates available') {
        throw "MaintenanceTool did not report that the candidate is fully applied."
    }
    $result.passed = $true
}
catch {
    $result.error = $_.Exception.Message
    throw
}
finally {
    Remove-Item Env:\PLAYGROUND_UPDATE_TEST_METADATA_URL,Env:\PLAYGROUND_UPDATE_TEST_RESULT,Env:\PLAYGROUND_UPDATE_TEST_AUTO_APPLY -ErrorAction SilentlyContinue
    if (Test-Path $maintenanceTool) {
        try { Invoke-CheckedProcess $maintenanceTool @("--confirm-command", "purge") "Purge" $runRoot } catch { $result.cleanupError = $_.Exception.Message }
    }
    $result.finishedAt = (Get-Date).ToUniversalTime().ToString("o")
    $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $runRoot "result.json") -Encoding UTF8
    Write-Host "Host validation result: $(Join-Path $runRoot 'result.json')"
}
