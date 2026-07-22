# Upload prebuilt Basler Playground release artifacts as a GitHub draft release.

param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CliArgs)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Required command not found: $Name" }
}
function Invoke-NativeCommand {
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$ArgumentList = @(), [Parameter(Mandatory = $true)][string]$FailureMessage)
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage (exit code $LASTEXITCODE)." }
}
function Get-RequiredFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer) { throw "Required release artifact is missing: $Path" }
    return $item
}
function Assert-FileHash([System.IO.FileInfo]$File, [string]$ExpectedHash) {
    if ($ExpectedHash -notmatch '^[0-9a-f]{64}$') { throw "Manifest hash is invalid for $($File.Name)." }
    $actualHash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $ExpectedHash) { throw "Artifact hash mismatch for $($File.Name)." }
    return $actualHash
}

if ($CliArgs.Count -gt 0) { throw "Usage: .\deployment.ps1" }
$ReleaseRepository = "Minu-Park/Basler-Playground"
$artifactDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "dist") -ErrorAction Stop).Path
$manifest = Get-Content -LiteralPath (Get-RequiredFile (Join-Path $artifactDirectory "release-artifacts.json")).FullName -Raw | ConvertFrom-Json
$PlaygroundTag = [string]$manifest.tag
if ($PlaygroundTag -notmatch '^v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?:-beta\.([1-9][0-9]*))?$') { throw "Artifact manifest has an invalid release tag." }
$displayVersion = $Matches[1]
$isPrerelease = [bool]$Matches[2]
$channel = if ($isPrerelease) { "beta" } else { "stable" }
if ($manifest.schemaVersion -ne 2 -or $manifest.channel -ne $channel -or [bool]$manifest.prerelease -ne $isPrerelease) { throw "Artifact manifest identity does not match $PlaygroundTag." }
if ($manifest.playgroundCommit -notmatch '^[0-9a-f]{40}$' -or $manifest.expectedTagCommit -ne $manifest.playgroundCommit) { throw "Artifact manifest does not bind $PlaygroundTag to one immutable Playground commit." }

Require-Command gh
Invoke-NativeCommand gh @("auth", "status") "GitHub CLI authentication check failed" | Out-Null
$installerName = "BaslerPlayground-$PlaygroundTag-windows-x64.exe"
$metadataName = if ($isPrerelease) { "latest-beta.json" } else { "latest.json" }
$expectedAssetNames = @($installerName, "$installerName.sha256", $metadataName)
$manifestAssets = @($manifest.assets)
if ($manifestAssets.Count -ne $expectedAssetNames.Count -or @($manifestAssets.fileName | Sort-Object -Unique).Count -ne $expectedAssetNames.Count -or @($expectedAssetNames | Where-Object { $_ -notin $manifestAssets.fileName }).Count -gt 0) { throw "Artifact manifest must contain exactly the three release assets for $PlaygroundTag." }
$assets = @{}
foreach ($entry in $manifestAssets) {
    $file = Get-RequiredFile (Join-Path $artifactDirectory $entry.fileName)
    $assets[$entry.fileName] = [ordered]@{ file = $file; sha256 = Assert-FileHash $file ([string]$entry.sha256) }
}
$checksum = [System.IO.File]::ReadAllText($assets["$installerName.sha256"].file.FullName, [System.Text.UTF8Encoding]::new($false)).TrimEnd("`r", "`n")
if ($checksum -ne "$($assets[$installerName].sha256)  $installerName") { throw "Installer checksum file does not contain the exact installer hash and filename." }
$metadata = Get-Content -LiteralPath $assets[$metadataName].file.FullName -Raw | ConvertFrom-Json
if ($metadata.version -ne $displayVersion -or $metadata.tag -ne $PlaygroundTag -or $metadata.channel -ne $channel -or $metadata.playgroundCommit -ne $manifest.playgroundCommit) { throw "Release metadata identity does not match the artifact manifest." }
$platform = @($metadata.platforms | Where-Object { $_.os -eq "windows" -and $_.arch -eq "x64" -and $_.package -eq "exe" })
if ($platform.Count -ne 1 -or $platform[0].fileName -ne $installerName -or $platform[0].sha256 -ne $assets[$installerName].sha256) { throw "Release metadata does not describe the generated Windows installer." }

$releaseNotesFile = Get-RequiredFile (Join-Path $artifactDirectory ([string]$manifest.releaseNotesFile))
$releaseExists = $false
$previousErrorActionPreference = $ErrorActionPreference
try { $ErrorActionPreference = "SilentlyContinue"; $releaseJson = gh release view $PlaygroundTag --repo $ReleaseRepository --json isDraft 2>$null; $releaseExists = $LASTEXITCODE -eq 0 } finally { $ErrorActionPreference = $previousErrorActionPreference }
if ($releaseExists -and -not (($releaseJson | ConvertFrom-Json).isDraft)) { throw "Release $PlaygroundTag is already published. Published release assets are immutable; create a new version." }
$assetPaths = @($expectedAssetNames | ForEach-Object { $assets[$_].file.FullName })
$releaseTypeArguments = if ($isPrerelease) { @("--prerelease") } else { @() }
if ($releaseExists) {
    Invoke-NativeCommand gh (@("release", "upload", $PlaygroundTag, "--repo", $ReleaseRepository) + $assetPaths + @("--clobber")) "Failed to upload release assets for $PlaygroundTag"
    Invoke-NativeCommand gh (@("release", "edit", $PlaygroundTag, "--repo", $ReleaseRepository, "--title", [string]$manifest.title, "--notes-file", $releaseNotesFile.FullName) + $releaseTypeArguments) "Failed to update release metadata for $PlaygroundTag"
} else {
    Invoke-NativeCommand gh (@("release", "create", $PlaygroundTag, "--repo", $ReleaseRepository) + $assetPaths + @("--title", [string]$manifest.title, "--notes-file", $releaseNotesFile.FullName) + $releaseTypeArguments + @("--draft")) "Failed to create draft release for $PlaygroundTag"
}
$uploaded = (Invoke-NativeCommand gh @("release", "view", $PlaygroundTag, "--repo", $ReleaseRepository, "--json", "isDraft,assets") "Failed to verify uploaded release assets" | ConvertFrom-Json)
if (-not $uploaded.isDraft) { throw "Release $PlaygroundTag was unexpectedly published during deployment." }
foreach ($assetName in $expectedAssetNames) {
    $uploadedAsset = @($uploaded.assets | Where-Object { $_.name -eq $assetName })
    if ($uploadedAsset.Count -ne 1 -or $uploadedAsset[0].digest -ne "sha256:$($assets[$assetName].sha256)") { throw "GitHub asset digest verification failed for $assetName." }
}
Write-Host "Draft release uploaded and verified: $PlaygroundTag"
