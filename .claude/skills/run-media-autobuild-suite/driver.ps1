#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Driver for media-autobuild_suite: launches the build and monitors it programmatically.

.DESCRIPTION
    Starts media-autobuild_suite.bat in the background, monitors build progress via compile.log,
    and can report status or stop the build cleanly.

.PARAMETER Action
    'launch' - start the build and return
    'monitor' - tail the compile log until completion or timeout
    'status' - report current build state and errors
    'stop' - stop all build processes

.PARAMETER Timeout
    For 'monitor': max seconds to watch. Default 3600 (1 hour).

.EXAMPLE
    .\driver.ps1 -Action launch
    .\driver.ps1 -Action monitor -Timeout 1800
    .\driver.ps1 -Action status
    .\driver.ps1 -Action stop
#>

param(
    [ValidateSet('launch', 'monitor', 'status', 'stop')]
    [string]$Action = 'launch',

    [int]$Timeout = 3600
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommandPath
$ProjectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptRoot))
$BuildDir = Join-Path $ProjectRoot "build"
$CompileLog = Join-Path $BuildDir "compile.log"
$StateFile = Join-Path $BuildDir "watcher_state.json"
$BatFile = Join-Path $ProjectRoot "media-autobuild_suite.bat"

function Launch-Build {
    Write-Host "Starting media-autobuild_suite.bat..." -ForegroundColor Green

    # Clean old state file
    if (Test-Path $StateFile) {
        Remove-Item $StateFile -Force
    }

    # Start the batch file in a background process
    $process = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c `"$BatFile`"" `
        -WorkingDirectory $ProjectRoot `
        -NoNewWindow `
        -PassThru

    Write-Host "Build started (PID: $($process.Id))" -ForegroundColor Green
    Write-Host "Compile log: $CompileLog"
    Write-Host "Monitor with: .\driver.ps1 -Action monitor"

    return $process.Id
}

function Monitor-Build {
    param([int]$TimeoutSeconds)

    Write-Host "Monitoring build (timeout: ${TimeoutSeconds}s)..." -ForegroundColor Cyan

    if (-not (Test-Path $CompileLog)) {
        Write-Warning "Compile log not yet created; waiting..."
        Start-Sleep -Seconds 2
    }

    $startTime = Get-Date
    $lastLines = 0
    $staleCount = 0

    while ($true) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds

        if ($elapsed -gt $TimeoutSeconds) {
            Write-Host "Timeout reached ($TimeoutSeconds seconds)" -ForegroundColor Yellow
            break
        }

        # Check if build process is still running
        $buildProcs = Get-Process -Name "cmd", "bash", "mintty" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*autobuild*" -or $_.CommandLine -like "*compile*" }

        if (-not $buildProcs) {
            Write-Host "Build processes finished" -ForegroundColor Green
            break
        }

        # Tail new lines from compile.log
        if (Test-Path $CompileLog) {
            $lines = @(Get-Content $CompileLog -ErrorAction SilentlyContinue)
            $currentLines = $lines.Count

            if ($currentLines -gt $lastLines) {
                # Show last few new lines
                $newLines = $lines[($lastLines)..($currentLines - 1)]
                foreach ($line in $newLines) {
                    if ($line -match '\[Failed\]') {
                        Write-Host $line -ForegroundColor Red
                    } elseif ($line -match '\[Updated\]|\[Recently updated\]') {
                        Write-Host $line -ForegroundColor Green
                    } else {
                        Write-Host $line -ForegroundColor Gray
                    }
                }
                $lastLines = $currentLines
                $staleCount = 0
            } else {
                $staleCount++
                if ($staleCount -ge 2) {
                    Write-Host "No new log output for 2 checks; build likely complete" -ForegroundColor Yellow
                    break
                }
            }
        }

        Start-Sleep -Seconds 5
    }

    # Final status
    Get-BuildStatus
}

function Get-BuildStatus {
    Write-Host "`nBuild Status:" -ForegroundColor Cyan

    if (-not (Test-Path $CompileLog)) {
        Write-Host "  No compile log found" -ForegroundColor Gray
        return
    }

    $logContent = Get-Content $CompileLog
    $totalLines = $logContent.Count
    $failedCount = ($logContent | Select-String '\[Failed\]' -ErrorAction SilentlyContinue).Count
    $completedCount = ($logContent | Select-String '\[Updated\]' -ErrorAction SilentlyContinue).Count

    Write-Host "  Log lines: $totalLines"
    Write-Host "  Completed packages: $completedCount"
    Write-Host "  Failed packages: $failedCount" $(if ($failedCount -gt 0) { "❌" } else { "✓" })

    # Show last completed/failed package
    $lastEvent = $logContent | Select-String '(Updated|Failed)' | Select-Object -Last 1
    if ($lastEvent) {
        Write-Host "  Last event: $($lastEvent.Line.Trim())"
    }

    # Check state file
    if (Test-Path $StateFile) {
        $state = Get-Content $StateFile | ConvertFrom-Json
        Write-Host "  Errors detected: $($state.errors_seen)"
        Write-Host "  Build done: $($state.build_done)"
    }
}

function Stop-Build {
    Write-Host "Stopping build processes..." -ForegroundColor Yellow

    Get-Process -Name "cmd", "bash", "mintty" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*autobuild*" -or $_.CommandLine -like "*compile*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue

    Write-Host "Build stopped" -ForegroundColor Green
}

# Execute action
switch ($Action) {
    'launch' { Launch-Build }
    'monitor' { Monitor-Build -TimeoutSeconds $Timeout }
    'status' { Get-BuildStatus }
    'stop' { Stop-Build }
}