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
"$($hash.Hash.ToLowerInvariant())  $installerName" |
    Set-Content -NoNewline -Encoding utf8 "$installerOut.sha256"

$commit = git -C $checkout rev-parse HEAD
$metadata = [ordered]@{
    version = $PlaygroundTag
    playgroundTag = $PlaygroundTag
    playgroundCommit = $commit
    channel = "stable"
    publishedAt = (Get-Date).ToUniversalTime().ToString("o")
    installer = [ordered]@{
        platform = "windows-x64"
        fileName = $installerName
        url = "https://github.com/minu-park/basler-playground/releases/download/$PlaygroundTag/$installerName"
        sha256 = $hash.Hash.ToLowerInvariant()
    }
    releaseUrl = "https://github.com/minu-park/basler-playground/releases/tag/$PlaygroundTag"
}

$metadata | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $dist "latest.json")

gh release create $PlaygroundTag `
    $installerOut `
    "$installerOut.sha256" `
    (Join-Path $dist "latest.json") `
    --title "Basler Playground $PlaygroundTag" `
    --notes "Installer built from private Playground tag $PlaygroundTag ($commit)." `
    --draft
