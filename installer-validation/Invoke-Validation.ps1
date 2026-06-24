param(
    [ValidateSet("CleanInstall", "ComponentUpdate", "ApplicationUpdate", "WindowsSdkDiagnostic", "FullFallback")]
    [string]$Scenario = "ComponentUpdate",

    [string]$BaselineInstaller,

    [string]$CandidateInstaller,

    [string]$CandidateRepository,

    [string]$ApplicationUnderTest,

    [string]$InstallRoot = "C:\Users\WDAGUtilityAccount\PlaygroundValidation",

    [string]$ReleaseRepository = "Minu-Park/basler-playground",

    [switch]$GenerateOnly,

    [switch]$KeepSandboxOpen,

    [switch]$CloseExistingSandbox,

    [switch]$KeepInstalled
)

$ErrorActionPreference = "Stop"

function Resolve-RequiredPath {
    param([string]$Path, [string]$Label)
    if (-not $Path -or -not (Test-Path $Path)) {
        throw "$Label does not exist: $Path"
    }
    return (Resolve-Path $Path).Path
}

function ConvertTo-XmlText {
    param([string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

if ($Scenario -eq "FullFallback") {
    throw "FullFallback is intentionally disabled until backup/purge/reinstall state preservation is implemented."
}
if ($Scenario -in @("ComponentUpdate", "ApplicationUpdate", "WindowsSdkDiagnostic")) {
    if (-not $BaselineInstaller) {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            throw "gh is required to resolve the latest stable baseline automatically."
        }
        $release = gh release view --repo $ReleaseRepository --json tagName,assets | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $release.tagName) {
            throw "Failed to resolve the latest stable release from $ReleaseRepository."
        }
        $asset = @($release.assets | Where-Object {
            $_.name -match 'windows-x64\.exe$' -and $_.name -notmatch '\.sha256$'
        }) | Select-Object -First 1
        if (-not $asset) {
            throw "Latest stable release $($release.tagName) has no Windows x64 installer."
        }
        $cacheRoot = Join-Path (Split-Path $PSScriptRoot -Parent) "build/installer-validation/cache/$($release.tagName)"
        $BaselineInstaller = Join-Path $cacheRoot $asset.name
        if (-not (Test-Path $BaselineInstaller)) {
            New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
            gh release download $release.tagName --repo $ReleaseRepository --pattern $asset.name --dir $cacheRoot
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to download baseline installer $($asset.name)."
            }
        }
        Write-Host "Using cached stable baseline: $BaselineInstaller"
    }
    $BaselineInstaller = Resolve-RequiredPath $BaselineInstaller "BaselineInstaller"
    if ($Scenario -ne "WindowsSdkDiagnostic") {
        $CandidateRepository = Resolve-RequiredPath $CandidateRepository "CandidateRepository"
        if (-not (Test-Path (Join-Path $CandidateRepository "Updates.xml"))) {
            throw "CandidateRepository must contain Updates.xml at its root."
        }
        if ($Scenario -eq "ApplicationUpdate") {
            $ApplicationUnderTest = Resolve-RequiredPath $ApplicationUnderTest "ApplicationUnderTest"
        }
    }
} else {
    $CandidateInstaller = Resolve-RequiredPath $CandidateInstaller "CandidateInstaller"
}

$sandboxExecutable = Join-Path $env:WINDIR "System32\WindowsSandbox.exe"
if (-not (Test-Path $sandboxExecutable)) {
    throw "Windows Sandbox is not installed. Enable Containers-DisposableClientVM first."
}
$existingSandbox = @(Get-Process WindowsSandboxRemoteSession -ErrorAction SilentlyContinue)
if ($existingSandbox.Count -gt 0) {
    if (-not $CloseExistingSandbox) {
        throw "An existing Windows Sandbox session is running. Close it or pass -CloseExistingSandbox before validation."
    }
    $existingSandbox | Stop-Process -Force
    Start-Sleep -Seconds 2
}

$root = Split-Path $PSScriptRoot -Parent
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path $root "build/installer-validation/$timestamp-$Scenario"
$configRoot = Join-Path $runRoot "config"
$resultsRoot = Join-Path $runRoot "results"
New-Item -ItemType Directory -Force -Path $configRoot, $resultsRoot | Out-Null

$scenarioConfig = [ordered]@{
    scenario = $Scenario
    installRoot = $InstallRoot
    keepInstalled = [bool]$KeepInstalled
    autoClose = -not [bool]$KeepSandboxOpen
    baselineInstaller = if ($BaselineInstaller) { "C:\ValidationInput\Baseline\$(Split-Path $BaselineInstaller -Leaf)" } else { $null }
    candidateInstaller = if ($CandidateInstaller) { "C:\ValidationInput\Candidate\$(Split-Path $CandidateInstaller -Leaf)" } else { $null }
    candidateRepository = if ($CandidateRepository) { "C:\ValidationInput\Repository" } else { $null }
    applicationUnderTest = if ($ApplicationUnderTest) { "C:\ValidationInput\Application\$(Split-Path $ApplicationUnderTest -Leaf)" } else { $null }
    testMetadataUrl = if ($Scenario -eq "ApplicationUpdate") { "file:///C:/ValidationConfig/latest.json" } else { $null }
    testResultPath = if ($Scenario -eq "ApplicationUpdate") { "C:\ValidationResults\app-update-exit.txt" } else { $null }
}
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText(
    (Join-Path $configRoot "scenario.json"),
    ($scenarioConfig | ConvertTo-Json -Depth 4),
    $utf8NoBom
)
if ($Scenario -eq "ApplicationUpdate") {
    $updatesXml = [xml](Get-Content (Join-Path $CandidateRepository "Updates.xml") -Raw)
    $corePackage = @($updatesXml.Updates.PackageUpdate | Where-Object { [string]$_.Name -eq "PlaygroundCore" }) | Select-Object -First 1
    if (-not $corePackage) {
        throw "CandidateRepository does not contain PlaygroundCore."
    }
    $metadata = [ordered]@{
        version = [string]$corePackage.Version
        tag = "validation-$([string]$corePackage.Version)"
        channel = "validation"
        update = [ordered]@{ epoch = 2; forceFullInstaller = $false }
        repository = [ordered]@{ url = "file:///C:/ValidationInput/Repository" }
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $configRoot "latest.json"),
        ($metadata | ConvertTo-Json -Depth 5),
        $utf8NoBom
    )
}

$mappedFolders = @(
    "<MappedFolder><HostFolder>$(ConvertTo-XmlText $PSScriptRoot)</HostFolder><SandboxFolder>C:\ValidationHarness</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>",
    "<MappedFolder><HostFolder>$(ConvertTo-XmlText $configRoot)</HostFolder><SandboxFolder>C:\ValidationConfig</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>",
    "<MappedFolder><HostFolder>$(ConvertTo-XmlText $resultsRoot)</HostFolder><SandboxFolder>C:\ValidationResults</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>"
)
if ($BaselineInstaller) {
    $mappedFolders += "<MappedFolder><HostFolder>$(ConvertTo-XmlText (Split-Path $BaselineInstaller -Parent))</HostFolder><SandboxFolder>C:\ValidationInput\Baseline</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>"
}
if ($CandidateInstaller) {
    $mappedFolders += "<MappedFolder><HostFolder>$(ConvertTo-XmlText (Split-Path $CandidateInstaller -Parent))</HostFolder><SandboxFolder>C:\ValidationInput\Candidate</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>"
}
if ($CandidateRepository) {
    $mappedFolders += "<MappedFolder><HostFolder>$(ConvertTo-XmlText $CandidateRepository)</HostFolder><SandboxFolder>C:\ValidationInput\Repository</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>"
}
if ($ApplicationUnderTest) {
    $mappedFolders += "<MappedFolder><HostFolder>$(ConvertTo-XmlText (Split-Path $ApplicationUnderTest -Parent))</HostFolder><SandboxFolder>C:\ValidationInput\Application</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>"
}

$command = "cmd.exe /d /c C:\ValidationHarness\Bootstrap.cmd"
$wsb = @"
<Configuration>
  <Networking>Enable</Networking>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <MappedFolders>
    $($mappedFolders -join "`n    ")
  </MappedFolders>
  <LogonCommand><Command>$(ConvertTo-XmlText $command)</Command></LogonCommand>
</Configuration>
"@
$wsbPath = Join-Path $runRoot "$Scenario.wsb"
[System.IO.File]::WriteAllText($wsbPath, $wsb, $utf8NoBom)

Write-Host "Validation run: $runRoot"
Write-Host "Sandbox config: $wsbPath"
if (-not $GenerateOnly) {
    Start-Process -FilePath $sandboxExecutable -ArgumentList $wsbPath | Out-Null
    $resultPath = Join-Path $resultsRoot "result.json"
    $deadline = [DateTime]::UtcNow.AddMinutes(30)
    while (-not (Test-Path $resultPath) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
    }
    if (-not (Test-Path $resultPath)) {
        throw "Windows Sandbox validation timed out without result.json. See bootstrap.log in: $resultsRoot"
    }
    $result = Get-Content $resultPath -Raw | ConvertFrom-Json
    if (-not $result.passed) {
        throw "Installer validation failed: $($result.error)"
    }
    Write-Host "Installer validation passed: $resultPath"
}
