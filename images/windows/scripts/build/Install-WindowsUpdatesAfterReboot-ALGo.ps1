################################################################################
##  File: Install-WindowsUpdatesAfterReboot-ALGo.ps1
##  Desc: Waits for Windows Updates to finish installing after reboot.
##        Fork-owned copy of upstream Install-WindowsUpdatesAfterReboot.ps1,
##        which stays byte-identical for upstream sync. Only difference: it
##        starts wuauserv before waiting.
##
##  Why:  The update agent writes event 19 (installed) for a reboot-requiring
##        update during its first pass after the reboot. After the reboot nothing
##        starts wuauserv here (Configure-BaseImage.ps1 sets NoAutoUpdate=1 and
##        disables WaaSMedicSvc), so event 19 never appears and the wait times
##        out although the update is installed. Build 43877564118 failed this
##        way on KB5131090. The 2026-11-16 probe on the same base image showed
##        wuauserv Stopped and no event 19 for 22 minutes after boot, then
##        event 19 eight seconds after Start-Service wuauserv.
##        Install-WindowsUpdates.ps1 starts the service the same way before
##        the reboot.
################################################################################

Write-Host "Starting wuauserv so the update agent records post-reboot results"
Start-Service -Name wuauserv -PassThru -ErrorAction Stop | Out-Host

# The probe saw event 19 land 8 s after the start; give it time before the
# first check so a healthy build does not pay a full 120 s retry interval.
Start-Sleep -Seconds 30

Invoke-ScriptBlockWithRetry -RetryCount 10 -RetryIntervalSeconds 120 -Command {
    $inProgress = Get-WindowsUpdateStates | Where-Object State -eq "Running" | Where-Object Title -notmatch "Microsoft Defender Antivirus"
    if ( $inProgress ) {
        $title = $inProgress.Title -join "`n"
        throw "Windows updates are still installing: $title"
    }
}
