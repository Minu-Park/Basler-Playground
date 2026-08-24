# Publish the mutable plugin catalog release asset.

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
    & gh release create $channelTag --repo $repository --title "Basler Playground plugin catalog" --notes "Mutable catalog for separately released device plugins."
    if ($LASTEXITCODE -ne 0) { throw "Failed to create the plugin catalog release." }
}
& gh release upload $channelTag --repo $repository $catalog.FullName --clobber
if ($LASTEXITCODE -ne 0) { throw "Failed to upload the plugin catalog." }
$asset = gh release view $channelTag --repo $repository --json assets | ConvertFrom-Json
$matching = @($asset.assets | Where-Object { $_.name -eq "plugins-index.json" })
if ($matching.Count -ne 1) { throw "Plugin catalog asset verification failed." }
Write-Host "Plugin catalog published: https://github.com/$repository/releases/download/$channelTag/plugins-index.json"
