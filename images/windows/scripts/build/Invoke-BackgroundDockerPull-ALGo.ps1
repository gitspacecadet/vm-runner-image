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
$dir = 'C:\Windows\Temp\algo-bg-docker-pull'
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

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$worker`""
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 15
        $state = (Get-ScheduledTask -TaskName $taskName).State
        Write-Host ("[BG PULL] {0:u} started task {1} for {2}; state={3}" -f (Get-Date).ToUniversalTime(), $taskName, ($images -join ', '), $state)
        if ($state -ne 'Running' -and -not (Test-Path $exitFile)) {
            Write-Warning "[BG PULL] Task is not running (state=$state); Wait will pull synchronously"
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
        while (-not (Test-Path $exitFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
        $waited = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)

        if (Test-Path $logFile) {
            Get-Content -Path $logFile | Where-Object { $_ -match '^\[BG PULL\]|Digest:|Status:|rror' } | ForEach-Object { Write-Host $_ }
        }
        if (Test-Path $exitFile) {
            $rc = (Get-Content -Path $exitFile | Select-Object -First 1).Trim()
            Write-Host "[BG PULL] Task finished with exit $rc; waited $waited min"
        } else {
            Write-Warning "[BG PULL] Timed out after $timeoutMin min; stopping the task"
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        foreach ($img in $images) {
            if (-not (docker images -q $img)) {
                Write-Warning "[BG PULL] FALLBACK: $img missing after the background pull; pulling synchronously"
                docker pull $img
                if ($LASTEXITCODE -ne 0) { throw "Docker pull failed with a non-zero exit code ($LASTEXITCODE)" }
            }
        }
        Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-PesterTests -TestFile "Docker" -TestName "DockerImages"
    }
    default {
        throw "Unknown PULL_MODE '$mode' (expected Start or Wait)"
    }
}
