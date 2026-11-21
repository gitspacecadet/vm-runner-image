# Local-only checks. No provisioning, Docker mutation, or workflow dispatch.
param([switch] $SkipPayload)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
Set-Location $repo
Write-Host "PowerShell $($PSVersionTable.PSVersion)"
$changed = @(git diff --name-only b9953709 -- '*.ps1') + @(git ls-files --others --exclude-standard -- '*.ps1')
foreach ($relative in @($changed | Sort-Object -Unique)) {
    $file = Join-Path $repo $relative
    $tokens = $null; $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { $parseErrors | Out-Host; throw "PS parse failed: $relative" }
    if (@([IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count) { throw "Non-ASCII: $relative" }
    Write-Host "Parse/ASCII PASS: $relative"
}
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
$result = Invoke-Pester -Path @(
    "$PSScriptRoot/BcPolicy-ALGo.Tests.ps1",
    "$PSScriptRoot/BuildImageTelemetry-ALGo.Tests.ps1",
    "$PSScriptRoot/ChocolateyPackages-ALGo.Tests.ps1",
    "$PSScriptRoot/WindowsUpdates-ALGo.Tests.ps1",
    "$PSScriptRoot/Sysprep-ALGo.Tests.ps1"
) -Output Detailed -PassThru
if ($result.FailedCount -gt 0 -or $result.PassedCount -eq 0) { throw 'Prototype local Pester tests failed' }
if (-not $SkipPayload) {
    foreach ($year in @('2022','2025')) {
        & "$PSScriptRoot/Test-ImagePayload-ALGo.ps1" -Year $year
    }
}
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'git diff --check failed' }
