param(
    [string]$PlaygroundRoot = "C:\Users\minwoo\Documents\Playground",
    [string]$CandidateVersion,
    [string]$ReleaseRepository = "Minu-Park/basler-playground",
    [switch]$CloseExistingSandbox
)

$ErrorActionPreference = "Stop"
$PlaygroundRoot = (Resolve-Path $PlaygroundRoot).Path
$buildRoot = Join-Path $PlaygroundRoot "build"
$cmakeCache = Join-Path $buildRoot "CMakeCache.txt"
if (-not (Test-Path $cmakeCache)) {
    throw "Configure the Playground build directory once before running updater validation: $buildRoot"
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "gh is required to resolve the stable baseline version."
}

$release = gh release view --repo $ReleaseRepository --json tagName | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $release.tagName -notmatch '^v?(\d+)\.(\d+)\.(\d+)$') {
    throw "The latest stable release tag is not a numeric version: $($release.tagName)"
}
$baselineVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
if (-not $CandidateVersion) {
    $CandidateVersion = "$($Matches[1]).$($Matches[2]).$([int]$Matches[3] + 1)"
}
if ($CandidateVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "CandidateVersion must be MAJOR.MINOR.PATCH."
}
if ([version]$CandidateVersion -le [version]$baselineVersion) {
    throw "CandidateVersion must be newer than the stable baseline $baselineVersion."
}

function Invoke-Configure {
    param([string]$Version, [bool]$EnableHooks)
    $hookValue = if ($EnableHooks) { "ON" } else { "OFF" }
    & cmake -S $PlaygroundRoot -B $buildRoot `
        "-DPLAYGROUND_ENABLE_UPDATE_TEST_HOOKS:BOOL=$hookValue" `
        "-DPLAYGROUND_VERSION_OVERRIDE:STRING=$Version"
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed for version $Version." }
}

function Invoke-Build {
    & cmake --build $buildRoot --config Release --target Playground --parallel 8
    if ($LASTEXITCODE -ne 0) { throw "Playground Release build failed." }
}

try {
    Write-Host "Building application-path probe as $baselineVersion..."
    Invoke-Configure $baselineVersion $true
    Invoke-Build
    $probeRoot = Join-Path $buildRoot "installer-validation/app-probe-$baselineVersion"
    New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
    $applicationUnderTest = Join-Path $probeRoot "Playground.exe"
    Copy-Item (Join-Path $buildRoot "bundle/Release/Playground.exe") $applicationUnderTest -Force

    Write-Host "Building candidate repository as $CandidateVersion..."
    Invoke-Configure $CandidateVersion $false
    Invoke-Build
    & cpack --config (Join-Path $buildRoot "CPackConfig.cmake") -C Release
    if ($LASTEXITCODE -ne 0) { throw "CPack failed for version $CandidateVersion." }

    $packageRoot = Join-Path $buildRoot "bundle/_CPack_Packages/win64/IFW/Basler Playground-$CandidateVersion-win64-release/packages"
    if (-not (Test-Path $packageRoot)) {
        throw "CPack package tree is missing: $packageRoot"
    }
    $componentList = Join-Path $buildRoot "ifw-update-components.txt"
    if (-not (Test-Path $componentList)) {
        throw "Generated update component list is missing: $componentList"
    }

    $filteredPackages = Join-Path $buildRoot "installer-validation/repogen-packages-$CandidateVersion"
    $repository = Join-Path $buildRoot "installer-validation/repository-$CandidateVersion"
    Remove-Item -LiteralPath $filteredPackages,$repository -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $filteredPackages,$repository | Out-Null
    foreach ($component in (Get-Content $componentList | Where-Object { $_.Trim() })) {
        $sourceComponent = Join-Path $packageRoot $component
        if (-not (Test-Path $sourceComponent)) {
            throw "Generated component package is missing: $component"
        }
        $targetComponent = Join-Path $filteredPackages $component
        Get-ChildItem -LiteralPath $sourceComponent -Recurse -File | ForEach-Object {
            $relative = $_.FullName.Substring($sourceComponent.Length).TrimStart('\')
            $target = Join-Path $targetComponent $relative
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            New-Item -ItemType HardLink -Path $target -Target $_.FullName | Out-Null
        }
    }

    $repogen = Get-ChildItem "C:\Qt\Tools" -Recurse -Filter repogen.exe -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $repogen) { throw "Qt Installer Framework repogen.exe was not found under C:\Qt\Tools." }
    & $repogen.FullName -p $filteredPackages $repository
    if ($LASTEXITCODE -ne 0) { throw "repogen failed for version $CandidateVersion." }

    $validationArgs = @{
        Scenario = "ApplicationUpdate"
        ApplicationUnderTest = $applicationUnderTest
        CandidateRepository = $repository
        ReleaseRepository = $ReleaseRepository
    }
    if ($CloseExistingSandbox) { $validationArgs.CloseExistingSandbox = $true }
    & (Join-Path $PSScriptRoot "Invoke-Validation.ps1") @validationArgs
    if ($LASTEXITCODE -ne 0) { throw "Application updater validation failed." }
}
finally {
    Write-Host "Restoring production updater build options..."
    & cmake -S $PlaygroundRoot -B $buildRoot `
        "-DPLAYGROUND_ENABLE_UPDATE_TEST_HOOKS:BOOL=OFF" `
        "-DPLAYGROUND_VERSION_OVERRIDE:STRING="
    if ($LASTEXITCODE -ne 0) { throw "Failed to restore production CMake options." }
    Invoke-Build
}
