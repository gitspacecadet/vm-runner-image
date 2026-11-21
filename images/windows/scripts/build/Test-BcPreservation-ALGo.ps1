# Read-only preservation gate after the final reboot. Does not recreate/start BC.
param([string] $CacheDir = 'C:\bcartifacts.cache')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ImageHelpers -ErrorAction Stop
. (Join-Path (Get-Module ImageHelpers).ModuleBase 'BuildImageTelemetry-ALGo.ps1')
$stage = Start-BuildImageStage -Name 'bc-final-reboot'
$succeeded = $false
try {
    if ($env:BC_CACHE_SKIP -and $env:BC_CACHE_SKIP.ToLower() -in @('1','true','yes','y')) {
        Write-BuildImageEvidence 'preservation-skipped' @{ reason = 'BC_CACHE_SKIP' }
    } else {
        Import-Module BcContainerHelper -ErrorAction Stop
        $root = $CacheDir
        $metadata = Get-Content -LiteralPath (Join-Path $root 'bc-cache-metadata.json') -Raw | ConvertFrom-Json
        $marker = Get-Content -LiteralPath (Join-Path $root 'keep-container-marker.json') -Raw | ConvertFrom-Json
        if (-not $marker.enabled -or $marker.containerName -ne 'bcsmoke' -or $marker.imageName -ne $metadata.dockerImage) {
            throw 'BC keep-container marker does not match the baked image/container'
        }
        if ($metadata.dockerImage -notlike 'my:*') { throw 'Expected baked my: image' }
        # Up to two minutes of readiness retries only when Docker/BC is not ready.
        # Existing fixed waits and Packer reboot structure are unchanged.
        Invoke-ScriptBlockWithRetry -RetryCount 24 -RetryIntervalSeconds 5 -Command {
            $identity = Get-BuildImageDockerIdentity -Image $metadata.dockerImage
            if ($identity.id -ne $metadata.dockerImageId) { throw 'Baked image identity changed after bake' }
            $raw = docker inspect bcsmoke --format '{{json .}}'
            if ($LASTEXITCODE -ne 0) { throw 'bcsmoke inspect failed' }
            $container = $raw | ConvertFrom-Json
            $health = 'none'
            if ($container.State.PSObject.Properties.Name -contains 'Health') { $health = $container.State.Health.Status }
            if (-not $container.State.Running -or $health -eq 'unhealthy') { throw 'bcsmoke is not running with acceptable health' }
            if ($container.Image -ne $identity.id -or $container.HostConfig.Isolation -ne 'process' -or $container.HostConfig.RestartPolicy.Name -ne 'unless-stopped') {
                throw 'bcsmoke image, isolation or restart policy changed'
            }
            $nst = (docker exec bcsmoke powershell -NoProfile -Command "(Get-Service -Name 'MicrosoftDynamicsNavServer*' | Where-Object Status -eq 'Running' | Measure-Object).Count" | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $nst -notmatch '^[1-9]\d*$') { throw 'BC service tier is not Running after final reboot' }
            $artifact = Get-BcContainerArtifactUrl -containerName bcsmoke
            if (-not $artifact -or $artifact.TrimEnd('/') -ne $metadata.artifactUrl.TrimEnd('/')) {
                throw 'BC container artifact metadata unavailable or changed'
            }
            Write-BuildImageEvidence 'preservation-pass' @{
                image = $metadata.dockerImage; imageId = $identity.id; container = 'bcsmoke'
                running = $true; health = $health; serviceTierCount = [int]$nst
                restartPolicy = 'unless-stopped'; keepMarker = $true; isolation = 'process'
                artifact = ([Uri]$artifact).GetLeftPart([UriPartial]::Path)
            }
        }
    }
    $succeeded = $true
} finally { Stop-BuildImageStage -Stage $stage -Succeeded $succeeded }
