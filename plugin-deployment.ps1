# Upload and verify one device-plugin package as a GitHub draft release.

param(
    [Parameter(Mandatory = $true)][string]$ArtifactDirectory
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
    if (-not $item -or $item.PSIsContainer) { throw "Required artifact is missing: $Path" }
    return $item
}
function Assert-FileHash([System.IO.FileInfo]$File, [string]$ExpectedHash) {
    if ($ExpectedHash -notmatch '^[0-9a-f]{64}$') { throw "Invalid manifest hash for $($File.Name)." }
    $actual = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedHash) { throw "Artifact hash mismatch for $($File.Name)." }
    return $actual
}

Require-Command gh
$directory = (Resolve-Path -LiteralPath $ArtifactDirectory -ErrorAction Stop).Path
$manifestFile = Get-RequiredFile (Join-Path $directory "plugin-artifacts.json")
$manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $manifest.kind -ne "device-plugin") { throw "Invalid device-plugin artifact manifest schema." }
$pluginId = [string]$manifest.pluginId
$pluginVersion = [string]$manifest.pluginVersion
if ($pluginId -notin @("camera", "framegrabber", "gocator", "heliotis-c4")) { throw "Unsupported plugin ID in artifact manifest." }
if ($pluginVersion -notmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-beta\.[1-9][0-9]*)?$') { throw "Invalid plugin version in artifact manifest." }
$expectedReleaseTag = "plugin-$pluginId-v$pluginVersion"
if ($manifest.releaseTag -ne $expectedReleaseTag -or $manifest.platform -ne "windows-x64") { throw "Plugin artifact identity is inconsistent." }
if ($manifest.coreCommit -notmatch '^[0-9a-f]{40}$' -or $manifest.sourceCommit -notmatch '^[0-9a-f]{40}$') { throw "Plugin artifact is not bound to immutable source commits." }

$packageName = [string]$manifest.packageName
$package = Get-RequiredFile (Join-Path $directory $packageName)
$packageHash = Assert-FileHash $package ([string]$manifest.packageSha256)
$checksumFile = Get-RequiredFile "$($package.FullName).sha256"
$checksum = [System.IO.File]::ReadAllText($checksumFile.FullName, [System.Text.UTF8Encoding]::new($false)).TrimEnd("`r", "`n")
if ($checksum -ne "$packageHash  $packageName") { throw "Plugin checksum sidecar does not match the package." }
$notesFile = Get-RequiredFile (Join-Path $directory "release-notes.md")

$repository = "Minu-Park/Basler-Playground"
Invoke-NativeCommand gh @("auth", "status") "GitHub CLI authentication check failed" | Out-Null
$releaseExists = $false
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "SilentlyContinue"
    $releaseJson = gh release view $expectedReleaseTag --repo $repository --json isDraft 2>$null
    $releaseExists = $LASTEXITCODE -eq 0
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($releaseExists -and -not (($releaseJson | ConvertFrom-Json).isDraft)) {
    throw "Release $expectedReleaseTag is already published; create a new plugin version."
}

$assetPaths = @($package.FullName, $checksumFile.FullName)
$releaseTypeArguments = if ([string]$manifest.channel -eq "beta") { @("--prerelease") } else { @() }
if ($releaseExists) {
    Invoke-NativeCommand gh (@("release", "upload", $expectedReleaseTag, "--repo", $repository) + $assetPaths + @("--clobber")) "Failed to upload plugin release assets"
    Invoke-NativeCommand gh (@("release", "edit", $expectedReleaseTag, "--repo", $repository, "--title", "Basler Playground $pluginId plugin $pluginVersion", "--notes-file", $notesFile.FullName) + $releaseTypeArguments) "Failed to update plugin release metadata"
} else {
    Invoke-NativeCommand gh (@("release", "create", $expectedReleaseTag, "--repo", $repository) + $assetPaths + @("--title", "Basler Playground $pluginId plugin $pluginVersion", "--notes-file", $notesFile.FullName) + $releaseTypeArguments + @("--draft")) "Failed to create plugin draft release"
}

$uploaded = (Invoke-NativeCommand gh @("release", "view", $expectedReleaseTag, "--repo", $repository, "--json", "isDraft,assets") "Failed to verify plugin release assets" | ConvertFrom-Json)
if (-not $uploaded.isDraft) { throw "Plugin release was unexpectedly published during deployment." }
foreach ($entry in @(@{ Name = $packageName; Hash = $packageHash }, @{ Name = "$packageName.sha256"; Hash = (Get-FileHash -LiteralPath $checksumFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })) {
    $asset = @($uploaded.assets | Where-Object { $_.name -eq $entry.Name })
    if ($asset.Count -ne 1 -or $asset[0].digest -ne "sha256:$($entry.Hash)") { throw "GitHub asset digest verification failed for $($entry.Name)." }
}
Write-Host "Draft plugin release uploaded and verified: $expectedReleaseTag"
