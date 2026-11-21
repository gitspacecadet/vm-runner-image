# Offline dependency/preservation regression check against the reviewed control.
param([string] $ControlRef = 'c9d649ebe5f3e89657e313f2234f71b1626d73e5')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$path = 'images/windows/templates/build.windows-2022-algo.pkr.hcl'
$controlLines = git -C $repo show "${ControlRef}:$path"
if ($LASTEXITCODE -ne 0) { throw 'Cannot read ordering control' }
$control = $controlLines -join "`n"
$treatment = (Get-Content -LiteralPath (Join-Path $repo $path) -Raw).Replace("`r`n", "`n")
function Get-Blocks([string] $Text) {
    @([regex]::Matches($Text, '(?ms)^  provisioner "([^"]+)" \{.*?^  \}'))
}
function Assert-Equal($Actual, $Expected, [string] $Message) {
    if (($Actual -join "`n") -cne ($Expected -join "`n")) { throw $Message }
    Write-Host "PASS: $Message"
}
$before = Get-Blocks $control
$after = Get-Blocks $treatment
foreach ($bcScript in @('Create-BcImage.ps1', 'Smoke-BcContainer.ps1')) {
    Assert-Equal @($after | Where-Object Value -Like "*$bcScript*" | ForEach-Object Value) `
        @($before | Where-Object Value -Like "*$bcScript*" | ForEach-Object Value) "$bcScript provisioner/settings unchanged"
}
Assert-Equal @($after | Where-Object { $_.Groups[1].Value -eq 'windows-restart' } | ForEach-Object Value) `
    @($before | Where-Object { $_.Groups[1].Value -eq 'windows-restart' } | ForEach-Object Value) 'all reboot/readiness blocks unchanged'
Assert-Equal @([regex]::Matches($treatment, '(?m)^\s*pause_before\s*=.*$') | ForEach-Object Value) `
    @([regex]::Matches($control, '(?m)^\s*pause_before\s*=.*$') | ForEach-Object Value) 'all fixed pauses unchanged'
$bcPattern = 'Create-BcImage.ps1|Smoke-BcContainer.ps1'
$scriptPattern = '"\$\{path.root\}/../scripts/[^"\r\n]+\.ps1"'
$controlScripts = @([regex]::Matches($control, $scriptPattern) | ForEach-Object Value)
$treatmentScripts = @([regex]::Matches($treatment, $scriptPattern) | ForEach-Object Value)
Assert-Equal @($treatmentScripts | Where-Object { $_ -notmatch "$bcPattern|Test-BcPreservation-ALGo.ps1" }) `
    @($controlScripts | Where-Object { $_ -notmatch $bcPattern }) 'all other scripts retained in original sequence'
$sequence = @('Install-WindowsUpdates.ps1','Configure-DynamicPort.ps1','Configure-GDIProcessHandleQuota.ps1',
    'Configure-Shell.ps1','Configure-DeveloperMode.ps1','Install-WindowsUpdatesAfterReboot-ALGo.ps1',
    'Create-BcImage.ps1','Smoke-BcContainer.ps1','Invoke-Cleanup.ps1','RunAll-ALGo-Tests.ps1',
    'testResults.xml','Generate-SoftwareReport-ALGo.ps1','Install-NativeImages.ps1','Configure-System.ps1',
    'Configure-User-ALGo.ps1','Post-Build-Validation.ps1','Test-BcPreservation-ALGo.ps1',
    'buildimage-evidence.zip','Sysprep.exe')
$offset = -1
foreach ($item in $sequence) {
    $next = $treatment.IndexOf($item, $offset + 1, [StringComparison]::Ordinal)
    if ($next -lt 0) { throw "Missing/out-of-order dependency: $item" }
    $offset = $next
}
Write-Host 'PASS: WU/config/reboot verification -> BC -> cleanup/tests/reports/NGEN/final configuration -> preservation/evidence -> Sysprep'
$wuCheck = @($after | Where-Object Value -Like '*Install-WindowsUpdatesAfterReboot-ALGo.ps1*')
if ($wuCheck.Count -ne 1 -or $wuCheck[0].Value -notmatch 'pause_before\s*=\s*"2m0s"' -or $wuCheck[0].Value -match 'Invoke-Cleanup') {
    throw 'Post-reboot verification must retain its two-minute pause and finish before BC/cleanup'
}
$prefix = '# Phase 3:'
Assert-Equal ($treatment.Substring(0, $treatment.IndexOf($prefix))) ($control.Substring(0, $control.IndexOf($prefix))) 'archive upload/hardening unchanged'
Write-Host 'PASS: offline dependency/order checks complete (no provisioning)'
