param(
    [Parameter(Mandatory = $true)][string]$Config,
    [Parameter(Mandatory = $true)][string]$Output
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-CheckedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][string]$Label
    )
    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '-'
    $stdoutPath = Join-Path $Output "$safeLabel.stdout.log"
    $stderrPath = Join-Path $Output "$safeLabel.stderr.log"
    $quotedArguments = @($ArgumentList | ForEach-Object {
        if ($_ -match '\s') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    })
    $process = Start-Process -FilePath $FilePath -ArgumentList $quotedArguments -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) {
        $detailLines = @()
        $detailLines += Get-Content $stderrPath -Tail 20 -ErrorAction SilentlyContinue
        $detailLines += Get-Content $stdoutPath -Tail 20 -ErrorAction SilentlyContinue
        $details = $detailLines -join "`n"
        throw "$Label failed with exit code $($process.ExitCode). $details"
    }
}

function Get-InstalledComponents {
    param([string]$InstallRoot)
    $componentsPath = Join-Path $InstallRoot "components.xml"
    if (-not (Test-Path $componentsPath)) {
        throw "Installed components.xml is missing: $componentsPath"
    }
    $xml = [xml](Get-Content $componentsPath -Raw)
    $result = [ordered]@{}
    foreach ($component in @($xml.Packages.Package)) {
        $name = [string]$component.Name
        if ($name) {
            $result[$name] = [string]$component.Version
        }
    }
    return $result
}

function Assert-ApplicationSmoke {
    param([string]$InstallRoot)
    $application = @(
        (Join-Path $InstallRoot "Playground.exe"),
        (Join-Path $InstallRoot "bin\Playground.exe")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $application) {
        throw "Playground.exe was not found after installation."
    }
    $process = Start-Process -FilePath $application -WorkingDirectory (Split-Path $application -Parent) -PassThru
    Start-Sleep -Seconds 10
    if ($process.HasExited) {
        throw "Playground exited during the smoke-test window with code $($process.ExitCode)."
    }
    Stop-Process -Id $process.Id -Force
}

function Get-ExpectedComponents {
    param([string]$Repository)
    $updatesXml = [xml](Get-Content (Join-Path $Repository "Updates.xml") -Raw)
    $expected = [ordered]@{}
    foreach ($package in @($updatesXml.Updates.PackageUpdate)) {
        $name = [string]$package.Name
        if ($name -in @("MSVCBuildTools", "WindowsSDK", "DevelopmentPrerequisitesPayload")) {
            throw "Installer-only component entered the update repository: $name"
        }
        $expected[$name] = [string]$package.Version
    }
    return $expected
}

function Assert-ExpectedComponents {
    param([System.Collections.IDictionary]$Expected, [System.Collections.IDictionary]$Actual)
    foreach ($entry in $Expected.GetEnumerator()) {
        if (-not $Actual.Contains($entry.Key) -or $Actual[$entry.Key] -ne $entry.Value) {
            throw "Component version mismatch for $($entry.Key): expected $($entry.Value), found $($Actual[$entry.Key])."
        }
    }
    $unexpected = @($Actual.Keys | Where-Object { -not $Expected.Contains($_) })
    if ($unexpected.Count -gt 0) {
        throw "Unexpected installed components remain after update: $($unexpected -join ', ')."
    }
}

function Assert-NoUpdates {
    param([string]$MaintenanceTool, [string]$RepositoryUri)
    $checkOutput = & $MaintenanceTool "--lang" "en" "--set-temp-repository" $RepositoryUri "check-updates" 2>&1 | Out-String
    $checkOutput | Set-Content (Join-Path $Output "check-updates.log") -Encoding UTF8
    if ($LASTEXITCODE -ne 0) {
        throw "MaintenanceTool check-updates failed with exit code $LASTEXITCODE."
    }
    if ($checkOutput -notmatch "(?i)no updates available") {
        throw "MaintenanceTool did not report that the candidate repository is fully applied."
    }
}

New-Item -ItemType Directory -Force -Path $Output | Out-Null
$logPath = Join-Path $Output "validation.log"
Start-Transcript -Path $logPath -Force | Out-Null
$result = [ordered]@{ passed = $false; startedAt = (Get-Date).ToUniversalTime().ToString("o") }
$settings = $null

try {
    $settings = Get-Content $Config -Raw | ConvertFrom-Json
    $sandboxUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($sandboxUser -notmatch "WDAGUtilityAccount") {
        throw "This script refuses to modify a non-Sandbox machine. Current identity: $sandboxUser"
    }
    $installRoot = [string]$settings.installRoot
    $maintenanceTool = Join-Path $installRoot "MaintenanceTool.exe"
    $installOptions = @(
        "--verbose",
        "--root", $installRoot,
        "--accept-licenses",
        "--reject-messages",
        "--no-default-installations",
        "--confirm-command"
    )

    if ($settings.scenario -in @("ComponentUpdate", "ApplicationUpdate")) {
        Invoke-CheckedProcess $settings.baselineInstaller ($installOptions + @("install", "Playground")) "Baseline installation"
        $before = Get-InstalledComponents $installRoot
        $before | ConvertTo-Json | Set-Content (Join-Path $Output "components-before.json") -Encoding UTF8

        if (-not (Test-Path $maintenanceTool)) {
            throw "MaintenanceTool.exe was not installed."
        }
        $repositoryUri = [System.Uri]::new($settings.candidateRepository).AbsoluteUri
        $expected = Get-ExpectedComponents $settings.candidateRepository

        if ($settings.scenario -eq "ApplicationUpdate") {
            $installedApplication = Join-Path $installRoot "Playground.exe"
            Copy-Item -LiteralPath $settings.applicationUnderTest -Destination $installedApplication -Force
            $env:PLAYGROUND_UPDATE_TEST_METADATA_URL = [string]$settings.testMetadataUrl
            $env:PLAYGROUND_UPDATE_TEST_RESULT = [string]$settings.testResultPath
            $env:PLAYGROUND_UPDATE_TEST_AUTO_APPLY = "1"
            $applicationProcess = Start-Process -FilePath $installedApplication -WorkingDirectory $installRoot -PassThru
            $deadline = [DateTime]::UtcNow.AddMinutes(5)
            while (-not (Test-Path $settings.testResultPath) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Seconds 1
            }
            if (-not (Test-Path $settings.testResultPath)) {
                if (-not $applicationProcess.HasExited) {
                    Stop-Process -Id $applicationProcess.Id -Force
                }
                throw "Playground did not complete the application-driven update within five minutes."
            }
            $appUpdateExitCode = (Get-Content $settings.testResultPath -Raw).Trim()
            if ($appUpdateExitCode -ne "0") {
                throw "Application-driven MaintenanceTool update failed with exit code $appUpdateExitCode."
            }
            Remove-Item Env:\PLAYGROUND_UPDATE_TEST_METADATA_URL,Env:\PLAYGROUND_UPDATE_TEST_RESULT,Env:\PLAYGROUND_UPDATE_TEST_AUTO_APPLY -ErrorAction SilentlyContinue
        } else {
            $updateArgs = @(
                "--lang", "en",
                "--set-temp-repository", $repositoryUri,
                "--accept-licenses",
                "--default-answer",
                "--confirm-command",
                "update"
            )
            Invoke-CheckedProcess $maintenanceTool $updateArgs "Component update"
        }
        $after = Get-InstalledComponents $installRoot
        $after | ConvertTo-Json | Set-Content (Join-Path $Output "components-after.json") -Encoding UTF8
        Assert-ExpectedComponents $expected $after
        $installedApplication = Join-Path $installRoot "Playground.exe"
        $installedProductVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($installedApplication).ProductVersion
        $installedProductVersion | Set-Content (Join-Path $Output "application-version-after.txt") -Encoding UTF8
        $expectedApplicationVersion = [string]$expected["PlaygroundCore"]
        if (-not $expectedApplicationVersion -or $installedProductVersion -notmatch "^$([regex]::Escape($expectedApplicationVersion))(?:\.|$)") {
            throw "Installed application version mismatch: expected $expectedApplicationVersion, found $installedProductVersion."
        }

        Assert-ApplicationSmoke $installRoot
        Assert-NoUpdates $maintenanceTool $repositoryUri
    } elseif ($settings.scenario -eq "CleanInstall") {
        Invoke-CheckedProcess $settings.candidateInstaller ($installOptions + @("install", "PlaygroundCore")) "Candidate installation"
        $after = Get-InstalledComponents $installRoot
        $after | ConvertTo-Json | Set-Content (Join-Path $Output "components-after.json") -Encoding UTF8
        Assert-ApplicationSmoke $installRoot
    } else {
        throw "Unsupported scenario: $($settings.scenario)"
    }

    if (-not $settings.keepInstalled -and (Test-Path $maintenanceTool)) {
        Invoke-CheckedProcess $maintenanceTool @("--confirm-command", "purge") "Purge"
    }
    $result.passed = $true
}
catch {
    $result.error = $_.Exception.Message
    Write-Error $_
}
finally {
    $result.finishedAt = (Get-Date).ToUniversalTime().ToString("o")
    $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Output "result.json") -Encoding UTF8
    Stop-Transcript | Out-Null
    if ($settings -and $settings.autoClose) {
        Start-Process -FilePath "$env:WINDIR\System32\shutdown.exe" -ArgumentList @("/s", "/t", "0")
    }
}

if (-not $result.passed) {
    exit 1
}
