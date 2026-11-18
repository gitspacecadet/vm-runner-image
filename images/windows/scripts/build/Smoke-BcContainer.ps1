################################################################################
##  File:  Smoke-BcContainer.ps1
##  Desc:  Validates the pre-built BC docker image actually starts a container.
##         Companion to Create-BcImage.ps1: that script builds + tags the image;
##         this script spins up a real container from it, verifies service tier
##         reachability, then tears down. Catches "image built but doesn't run"
##         bugs at bake time rather than in customer CI/CD.
##
##  Behavior:
##   - Skips if BC_CACHE_SKIP=true (same gate as Create-BcImage.ps1)
##   - Reads bc-cache-metadata.json for the image name
##   - Creates a container (name: bcsmoke) with a random per-image credential,
##     waits up to 6 min for service tier reachability, then KEEPS it by default
##     (keep-container experiment; BC_SMOKE_REMOVE=true removes it)
##   - Fails the Packer build if container won't start (treats image as broken)
##
##  Trade-off (project-owner-approved 2026-06-08 as Option A -- smoke-test only):
##   - Adds ~3-5 min to Packer wall-clock
##   - No CI/CD reuse benefit (container state isn't snapshotted; would be
##     hostname/license-bound on the Packer VM)
##   - Reliability win: a broken BC image fails the bake, not the customer build
################################################################################
set-strictmode -version latest
$ErrorActionPreference = 'Stop'

if ($env:BC_CACHE_SKIP -and $env:BC_CACHE_SKIP.ToString().ToLower() -in @('1','true','yes','y')) {
	Write-Host "[BC SMOKE] Skipping Business Central smoke-test because BC_CACHE_SKIP=$($env:BC_CACHE_SKIP)"
	return
}

Write-Host "[BC SMOKE] Starting Business Central container smoke-test" -ForegroundColor Cyan

$cacheDir = if ($env:BC_CACHE_DIR) { $env:BC_CACHE_DIR } else { 'C:\bcartifacts.cache' }
$metadataPath = Join-Path $cacheDir 'bc-cache-metadata.json'
if (-not (Test-Path $metadataPath)) {
	throw "[BC SMOKE] Cache metadata missing at $metadataPath -- Create-BcImage.ps1 must have failed or been skipped"
}

$metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
$imageName = $metadata.dockerImage
$artifactUrl = $metadata.artifactUrl
if (-not $imageName) { throw "[BC SMOKE] bc-cache-metadata.json missing dockerImage field" }
Write-Host "[BC SMOKE] Target image: $imageName"
Write-Host "[BC SMOKE] Artifact URL: $artifactUrl"

Import-Module BcContainerHelper -Force

$containerName = 'bcsmoke'
$cleanupRequired = $false

# Per-image random credential (operator ruling 2026-11-18, item 5c). It replaces
# the old fixed 'admin' password, which every runner carried because the smoke
# container is kept (see the finally block).
#   - Generated here, held only in memory, never written to disk or the log.
#   - BcContainerHelper hands it to the container AES-encrypted with a one-time
#     key that both the host and the container delete, so it can't be recovered.
#   - Nothing needs it later: the checks below don't authenticate, the container
#     restarts without it, and CI/CD jobs create their own containers.
function New-SmokePassword {
	$bytes = New-Object Byte[] 15
	$rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
	try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
	# 15 bytes -> exactly 20 base64 chars (no '=' padding). '+' and '/' map to
	# letters so the value is safe in any quoting. The fixed 'Aa1!' tail
	# guarantees the upper/lower/digit/symbol classes BC and SQL require.
	$core = [Convert]::ToBase64String($bytes).Replace('+', 'k').Replace('/', 'q')
	return ConvertTo-SecureString -String ($core + 'Aa1!') -AsPlainText -Force
}
$smokeCredential = New-Object System.Management.Automation.PSCredential('admin', (New-SmokePassword))

try {
	Write-Host "[BC SMOKE] Creating container '$containerName' from $imageName"
	$createStart = Get-Date

	$newContainerParams = @{
		containerName      = $containerName
		imageName          = $imageName
		artifactUrl        = $artifactUrl
		auth               = 'NavUserPassword'
		Credential         = $smokeCredential
		updateHosts        = $true
		accept_eula        = $true
		accept_outdated    = $true
		multitenant        = $true
		isolation          = 'process'
		shortcuts          = 'None'
		includeTestToolkit = $false
		doNotExportObjectsToText = $true
	}

	$cleanupRequired = $true
	New-BcContainer @newContainerParams

	$createElapsed = (Get-Date) - $createStart
	Write-Host "[BC SMOKE] Container created in $([Math]::Round($createElapsed.TotalSeconds,1))s"

	# Service-tier reachability check -- BcContainerHelper's Test-BcContainer
	# is the canonical "is it up?" gate. If this returns false, the container
	# is up but BC service tier hasn't bound yet.
	$reachable = $false
	$deadline = (Get-Date).AddMinutes(2)
	while ((Get-Date) -lt $deadline) {
		try {
			Test-BcContainer -containerName $containerName -doNotCheckHealth | Out-Null
			$reachable = $true
			break
		} catch {
			Start-Sleep -Seconds 5
		}
	}

	if (-not $reachable) {
		throw "[BC SMOKE] Service tier never became reachable inside the 2-min window after container start"
	}

	Write-Host "[BC SMOKE] Service tier reachable. Verifying basic container info..."
	$containerInfo = Get-BcContainerArtifactUrl -containerName $containerName
	if (-not $containerInfo) {
		throw "[BC SMOKE] Get-BcContainerArtifactUrl returned empty -- container metadata not accessible"
	}
	Write-Host "[BC SMOKE] Container artifact URL: $containerInfo"
	Write-Host "[BC SMOKE] Container is healthy. Smoke-test passed." -ForegroundColor Green
}
finally {
	if ($cleanupRequired) {
		# EXPERIMENT 2026-06-09: Keep the smoke container in the image (skip Remove-BcContainer)
		# to test whether a pre-baked BC container shortens cold-VM container creation time on
		# the subsequent CI/CD run that uses the new image. New-BcContainer in the CI/CD uses
		# a different container name (bc<workflowRunId>), so this container sits as a "decoy"
		# warming Docker layer cache + OS file cache + possibly the BC service tier in RAM
		# (because --restart unless-stopped will auto-start it on VM boot).
		#
		# Default is "keep". To revert to normal smoke-then-remove behavior, set
		# BC_SMOKE_REMOVE=true in the Packer environment_vars.
		$shouldRemove = $env:BC_SMOKE_REMOVE -and $env:BC_SMOKE_REMOVE.ToString().ToLower() -in @('1','true','yes','y')
		if ($shouldRemove) {
			Write-Host "[BC SMOKE] Removing smoke container '$containerName' (BC_SMOKE_REMOVE=true)..."
			try {
				Remove-BcContainer -containerName $containerName
				Write-Host "[BC SMOKE] Smoke container removed."
			} catch {
				Write-Warning "[BC SMOKE] Failed to remove container '$containerName': $_"
			}
		} else {
			Write-Host "[BC SMOKE] EXPERIMENT: keeping container '$containerName' in image (BC_SMOKE_REMOVE not set)."
			Write-Host "[BC SMOKE]   --restart unless-stopped means container auto-restarts on VM boot."
			Write-Host "[BC SMOKE]   On the next CI/CD using this image, observe whether container creation time"
			Write-Host "[BC SMOKE]   drops from ~360s (cold-VM) toward ~126s (warm-runner) baseline."

			# Write durable marker so CSE on the VMSS instance can declare keep-container=true
			# in the [PROBE_KEEP_CONTAINER] log line ScaleIn's harvester correlates against image versions.
			$markerPath = Join-Path $cacheDir 'keep-container-marker.json'
			try {
				$marker = [ordered]@{
					enabled       = $true
					containerName = $containerName
					imageName     = $imageName
					bakedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
					commit        = 'cb27d8f5'  # experiment commit; bumps with future revisions
				}
				$marker | ConvertTo-Json -Depth 5 | Out-File -FilePath $markerPath -Encoding UTF8
				Write-Host "[BC SMOKE]   Marker written: $markerPath"
			} catch {
				Write-Warning "[BC SMOKE]   Failed to write keep-container marker: $_"
			}
		}
	}
}

Write-Host "[BC SMOKE] Completed Business Central container smoke-test" -ForegroundColor Green
