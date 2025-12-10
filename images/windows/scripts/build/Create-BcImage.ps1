################################################################################
##  File:  Create-BcImage.ps1
##  Desc:  Pre-caches Business Central (BC) generic image, artifacts, and
##         pre-builds the Docker image so that future container creation on
##         the runner is much faster.
##
##  Behavior:
##   - Skips execution if BC_CACHE_SKIP=true environment variable is set
##   - Parameterizable via env vars:
##       BC_COUNTRY (default: us)
##       BC_TYPE (default: Sandbox)
##       BC_SELECT (default: Latest)
##       BC_CACHE_DIR (default: C:\bcartifacts.cache)
##   - Writes a metadata file to C:\bcartifacts.cache\bc-cache-metadata.json
##
##  What it does:
##   1. Pulls the generic BC Docker image
##   2. Downloads BC artifacts and platform files to cache
##   3. Pre-builds a multitenant Docker image from the artifacts
##   4. Saves metadata for verification
##
##  This pre-built image reduces CI/CD build times from ~44 minutes to ~2-3 minutes
################################################################################
set-strictmode -version latest
$ErrorActionPreference = 'Stop'

if ($env:BC_CACHE_SKIP -and $env:BC_CACHE_SKIP.ToString().ToLower() -in @('1','true','yes','y')) {
	Write-Host "[BC CACHE] Skipping Business Central cache priming because BC_CACHE_SKIP=$($env:BC_CACHE_SKIP)"
	return
}

Write-Host "[BC CACHE] Starting Business Central cache priming" -ForegroundColor Cyan

function Invoke-Section {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][scriptblock]$Action
	)
	Write-Host "[BC CACHE] >>> $Name" -ForegroundColor Yellow
	& $Action
	Write-Host "[BC CACHE] <<< $Name" -ForegroundColor DarkYellow
}

Invoke-Section -Name 'Install BcContainerHelper' -Action {
	if (-not (Get-Module -ListAvailable -Name BcContainerHelper)) {
		Write-Host "Installing BcContainerHelper module"
		Install-Module -Name BcContainerHelper -Force -AllowClobber | Out-Null
	} else {
		Write-Host "BcContainerHelper already present"
	}
	Import-Module BcContainerHelper -Force
}

$hostOsVersion = (Get-CimInstance -ClassName Win32_OperatingSystem).Version
Write-Host "[BC CACHE] Host OS Version: $hostOsVersion"

$genericImageName = Get-BestGenericImageName -hostOsVersion $hostOsVersion
Write-Host "[BC CACHE] Generic image determined: $genericImageName"

# Verify the generic BC image is already present (pulled via toolset docker.images)
Invoke-Section -Name 'Verify generic BC image' -Action {
	$existingImage = docker images --format "{{.Repository}}:{{.Tag}}" | Where-Object { $_ -eq $genericImageName }
	if ($existingImage) {
		Write-Host "[BC CACHE] Generic image already present: $genericImageName (pulled via toolset)"
	} else {
		Write-Host "[BC CACHE] Generic image not found, pulling: $genericImageName"
		docker pull $genericImageName
		if ($LASTEXITCODE -ne 0) { throw "Failed to pull generic BC image $genericImageName (exit $LASTEXITCODE)" }
	}
}

$country = if ($env:BC_COUNTRY) { $env:BC_COUNTRY } else { 'us' }
$type    = if ($env:BC_TYPE) { $env:BC_TYPE } else { 'Sandbox' }
$select  = if ($env:BC_SELECT) { $env:BC_SELECT } else { 'Latest' }
$cacheDir = if ($env:BC_CACHE_DIR) { $env:BC_CACHE_DIR } else { 'C:\bcartifacts.cache' }

New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
Write-Host "[BC CACHE] Using cache directory: $cacheDir"

Invoke-Section -Name 'Resolve artifact URL' -Action {
	$script:artifactUrl = Get-BCArtifactUrl -type $type -country $country -select $select
	if (-not $script:artifactUrl) { throw 'Artifact URL resolution returned empty result' }
	Write-Host "[BC CACHE] Artifact URL: $script:artifactUrl"
}

Invoke-Section -Name 'Download artifacts' -Action {
	Download-Artifacts -artifactUrl $script:artifactUrl -includePlatform -force -basePath $cacheDir
}

# Step 2: Build Docker Image
Invoke-Section -Name 'Build BC Docker Image' -Action {
	# Use "my" as imageName to match AL-Go convention
	$versionTag = ($script:artifactUrl -split '/')[-2]  # e.g., 27.0.38460.41755
	$imageName = "my"  # MUST match AL-Go default imageName parameter
	$imageTag = "$type-$versionTag-$country-mt"
	$script:fullImageName = "${imageName}:${imageTag}".ToLower()

	Write-Host "[BC CACHE] Building Docker image: $script:fullImageName"
	Write-Host "[BC CACHE] This image will be reused by AL-Go on every build"

	# Build the image using New-BcImage
	$buildParams = @{
		artifactUrl = $script:artifactUrl
		baseImage = $genericImageName
		imageName = $script:fullImageName
		isolation = 'process'
		multitenant = $true
	}

	New-BcImage @buildParams

	Write-Host "[BC CACHE] Docker image built successfully"
	docker images $script:fullImageName
}

Invoke-Section -Name 'Write metadata' -Action {
	$metadata = [ordered]@{
		timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
		hostOsVersion = $hostOsVersion
		genericImage = $genericImageName
		artifactUrl = $script:artifactUrl
		country = $country
		type = $type
		select = $select
		cacheDir = $cacheDir
		dockerImage = $script:fullImageName
	}
	$metadataPath = Join-Path $cacheDir 'bc-cache-metadata.json'
	$metadata | ConvertTo-Json -Depth 5 | Out-File -FilePath $metadataPath -Encoding UTF8
	Write-Host "[BC CACHE] Metadata written: $metadataPath"
}

Write-Host "[BC CACHE] Completed Business Central cache priming" -ForegroundColor Green
