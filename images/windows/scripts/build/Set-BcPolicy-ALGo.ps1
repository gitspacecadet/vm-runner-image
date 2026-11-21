# Run before the first Docker pull/helper import. No helper version pin.
param([string] $HelperDirectory = (Join-Path $env:ProgramData 'BcContainerHelper'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Get-Module ImageHelpers).ModuleBase 'BcPolicy-ALGo.ps1')
$generic = if ($env:BC_GENERIC_IMAGE) { $env:BC_GENERIC_IMAGE } else { (Get-ToolsetContent).docker.images[0] }
$policy = Get-ALGoBcPolicy -GenericImage $generic
$folder = $HelperDirectory
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$path = Join-Path $folder 'BcContainerHelper.config.json'
# A clean marketplace build must not silently overwrite someone else's policy.
if (Test-Path -LiteralPath $path) { throw "Unexpected pre-existing helper policy: $path" }
$policy | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding ASCII
Write-Host "[BC POLICY] generic=$generic isolation=process (bake, smoke and helper defaults)"
