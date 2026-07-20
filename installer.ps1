# Local Windows installer-artifact builder for basler-playground.
# Requires: git, Inno Setup, and access to the private Playground repository.

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CliArgs
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Read-InstallerArguments {
    param([string[]]$Arguments)

    $tag = $null
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        switch ($Arguments[$index]) {
            "--tag" {
                if ($tag -or ++$index -ge $Arguments.Count -or $Arguments[$index].StartsWith("--")) {
                    throw "Usage: .\installer.ps1 --tag vX.Y.Z"
                }
                $tag = $Arguments[$index]
            }
            default { throw "Usage: .\installer.ps1 --tag vX.Y.Z" }
        }
    }
    if (-not $tag) { throw "Usage: .\installer.ps1 --tag vX.Y.Z" }
    return [pscustomobject]@{ Tag = $tag }
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

function Get-ReleaseNotesForTag {
    param([Parameter(Mandatory = $true)][string]$Path,
          [Parameter(Mandatory = $true)][string]$Tag)

    if (-not (Test-Path $Path)) { return $null }
    $document = Get-Content $Path -Raw
    $pattern = "(?ms)^#\s+$([regex]::Escape($Tag))\s*\r?\n(?<body>.*?)(?=^#\s+v\d|\z)"
    $match = [regex]::Match($document, $pattern)
    if (-not $match.Success) { return $null }
    return $match.Groups["body"].Value.Trim()
}

Require-Command git

$arguments = Read-InstallerArguments $CliArgs
$PlaygroundTag = $arguments.Tag
$PlaygroundRepo = "git@github.com:minu-park/playground.git"
if ($PlaygroundTag -notmatch '^v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?:-beta\.([1-9][0-9]*))?$') {
    throw "PlaygroundTag must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-beta.N."
}
$displayVersion = $PlaygroundTag.Substring(1)
$isPrerelease = [bool]$Matches[2]
$channel = if ($isPrerelease) { "beta" } else { "stable" }

$root = $PSScriptRoot
$checkout = Join-Path $root "playground"
if (Test-Path $checkout) {
    $existingCheckoutStatus = @(Invoke-NativeCommand git @(
        "-C", $checkout, "status", "--porcelain", "--untracked-files=all"
    ) "Failed to inspect the existing Playground release checkout")
    if ($existingCheckoutStatus.Count -gt 0) {
        throw "Playground release checkout contains local or untracked source changes. Preserve or remove them before packaging."
    }
} else {
    Invoke-NativeCommand git @("clone", "--filter=blob:none", $PlaygroundRepo, $checkout) "Failed to clone Playground"
}

Invoke-NativeCommand git @("-C", $checkout, "fetch", "--prune", "--tags", "--force", "origin") "Failed to fetch Playground tags from origin"
Invoke-NativeCommand git @("-C", $checkout, "show-ref", "--tags", "--verify", "--quiet", "refs/tags/$PlaygroundTag") "Playground tag $PlaygroundTag was not found"
$tagCommit = (Invoke-NativeCommand git @("-C", $checkout, "rev-parse", "refs/tags/$PlaygroundTag^{commit}") "Failed to resolve Playground tag $PlaygroundTag" | Select-Object -Last 1).Trim()
Invoke-NativeCommand git @("-C", $checkout, "checkout", "--detach", $PlaygroundTag) "Failed to check out Playground tag $PlaygroundTag"
Invoke-NativeCommand git @("-C", $checkout, "submodule", "update", "--init", "--recursive") "Failed to initialize Playground submodules"
$checkoutStatus = @(Invoke-NativeCommand git @(
    "-C", $checkout, "status", "--porcelain", "--untracked-files=all"
) "Failed to verify the Playground release checkout")
if ($checkoutStatus.Count -gt 0) {
    throw "Playground release checkout is not clean after selecting $PlaygroundTag."
}

$pylonPath = Join-Path $root "pylon"
if (Test-Path $pylonPath) {
    $env:PLAYGROUND_LOCAL_PYLON_RUNTIME_DIR = (Resolve-Path $pylonPath).Path
} else {
    $defaultPylonRuntime = "C:\Program Files\Basler\pylon\Runtime\x64"
    if (Test-Path $defaultPylonRuntime) {
        $env:PLAYGROUND_LOCAL_PYLON_RUNTIME_DIR = $defaultPylonRuntime
    }
}

Push-Location $checkout
try {
    Invoke-NativeCommand ".\package_bundle.bat" @("Release") "Playground Inno Setup packaging failed"
} finally {
    Pop-Location
}

$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$installerName = "BaslerPlayground-$PlaygroundTag-windows-x64.exe"
$builtInstaller = Join-Path $checkout "build\bundle\$installerName"
if (-not (Test-Path $builtInstaller)) {
    throw "Expected Inno Setup installer not found: $builtInstaller"
}
$packagedApplicationPath = Join-Path $checkout "build\bundle\Release\Playground.exe"
if (-not (Test-Path $packagedApplicationPath)) {
    throw "Packaged application executable not found: $packagedApplicationPath"
}
$applicationProductVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($packagedApplicationPath).ProductVersion
if ($applicationProductVersion -ne $displayVersion) {
    throw "Packaged application version mismatch: expected $displayVersion, found $applicationProductVersion."
}

$installerOut = Join-Path $dist $installerName
Copy-Item -LiteralPath $builtInstaller -Destination $installerOut -Force
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$hash = Get-FileHash $installerOut -Algorithm SHA256
[System.IO.File]::WriteAllText("$installerOut.sha256", "$($hash.Hash.ToLowerInvariant())  $installerName", $utf8NoBom)

$commit = (Invoke-NativeCommand git @("-C", $checkout, "rev-parse", "HEAD") "Failed to resolve the Playground commit" | Select-Object -Last 1).Trim()
if ($commit -ne $tagCommit) {
    throw "Checked-out Playground commit does not match immutable tag $PlaygroundTag."
}
$releaseUrl = "https://github.com/minu-park/basler-playground/releases/tag/$PlaygroundTag"
$installerUrl = "https://github.com/minu-park/basler-playground/releases/download/$PlaygroundTag/$installerName"
$releaseNotes = "Installer built from private Playground tag $PlaygroundTag ($commit)."
$routedReleaseNotes = Get-ReleaseNotesForTag (Join-Path $checkout "RELEASE_NOTES.md") $PlaygroundTag
if ($routedReleaseNotes) { $releaseNotes = $routedReleaseNotes }
$metadata = [ordered]@{
    version = $displayVersion
    tag = $PlaygroundTag
    channel = $channel
    publishedAt = (Get-Date).ToUniversalTime().ToString("o")
    notesUrl = $releaseUrl
    releaseNotes = $releaseNotes
    platforms = @([ordered]@{
        os = "windows"
        arch = "x64"
        package = "exe"
        fileName = $installerName
        url = $installerUrl
        sha256 = $hash.Hash.ToLowerInvariant()
    })
    playgroundCommit = $commit
}
$metadataFileName = if ($isPrerelease) { "latest-beta.json" } else { "latest.json" }
$metadataOut = Join-Path $dist $metadataFileName
[System.IO.File]::WriteAllText($metadataOut, ($metadata | ConvertTo-Json -Depth 6), $utf8NoBom)

$releaseNotesOut = Join-Path $dist "release-notes.md"
[System.IO.File]::WriteAllText($releaseNotesOut, $releaseNotes, $utf8NoBom)
$releaseAssets = @($installerOut, "$installerOut.sha256", $metadataOut)
$artifactManifest = [ordered]@{
    schemaVersion = 2
    tag = $PlaygroundTag
    playgroundCommit = $commit
    expectedTagCommit = $tagCommit
    title = "Basler Playground $PlaygroundTag"
    channel = $channel
    prerelease = $isPrerelease
    outputDirectory = $dist
    releaseNotesFile = (Split-Path $releaseNotesOut -Leaf)
    assets = @($releaseAssets | ForEach-Object {
        $file = Get-Item -LiteralPath $_
        [ordered]@{ fileName = $file.Name; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
}
[System.IO.File]::WriteAllText((Join-Path $dist "release-artifacts.json"), ($artifactManifest | ConvertTo-Json -Depth 6), $utf8NoBom)
Write-Host "Installer artifacts created: $dist"
Write-Host "Upload them with: .\deployment.ps1"
