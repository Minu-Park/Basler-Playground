# Local Windows release helper for basler-playground.
# Requires: git, GitHub CLI (`gh auth login`), and access to the private Playground repository.

param(
    [Parameter(Mandatory = $true)]
    [string]$PlaygroundTag,

    [string]$PlaygroundRepo = "git@github.com:minu-park/playground.git",

    [int]$UpdateEpoch = 2,

    [switch]$ForceFullInstaller
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
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
Require-Command gh

Invoke-NativeCommand gh @("auth", "status") "GitHub CLI authentication check failed" | Out-Null

if ($PlaygroundTag -notmatch '^v\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "PlaygroundTag must look like vX.Y.Z."
}
if ($UpdateEpoch -lt 1) {
    throw "UpdateEpoch must be a positive integer."
}
$packageVersion = [regex]::Match($PlaygroundTag, '^v(\d+\.\d+\.\d+)').Groups[1].Value

$root = $PSScriptRoot
$checkout = Join-Path $root "playground"

if (-not (Test-Path $checkout)) {
    Invoke-NativeCommand git @("clone", "--filter=blob:none", $PlaygroundRepo, $checkout) "Failed to clone Playground"
}

Invoke-NativeCommand git @("-C", $checkout, "fetch", "--force", "--tags", "origin") "Failed to fetch Playground tags from origin"
Invoke-NativeCommand git @("-C", $checkout, "checkout", "--force", $PlaygroundTag) "Failed to check out Playground tag $PlaygroundTag"
# Initialize Playground's own private/internal submodules after the tag checkout.
Invoke-NativeCommand git @("-C", $checkout, "submodule", "update", "--init", "--recursive") "Failed to initialize Playground submodules"

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

$expectedInstallerName = "Basler Playground-$packageVersion-win64-release.exe"
$expectedInstallerPath = Join-Path $checkout "build/bundle/$expectedInstallerName"
$installer = Get-Item $expectedInstallerPath -ErrorAction SilentlyContinue

if (-not $installer) {
    throw "Expected installer not found: $expectedInstallerPath"
}

$installerName = "BaslerPlayground-$PlaygroundTag-windows-x64.exe"
$installerOut = Join-Path $dist $installerName
Copy-Item $installer.FullName $installerOut -Force

$hash = Get-FileHash $installerOut -Algorithm SHA256
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText(
    "$installerOut.sha256",
    "$($hash.Hash.ToLowerInvariant())  $installerName",
    $utf8NoBom
)

$ifwPackageName = "Basler Playground-$packageVersion-win64-release"
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

$commit = (Invoke-NativeCommand git @("-C", $checkout, "rev-parse", "HEAD") "Failed to resolve the Playground commit" | Select-Object -Last 1).Trim()
$version = $PlaygroundTag.Substring(1)
$isPrerelease = $PlaygroundTag.Contains("-")
$channel = if ($isPrerelease) { "prerelease" } else { "stable" }
$releaseUrl = "https://github.com/minu-park/basler-playground/releases/tag/$PlaygroundTag"
$installerUrl = "https://github.com/minu-park/basler-playground/releases/download/$PlaygroundTag/$installerName"
$repositoryZipUrl = "https://github.com/minu-park/basler-playground/releases/download/$PlaygroundTag/$repositoryZipName"
$releaseNotes = "Installer built from private Playground tag $PlaygroundTag ($commit)."
$routedReleaseNotes = Get-ReleaseNotesForTag (Join-Path $checkout "RELEASE_NOTES.md") $PlaygroundTag
if ($routedReleaseNotes) {
    $releaseNotes = $routedReleaseNotes
}
$metadata = [ordered]@{
    version = $version
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
        forceFullInstaller = [bool]$ForceFullInstaller
    }
    playgroundCommit = $commit
}
if (-not $ForceFullInstaller) {
    $metadata.repositoryZip = [ordered]@{
        fileName = $repositoryZipName
        url = $repositoryZipUrl
        sha256 = $repositoryZipHash.Hash.ToLowerInvariant()
    }
}

$metadataOut = Join-Path $dist "latest.json"
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
$releaseTypeArguments = @()
if ($isPrerelease) {
    $releaseTypeArguments += "--prerelease"
}

$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "SilentlyContinue"
    gh release view $PlaygroundTag 2>$null | Out-Null
    $releaseExists = $LASTEXITCODE -eq 0
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($releaseExists) {
    Invoke-NativeCommand gh (@("release", "upload", $PlaygroundTag) + $releaseAssets + @("--clobber")) "Failed to upload release assets for $PlaygroundTag"
    Invoke-NativeCommand gh (@(
        "release", "edit", $PlaygroundTag,
        "--title", "Basler Playground $PlaygroundTag",
        "--notes-file", $releaseNotesOut
    ) + $releaseTypeArguments) "Failed to update release metadata for $PlaygroundTag"
} else {
    Invoke-NativeCommand gh (@("release", "create", $PlaygroundTag) + $releaseAssets + @(
        "--title", "Basler Playground $PlaygroundTag",
        "--notes-file", $releaseNotesOut
    ) + $releaseTypeArguments + @("--draft")) "Failed to create draft release for $PlaygroundTag"
}
