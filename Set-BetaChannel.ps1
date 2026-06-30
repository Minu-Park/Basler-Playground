param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseTag,

    [string]$ReleaseRepository = "Minu-Park/Basler-Playground"
)

$ErrorActionPreference = "Stop"

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage (exit code $LASTEXITCODE)."
    }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "Required command not found: gh"
}
if ($ReleaseTag -notmatch '^v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?:-beta\.([1-9][0-9]*))?$') {
    throw "ReleaseTag must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-beta.N."
}

$expectedVersion = $ReleaseTag.Substring(1)
$expectedChannel = if ($Matches[2]) { "beta" } else { "stable" }
$expectedIfwVersion = if ($Matches[2]) { "$($Matches[1]).$($Matches[2])" } else { "$($Matches[1]).999999" }
$sourceMetadataName = if ($expectedChannel -eq "beta") { "latest-beta.json" } else { "latest.json" }
$releaseJson = gh release view $ReleaseTag --repo $ReleaseRepository --json isDraft,isPrerelease,assets
if ($LASTEXITCODE -ne 0) {
    throw "Failed to inspect release $ReleaseTag."
}
$release = $releaseJson | ConvertFrom-Json
if ($release.isDraft) {
    throw "Release $ReleaseTag is still a draft. Publish it before changing the beta channel."
}
if ($expectedChannel -eq "beta" -and -not $release.isPrerelease) {
    throw "Beta release $ReleaseTag must be published as a GitHub prerelease."
}
$releaseAssetNames = @($release.assets | ForEach-Object { [string]$_.name })
if ($sourceMetadataName -notin $releaseAssetNames) {
    throw "Release $ReleaseTag does not contain $sourceMetadataName."
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("playground-beta-channel-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    Invoke-NativeCommand gh @(
        "release", "download", $ReleaseTag,
        "--repo", $ReleaseRepository,
        "--pattern", $sourceMetadataName,
        "--dir", $tempRoot
    ) "Failed to download metadata for $ReleaseTag"

    $sourceMetadata = Join-Path $tempRoot $sourceMetadataName
    $metadata = Get-Content $sourceMetadata -Raw | ConvertFrom-Json
    if ($metadata.version -ne $expectedVersion -or $metadata.tag -ne $ReleaseTag -or
        $metadata.channel -ne $expectedChannel -or $metadata.update.ifwVersion -ne $expectedIfwVersion) {
        throw "Release metadata identity does not match $ReleaseTag."
    }

    $channelAsset = Join-Path $tempRoot "latest-beta.json"
    if ($sourceMetadata -ne $channelAsset) {
        Copy-Item -LiteralPath $sourceMetadata -Destination $channelAsset
    }

    $channelExists = $false
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        gh release view beta-channel --repo $ReleaseRepository *> $null
        $channelExists = $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($channelExists) {
        Invoke-NativeCommand gh @(
            "release", "upload", "beta-channel",
            "--repo", $ReleaseRepository,
            $channelAsset,
            "--clobber"
        ) "Failed to update the beta-channel asset"
        Invoke-NativeCommand gh @(
            "release", "edit", "beta-channel",
            "--repo", $ReleaseRepository,
            "--prerelease",
            "--title", "Basler Playground beta channel",
            "--notes", "Mutable channel pointer. Current target: $ReleaseTag"
        ) "Failed to update the beta-channel release"
    } else {
        Invoke-NativeCommand gh @(
            "release", "create", "beta-channel",
            "--repo", $ReleaseRepository,
            "--prerelease",
            "--title", "Basler Playground beta channel",
            "--notes", "Mutable channel pointer. Current target: $ReleaseTag",
            $channelAsset
        ) "Failed to create the beta-channel release"
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "beta-channel now points to $ReleaseTag."
