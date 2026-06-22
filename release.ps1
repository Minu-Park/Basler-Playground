# Local Windows release helper for basler-playground.
# Requires: git, GitHub CLI (`gh auth login`), and access to the private Playground repository.

param(
    [Parameter(Mandatory = $true)]
    [string]$PlaygroundTag,

    [string]$PlaygroundRepo = "git@github.com:minu-park/playground.git"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

Require-Command git
Require-Command gh

gh auth status | Out-Null

if ($PlaygroundTag -notmatch '^v\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "PlaygroundTag must look like vX.Y.Z."
}

$root = $PSScriptRoot
$checkout = Join-Path $root "playground"

if (-not (Test-Path $checkout)) {
    git clone --filter=blob:none $PlaygroundRepo $checkout
}

git -C $checkout fetch --tags origin
git -C $checkout checkout --force $PlaygroundTag
# Initialize Playground's own private/internal submodules after the tag checkout.
git -C $checkout submodule update --init --recursive

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

$installer = Get-ChildItem (Join-Path $checkout "build/bundle") -Filter *.exe |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $installer) {
    throw "No installer exe found under playground/build/bundle."
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

# Run repogen to generate update repository
$cpackIfwRoot = $env:CPACK_IFW_ROOT
if (-not $cpackIfwRoot) {
    if (Test-Path "C:\Qt\Tools\QtInstallerFramework") {
        $cpackIfwRoot = (Get-ChildItem "C:\Qt\Tools\QtInstallerFramework" -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
    }
}
if (-not $cpackIfwRoot) {
    throw "Qt Installer Framework path not found. Please set CPACK_IFW_ROOT environment variable."
}
$repogen = Join-Path $cpackIfwRoot "bin/repogen.exe"
if (-not (Test-Path $repogen)) {
    throw "repogen.exe not found at $repogen"
}

$ifwTempDir = Get-ChildItem (Join-Path $checkout "build/bundle/_CPack_Packages/win64/IFW") -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "packages") } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $ifwTempDir) {
    throw "IFW temporary packages directory not found."
}
$packagesDir = Join-Path $ifwTempDir.FullName "packages"

$repoOutDir = Join-Path $dist "repository"
if (Test-Path $repoOutDir) {
    Remove-Item $repoOutDir -Recurse -Force
}
Write-Host "Running repogen to build repository at $repoOutDir..."
& $repogen -p $packagesDir $repoOutDir
if ($LASTEXITCODE -ne 0) {
    throw "repogen failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path (Join-Path $repoOutDir "Updates.xml"))) {
    throw "repogen completed without creating Updates.xml."
}

# Zip repository
$repoZipOut = Join-Path $dist "repository.zip"
if (Test-Path $repoZipOut) {
    Remove-Item $repoZipOut -Force
}
Write-Host "Compressing repository to $repoZipOut..."
Compress-Archive -Path "$repoOutDir\*" -DestinationPath $repoZipOut -Force

$repoZipHash = Get-FileHash $repoZipOut -Algorithm SHA256

$commit = git -C $checkout rev-parse HEAD
$version = $PlaygroundTag.Substring(1)
$releaseUrl = "https://github.com/minu-park/basler-playground/releases/tag/$PlaygroundTag"
$installerUrl = "https://github.com/minu-park/basler-playground/releases/download/$PlaygroundTag/$installerName"
$repositoryZipUrl = "https://github.com/minu-park/basler-playground/releases/download/$PlaygroundTag/repository.zip"
$metadata = [ordered]@{
    version = $version
    tag = $PlaygroundTag
    channel = "stable"
    publishedAt = (Get-Date).ToUniversalTime().ToString("o")
    notesUrl = $releaseUrl
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
    repositoryZip = [ordered]@{
        fileName = "repository.zip"
        url = $repositoryZipUrl
        sha256 = $repoZipHash.Hash.ToLowerInvariant()
    }
    playgroundCommit = $commit
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
    $repoZipOut,
    $metadataOut
)
$releaseNotes = "Installer built from private Playground tag $PlaygroundTag ($commit)."

gh release view $PlaygroundTag *> $null
$releaseExists = $LASTEXITCODE -eq 0
if ($releaseExists) {
    gh release upload $PlaygroundTag @releaseAssets --clobber
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload release assets for $PlaygroundTag."
    }
    gh release edit $PlaygroundTag `
        --title "Basler Playground $PlaygroundTag" `
        --notes $releaseNotes
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update release metadata for $PlaygroundTag."
    }
} else {
    gh release create $PlaygroundTag @releaseAssets `
        --title "Basler Playground $PlaygroundTag" `
        --notes $releaseNotes `
        --draft
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create draft release for $PlaygroundTag."
    }
}
