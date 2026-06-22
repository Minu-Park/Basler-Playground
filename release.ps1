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

Require-Command git
Require-Command gh

Invoke-NativeCommand gh @("auth", "status") "GitHub CLI authentication check failed" | Out-Null

if ($PlaygroundTag -notmatch '^v\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "PlaygroundTag must look like vX.Y.Z."
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

$repoOutDir = Join-Path $dist "repository"
if (Test-Path $repoOutDir) {
    Remove-Item $repoOutDir -Recurse -Force
}
Write-Host "Generating IFW update repository at $repoOutDir..."
Invoke-NativeCommand $repogen @("-p", $packagesDir, $repoOutDir) "repogen failed"
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

$commit = (Invoke-NativeCommand git @("-C", $checkout, "rev-parse", "HEAD") "Failed to resolve the Playground commit" | Select-Object -Last 1).Trim()
$version = $PlaygroundTag.Substring(1)
$isPrerelease = $PlaygroundTag.Contains("-")
$channel = if ($isPrerelease) { "prerelease" } else { "stable" }
$releaseUrl = "https://github.com/minu-park/basler-playground/releases/tag/$PlaygroundTag"
$installerUrl = "https://github.com/minu-park/basler-playground/releases/download/$PlaygroundTag/$installerName"
$repositoryZipUrl = "https://github.com/minu-park/basler-playground/releases/download/$PlaygroundTag/repository.zip"
$metadata = [ordered]@{
    version = $version
    tag = $PlaygroundTag
    channel = $channel
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
        "--notes", $releaseNotes
    ) + $releaseTypeArguments) "Failed to update release metadata for $PlaygroundTag"
} else {
    Invoke-NativeCommand gh (@("release", "create", $PlaygroundTag) + $releaseAssets + @(
        "--title", "Basler Playground $PlaygroundTag",
        "--notes", $releaseNotes
    ) + $releaseTypeArguments + @("--draft")) "Failed to create draft release for $PlaygroundTag"
}
