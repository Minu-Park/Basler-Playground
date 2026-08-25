# Build one device-plugin ZIP from an immutable Playground source tag for a combined Core release.

param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CliArgs)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage (exit code $LASTEXITCODE)."
    }
}

function Read-PluginArguments {
    param([string[]]$Arguments)

    $values = @{}
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = $Arguments[$index]
        if ($argument -notin @("--core-tag", "--source-ref", "--plugin", "--version")) {
            throw "Usage: .\plugin-package.ps1 --core-tag vX.Y.Z[-beta.N] [--source-ref <commit-or-tag>] --plugin camera|framegrabber|gocator|heliotis-c4 --version X.Y.Z[-beta.N]"
        }
        if (++$index -ge $Arguments.Count -or $Arguments[$index].StartsWith("--")) {
            throw "Missing value for $argument."
        }
        $values[$argument] = $Arguments[$index]
    }
    foreach ($required in @("--core-tag", "--plugin", "--version")) {
        if (-not $values.ContainsKey($required)) { throw "Missing required argument: $required" }
    }
    return [pscustomobject]@{
        CoreTag = $values["--core-tag"]
        SourceRef = if ($values.ContainsKey("--source-ref")) { $values["--source-ref"] } else { $values["--core-tag"] }
        PluginId = $values["--plugin"]
        PluginVersion = $values["--version"]
    }
}

function Get-RequiredFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer) { throw "Required file is missing: $Path" }
    return $item
}

Require-Command git
Require-Command Compress-Archive

$arguments = Read-PluginArguments $CliArgs
$coreTag = [string]$arguments.CoreTag
$sourceRef = [string]$arguments.SourceRef
$pluginId = [string]$arguments.PluginId
$pluginVersion = [string]$arguments.PluginVersion
$allowedPlugins = @("camera", "framegrabber", "gocator", "heliotis-c4")
if ($coreTag -notmatch '^v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?:-beta\.([1-9][0-9]*))?$') {
    throw "Core tag must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-beta.N."
}
if ($pluginId -notin $allowedPlugins) { throw "Unsupported plugin ID: $pluginId" }
if ([string]::IsNullOrWhiteSpace($sourceRef) -or $sourceRef.StartsWith("-")) { throw "SourceRef must be a non-empty git tag, branch, or commit." }
if ($pluginVersion -notmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-beta\.[1-9][0-9]*)?$') {
    throw "Plugin version must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-beta.N."
}

$coreVersion = $coreTag.Substring(1) -replace '-beta\.[0-9]+$', ''
$root = $PSScriptRoot
$checkout = Join-Path $root "playground"
$playgroundRepo = "git@github.com:minu-park/playground.git"
if (Test-Path $checkout) {
    $status = @(Invoke-NativeCommand git @("-C", $checkout, "status", "--porcelain", "--untracked-files=all") "Failed to inspect the existing Playground release checkout")
    if ($status.Count -gt 0) { throw "Playground release checkout contains local or untracked source changes." }
} else {
    Invoke-NativeCommand git @("clone", "--filter=blob:none", $playgroundRepo, $checkout) "Failed to clone Playground"
}
Invoke-NativeCommand git @("-C", $checkout, "fetch", "--prune", "--tags", "--force", "origin") "Failed to fetch Playground tags"
Invoke-NativeCommand git @("-C", $checkout, "show-ref", "--tags", "--verify", "--quiet", "refs/tags/$coreTag") "Playground tag $coreTag was not found"
$tagCommit = (Invoke-NativeCommand git @("-C", $checkout, "rev-parse", "refs/tags/$coreTag^{commit}") "Failed to resolve Playground tag $coreTag" | Select-Object -Last 1).Trim()
Invoke-NativeCommand git @("-C", $checkout, "rev-parse", "$sourceRef^{commit}") "Source ref $sourceRef was not found in the Playground repository" | Out-Null
$sourceCommit = (Invoke-NativeCommand git @("-C", $checkout, "rev-parse", "$sourceRef^{commit}") "Failed to resolve source ref $sourceRef" | Select-Object -Last 1).Trim()
Invoke-NativeCommand git @("-C", $checkout, "checkout", "--detach", $sourceRef) "Failed to check out source ref $sourceRef"
Invoke-NativeCommand git @("-C", $checkout, "submodule", "update", "--init", "--recursive") "Failed to initialize Playground submodules"

$versionVariable = @{
    camera = "PLAYGROUND_PLUGIN_CAMERA_VERSION"
    framegrabber = "PLAYGROUND_PLUGIN_FRAMEGRABBER_VERSION"
    gocator = "PLAYGROUND_PLUGIN_GOCATOR_VERSION"
    "heliotis-c4" = "PLAYGROUND_PLUGIN_HELIOTIS_C4_VERSION"
}[$pluginId]
$environmentPath = "Env:$versionVariable"
$oldEnvironment = Get-Item -Path $environmentPath -ErrorAction SilentlyContinue
$oldCoreVersionEnvironment = Get-Item -Path "Env:PLAYGROUND_VERSION_OVERRIDE" -ErrorAction SilentlyContinue
$pylonPath = Join-Path $root "pylon"
if (Test-Path $pylonPath) {
    $env:PLAYGROUND_LOCAL_PYLON_RUNTIME_DIR = (Resolve-Path $pylonPath).Path
}
$defaultPylonRuntime = "C:\Program Files\Basler\pylon\Runtime\x64"
if (-not $env:PLAYGROUND_LOCAL_PYLON_RUNTIME_DIR -and (Test-Path $defaultPylonRuntime)) {
    $env:PLAYGROUND_LOCAL_PYLON_RUNTIME_DIR = $defaultPylonRuntime
}

Set-Item -Path $environmentPath -Value $pluginVersion
Set-Item -Path "Env:PLAYGROUND_VERSION_OVERRIDE" -Value $coreTag.Substring(1)
$pluginRoot = $null
try {
    Push-Location $checkout
    try {
        Invoke-NativeCommand ".\package_bundle.bat" @("Release", "Plugins") "Plugin bundle staging failed"
    } finally {
        Pop-Location
    }

    $pluginRoot = Join-Path $checkout "build\bundle\Release\plugins\$pluginId\current"
    if (-not (Test-Path (Join-Path $pluginRoot "plugin.json"))) {
        throw "Plugin manifest was not staged: $pluginRoot"
    }
    $manifest = Get-Content -LiteralPath (Join-Path $pluginRoot "plugin.json") -Raw | ConvertFrom-Json
    if ($manifest.id -ne $pluginId -or $manifest.version -ne $pluginVersion) {
        throw "Staged plugin manifest identity/version mismatch."
    }
    if ($manifest.minimumCoreVersion -ne $coreVersion) {
        throw "Staged plugin minimumCoreVersion mismatch: expected $coreVersion, found $($manifest.minimumCoreVersion)."
    }
    if (Test-Path (Join-Path $pluginRoot "PlaygroundCore.exe")) {
        throw "Plugin package contains Core application files."
    }

    $dist = Join-Path $root "dist\plugin-$pluginId-v$pluginVersion"
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    $zipName = "BaslerPlayground-$pluginId-v$pluginVersion-windows-x64.zip"
    $zipPath = Join-Path $dist $zipName
    if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $pluginRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal -Force
    $zipFile = Get-RequiredFile $zipPath
    $hash = (Get-FileHash -LiteralPath $zipFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText("$zipPath.sha256", "$hash  $zipName", $utf8NoBom)

    $releaseTag = "plugin-$pluginId-v$pluginVersion"
    $releaseUrl = "https://github.com/Minu-Park/Basler-Playground/releases/tag/$releaseTag"
    $packageUrl = "https://github.com/Minu-Park/Basler-Playground/releases/download/$releaseTag/$zipName"
    $artifactManifest = [ordered]@{
        schemaVersion = 1
        kind = "device-plugin"
        pluginId = $pluginId
        displayName = [string]$manifest.displayName
        description = "Device integration package for Basler Playground."
        pluginVersion = $pluginVersion
        minimumCoreVersion = $coreVersion
        coreTag = $coreTag
        coreCommit = $tagCommit
        sourceRef = $sourceRef
        sourceCommit = $sourceCommit
        releaseTag = $releaseTag
        channel = if ($pluginVersion -match '-beta\.') { "beta" } else { "stable" }
        packageName = $zipName
        packageSha256 = $hash
        packageUrl = $packageUrl
        platform = "windows-x64"
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $dist "plugin-artifacts.json"),
        ($artifactManifest | ConvertTo-Json -Depth 6),
        $utf8NoBom)
    $notes = "Basler Playground $pluginId plugin $pluginVersion, built from source $sourceRef ($sourceCommit) for Core $coreTag ($tagCommit)."
    [System.IO.File]::WriteAllText((Join-Path $dist "release-notes.md"), $notes, $utf8NoBom)
    Write-Host "Plugin artifacts created: $dist"
    Write-Host "Add this artifact directory to assemble-release.ps1; standalone plugin publication is disabled by default."
} finally {
    if ($oldEnvironment) {
        Set-Item -Path $environmentPath -Value $oldEnvironment.Value
    } else {
        Remove-Item -Path $environmentPath -ErrorAction SilentlyContinue
    }
    if ($oldCoreVersionEnvironment) {
        Set-Item -Path "Env:PLAYGROUND_VERSION_OVERRIDE" -Value $oldCoreVersionEnvironment.Value
    } else {
        Remove-Item -Path "Env:PLAYGROUND_VERSION_OVERRIDE" -ErrorAction SilentlyContinue
    }
}
