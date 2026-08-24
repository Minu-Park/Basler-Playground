# Generate the mutable catalog consumed by Help > Plugins.

param(
    [Parameter(Mandatory = $true)][string]$CoreTag,
    [string]$ArtifactRoot = "",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ($CoreTag -notmatch '^v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?:-beta\.([1-9][0-9]*))?$') {
    throw "CoreTag must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-beta.N."
}
$coreVersion = $CoreTag.Substring(1) -replace '-beta\.[0-9]+$', ''
$root = if ($ArtifactRoot) { (Resolve-Path -LiteralPath $ArtifactRoot -ErrorAction Stop).Path } else { (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "dist") -ErrorAction Stop).Path }
$output = if ($OutputPath) { $OutputPath } else { Join-Path $root "plugins-index.json" }
$expectedPluginIds = @("camera", "framegrabber", "gocator", "heliotis-c4")
$artifactFiles = @(Get-ChildItem -LiteralPath $root -Directory -Filter "plugin-*" | ForEach-Object {
    $candidate = Join-Path $_.FullName "plugin-artifacts.json"
    if (Test-Path $candidate) { Get-Item -LiteralPath $candidate }
})
if ($artifactFiles.Count -eq 0) { throw "No plugin artifact manifests found under $root." }

$entriesById = @{}
foreach ($artifactFile in $artifactFiles) {
    $artifact = Get-Content -LiteralPath $artifactFile.FullName -Raw | ConvertFrom-Json
    $id = [string]$artifact.pluginId
    if ($id -notin $expectedPluginIds) { throw "Unexpected plugin ID in $($artifactFile.Name): $id" }
    if ($entriesById.ContainsKey($id)) { throw "Duplicate plugin artifact for $id." }
    if ($artifact.coreTag -ne $CoreTag -or $artifact.minimumCoreVersion -ne $coreVersion) {
        throw "Plugin artifact $id is not built for Core $CoreTag."
    }
    if ([string]$artifact.packageSha256 -notmatch '^[0-9a-f]{64}$') { throw "Invalid package hash for $id." }
    $entriesById[$id] = [ordered]@{
        id = $id
        displayName = [string]$artifact.displayName
        description = [string]$artifact.description
        version = [string]$artifact.pluginVersion
        minimumCoreVersion = $coreVersion
        releaseTag = [string]$artifact.releaseTag
        platforms = [ordered]@{
            "windows-x64" = [ordered]@{
                fileName = [string]$artifact.packageName
                url = [string]$artifact.packageUrl
                sha256 = [string]$artifact.packageSha256
            }
        }
    }
}
foreach ($id in $expectedPluginIds) {
    if (-not $entriesById.ContainsKey($id)) { throw "Plugin catalog is incomplete; missing $id." }
}

$catalog = [ordered]@{
    schemaVersion = 1
    channel = if ($CoreTag -match '-beta\.') { "beta" } else { "stable" }
    coreVersion = $coreVersion
    coreTag = $CoreTag
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    plugins = @($expectedPluginIds | ForEach-Object { $entriesById[$_] })
}
$parent = Split-Path -Parent $output
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($output, ($catalog | ConvertTo-Json -Depth 8), $utf8NoBom)
Write-Host "Plugin catalog created: $output"
