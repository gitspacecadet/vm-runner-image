BeforeAll {
    $script:sysprep = "$PSScriptRoot/../../images/windows/scripts/build/Invoke-Sysprep-ALGo.ps1"
}
Describe 'Bounded Sysprep failure propagation without running Sysprep' {
    BeforeEach {
        $script:savedProgramData = $env:ProgramData
        $env:ProgramData = $TestDrive
        $global:PrototypeSysprepTest = @{ Complete = $true; ExitCode = 0; WaitMilliseconds = 0 }
        Mock Import-Module { }
        Mock Get-Module { [pscustomobject]@{ ModuleBase = (Resolve-Path './images/windows/scripts/helpers').Path } } -ParameterFilter { $Name -eq 'ImageHelpers' }
        Mock Test-Path { $false }
        Mock Remove-Item { throw 'Unexpected filesystem removal in Sysprep test' }
        Mock Copy-Item { }
        Mock Compress-Archive { }
        Mock Get-ItemProperty { [pscustomobject]@{ ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' } }
        Mock Start-Process {
            $process = [pscustomobject]@{ ExitCode = $global:PrototypeSysprepTest.ExitCode }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
                param($milliseconds)
                $global:PrototypeSysprepTest.WaitMilliseconds = $milliseconds
                return $global:PrototypeSysprepTest.Complete
            }
            return $process
        }
    }
    AfterEach {
        $env:ProgramData = $script:savedProgramData
        Remove-Variable PrototypeSysprepTest -Scope Global
    }
    It 'requires successful process completion and the generalized state' {
        & $sysprep
        $global:PrototypeSysprepTest.WaitMilliseconds | Should -Be 900000
        Should -Invoke Start-Process -Exactly -Times 1 -ParameterFilter { $WindowStyle -eq 'Hidden' -and $ArgumentList -contains '/generalize' -and $ArgumentList -contains '/quit' }
        Should -Invoke Compress-Archive -Exactly -Times 1
    }
    It 'fails instead of capturing after process timeout and records failed-stage evidence' {
        $global:PrototypeSysprepTest.Complete = $false
        { & $sysprep } | Should -Throw '*exceeded 15 minutes*'
        $rows = @(Get-Content "$TestDrive/BuildImageEvidence/stages.jsonl" | ConvertFrom-Json)
        $rows[-1].data.succeeded | Should -BeFalse
        Should -Invoke Get-ItemProperty -Exactly -Times 0
    }
    It 'fails instead of capturing after a nonzero Sysprep exit' {
        $global:PrototypeSysprepTest.ExitCode = 5
        { & $sysprep } | Should -Throw '*exit 5*'
        Should -Invoke Get-ItemProperty -Exactly -Times 0
        Should -Invoke Compress-Archive -Exactly -Times 1
    }
}
