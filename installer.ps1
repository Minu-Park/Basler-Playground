# Local Windows installer-artifact builder for basler-playground.
# Requires: git and access to the private Playground repository.

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
                    throw "Usage: .\\installer.ps1 --tag vX.Y.Z"
                }
                $tag = $Arguments[$index]
            }
            default {
                throw "Usage: .\\installer.ps1 --tag vX.Y.Z"
            }
        }
    }
    if (-not $tag) {
        throw "Usage: .\\installer.ps1 --tag vX.Y.Z"
    }
    return [pscustomobject]@{ Tag = $tag }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    & $FilePath @ArgumentList
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$FailureMessage (exit code $exitCode)."
    }
}

function New-HardLinkedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $sourcePath = (Resolve-Path $Source).Path
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($file in Get-ChildItem $sourcePath -Recurse -File) {
        $relativePath = $file.FullName.Substring($sourcePath.Length + 1)
        $destinationFile = Join-Path $Destination $relativePath
        New-Item -ItemType Directory -Force -Path (Split-Path $destinationFile -Parent) | Out-Null
        try {
            New-Item -ItemType HardLink -Path $destinationFile -Target $file.FullName -ErrorAction Stop | Out-Null
        }
        catch {
            Copy-Item -LiteralPath $file.FullName -Destination $destinationFile -Force
        }
    }
}

function Get-ReleaseNotesForTag {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    if (-not (Test-Path $Path)) {
        return $null
    }
    $document = Get-Content $Path -Raw
    $pattern = "(?ms)^#\s+$([regex]::Escape($Tag))\s*\r?\n(?<body>.*?)(?=^#\s+v\d|\z)"
    $match = [regex]::Match($document, $pattern)
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups["body"].Value.Trim()
}

Require-Command git

$arguments = Read-InstallerArguments $CliArgs
$PlaygroundTag = $arguments.Tag
$PlaygroundRepo = "git@github.com:minu-park/playground.git"
$UpdateEpoch = 4

if ($PlaygroundTag -notmatch '^v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?:-beta\.([1-9][0-9]*))?$') {
    throw "PlaygroundTag must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-beta.N."
}
$packageVersion = $Matches[1]
$betaRevision = $Matches[2]
if ($betaRevision -and [int64]$betaRevision -gt 999998) {
    throw "The beta revision must be between 1 and 999998."
}
$displayVersion = $PlaygroundTag.Substring(1)
$isPrerelease = [bool]$betaRevision
$channel = if ($isPrerelease) { "beta" } else { "stable" }
$ifwVersion = if ($isPrerelease) { "$packageVersion.$betaRevision" } else { "$packageVersion.999999" }

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

Invoke-NativeCommand git @("-C", $checkout, "fetch", "--prune", "--tags", "origin") "Failed to fetch Playground tags from origin"
Invoke-NativeCommand git @("-C", $checkout, "show-ref", "--tags", "--verify", "--quiet", "refs/tags/$PlaygroundTag") "Playground tag $PlaygroundTag was not found"
$tagCommit = (Invoke-NativeCommand git @("-C", $checkout, "rev-parse", "refs/tags/$PlaygroundTag^{commit}") "Failed to resolve Playground tag $PlaygroundTag" | Select-Object -Last 1).Trim()
Invoke-NativeCommand git @("-C", $checkout, "checkout", "--detach", $PlaygroundTag) "Failed to check out Playground tag $PlaygroundTag"
# Initialize Playground's own private/internal submodules after the tag checkout.
Invoke-NativeCommand git @("-C", $checkout, "submodule", "update", "--init", "--recursive") "Failed to initialize Playground submodules"
$checkoutStatus = @(Invoke-NativeCommand git @(
    "-C", $checkout, "status", "--porcelain", "--untracked-files=all"
) "Failed to verify the Playground release checkout")
if ($checkoutStatus.Count -gt 0) {
    throw "Playground release checkout is not clean after selecting $PlaygroundTag. Remove local or untracked source changes before packaging."
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
    if (Test-Path ".\package_bundle.bat") {
        .\package_bundle.bat Release
    } elseif (Test-Path ".\build_package.bat") {
        .\build_package.bat Release
    } else {
        throw "No Windows packaging script found in Playground checkout."
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Playground packaging failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$expectedInstallerName = "Basler Playground-$displayVersion-win64-release.exe"
$expectedInstallerPath = Join-Path $checkout "build/bundle/$expectedInstallerName"
$installer = Get-Item $expectedInstallerPath -ErrorAction SilentlyContinue

if (-not $installer) {
    throw "Expected installer not found: $expectedInstallerPath"
}
$packagedApplicationPath = Join-Path $checkout "build/bundle/Release/Playground.exe"
if (-not (Test-Path $packagedApplicationPath)) {
    throw "Packaged application executable not found: $packagedApplicationPath"
}
$applicationProductVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo(
    $packagedApplicationPath).ProductVersion
if ($applicationProductVersion -ne $displayVersion) {
    throw "Packaged application version mismatch: expected $displayVersion, found $applicationProductVersion."
}

$installerName = "BaslerPlayground-$PlaygroundTag-windows-x64.exe"
$installerOut = Join-Path $dist $installerName
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$ifwPackageName = "Basler Playground-$displayVersion-win64-release"
$ifwTempPath = Join-Path $checkout "build/bundle/_CPack_Packages/win64/IFW/$ifwPackageName"
$ifwTempDir = Get-Item $ifwTempPath -ErrorAction SilentlyContinue

if (-not $ifwTempDir -or -not (Test-Path (Join-Path $ifwTempDir.FullName "packages"))) {
    throw "Expected CPack IFW package directory was not found: $ifwTempPath"
}

$cpackIfwRoot = $env:CPACK_IFW_ROOT
if (-not $cpackIfwRoot -and (Test-Path "C:\Qt\Tools\QtInstallerFramework")) {
    $cpackIfwRoot = (Get-ChildItem "C:\Qt\Tools\QtInstallerFramework" -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}
if (-not $cpackIfwRoot) {
    throw "Qt Installer Framework path not found. Set CPACK_IFW_ROOT."
}
$repogen = Join-Path $cpackIfwRoot "bin/repogen.exe"
if (-not (Test-Path $repogen)) {
    throw "repogen.exe not found: $repogen"
}
$packagesDir = Join-Path $ifwTempDir.FullName "packages"
$updateComponentsPath = Join-Path $checkout "build/ifw-update-components.txt"
if (-not (Test-Path $updateComponentsPath)) {
    throw "IFW update component manifest not found: $updateComponentsPath"
}
$updateComponents = @(Get-Content $updateComponentsPath | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($updateComponents.Count -eq 0) {
    throw "IFW update component manifest is empty."
}
$installerOnlyComponents = @("DevelopmentPrerequisitesPayload", "MSVCBuildTools", "WindowsSDK")
$invalidUpdateComponents = @($updateComponents | Where-Object { $_ -in $installerOnlyComponents })
if ($invalidUpdateComponents.Count -gt 0) {
    throw "Installer-only components cannot enter the update repository: $($invalidUpdateComponents -join ', ')."
}

$repositoryRoot = Join-Path $dist "repository"
$filteredPackages = Join-Path $checkout "build/release-packages"
if (Test-Path $repositoryRoot) {
    Remove-Item $repositoryRoot -Recurse -Force
}
if (Test-Path $filteredPackages) {
    Remove-Item $filteredPackages -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $repositoryRoot | Out-Null
New-Item -ItemType Directory -Force -Path $filteredPackages | Out-Null

try {
    foreach ($component in $updateComponents) {
        $packageDir = Join-Path $packagesDir $component
        $packageXmlPath = Join-Path $packageDir "meta/package.xml"
        $packageDataPath = Join-Path $packageDir "data"
        if (-not (Test-Path $packageXmlPath) -or -not (Test-Path $packageDataPath)) {
            throw "Update component package is incomplete: $component"
        }
        New-HardLinkedDirectory $packageDir (Join-Path $filteredPackages $component)
    }

    Invoke-NativeCommand $repogen @("-p", $filteredPackages, $repositoryRoot) "repogen failed"
}
finally {
    if (Test-Path $filteredPackages) {
        Remove-Item $filteredPackages -Recurse -Force
    }
}

$updatesXmlPath = Join-Path $repositoryRoot "Updates.xml"
if (-not (Test-Path $updatesXmlPath)) {
    throw "repogen completed without creating Updates.xml."
}
$updatesXml = [xml](Get-Content $updatesXmlPath -Raw)
$updatePackageNames = @($updatesXml.Updates.PackageUpdate | ForEach-Object { [string]$_.Name })
$unexpectedPackages = @($updatePackageNames | Where-Object { $_ -notin $updateComponents })
$missingPackages = @($updateComponents | Where-Object { $_ -notin $updatePackageNames })
if ($unexpectedPackages.Count -gt 0 -or $missingPackages.Count -gt 0) {
    throw "Update repository component mismatch. Unexpected: $($unexpectedPackages -join ', '); missing: $($missingPackages -join ', ')."
}
$coreUpdate = @($updatesXml.Updates.PackageUpdate | Where-Object {
    [string]$_.Name -eq "PlaygroundCore"
}) | Select-Object -First 1
if (-not $coreUpdate -or [string]$coreUpdate.Version -ne $ifwVersion) {
    throw "PlaygroundCore IFW version mismatch: expected $ifwVersion, found $([string]$coreUpdate.Version)."
}

$repositoryZipName = "BaslerPlayground-$PlaygroundTag-ifw-repository.zip"
$repositoryZipOut = Join-Path $dist $repositoryZipName
if (Test-Path $repositoryZipOut) {
    Remove-Item $repositoryZipOut -Force
}
Compress-Archive -Path (Join-Path $repositoryRoot "*") -DestinationPath $repositoryZipOut -CompressionLevel Optimal
if (-not (Test-Path $repositoryZipOut)) {
    throw "Failed to create IFW repository archive: $repositoryZipOut"
}
$repositoryZipHash = Get-FileHash $repositoryZipOut -Algorithm SHA256

if (Test-Path $installerOut) {
    Remove-Item -LiteralPath $installerOut -Force
}
Copy-Item -LiteralPath $installer.FullName -Destination $installerOut -Force
$hash = Get-FileHash $installerOut -Algorithm SHA256
[System.IO.File]::WriteAllText(
    "$installerOut.sha256",
    "$($hash.Hash.ToLowerInvariant())  $installerName",
    $utf8NoBom
)

$commit = (Invoke-NativeCommand git @("-C", $checkout, "rev-parse", "HEAD") "Failed to resolve the Playground commit" | Select-Object -Last 1).Trim()
if ($commit -ne $tagCommit) {
    throw "Checked-out Playground commit does not match immutable tag $PlaygroundTag."
}
$releaseUrl = "https://github.com/minu-park/basler-playground/releases/tag/$PlaygroundTag"
$installerUrl = "https://github.com/minu-park/basler-playground/releases/download/$PlaygroundTag/$installerName"
$repositoryZipUrl = "https://github.com/minu-park/basler-playground/releases/download/$PlaygroundTag/$repositoryZipName"
$releaseNotes = "Installer built from private Playground tag $PlaygroundTag ($commit)."
$routedReleaseNotes = Get-ReleaseNotesForTag (Join-Path $checkout "RELEASE_NOTES.md") $PlaygroundTag
if ($routedReleaseNotes) {
    $releaseNotes = $routedReleaseNotes
}
$metadata = [ordered]@{
    version = $displayVersion
    tag = $PlaygroundTag
    channel = $channel
    publishedAt = (Get-Date).ToUniversalTime().ToString("o")
    notesUrl = $releaseUrl
    releaseNotes = $releaseNotes
    platforms = @(
        [ordered]@{
            os = "windows"
            arch = "x64"
            package = "exe"
            fileName = $installerName
            url = $installerUrl
            sha256 = $hash.Hash.ToLowerInvariant()
        }
    )
    update = [ordered]@{
        epoch = $UpdateEpoch
        ifwVersion = $ifwVersion
        forceFullInstaller = $false
    }
    playgroundCommit = $commit
}
$metadata.repositoryZip = [ordered]@{
    fileName = $repositoryZipName
    url = $repositoryZipUrl
    sha256 = $repositoryZipHash.Hash.ToLowerInvariant()
}

$metadataFileName = if ($isPrerelease) { "latest-beta.json" } else { "latest.json" }
$metadataOut = Join-Path $dist $metadataFileName
[System.IO.File]::WriteAllText(
    $metadataOut,
    ($metadata | ConvertTo-Json -Depth 6),
    $utf8NoBom
)

$releaseAssets = @(
    $installerOut,
    "$installerOut.sha256",
    $repositoryZipOut,
    $metadataOut
)
$releaseNotesOut = Join-Path $dist "release-notes.md"
[System.IO.File]::WriteAllText($releaseNotesOut, $releaseNotes, $utf8NoBom)
$artifactManifest = [ordered]@{
    schemaVersion = 1
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
        [ordered]@{
            fileName = $file.Name
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
}
$artifactManifestOut = Join-Path $dist "release-artifacts.json"
[System.IO.File]::WriteAllText(
    $artifactManifestOut,
    ($artifactManifest | ConvertTo-Json -Depth 6),
    $utf8NoBom
)

Write-Host "Installer artifacts created: $dist"
Write-Host "Upload them with: .\\deployment.ps1"
