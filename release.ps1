# Local Windows release helper for basler-playground.
# Requires: git, GitHub CLI (`gh auth login`), and access to the private Playground repository.

param(
    [Parameter(Mandatory = $true)]
    [string]$PlaygroundTag,

    [string]$PlaygroundRepo = "git@github.com:minu-park/playground.git",

    [int]$UpdateEpoch = 2,

    [switch]$ForceFullInstaller,

    [string]$RepositoryBranch = "ifw-repository",

    [string]$RepositoryPath = "windows/x64",

    [string]$RepositoryUrl = "https://raw.githubusercontent.com/Minu-Park/basler-playground/ifw-repository/windows/x64/"
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

function Get-ComponentContentHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedPath = (Resolve-Path $Path).Path
    $lines = Get-ChildItem $resolvedPath -Recurse -File |
        Sort-Object FullName |
        ForEach-Object {
            $relativePath = $_.FullName.Substring($resolvedPath.Length + 1).Replace('\', '/')
            if ($relativePath -ieq "meta/package.xml") {
                $packageXml = [xml](Get-Content $_.FullName -Raw)
                $releaseDateNode = $packageXml.SelectSingleNode("/Package/ReleaseDate")
                if ($releaseDateNode) {
                    [void]$releaseDateNode.ParentNode.RemoveChild($releaseDateNode)
                }
                $normalizedBytes = [System.Text.Encoding]::UTF8.GetBytes($packageXml.Package.OuterXml)
                $fileSha = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $fileHash = ([System.BitConverter]::ToString($fileSha.ComputeHash($normalizedBytes))).Replace("-", "").ToLowerInvariant()
                }
                finally {
                    $fileSha.Dispose()
                }
                "$relativePath`t$($normalizedBytes.Length)`t$fileHash"
            } else {
                $fileHash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                "$relativePath`t$($_.Length)`t$fileHash"
            }
        }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
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

Require-Command git
Require-Command gh

Invoke-NativeCommand gh @("auth", "status") "GitHub CLI authentication check failed" | Out-Null

if ($PlaygroundTag -notmatch '^v\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "PlaygroundTag must look like vX.Y.Z."
}
if ($UpdateEpoch -lt 1) {
    throw "UpdateEpoch must be a positive integer."
}
if ([System.IO.Path]::IsPathRooted($RepositoryPath) -or $RepositoryPath -split '[/\\]' -contains '..') {
    throw "RepositoryPath must be a relative path without parent traversal."
}
$repositoryUri = $null
if (-not [System.Uri]::TryCreate($RepositoryUrl, [System.UriKind]::Absolute, [ref]$repositoryUri) -or
    $repositoryUri.Scheme -ne [System.Uri]::UriSchemeHttps) {
    throw "RepositoryUrl must be an absolute HTTPS URL."
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

$repositoryWorktree = Join-Path ([System.IO.Path]::GetTempPath()) ("basler-playground-ifw-" + [guid]::NewGuid().ToString("N"))
$repositoryRoot = Join-Path $repositoryWorktree $RepositoryPath
$repositoryManifestPath = Join-Path $repositoryWorktree ".release/component-content.json"
try {
    & git -C $root ls-remote --exit-code --heads origin $RepositoryBranch 2>$null | Out-Null
    $repositoryBranchExists = $LASTEXITCODE -eq 0
    if ($repositoryBranchExists) {
        Invoke-NativeCommand git @("-C", $root, "fetch", "--force", "origin", "+refs/heads/$RepositoryBranch`:refs/remotes/origin/$RepositoryBranch") "Failed to fetch repository publishing branch"
        Invoke-NativeCommand git @("-C", $root, "worktree", "add", "--detach", $repositoryWorktree, "origin/$RepositoryBranch") "Failed to create repository publishing worktree"
    } else {
        Invoke-NativeCommand git @("-C", $root, "worktree", "add", "--detach", $repositoryWorktree) "Failed to create repository publishing worktree"
        Invoke-NativeCommand git @("-C", $repositoryWorktree, "checkout", "--orphan", $RepositoryBranch) "Failed to create repository branch"
        $safeTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $safeWorktree = [System.IO.Path]::GetFullPath($repositoryWorktree)
        if (-not $safeWorktree.StartsWith($safeTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clear repository worktree outside the temporary directory: $safeWorktree"
        }
        Get-ChildItem $repositoryWorktree -Force | Where-Object { $_.Name -ne ".git" } | Remove-Item -Recurse -Force
    }

    $previousContent = @{}
    $previousHashFormat = 1
    if (Test-Path $repositoryManifestPath) {
        $previousJson = Get-Content $repositoryManifestPath -Raw | ConvertFrom-Json
        if ($previousJson.hashFormat) {
            $previousHashFormat = [int]$previousJson.hashFormat
        }
        foreach ($property in $previousJson.components.psobject.Properties) {
            $previousContent[$property.Name] = $property.Value
        }
    }

    $currentContent = [ordered]@{}
    $filteredPackages = Join-Path $repositoryWorktree ".packages"
    New-Item -ItemType Directory -Force -Path $filteredPackages | Out-Null
    foreach ($component in $updateComponents) {
        $packageDir = Join-Path $packagesDir $component
        $packageXmlPath = Join-Path $packageDir "meta/package.xml"
        $packageDataPath = Join-Path $packageDir "data"
        if (-not (Test-Path $packageXmlPath) -or -not (Test-Path $packageDataPath)) {
            throw "Update component package is incomplete: $component"
        }
        $packageXml = [xml](Get-Content $packageXmlPath -Raw)
        $componentVersion = [string]$packageXml.Package.Version
        $contentHash = Get-ComponentContentHash $packageDir
        if ($previousHashFormat -eq 2 -and $previousContent.ContainsKey($component)) {
            $previous = $previousContent[$component]
            if ([string]$previous.version -eq $componentVersion -and [string]$previous.sha256 -ne $contentHash) {
                throw "Component '$component' content changed without a version bump ($componentVersion)."
            }
        }
        $currentContent[$component] = [ordered]@{ version = $componentVersion; sha256 = $contentHash }
        New-HardLinkedDirectory $packageDir (Join-Path $filteredPackages $component)
    }

    New-Item -ItemType Directory -Force -Path $repositoryRoot | Out-Null
    if ($repositoryBranchExists -and (Test-Path (Join-Path $repositoryRoot "Updates.xml"))) {
        Invoke-NativeCommand $repogen @("--update-new-components", "-p", $filteredPackages, $repositoryRoot) "Incremental repogen failed"
    } else {
        Invoke-NativeCommand $repogen @("-p", $filteredPackages, $repositoryRoot) "repogen failed"
    }
    Remove-Item $filteredPackages -Recurse -Force

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

    New-Item -ItemType Directory -Force -Path (Split-Path $repositoryManifestPath -Parent) | Out-Null
    [System.IO.File]::WriteAllText(
        $repositoryManifestPath,
        ([ordered]@{ hashFormat = 2; epoch = $UpdateEpoch; components = $currentContent } | ConvertTo-Json -Depth 6),
        $utf8NoBom
    )
    Invoke-NativeCommand git @("-C", $repositoryWorktree, "add", "--all") "Failed to stage repository update"
    & git -C $repositoryWorktree diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        Invoke-NativeCommand git @("-C", $repositoryWorktree, "commit", "-m", "release: publish IFW repository for $PlaygroundTag") "Failed to commit repository update"
        Invoke-NativeCommand git @("-C", $repositoryWorktree, "push", "origin", "HEAD:refs/heads/$RepositoryBranch") "Failed to publish repository branch"
    }
}
finally {
    if (Test-Path $repositoryWorktree) {
        & git -C $root worktree remove --force $repositoryWorktree 2>$null
    }
}

$commit = (Invoke-NativeCommand git @("-C", $checkout, "rev-parse", "HEAD") "Failed to resolve the Playground commit" | Select-Object -Last 1).Trim()
$version = $PlaygroundTag.Substring(1)
$isPrerelease = $PlaygroundTag.Contains("-")
$channel = if ($isPrerelease) { "prerelease" } else { "stable" }
$releaseUrl = "https://github.com/minu-park/basler-playground/releases/tag/$PlaygroundTag"
$installerUrl = "https://github.com/minu-park/basler-playground/releases/download/$PlaygroundTag/$installerName"
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
    update = [ordered]@{
        epoch = $UpdateEpoch
        forceFullInstaller = [bool]$ForceFullInstaller
    }
    playgroundCommit = $commit
}
if (-not $ForceFullInstaller) {
    $metadata.repository = [ordered]@{
        url = $RepositoryUrl
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
