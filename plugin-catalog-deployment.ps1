# Maintain the legacy plugin catalog compatibility pointer.

param([Parameter(Mandatory = $true)][string]$CatalogPath)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "Required command not found: gh" }
$catalog = Get-Item -LiteralPath $CatalogPath -ErrorAction Stop
if ($catalog.PSIsContainer -or $catalog.Name -ne "plugins-index.json") { throw "CatalogPath must point to plugins-index.json." }
$document = Get-Content -LiteralPath $catalog.FullName -Raw | ConvertFrom-Json
if ($document.schemaVersion -ne 1 -or @($document.plugins).Count -ne 4) { throw "Catalog has an invalid schema or plugin count." }
if (@($document.plugins.id | Sort-Object -Unique).Count -ne 4) { throw "Catalog plugin IDs must be unique." }

$repository = "Minu-Park/Basler-Playground"
& gh auth status
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI authentication check failed." }

function Set-ReleaseNotLatest {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    # Keep the mutable catalog out of GitHub's product Latest release pointer.
    $release = (gh api "repos/$Repository/releases/tags/$Tag" | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or -not $release.id) {
        throw "Failed to resolve release $Tag."
    }
    & gh api --method PATCH "repos/$Repository/releases/$($release.id)" -F make_latest=false | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to exclude release $Tag from GitHub Latest."
    }
}

$channelTag = "plugin-channel"
$releaseExists = $false
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "SilentlyContinue"
    gh release view $channelTag --repo $repository --json isDraft 2>$null | Out-Null
    $releaseExists = $LASTEXITCODE -eq 0
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if (-not $releaseExists) {
    & gh release create $channelTag --repo $repository --prerelease --title "Basler Playground plugin catalog" --notes "Mutable catalog for separately released device plugins."
    if ($LASTEXITCODE -ne 0) { throw "Failed to create the plugin catalog release." }
} else {
    & gh release edit $channelTag --repo $repository --prerelease
    if ($LASTEXITCODE -ne 0) { throw "Failed to keep the plugin catalog release as a prerelease." }
}
& gh release upload $channelTag --repo $repository $catalog.FullName --clobber
if ($LASTEXITCODE -ne 0) { throw "Failed to upload the plugin catalog." }
Set-ReleaseNotLatest $repository $channelTag
$asset = gh release view $channelTag --repo $repository --json assets | ConvertFrom-Json
$matching = @($asset.assets | Where-Object { $_.name -eq "plugins-index.json" })
if ($matching.Count -ne 1) { throw "Plugin catalog asset verification failed." }
Write-Host "Compatibility plugin list updated: https://github.com/$repository/releases/download/$channelTag/plugins-index.json"
