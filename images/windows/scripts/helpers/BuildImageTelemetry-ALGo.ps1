# Fork-owned, PS 5.1 telemetry. Never pass credentials or whole environment objects.
# ProgramData survives Invoke-Cleanup (which removes TEMP and the PS profile).
function Write-BuildImageEvidence {
    param([string] $Kind, [System.Collections.IDictionary] $Data)
    $root = Join-Path $env:ProgramData 'BuildImageEvidence'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $record = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); kind = $Kind; data = $Data }
    $json = $record | ConvertTo-Json -Depth 8 -Compress
    Add-Content -LiteralPath (Join-Path $root 'stages.jsonl') -Value $json -Encoding UTF8
    Write-Host "[BUILDIMAGE EVIDENCE] $json"
}

function Start-BuildImageStage {
    param([string] $Name, [switch] $Sample)
    $stage = [pscustomobject]@{
        Name = $Name
        StartUtc = [DateTime]::UtcNow
        Clock = [Diagnostics.Stopwatch]::StartNew()
        Job = $null
        SamplePath = $null
    }
    Write-BuildImageEvidence 'start' @{ stage = $Name; startUtc = $stage.StartUtc.ToString('o') }
    if ($Sample) {
        $stage.SamplePath = Join-Path $env:ProgramData "BuildImageEvidence\resources-$Name.jsonl"
        # One worker only during each measured stage; no task/service survives reboot.
        # CIM class/property names are independent of the OS performance-counter locale.
        $stage.Job = Start-Job -ArgumentList $stage.SamplePath, $Name -ScriptBlock {
            param($SamplePath, $StageName)
            while ($true) {
                try {
                    $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
                    $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction Stop |
                        Select-Object Name, DiskReadBytesPersec, DiskWriteBytesPersec, CurrentDiskQueueLength, PercentDiskTime
                    $network = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop |
                        Select-Object Name, BytesReceivedPersec, BytesSentPersec
                    $row = [ordered]@{
                        utc = [DateTime]::UtcNow.ToString('o'); stage = $StageName
                        cpuPercent = $cpu.PercentProcessorTime; disks = @($disk); network = @($network)
                    }
                } catch {
                    # No exception text: providers can include machine/user-specific data.
                    $row = @{ utc = [DateTime]::UtcNow.ToString('o'); stage = $StageName; sampleUnavailable = $true }
                }
                $row | ConvertTo-Json -Depth 6 -Compress | Add-Content -LiteralPath $SamplePath -Encoding UTF8
                Start-Sleep -Seconds 15
            }
        }
    }
    return $stage
}

function Stop-BuildImageStage {
    param($Stage, [bool] $Succeeded)
    $Stage.Clock.Stop()
    $endUtc = [DateTime]::UtcNow
    if ($null -ne $Stage.Job) {
        Stop-Job -Job $Stage.Job
        Remove-Job -Job $Stage.Job -Force
        if (Test-Path -LiteralPath $Stage.SamplePath) {
            # Also preserve samples in the workflow log without a workflow-package change.
            Get-Content -LiteralPath $Stage.SamplePath | ForEach-Object { Write-Host "[BUILDIMAGE RESOURCE] $_" }
        } else {
            Write-Warning "No resource samples for $($Stage.Name); do not infer resource utilization."
        }
    }
    Write-BuildImageEvidence 'end' @{
        stage = $Stage.Name; startUtc = $Stage.StartUtc.ToString('o'); endUtc = $endUtc.ToString('o')
        elapsedSeconds = [Math]::Round($Stage.Clock.Elapsed.TotalSeconds, 3); succeeded = $Succeeded
    }
}

function Get-BuildImageDockerIdentity {
    param([string] $Image)
    $raw = docker image inspect $Image --format '{{json .}}'
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect Docker image $Image" }
    $item = $raw | ConvertFrom-Json
    # Whitelist image identity; never emit Docker Config/Env or container credentials.
    return @{ image = $Image; id = $item.Id; repoTags = @($item.RepoTags); repoDigests = @($item.RepoDigests); osVersion = $item.OsVersion }
}
