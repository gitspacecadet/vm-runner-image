# Packer invokes this through the administrator WinRM account, never SYSTEM.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ImageHelpers -ErrorAction Stop
. (Join-Path (Get-Module ImageHelpers).ModuleBase 'BuildImageTelemetry-ALGo.ps1')
$stage = Start-BuildImageStage -Name 'sysprep'
$succeeded = $false
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -eq 'S-1-5-18') { throw 'Sysprep must not run as SYSTEM' }
    $unattend = Join-Path $env:SystemRoot 'System32\Sysprep\unattend.xml'
    if (Test-Path -LiteralPath $unattend) { Remove-Item -LiteralPath $unattend -Force }
    $process = Start-Process -FilePath "$env:SystemRoot\System32\Sysprep\Sysprep.exe" -ArgumentList '/oobe','/generalize','/mode:vm','/quiet','/quit' -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(900000)) { throw 'Sysprep process exceeded 15 minutes' }
    if ($process.ExitCode -ne 0) { throw "Sysprep failed: exit $($process.ExitCode)" }
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        $state = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
        if ($state -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { $succeeded = $true; break }
        if ([DateTime]::UtcNow -ge $deadline) { throw "Sysprep state timeout: $state" }
        Start-Sleep -Seconds 10
    } while ($true)
    Write-BuildImageEvidence 'sysprep-result' @{ exitCode = $process.ExitCode; imageState = $state; accountSid = $identity.User.Value }
} finally {
    $panther = "$env:SystemRoot\System32\Sysprep\Panther"
    foreach ($name in @('setupact.log','setuperr.log')) {
        $source = Join-Path $panther $name
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination "C:\ProgramData\BuildImageEvidence\sysprep-$name" -Force
        }
    }
    Stop-BuildImageStage -Stage $stage -Succeeded $succeeded
    Compress-Archive -Path 'C:\ProgramData\BuildImageEvidence\*' -DestinationPath 'C:\ProgramData\buildimage-evidence.zip' -Force
}
