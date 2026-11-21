# Execute inside a NEW isolated gallery VM, before registering a test runner.
# Read-only: never starts/recreates containers or changes credentials/pool state.
param(
    [Parameter(Mandatory)][string] $ExpectedGalleryVersionId,
    [ValidateSet(20348,26100)][int] $ExpectedHostBuild = 26100,
    [string] $ExpectedVmSize = 'Standard_B4ms',
    [ValidateRange(2,12)][int] $HealthySamples = 3,
    [ValidateRange(5,60)][int] $SampleIntervalSeconds = 15,
    [string] $OutputDirectory = 'C:\ProgramData\PrototypeValidation'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$start = [DateTime]::UtcNow
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$record = [ordered]@{ startUtc = $start.ToString('o'); succeeded = $false; kind = 'fresh-gallery-boot'; samples = @() }
try {
    $imds = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' -TimeoutSec 15
    if ($imds.compute.subscriptionId -ne '198177af-a00c-409d-8ce7-60d9de619f7b') { throw 'Validation VM is not in MPN' }
    if ($imds.compute.storageProfile.imageReference.id -ine $ExpectedGalleryVersionId) { throw 'Actual gallery version differs from requested treatment' }
    if ($imds.compute.vmSize -ne $ExpectedVmSize) { throw 'Unexpected validation VM size' }
    $record.vm = @{ resourceId = $imds.compute.resourceId; vmId = $imds.compute.vmId; vmSize = $imds.compute.vmSize; galleryVersion = $imds.compute.storageProfile.imageReference.id }
    if (Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue) { throw 'Fresh validation VM already has a registered runner service' }
    $os = Get-CimInstance Win32_OperatingSystem
    $current = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $firmware = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType.ToString()
    if ([int]$os.BuildNumber -ne $ExpectedHostBuild -or $os.OSArchitecture -notmatch '64' -or $current.InstallationType -ne 'Server') { throw 'Unexpected host OS/build/architecture/install option' }
    if ($firmware -ne 'Bios') { throw "V1 BIOS firmware expected; found $firmware" }
    $license = @(Get-CimInstance SoftwareLicensingProduct | Where-Object { $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' -and $_.PartialProductKey })
    if (-not @($license | Where-Object LicenseStatus -eq 1).Count) { throw 'Windows LicenseStatus=1 is required' }
    $record.host = @{ caption = $os.Caption; version = $os.Version; ubr = $current.UBR; build = $os.BuildNumber; architecture = $os.OSArchitecture; installationType = $current.InstallationType; firmware = $firmware; licenseStatuses = @($license.LicenseStatus); lastBootUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o') }
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    do {
        $ready = & { $ErrorActionPreference = 'Continue'; docker info --format '{{.ServerVersion}}' 2>$null }
        if ($LASTEXITCODE -eq 0 -and $ready) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Docker API did not become ready within 15 minutes' }
        Start-Sleep -Seconds 5
    } while ($true)
    $record.dockerApiReadyElapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $start).TotalSeconds,3)
    Import-Module BcContainerHelper -Force -ErrorAction Stop
    $metadata = Get-Content 'C:\bcartifacts.cache\bc-cache-metadata.json' -Raw | ConvertFrom-Json
    $marker = Get-Content 'C:\bcartifacts.cache\keep-container-marker.json' -Raw | ConvertFrom-Json
    $policy = Get-Content 'C:\ProgramData\BcContainerHelper\BcContainerHelper.config.json' -Raw | ConvertFrom-Json
    if ((Get-BestGenericImageName) -ne $metadata.genericImage -or $policy.genericImageName -ne $metadata.genericImage -or $bcContainerHelperConfig.defaultNewContainerParameters.isolation -ne 'process') { throw 'Helper base/process policy changed after generalization' }
    if (-not $marker.enabled -or $marker.containerName -ne 'bcsmoke' -or $marker.imageName -ne $metadata.dockerImage) { throw 'Keep-container marker changed' }
    $raw = docker image inspect $metadata.dockerImage --format '{{json .}}'
    if ($LASTEXITCODE -ne 0) { throw 'Baked image missing after fresh boot' }
    $baked = $raw | ConvertFrom-Json
    if ($baked.Id -ne $metadata.dockerImageId) { throw 'Exact baked image ID changed' }
    $raw = docker image inspect $metadata.genericImage --format '{{json .}}'
    if ($LASTEXITCODE -ne 0) { throw 'Generic image missing after fresh boot' }
    $generic = $raw | ConvertFrom-Json
    if ($generic.Id -ne $metadata.genericImageId -or $generic.RepoDigests -notcontains $metadata.genericImage) { throw 'Exact generic image identity changed' }
    # Record client/server API and storage-driver readiness, never Docker Env.
    $raw = docker version --format '{{json .}}'
    if ($LASTEXITCODE -ne 0) { throw 'Docker version API unavailable' }
    $version = $raw | ConvertFrom-Json
    $driver = docker info --format '{{.Driver}}'
    if ($LASTEXITCODE -ne 0 -or $driver -ne 'windowsfilter') { throw 'Windows Docker storage driver not ready' }
    $record.runtime = @{ dockerClient = $version.Client.Version; dockerServer = $version.Server.Version; apiVersion = $version.Server.ApiVersion; driver = "$driver"; helperVersion = (Get-Module BcContainerHelper).Version.ToString() }
    $record.cache = @{ image = $metadata.dockerImage; imageId = $baked.Id; generic = $metadata.genericImage; genericId = $generic.Id; genericOsVersion = $generic.OsVersion; artifact = ([uri]$metadata.artifactUrl).GetLeftPart([UriPartial]::Path); keepMarker = $true; artifactDirectories = @(Get-ChildItem 'C:\bcartifacts.cache' -Directory).Count }
    if ($record.cache.artifactDirectories -lt 1) { throw 'Artifact cache directories missing' }
    # Wait for automatic startup; never issue docker start or recreate bcsmoke.
    do {
        $raw = docker inspect bcsmoke --format '{{json .}}'
        if ($LASTEXITCODE -ne 0) { throw 'Retained bcsmoke missing' }
        $container = $raw | ConvertFrom-Json
        if ($container.State.Running -and $container.State.Health.Status -eq 'healthy') { break }
        if ($container.State.Health.Status -eq 'unhealthy' -or [DateTime]::UtcNow -ge $deadline) { throw 'Automatic bcsmoke startup did not become healthy within the readiness deadline' }
        Start-Sleep -Seconds 5
    } while ($true)
    $record.smokeHealthyElapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $start).TotalSeconds,3)
    for ($index = 0; $index -lt $HealthySamples; $index++) {
        $raw = docker inspect bcsmoke --format '{{json .}}'
        if ($LASTEXITCODE -ne 0) { throw 'Retained bcsmoke missing' }
        $container = $raw | ConvertFrom-Json
        if (-not $container.State.Running -or $container.State.Health.Status -ne 'healthy') { throw 'bcsmoke is not sustained Docker-healthy' }
        if ($container.Image -ne $baked.Id -or $container.HostConfig.Isolation -ne 'process' -or $container.HostConfig.RestartPolicy.Name -ne 'unless-stopped') { throw 'Retained container image/isolation/restart policy mismatch' }
        $nst = (docker exec bcsmoke powershell -NoProfile -Command "(Get-Service -Name 'MicrosoftDynamicsNavServer*' | Where-Object Status -eq 'Running' | Measure-Object).Count" | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $nst -notmatch '^[1-9]\d*$') { throw 'BC service tier not Running' }
        if ((Get-BcContainerArtifactUrl -containerName bcsmoke).TrimEnd('/') -ne $metadata.artifactUrl.TrimEnd('/')) { throw 'BC artifact changed' }
        $sample = @{ utc = [DateTime]::UtcNow.ToString('o'); health = 'healthy'; running = $true; isolation = 'process'; serviceTierCount = [int]$nst; restartPolicy = 'unless-stopped' }
        $record.samples += $sample
        Write-Host "[FRESH IMAGE] $($sample | ConvertTo-Json -Compress)"
        if ($index -lt ($HealthySamples - 1)) { Start-Sleep -Seconds $SampleIntervalSeconds }
    }
    $record.succeeded = $true
} catch {
    $record.failure = $_.Exception.Message
    throw
} finally {
    $record.endUtc = [DateTime]::UtcNow.ToString('o')
    $record.elapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $start).TotalSeconds,3)
    $record | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $OutputDirectory 'fresh-image-result.json') -Encoding ASCII
    Write-Host "[FRESH IMAGE RESULT] $($record | ConvertTo-Json -Depth 8 -Compress)"
}
# This gate does not claim authenticated BC functionality or real AL-Go success.
