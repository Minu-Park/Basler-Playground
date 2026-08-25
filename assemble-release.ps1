# Assemble one Core release record containing Core, Full, and device-plugin assets.

param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$CoreArtifactDirectory,
    [Parameter(Mandatory = $true)][string]$FullArtifactDirectory,
    [Parameter(Mandatory = $true)][string]$PluginArtifactRoot,
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-RequiredFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer) {
        throw "Required release artifact is missing: $Path"
    }
    return $item
}

function Read-ProfileArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$ExpectedProfile
    )

    $resolvedDirectory = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).Path
    $manifestFile = Get-RequiredFile (Join-Path $resolvedDirectory "release-artifacts.json")
    $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 2 -or $manifest.tag -ne $Tag -or $manifest.packageProfile -ne $ExpectedProfile) {
        throw "Artifact manifest in $resolvedDirectory is not the expected $ExpectedProfile profile for $Tag."
    }

    $assetEntries = @($manifest.assets)
    $installerEntry = @($assetEntries | Where-Object { $_.fileName -match '\.exe$' })
    if ($installerEntry.Count -ne 1) {
        throw "Profile $ExpectedProfile must contain exactly one installer asset."
    }
    $installer = Get-RequiredFile (Join-Path $resolvedDirectory ([string]$installerEntry[0].fileName))
    $checksum = Get-RequiredFile "$($installer.FullName).sha256"
    $metadataName = if ($manifest.channel -eq "beta") { "latest-beta.json" } else { "latest.json" }
    $metadata = Get-RequiredFile (Join-Path $resolvedDirectory $metadataName)
    return [pscustomobject]@{
        Directory = $resolvedDirectory
        Manifest = $manifest
        Installer = $installer
        Checksum = $checksum
        Metadata = (Get-Content -LiteralPath $metadata.FullName -Raw | ConvertFrom-Json)
    }
}

if ($Tag -notmatch '^v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?:-beta\.[1-9][0-9]*)?$') {
    throw "Tag must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-beta.N."
}
$isBeta = $Tag -match '-beta\.'
$channel = if ($isBeta) { "beta" } else { "stable" }
$displayVersion = $Tag.Substring(1)
$core = Read-ProfileArtifact -Directory $CoreArtifactDirectory -ExpectedProfile "core-only"
$full = Read-ProfileArtifact -Directory $FullArtifactDirectory -ExpectedProfile "full"
if ($core.Manifest.playgroundCommit -ne $full.Manifest.playgroundCommit) {
    throw "Core and Full artifacts are bound to different Playground commits."
}

$root = $PSScriptRoot
$output = if ($OutputDirectory) {
    if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
        [System.IO.Path]::GetFullPath($OutputDirectory)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $root $OutputDirectory))
    }
} else {
    Join-Path $root "dist\release-$Tag"
}
New-Item -ItemType Directory -Force -Path $output | Out-Null

$coreInstallerName = $core.Installer.Name
$fullInstallerName = "BaslerPlayground-$Tag-full-windows-x64.exe"
$coreInstaller = Join-Path $output $coreInstallerName
$fullInstaller = Join-Path $output $fullInstallerName
Copy-Item -LiteralPath $core.Installer.FullName -Destination $coreInstaller -Force
Copy-Item -LiteralPath "$($core.Installer.FullName).sha256" -Destination "$coreInstaller.sha256" -Force
Copy-Item -LiteralPath $full.Installer.FullName -Destination $fullInstaller -Force
Copy-Item -LiteralPath "$($full.Installer.FullName).sha256" -Destination "$fullInstaller.sha256" -Force

$coreHash = (Get-FileHash -LiteralPath $coreInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
$fullHash = (Get-FileHash -LiteralPath $fullInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText("$coreInstaller.sha256", "$coreHash  $coreInstallerName", $utf8NoBom)
[System.IO.File]::WriteAllText("$fullInstaller.sha256", "$fullHash  $fullInstallerName", $utf8NoBom)

$downloadRoot = "https://github.com/Minu-Park/Basler-Playground/releases/download/$Tag"
$platforms = @(
    [ordered]@{
        os = "windows"
        arch = "x64"
        package = "exe"
        packageProfile = "core-only"
        fileName = $coreInstallerName
        url = "$downloadRoot/$coreInstallerName"
        sha256 = $coreHash
    },
    [ordered]@{
        os = "windows"
        arch = "x64"
        package = "exe"
        packageProfile = "full"
        fileName = $fullInstallerName
        url = "$downloadRoot/$fullInstallerName"
        sha256 = $fullHash
    }
)

$pluginIds = @("camera", "framegrabber", "gocator", "heliotis-c4")
$selectedPlugins = @()
foreach ($pluginId in $pluginIds) {
    $candidates = @(Get-ChildItem -LiteralPath (Resolve-Path -LiteralPath $PluginArtifactRoot -ErrorAction Stop).Path -Directory -Filter "plugin-$pluginId-v*" | ForEach-Object {
        $manifestPath = Join-Path $_.FullName "plugin-artifacts.json"
        if (-not (Test-Path $manifestPath)) { return }
        $candidateManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($candidateManifest.coreTag -eq $Tag) {
            [pscustomobject]@{ Directory = $_; Manifest = $candidateManifest }
        }
    })
    if ($candidates.Count -ne 1) {
        throw "Expected exactly one $pluginId artifact bound to $Tag, found $($candidates.Count)."
    }
    $candidate = $candidates[0]
    $packageName = [string]$candidate.Manifest.packageName
    $package = Get-RequiredFile (Join-Path $candidate.Directory.FullName $packageName)
    $packageHash = (Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($packageHash -ne [string]$candidate.Manifest.packageSha256) {
        throw "Package hash mismatch for $pluginId."
    }
    $packageOut = Join-Path $output $packageName
    Copy-Item -LiteralPath $package.FullName -Destination $packageOut -Force
    $checksumOut = "$packageOut.sha256"
    [System.IO.File]::WriteAllText($checksumOut, "$packageHash  $packageName", $utf8NoBom)
    $selectedPlugins += [pscustomobject]@{
        Id = $pluginId
        Manifest = $candidate.Manifest
        Package = (Get-Item -LiteralPath $packageOut)
        PackageHash = $packageHash
    }
}

$catalog = [ordered]@{
    schemaVersion = 1
    channel = $channel
    coreVersion = ($Tag.Substring(1) -replace '-beta\.[0-9]+$', '')
    coreTag = $Tag
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    plugins = @($selectedPlugins | ForEach-Object {
        $plugin = $_
        [ordered]@{
            id = [string]$plugin.Manifest.pluginId
            displayName = [string]$plugin.Manifest.displayName
            description = [string]$plugin.Manifest.description
            version = [string]$plugin.Manifest.pluginVersion
            minimumCoreVersion = [string]$plugin.Manifest.minimumCoreVersion
            releaseTag = $Tag
            platforms = [ordered]@{
                "windows-x64" = [ordered]@{
                    fileName = $plugin.Package.Name
                    url = "$downloadRoot/$($plugin.Package.Name)"
                    sha256 = $plugin.PackageHash
                }
            }
        }
    })
}
$metadataName = if ($isBeta) { "latest-beta.json" } else { "latest.json" }
$catalogPath = Join-Path $output "plugins-index.json"
[System.IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 10), $utf8NoBom)

$releaseNotes = @"
## What's New

- **Core / Full / Plugins**: The beta release contains the lightweight Core installer, the Full installer, and the four independently installable device-plugin packages in one GitHub release.
- **Simulation-first Core**: Core starts without device plugins; Help > Plugins installs or updates Camera, Frame Grabber, Gocator, and Heliotis C4 packages.
- **Verified packages**: Every installer and plugin package has a SHA-256 sidecar and is bound to Core $Tag.

## Improvements & Fixes

- Plugin packages are activated in the local package root after the affected sessions close.
- Full and Core are separate installer assets of the same release, while plugin packages remain individually versioned.
"@
$metadata = [ordered]@{
    version = $displayVersion
    tag = $Tag
    channel = $channel
    publishedAt = (Get-Date).ToUniversalTime().ToString("o")
    notesUrl = "https://github.com/minu-park/basler-playground/releases/tag/$Tag"
    releaseNotes = $releaseNotes.Trim()
    packageProfile = "combined"
    packageProfiles = @("core-only", "full", "plugins")
    platforms = $platforms
    pluginCatalog = [ordered]@{
        fileName = "plugins-index.json"
        url = "$downloadRoot/plugins-index.json"
    }
    playgroundCommit = [string]$core.Manifest.playgroundCommit
}
$metadataPath = Join-Path $output $metadataName
[System.IO.File]::WriteAllText($metadataPath, ($metadata | ConvertTo-Json -Depth 10), $utf8NoBom)
$notesPath = Join-Path $output "release-notes.md"
[System.IO.File]::WriteAllText($notesPath, $releaseNotes.Trim(), $utf8NoBom)

$assetFiles = @(
    $coreInstaller,
    "$coreInstaller.sha256",
    $fullInstaller,
    "$fullInstaller.sha256",
    $metadataPath,
    $catalogPath
)
foreach ($plugin in $selectedPlugins) {
    $assetFiles += $plugin.Package.FullName
    $assetFiles += "$($plugin.Package.FullName).sha256"
}
$artifactManifest = [ordered]@{
    schemaVersion = 3
    kind = "combined-release"
    tag = $Tag
    playgroundCommit = [string]$core.Manifest.playgroundCommit
    expectedTagCommit = [string]$core.Manifest.expectedTagCommit
    title = "Basler Playground $Tag"
    channel = $channel
    prerelease = $isBeta
    packageProfiles = @("core-only", "full", "plugins")
    outputDirectory = $output
    releaseNotesFile = (Split-Path $notesPath -Leaf)
    assets = @($assetFiles | ForEach-Object {
        $file = Get-Item -LiteralPath $_
        [ordered]@{ fileName = $file.Name; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
}
[System.IO.File]::WriteAllText((Join-Path $output "release-artifacts.json"), ($artifactManifest | ConvertTo-Json -Depth 10), $utf8NoBom)
Write-Host "Combined release artifacts created: $output"
