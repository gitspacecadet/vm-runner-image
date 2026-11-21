BeforeAll {
    $script:helpers = (Resolve-Path "$PSScriptRoot/../../images/windows/scripts/helpers").Path
    . "$script:helpers/BuildImageTelemetry-ALGo.ps1"
    $script:gate = "$PSScriptRoot/../../images/windows/scripts/build/Test-BcPreservation-ALGo.ps1"
    function docker { }
    function Get-BcContainerArtifactUrl { }
    # Exercise the gate's assertions without sleeping, Docker, BC or module installs.
    function Invoke-ScriptBlockWithRetry { param($Command, $RetryCount, $RetryIntervalSeconds) & $Command }
}

Describe 'BuildImage durable telemetry' {
    BeforeEach {
        $script:originalProgramData = $env:ProgramData
        $env:ProgramData = $TestDrive
    }
    AfterEach { $env:ProgramData = $script:originalProgramData }

    It 'records UTC start/end, elapsed time and failure without swallowing the action error' {
        $stage = Start-BuildImageStage 'offline-failure'
        try { throw 'action failure' } catch { $caught = $_.Exception.Message } finally {
            Stop-BuildImageStage -Stage $stage -Succeeded $false
        }
        $rows = @(Get-Content "$TestDrive/BuildImageEvidence/stages.jsonl" | ConvertFrom-Json)
        $rows[-1].data.succeeded | Should -BeFalse
        # PS 7.5+ converts JSON ISO strings to DateTime; check the wire format.
        $wire = Get-Content "$TestDrive/BuildImageEvidence/stages.jsonl" -Raw
        $wire | Should -Match '"startUtc":"[^"]+Z"'
        $wire | Should -Match '"endUtc":"[^"]+Z"'
        $rows[-1].data.elapsedSeconds | Should -BeGreaterOrEqual 0
        $caught | Should -Be 'action failure'
    }

    It 'whitelists Docker identity and excludes Config credentials' {
        Mock docker {
            $global:LASTEXITCODE = 0
            '{"Id":"sha256:baked","RepoTags":["my:example"],"RepoDigests":[],"OsVersion":"10.0.20348.1","Config":{"Env":["password=DO-NOT-LOG"]}}'
        }
        $identity = Get-BuildImageDockerIdentity 'my:example'
        $identity.id | Should -Be 'sha256:baked'
        ($identity | ConvertTo-Json) | Should -Not -Match 'DO-NOT-LOG|Config|password'
    }

    It 'fails image identity inspection when Docker fails' {
        Mock docker { $global:LASTEXITCODE = 1 }
        { Get-BuildImageDockerIdentity 'my:missing' } | Should -Throw '*Cannot inspect*'
    }
}

Describe 'BC final reboot preservation gate' {
    BeforeEach {
        $script:originalProgramData = $env:ProgramData
        $script:originalSkip = $env:BC_CACHE_SKIP
        $env:ProgramData = $TestDrive
        $env:BC_CACHE_SKIP = 'false'
        $script:cache = Join-Path $TestDrive 'bc-cache'
        New-Item -Path $script:cache -ItemType Directory -Force | Out-Null
        '{"dockerImage":"my:example","dockerImageId":"sha256:baked","artifactUrl":"https://example.invalid/sandbox/1/us"}' |
            Set-Content "$script:cache/bc-cache-metadata.json"
        '{"enabled":true,"containerName":"bcsmoke","imageName":"my:example"}' |
            Set-Content "$script:cache/keep-container-marker.json"
        $global:BuildImageTestState = @{
            Running = $true; Health = 'healthy'; Restart = 'unless-stopped'
            ContainerImage = 'sha256:baked'; Nst = '1'; Artifact = 'https://example.invalid/sandbox/1/us'
        }
        Mock Import-Module { }
        Mock Get-Module { [pscustomobject]@{ ModuleBase = (Resolve-Path './images/windows/scripts/helpers').Path } } -ParameterFilter { $Name -eq 'ImageHelpers' }
        Mock Get-BcContainerArtifactUrl { $global:BuildImageTestState.Artifact }
        Mock docker {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'image') {
                '{"Id":"sha256:baked","RepoTags":["my:example"],"RepoDigests":[],"OsVersion":"10.0.20348.1"}'
            } elseif ($args[0] -eq 'inspect') {
                @{ Image = $global:BuildImageTestState.ContainerImage; State = @{ Running = $global:BuildImageTestState.Running; Health = @{ Status = $global:BuildImageTestState.Health } }
                    HostConfig = @{ RestartPolicy = @{ Name = $global:BuildImageTestState.Restart } } } | ConvertTo-Json -Depth 5 -Compress
            } elseif ($args[0] -eq 'exec') { $global:BuildImageTestState.Nst }
            else { throw "Unexpected mutating Docker command: $($args -join ' ')" }
        }
    }
    AfterEach {
        $env:ProgramData = $script:originalProgramData
        $env:BC_CACHE_SKIP = $script:originalSkip
        Remove-Variable -Name BuildImageTestState -Scope Global
    }

    It 'accepts a kept, healthy container with BC service and matching artifact after reboot' {
        & $script:gate -CacheDir $script:cache
        Should -Invoke docker -Times 3 -Exactly
        Should -Invoke Get-BcContainerArtifactUrl -Times 1 -Exactly
    }
    It 'rejects a stopped container' {
        $global:BuildImageTestState.Running = $false
        { & $script:gate -CacheDir $script:cache } | Should -Throw '*not running*'
    }
    It 'rejects unhealthy Docker state' {
        $global:BuildImageTestState.Health = 'unhealthy'
        { & $script:gate -CacheDir $script:cache } | Should -Throw '*acceptable health*'
    }
    It 'rejects a missing BC service tier' {
        $global:BuildImageTestState.Nst = '0'
        { & $script:gate -CacheDir $script:cache } | Should -Throw '*service tier*'
    }
    It 'rejects changed artifact metadata' {
        $global:BuildImageTestState.Artifact = 'https://example.invalid/sandbox/2/us'
        { & $script:gate -CacheDir $script:cache } | Should -Throw '*metadata unavailable or changed*'
    }
    It 'rejects an image mismatch' {
        $global:BuildImageTestState.ContainerImage = 'sha256:other'
        { & $script:gate -CacheDir $script:cache } | Should -Throw '*image or restart policy*'
    }
    It 'rejects a changed restart policy' {
        $global:BuildImageTestState.Restart = 'no'
        { & $script:gate -CacheDir $script:cache } | Should -Throw '*image or restart policy*'
    }
    It 'rejects a missing keep marker' {
        Remove-Item "$script:cache/keep-container-marker.json"
        { & $script:gate -CacheDir $script:cache } | Should -Throw
    }
    It 'honors the existing opt-out without touching Docker' {
        $env:BC_CACHE_SKIP = 'true'
        & $script:gate -CacheDir $script:cache
        Should -Invoke docker -Times 0 -Exactly
    }
}
