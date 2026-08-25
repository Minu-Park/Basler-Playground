# Upload prebuilt Basler Playground release artifacts as one GitHub release.

param(
    [switch]$AllowPublished,
    [string]$ArtifactDirectory = ""
)

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

$ReleaseRepository = "Minu-Park/Basler-Playground"
$artifactDirectory = if ($ArtifactDirectory) {
    (Resolve-Path -LiteralPath $ArtifactDirectory -ErrorAction Stop).Path
} else {
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "dist") -ErrorAction Stop).Path
}
$manifest = Get-Content -LiteralPath (Get-RequiredFile (Join-Path $artifactDirectory "release-artifacts.json")).FullName -Raw | ConvertFrom-Json
$PlaygroundTag = [string]$manifest.tag
if ($PlaygroundTag -notmatch '^v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?:-beta\.([1-9][0-9]*))?$') { throw "Artifact manifest has an invalid release tag." }
$displayVersion = $PlaygroundTag.Substring(1)
$isPrerelease = [bool]$Matches[2]
$channel = if ($isPrerelease) { "beta" } else { "stable" }
if ($manifest.schemaVersion -notin @(2, 3) -or $manifest.channel -ne $channel -or [bool]$manifest.prerelease -ne $isPrerelease) { throw "Artifact manifest identity does not match $PlaygroundTag." }
if ($manifest.playgroundCommit -notmatch '^[0-9a-f]{40}$' -or $manifest.expectedTagCommit -ne $manifest.playgroundCommit) { throw "Artifact manifest does not bind $PlaygroundTag to one immutable Playground commit." }

Require-Command gh
Invoke-NativeCommand gh @("auth", "status") "GitHub CLI authentication check failed" | Out-Null
$metadataName = if ($isPrerelease) { "latest-beta.json" } else { "latest.json" }
$manifestAssets = @($manifest.assets)
if ($manifest.schemaVersion -eq 2) {
    $installerName = "BaslerPlayground-$PlaygroundTag-Core-Windows-x64.exe"
    $expectedAssetNames = @($installerName, "$installerName.sha256", $metadataName)
    if ($manifestAssets.Count -ne $expectedAssetNames.Count -or @($manifestAssets.fileName | Sort-Object -Unique).Count -ne $expectedAssetNames.Count -or @($expectedAssetNames | Where-Object { $_ -notin $manifestAssets.fileName }).Count -gt 0) { throw "Core artifact manifest must contain exactly the three release assets for $PlaygroundTag." }
} else {
    $installerName = "BaslerPlayground-$PlaygroundTag-Core-Windows-x64.exe"
    $fullInstallerName = "BaslerPlayground-$PlaygroundTag-Full-Windows-x64.exe"
    $expectedAssetNames = @($manifestAssets.fileName)
    $requiredNames = @($installerName, "$installerName.sha256", $fullInstallerName, "$fullInstallerName.sha256", $metadataName, "plugins-index.json")
    if (@($expectedAssetNames | Sort-Object -Unique).Count -ne $expectedAssetNames.Count -or @($requiredNames | Where-Object { $_ -notin $expectedAssetNames }).Count -gt 0) { throw "Combined artifact manifest is missing a required Core, Full, or plugin asset." }
    $pluginPackages = @($expectedAssetNames | Where-Object { $_ -match '^Plugin-(Camera|FrameGrabber|Gocator|Heliotis-C4)-.+-Windows-x64\.zip$' })
    if ($pluginPackages.Count -ne 4 -or @($pluginPackages | ForEach-Object { "$_.sha256" } | Where-Object { $_ -notin $expectedAssetNames }).Count -ne 0) { throw "Combined artifact manifest must contain four plugin ZIPs and four checksum sidecars." }
}
$assets = @{}
foreach ($entry in $manifestAssets) {
    $file = Get-RequiredFile (Join-Path $artifactDirectory $entry.fileName)
    $assets[$entry.fileName] = [ordered]@{ file = $file; sha256 = Assert-FileHash $file ([string]$entry.sha256) }
}
foreach ($checksumAsset in @($manifestAssets | Where-Object { $_.fileName -like "*.sha256" })) {
    $checksumName = [string]$checksumAsset.fileName
    $packageName = $checksumName.Substring(0, $checksumName.Length - ".sha256".Length)
    if (-not $assets.ContainsKey($packageName)) { throw "Checksum sidecar has no matching package asset: $checksumName." }
    $checksum = [System.IO.File]::ReadAllText($assets[$checksumName].file.FullName, [System.Text.UTF8Encoding]::new($false)).TrimEnd("`r", "`n")
    if ($checksum -ne "$($assets[$packageName].sha256)  $packageName") { throw "Checksum file does not contain the exact hash and filename: $checksumName." }
}
$metadata = Get-Content -LiteralPath $assets[$metadataName].file.FullName -Raw | ConvertFrom-Json
if ($metadata.version -ne $displayVersion -or $metadata.tag -ne $PlaygroundTag -or $metadata.channel -ne $channel -or $metadata.playgroundCommit -ne $manifest.playgroundCommit) { throw "Release metadata identity does not match the artifact manifest." }
$platform = @($metadata.platforms | Where-Object { $_.os -eq "windows" -and $_.arch -eq "x64" -and $_.package -eq "exe" })
if ($manifest.schemaVersion -eq 2) {
    if ($platform.Count -ne 1 -or $platform[0].fileName -ne $installerName -or $platform[0].sha256 -ne $assets[$installerName].sha256) { throw "Release metadata does not describe the generated Windows installer." }
} elseif ($platform.Count -ne 2 -or @($platform.fileName | Where-Object { $_ -notin @($installerName, $fullInstallerName) }).Count -ne 0 -or @($platform | Where-Object { $_.sha256 -ne $assets[$_.fileName].sha256 }).Count -ne 0) {
    throw "Combined release metadata must describe both Core and Full Windows installers."
}

$releaseNotesFile = Get-RequiredFile (Join-Path $artifactDirectory ([string]$manifest.releaseNotesFile))
$releaseExists = $false
$releasePublished = $false
$previousErrorActionPreference = $ErrorActionPreference
try { $ErrorActionPreference = "SilentlyContinue"; $releaseJson = gh release view $PlaygroundTag --repo $ReleaseRepository --json isDraft 2>$null; $releaseExists = $LASTEXITCODE -eq 0 } finally { $ErrorActionPreference = $previousErrorActionPreference }
if ($releaseExists) {
    $releasePublished = -not (($releaseJson | ConvertFrom-Json).isDraft)
    if ($releasePublished -and -not $AllowPublished) { throw "Release $PlaygroundTag is already published. Pass -AllowPublished only to append or correct its assets." }
}
$assetPaths = @($expectedAssetNames | ForEach-Object { $assets[$_].file.FullName })
$releaseTypeArguments = if ($isPrerelease) { @("--prerelease") } else { @() }
if ($releaseExists) {
    Invoke-NativeCommand gh (@("release", "upload", $PlaygroundTag, "--repo", $ReleaseRepository) + $assetPaths + @("--clobber")) "Failed to upload release assets for $PlaygroundTag"
    Invoke-NativeCommand gh (@("release", "edit", $PlaygroundTag, "--repo", $ReleaseRepository, "--title", [string]$manifest.title, "--notes-file", $releaseNotesFile.FullName) + $releaseTypeArguments) "Failed to update release metadata for $PlaygroundTag"
} else {
    Invoke-NativeCommand gh (@("release", "create", $PlaygroundTag, "--repo", $ReleaseRepository) + $assetPaths + @("--title", [string]$manifest.title, "--notes-file", $releaseNotesFile.FullName) + $releaseTypeArguments + @("--draft")) "Failed to create draft release for $PlaygroundTag"
}
$uploaded = (Invoke-NativeCommand gh @("release", "view", $PlaygroundTag, "--repo", $ReleaseRepository, "--json", "isDraft,assets") "Failed to verify uploaded release assets" | ConvertFrom-Json)
if (-not $uploaded.isDraft -and -not $releasePublished) { throw "Release $PlaygroundTag was unexpectedly published during deployment." }
foreach ($assetName in $expectedAssetNames) {
    $uploadedAsset = @($uploaded.assets | Where-Object { $_.name -eq $assetName })
    if ($uploadedAsset.Count -ne 1 -or $uploadedAsset[0].digest -ne "sha256:$($assets[$assetName].sha256)") { throw "GitHub asset digest verification failed for $assetName." }
}
Write-Host "Release assets uploaded and verified: $PlaygroundTag"
