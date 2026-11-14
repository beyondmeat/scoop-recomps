#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Tests installation of a Scoop manifest.

.DESCRIPTION
    Validates JSON syntax, installs the app using Scoop, verifies installation,
    and performs cleanup.

.PARAMETER ManifestPath
    Path to the manifest JSON file.

.PARAMETER AppName
    Optional name override. Defaults to filename.

.PARAMETER AutoRetry
    Check asset URLs and attempt to repair unavailable manifests before installing.

.PARAMETER RunShortcut
    Run the installed app's first Start Menu shortcut and stop it after RunSeconds.

.PARAMETER RunSeconds
    Number of seconds to let the app run when RunShortcut is enabled.

.PARAMETER SkipSetupShortcut
    Do not run shortcuts whose target filename indicates an installer or setup app.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ManifestPath,

    [string]$AppName,

    [bool]$AutoRetry = $true,

    [switch]$RunShortcut,

    [ValidateRange(1, 60)]
    [int]$RunSeconds = 5,

    [switch]$SkipSetupShortcut
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib-releasehelpers.ps1"

# Ensure TLS 1.2 is enabled (critical for PS 5.1)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

if (-not (Get-Command 'scoop' -ErrorAction SilentlyContinue)) {
    Write-Error "Scoop is not installed or not in PATH."
    exit 1
}

$scoopCommand = Get-Command 'scoop'
if (-not [string]::IsNullOrWhiteSpace($env:SCOOP)) {
    $scoopRoot = $env:SCOOP
} elseif ($scoopCommand.Source -and
    (Split-Path -Leaf (Split-Path -Parent $scoopCommand.Source)) -eq 'shims') {
    $scoopRoot = Split-Path -Parent (Split-Path -Parent $scoopCommand.Source)
} else {
    Write-Error 'Unable to determine the local Scoop root.'
    exit 1
}
$localAppsDirectory = Join-Path $scoopRoot 'apps'
$testExitCode = 0

function Uninstall-TestApp {
    param([string]$Name)

    $localAppPath = Join-Path $localAppsDirectory $Name
    if (-not (Test-Path -LiteralPath $localAppPath)) { return }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds 3 }

        $uninstallOutput = @(scoop uninstall $Name 2>&1)
        $uninstallExitCode = $LASTEXITCODE
        if (-not (Test-Path -LiteralPath $localAppPath)) {
            Write-Host "Removed test install '$Name'." -ForegroundColor Green
            return
        }

        if ($attempt -eq 3) {
            $uninstallOutput | ForEach-Object { Write-Host $_ }
            throw "Unable to uninstall test app '$Name' after $attempt attempts (exit code $uninstallExitCode)."
        }

        Write-Host "App '$Name' is still installed after cleanup attempt $attempt; retrying." -ForegroundColor Yellow
    }
}

try {
    $ManifestPath = Convert-Path $ManifestPath
    if ([string]::IsNullOrWhiteSpace($AppName)) {
        $AppName = [System.IO.Path]::GetFileNameWithoutExtension($ManifestPath)
    }

    # Validate JSON syntax
    try {
        $json = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        if (-not $json.version) { throw "Missing 'version' field" }
    } catch {
        throw "Invalid JSON or schema: $($_.Exception.Message)"
    }

    # Auto-retry behavior: if the manifest's asset URL returns 404, attempt
    # an update (via update-manifest.ps1) and retry once. If still failing,
    # run autofix-manifest.ps1 as a last-resort attempt.
    function Test-UrlExists {
        param([string]$Url)
        try {
            Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop | Out-Null
            return $true
        } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
                return $false
            }

            throw
        }
    }

    function Resolve-ManifestAssetUrl {
        param(
            [string]$Template,
            [string]$Version,
            [string]$ConcreteUrl
        )

        if ($Template -match '\$match') {
            return $ConcreteUrl
        }

        return $Template.Replace('$version', $Version)
    }

    function Get-ManifestAssetUrls {
        param([object]$Manifest)

        $urls = @()
        $architectureNames = @()
        if ($Manifest.architecture) {
            $architectureNames += @($Manifest.architecture.PSObject.Properties.Name)
        }
        if ($Manifest.autoupdate -and $Manifest.autoupdate.architecture) {
            $architectureNames += @($Manifest.autoupdate.architecture.PSObject.Properties.Name)
        }
        foreach ($architecture in @('64bit', '32bit', 'arm64')) {
            if ($Manifest.autoupdate -and $Manifest.autoupdate.$architecture -and
                $architectureNames -notcontains $architecture) {
                $architectureNames += $architecture
            }
        }
        $architectureNames = @($architectureNames | Select-Object -Unique)

        if ($Manifest.autoupdate -and $Manifest.autoupdate.url) {
            $url = Resolve-ManifestAssetUrl -Template $Manifest.autoupdate.url `
                -Version ([string]$Manifest.version) -ConcreteUrl $Manifest.url
            if ($url) { $urls += $url }
        } elseif ($Manifest.url) {
            $urls += $Manifest.url
        }

        foreach ($architecture in $architectureNames) {
            $templates = @()
            $concreteUrl = $null
            if ($Manifest.architecture) {
                $concreteUrl = $Manifest.architecture.$architecture.url
            }
            if ($Manifest.autoupdate -and $Manifest.autoupdate.architecture) {
                $url = $Manifest.autoupdate.architecture.$architecture.url
                if ($url) { $templates += $url }
            }
            if ($Manifest.autoupdate -and $Manifest.autoupdate.$architecture.url) {
                $templates += $Manifest.autoupdate.$architecture.url
            }

            if ($templates.Count -gt 0) {
                foreach ($template in $templates) {
                    $url = Resolve-ManifestAssetUrl -Template $template `
                        -Version ([string]$Manifest.version) `
                        -ConcreteUrl $concreteUrl
                    if ($url -and $urls -notcontains $url) { $urls += $url }
                }
            } else {
                if ($concreteUrl -and $urls -notcontains $concreteUrl) { $urls += $concreteUrl }
            }
        }

        return $urls
    }

    function Test-ManifestAssetAvailability {
        param(
            [string]$ManifestPath,
            [int]$Retries = 1
        )

        for ($attempt = 0; $attempt -le $Retries; $attempt++) {
            $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
            $urls = @(Get-ManifestAssetUrls -Manifest $manifest)

            if ($urls.Count -eq 0) { return $true }

            $allGood = $true
            foreach ($u in $urls) {
                if (-not (Test-UrlExists $u)) {
                    $allGood = $false
                    break
                }
            }

            if ($allGood) { return $true }

            if ($attempt -lt $Retries) {
                Write-Host "One or more assets returned 404, attempting to update manifest (attempt $($attempt + 1) of $Retries)..." -ForegroundColor Yellow
                $updateResult = Invoke-PowerShellScript -Path (Join-Path $PSScriptRoot 'update-manifest.ps1') `
                    -ArgumentList @('-ManifestPath', $ManifestPath, '-Update')
                if ($updateResult.ExitCode -ne 0) {
                    throw "Manifest update failed with exit code $($updateResult.ExitCode). $($updateResult.Output)"
                }
                if ($updateResult.Output) { Write-Host $updateResult.Output }
                Start-Sleep -Seconds 1
                continue
            } else {
                Write-Host "Asset missing after updates; running autofix and rechecking..." -ForegroundColor Yellow
                $autofixResult = Invoke-PowerShellScript -Path (Join-Path $PSScriptRoot 'autofix-manifest.ps1') `
                    -ArgumentList @('-ManifestPath', $ManifestPath)
                if ($autofixResult.ExitCode -ne 0) {
                    throw "Manifest autofix failed with exit code $($autofixResult.ExitCode). $($autofixResult.Output)"
                }
                if ($autofixResult.Output) { Write-Host $autofixResult.Output }
                Start-Sleep -Seconds 1

                $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
                $urls = @(Get-ManifestAssetUrls -Manifest $manifest)

                foreach ($u in $urls) {
                    if (-not (Test-UrlExists $u)) { return $false }
                }

                return $true
            }
        }
    }

    function Invoke-InstalledShortcut {
        param(
            [object]$Manifest,
            [string]$InstallPath,
            [string]$PackageName
        )

        $shortcutDefinitions = $Manifest.shortcuts
        if (-not $shortcutDefinitions -and $Manifest.architecture.'64bit'.shortcuts) {
            $shortcutDefinitions = $Manifest.architecture.'64bit'.shortcuts
        }
        if (-not $shortcutDefinitions -or $shortcutDefinitions.Count -eq 0) {
            throw "No Start Menu shortcut is declared for '$PackageName'."
        }

        $shortcutDefinition = $shortcutDefinitions[0]
        $targetRelativePath = [string]$shortcutDefinition[0]
        $shortcutName = [string]$shortcutDefinition[1]
        $targetPath = Join-Path $InstallPath $targetRelativePath
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            throw "Shortcut target '$targetRelativePath' is missing from '$InstallPath'."
        }

        $shortcutRoots = @(
            (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\Scoop Apps'),
            (Join-Path ([Environment]::GetFolderPath('CommonStartMenu')) 'Programs\Scoop Apps')
        )
        $shortcutPath = $null
        foreach ($root in $shortcutRoots) {
            $candidate = Join-Path $root ($shortcutName + '.lnk')
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $shortcutPath = $candidate
                break
            }
        }
        if (-not $shortcutPath) {
            throw "Start Menu shortcut '$shortcutName' was not created."
        }

        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $resolvedTarget = [Environment]::ExpandEnvironmentVariables($shortcut.TargetPath)
        if (-not (Test-Path -LiteralPath $resolvedTarget -PathType Leaf)) {
            throw "Shortcut '$shortcutName' points to missing target '$resolvedTarget'."
        }
        Write-Host "Shortcut target verified: $resolvedTarget" -ForegroundColor Cyan

        if ($SkipSetupShortcut -and
            [System.IO.Path]::GetFileName($resolvedTarget) -match '(?i)(setup|installer|install).*\.(exe|cmd|bat)$') {
            Write-Host "Skipping setup shortcut as requested: $shortcutName" -ForegroundColor Yellow
            return
        }

        $watchRoots = @(
            $InstallPath,
            (Join-Path $env:LOCALAPPDATA ''),
            (Join-Path $env:APPDATA ''),
            (Join-Path $env:USERPROFILE 'Documents'),
            (Join-Path $env:USERPROFILE 'Saved Games')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique
        $watchers = @()
        $sourceIdentifiers = @()
        $testId = [guid]::NewGuid().ToString('N')

        try {
            foreach ($watchRoot in $watchRoots) {
                $watcher = New-Object System.IO.FileSystemWatcher
                $watcher.Path = $watchRoot
                $watcher.Filter = '*'
                $watcher.IncludeSubdirectories = $true
                $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor
                    [System.IO.NotifyFilters]::DirectoryName -bor
                    [System.IO.NotifyFilters]::LastWrite -bor
                    [System.IO.NotifyFilters]::CreationTime
                $watcher.InternalBufferSize = 65536

                foreach ($eventName in @('Created', 'Changed', 'Renamed')) {
                    $sourceIdentifier = "ManifestInstall-$testId-$eventName-$($watchers.Count)"
                    Register-ObjectEvent -InputObject $watcher -EventName $eventName `
                        -SourceIdentifier $sourceIdentifier | Out-Null
                    $sourceIdentifiers += $sourceIdentifier
                }

                $watcher.EnableRaisingEvents = $true
                $watchers += $watcher
            }

            Write-Host "Launching shortcut: $shortcutName" -ForegroundColor Cyan
            $baselineProcessIds = @(Get-CimInstance -ClassName Win32_Process |
                Select-Object -ExpandProperty ProcessId)
            $launchTime = Get-Date
            $launchedProcess = Start-Process -FilePath $shortcutPath -PassThru
            Write-Host "Started process $($launchedProcess.Id); observing for $RunSeconds seconds."
            Start-Sleep -Seconds $RunSeconds
            $shortcutExitCode = $null
            if ($launchedProcess.HasExited) {
                $shortcutExitCode = $launchedProcess.ExitCode
                Write-Host "Shortcut process exited during observation (code $shortcutExitCode)." -ForegroundColor Yellow
            }

            $processes = @(Get-CimInstance -ClassName Win32_Process)
            $processIds = @($launchedProcess.Id)
            $appInstallRoot = (Split-Path -Parent $InstallPath).TrimEnd('\') + '\'
            $targetProcessIds = @(
                $processes | Where-Object {
                    $isNewProcess = $baselineProcessIds -notcontains $_.ProcessId
                    $executableMatches = $_.ExecutablePath -and
                        $_.ExecutablePath.StartsWith($appInstallRoot, [System.StringComparison]::OrdinalIgnoreCase)
                    $commandLineMatches = $_.CommandLine -and
                        $_.CommandLine.IndexOf($resolvedTarget, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                    $isNewProcess -and ($executableMatches -or $commandLineMatches)
                } | Select-Object -ExpandProperty ProcessId
            )
            $processIds += $targetProcessIds
            $processIds = @($processIds | Select-Object -Unique)
            $pendingIds = @($processIds)
            while ($pendingIds.Count -gt 0) {
                $parentId = $pendingIds[0]
                $pendingIds = @($pendingIds | Select-Object -Skip 1)
                $childIds = @($processes | Where-Object { $_.ParentProcessId -eq $parentId } |
                    Select-Object -ExpandProperty ProcessId)
                foreach ($childId in $childIds) {
                    if ($processIds -notcontains $childId) {
                        $processIds += $childId
                        $pendingIds += $childId
                    }
                }
            }

            $gracefulCloseRequested = $false
            foreach ($processId in $processIds) {
                $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($process -and $process.MainWindowHandle -ne 0) {
                    $process.CloseMainWindow() | Out-Null
                    $gracefulCloseRequested = $true
                }
            }
            if ($gracefulCloseRequested) { Start-Sleep -Seconds 2 }

            for ($i = $processIds.Count - 1; $i -ge 0; $i--) {
                $processId = $processIds[$i]
                if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
                    Stop-Process -Id $processId -Force -ErrorAction Stop
                    Write-Host "Stopped test process $processId."
                }
            }

            $stopDeadline = (Get-Date).AddSeconds(5)
            $pendingStopIds = @()
            do {
                $pendingStopIds = @($processIds | Where-Object {
                    Get-Process -Id $_ -ErrorAction SilentlyContinue
                })
                if ($pendingStopIds.Count -eq 0) { break }
                Start-Sleep -Milliseconds 250
            } while ((Get-Date) -lt $stopDeadline)

            if ($pendingStopIds.Count -gt 0) {
                throw "Test processes did not exit after being stopped: $($pendingStopIds -join ', ')."
            }

            Start-Sleep -Seconds 3
            $observedChanges = @(
                Get-Event | Where-Object { $sourceIdentifiers -contains $_.SourceIdentifier } |
                    ForEach-Object {
                        [pscustomobject]@{
                            Change = $_.SourceEventArgs.ChangeType
                            Path   = $_.SourceEventArgs.FullPath
                        }
                    } | Sort-Object Path -Unique
            )

            if ($observedChanges.Count -eq 0) {
                Write-Host 'No file system changes observed during launch.'
            } else {
                $persistPaths = @($Manifest.persist | ForEach-Object {
                    if ($_ -is [array]) { [string]$_[0] }
                    else { [string]$_ }
                } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    ForEach-Object { $_.Replace('/', '\').TrimEnd([char]'\') })

                foreach ($change in $observedChanges | Select-Object -First 100) {
                    if ($change.Path.StartsWith($InstallPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $relativePath = $change.Path.Substring($InstallPath.TrimEnd('\').Length).TrimStart('\')
                        $relativePath = $relativePath.Replace('/', '\')
                        $isPersisted = @($persistPaths | Where-Object {
                            $relativePath.Equals($_, [System.StringComparison]::OrdinalIgnoreCase) -or
                                $relativePath.StartsWith($_ + '\', [System.StringComparison]::OrdinalIgnoreCase)
                        }).Count -gt 0
                        $isPersistParent = @($persistPaths | Where-Object {
                            $_.StartsWith($relativePath.TrimEnd([char]'\') + '\', [System.StringComparison]::OrdinalIgnoreCase)
                        }).Count -gt 0
                        if (-not $isPersisted) {
                            if ($isPersistParent) {
                                Write-Host "Runtime directory is parent of persisted paths ($($change.Change)): $relativePath"
                            } else {
                                Write-Host "Potential persist candidate ($($change.Change)): $relativePath" -ForegroundColor Yellow
                            }
                        } else {
                            Write-Host "Runtime change already covered by persist ($($change.Change)): $relativePath"
                        }
                    } else {
                        Write-Host "Runtime file change outside app directory ($($change.Change)): $($change.Path)" -ForegroundColor Yellow
                    }
                }
                if ($observedChanges.Count -gt 100) {
                    Write-Host "Omitted $($observedChanges.Count - 100) additional file system changes."
                }
            }

            if ($null -ne $shortcutExitCode -and $shortcutExitCode -ne 0) {
                throw "Shortcut process exited during observation with code $shortcutExitCode."
            }

            $crashDumpRoot = (Join-Path $env:LOCALAPPDATA 'CrashDumps').TrimEnd('\') + '\'
            $crashDumps = @()
            foreach ($change in $observedChanges) {
                if (-not $change.Path.StartsWith($crashDumpRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
                foreach ($processId in $processIds) {
                    if ($change.Path.EndsWith(".$processId.dmp", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $crashDumps += $change.Path
                        break
                    }
                }
            }
            if ($crashDumps.Count -gt 0) {
                throw "Shortcut process created a crash dump during observation: $($crashDumps -join ', ')."
            }
        } finally {
            foreach ($sourceIdentifier in $sourceIdentifiers) {
                Unregister-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
                Get-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
            }
            foreach ($watcher in $watchers) {
                $watcher.EnableRaisingEvents = $false
                $watcher.Dispose()
            }
        }
    }

    if ($AutoRetry) {
        # Default to one retry; this keeps the behavior limited while handling
        # transient 404s caused by rotated nightly assets.
        if (-not (Test-ManifestAssetAvailability -ManifestPath $ManifestPath -Retries 1)) {
            throw "Asset URLs are unreachable even after update/autofix. Aborting."
        }
    }

    # Clean previous state
    if (Test-Path -LiteralPath (Join-Path $localAppsDirectory $AppName)) {
        Write-Host "Cleaning up previous installation..." -ForegroundColor Yellow
        Uninstall-TestApp -Name $AppName
    }

    Write-Host "Installing $AppName..." -ForegroundColor Cyan

    # Install
    scoop install "$ManifestPath"
    if ($LASTEXITCODE -ne 0) {
        throw "Installation failed with exit code $LASTEXITCODE"
    }

    # Verify
    $localAppPath = Join-Path $localAppsDirectory $AppName
    if (-not (Test-Path -LiteralPath $localAppPath)) {
        throw "Installation reported success but local app '$AppName' was not found."
    }

    $installPath = Convert-Path (scoop prefix $AppName)

    if ($json.persist) {
        $appDirectory = Split-Path -Parent $installPath
        $appsDirectory = Split-Path -Parent $appDirectory
        $scoopRoot = Split-Path -Parent $appsDirectory
        $persistDirectory = Join-Path (Join-Path $scoopRoot 'persist') $AppName
        $persistEntries = @($json.persist)

        foreach ($entry in $persistEntries) {
            $source = [string]$entry
            $target = $source
            if ($entry -is [array]) {
                $source = [string]$entry[0]
                if ($entry.Count -gt 1) { $target = [string]$entry[1] }
            }

            $installedPath = Join-Path $installPath $source
            $storedPath = Join-Path $persistDirectory $target
            if (-not (Test-Path -LiteralPath $installedPath) -or -not (Test-Path -LiteralPath $storedPath)) {
                throw "Persist entry '$source' was not created in both the app directory and persist store."
            }

            $persistedItem = Get-Item -LiteralPath $storedPath
            $itemType = if ($persistedItem.PSIsContainer) { 'folder' } else { 'file' }
            Write-Host "Persist verified ($itemType): $source" -ForegroundColor Green
        }
    } else {
        Write-Host "No persist entries declared."
    }

    if ($RunShortcut) {
        Invoke-InstalledShortcut -Manifest $json -InstallPath $installPath -PackageName $AppName
    }

    Write-Host "Installation successful!" -ForegroundColor Green

} catch {
    Write-Error $_.Exception.Message
    $testExitCode = 1
} finally {
    # Cleanup
    if (Get-Command 'scoop' -ErrorAction SilentlyContinue) {
        if (Test-Path -LiteralPath (Join-Path $localAppsDirectory $AppName)) {
            Write-Host "Uninstalling cleanup..." -ForegroundColor Gray
            Uninstall-TestApp -Name $AppName
        }
    }
}

exit $testExitCode
