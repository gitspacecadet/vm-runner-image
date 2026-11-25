################################################################################
##  File:  Invoke-BackgroundDockerPull-ALGo.ps1
##  Desc:  Build-time lever L12: overlap the toolset docker.images pull with
##         the Phase 9a/9 installs.
##         PULL_MODE=Start registers and starts a SYSTEM scheduled task that
##         pulls the images (a process started inside the Packer WinRM session
##         is killed when that session ends, a scheduled task is not).
##         PULL_MODE=Wait waits for the task, pulls anything still missing
##         synchronously (fallback), removes the task and its files, then runs
##         the same DockerImages test upstream Install-Docker.ps1 ran.
##         There must be NO restart between Start and Wait (it kills the pull).
################################################################################

$ErrorActionPreference = 'Stop'
$taskName = 'ALGoBackgroundDockerPull'
$workDir  = 'C:\Windows\Temp\algo-bg-docker-pull'
if ($env:PULL_WORK_DIR) { $workDir = $env:PULL_WORK_DIR }   # tests only
$listFile = Join-Path $workDir 'images.txt'
$logFile  = Join-Path $workDir 'pull.log'
$exitFile = Join-Path $workDir 'pull.exit'
$worker   = Join-Path $workDir 'pull.ps1'
$mode     = $env:PULL_MODE
$timeoutMin = 45
if ($env:PULL_TIMEOUT_MIN) { $timeoutMin = [int] $env:PULL_TIMEOUT_MIN }

function Get-PullImages {
    if (Test-IsWin25) { return @() }
    return @((Get-ToolsetContent).docker.images | Where-Object { $_ })
}

# Runs as SYSTEM inside the scheduled task. Keeps going on errors and records
# the last non-zero docker exit code; Wait decides what to do with it.
$workerText = @'
$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $dir 'pull.log'
$rc = 0
foreach ($img in (Get-Content (Join-Path $dir 'images.txt'))) {
    Add-Content -Path $log -Value ('[BG PULL] {0:u} start {1}' -f (Get-Date).ToUniversalTime(), $img)
    & docker.exe pull $img 2>&1 | ForEach-Object { "$_" } | Add-Content -Path $log
    $code = $LASTEXITCODE
    if ($code -ne 0) { $rc = $code }
    Add-Content -Path $log -Value ('[BG PULL] {0:u} end {1} exit {2}' -f (Get-Date).ToUniversalTime(), $img, $code)
}
Set-Content -Path (Join-Path $dir 'pull.exit') -Value $rc -Encoding Ascii
'@

switch ($mode) {
    'Start' {
        $images = Get-PullImages
        if ($images.Count -eq 0) {
            Write-Host "[BG PULL] No docker.images to pull"
            return
        }
        if (Test-Path $workDir) { Remove-Item -Path $workDir -Recurse -Force }
        New-Item -ItemType Directory -Path $workDir | Out-Null
        Set-Content -Path $listFile -Value $images -Encoding Ascii
        Set-Content -Path $worker -Value $workerText -Encoding Ascii

        # A pure optimisation must not fail the build: on any error, warn and
        # leave the pull to Wait's synchronous fallback.
        try {
            $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$worker`""
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            Start-Sleep -Seconds 15
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $state = if ($task) { $task.State } else { 'Missing' }
            Write-Host ("[BG PULL] {0:u} started task {1} for {2}; state={3}" -f (Get-Date).ToUniversalTime(), $taskName, ($images -join ', '), $state)
            if ("$state" -ne 'Running' -and -not (Test-Path $exitFile)) {
                Write-Warning "[BG PULL] Task is not running (state=$state); Wait will pull synchronously"
            }
        } catch {
            Write-Warning "[BG PULL] Could not start the background pull ($($_.Exception.Message)); Wait will pull synchronously"
        }
    }
    'Wait' {
        $images = Get-PullImages
        if ($images.Count -eq 0) {
            Write-Host "[BG PULL] No docker.images to wait for"
            return
        }
        $t0 = Get-Date
        $deadline = $t0.AddMinutes($timeoutMin)
        # Stop waiting as soon as the task is no longer running: the worker
        # writes pull.exit before it exits, so "not running + no exit file"
        # means it never started or died, and only the fallback can help.
        while (-not (Test-Path $exitFile) -and (Get-Date) -lt $deadline) {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if (-not $task -or "$($task.State)" -ne 'Running') {
                if (-not (Test-Path $exitFile)) {
                    Write-Warning "[BG PULL] Task not running (state=$(if ($task) { $task.State } else { 'Missing' })) and no exit file"
                }
                break
            }
            Start-Sleep -Seconds 10
        }
        $waited = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)

        if (Test-Path $logFile) {
            Get-Content -Path $logFile | Where-Object { $_ -match '^\[BG PULL\]|Digest:|Status:|rror' } | ForEach-Object { Write-Host $_ }
        }
        if (Test-Path $exitFile) {
            $rc = (Get-Content -Path $exitFile | Select-Object -First 1).Trim()
            Write-Host "[BG PULL] Task finished with exit $rc; waited $waited min"
        } else {
            Write-Warning "[BG PULL] No exit file after $waited min; stopping the task"
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5   # let a child docker.exe exit before the fallback
        }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        # Native calls under Continue so docker stderr (e.g. credential-helper
        # warnings) cannot raise NativeCommandError; the exit code decides.
        $ErrorActionPreference = 'Continue'
        foreach ($img in $images) {
            if (-not (docker images -q $img)) {
                Write-Warning "[BG PULL] FALLBACK: $img missing after the background pull; pulling synchronously"
                docker pull $img
                if ($LASTEXITCODE -ne 0) { throw "Docker pull failed with a non-zero exit code ($LASTEXITCODE)" }
            }
        }
        $ErrorActionPreference = 'Stop'
        Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-PesterTests -TestFile "Docker" -TestName "DockerImages"
    }
    default {
        throw "Unknown PULL_MODE '$mode' (expected Start or Wait)"
    }
}
