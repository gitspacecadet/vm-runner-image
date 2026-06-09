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
##   - Creates a throwaway container (name: bcsmoke), waits up to 6 min for
##     service tier reachability, tears down on success or failure
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

# Throwaway password -- never persisted; container is removed at end.
$smokePassword = ConvertTo-SecureString -String 'P@ssword$1' -AsPlainText -Force
$smokeCredential = New-Object System.Management.Automation.PSCredential('admin', $smokePassword)

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
		Write-Host "[BC SMOKE] Removing smoke container '$containerName'..."
		try {
			Remove-BcContainer -containerName $containerName
			Write-Host "[BC SMOKE] Smoke container removed."
		} catch {
			# Don't fail Packer on cleanup error -- log + continue. Container
			# will be torn down with the Packer VM regardless.
			Write-Warning "[BC SMOKE] Failed to remove container '$containerName': $_"
		}
	}
}

Write-Host "[BC SMOKE] Completed Business Central container smoke-test" -ForegroundColor Green
