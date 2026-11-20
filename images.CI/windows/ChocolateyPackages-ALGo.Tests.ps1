BeforeAll {
    . "$PSScriptRoot/../../images/windows/scripts/build/Install-ChocolateyPackages-ALGo.ps1"
    # No Chocolatey installation or network is needed for these tests.
    function choco { }
}

Describe 'ALGo Chocolatey backoff' {
    BeforeEach {
        $script:installs = 0
        $script:succeedOn = 1
        $script:calls = [Collections.Generic.List[string]]::new()
        $script:delays = [Collections.Generic.List[int]]::new()
        Mock choco {
            # Native commands omit a null splatted ArgumentList; PS mocks retain it.
            $script:calls.Add((($args | Where-Object { $null -ne $_ }) -join ' '))
            if ($args[0] -eq 'install') {
                $script:installs++
            } elseif ($args[0] -eq 'list' -and $script:installs -ge $script:succeedOn) {
                'example|1.2.3'
            }
        }
        $script:sleep = { param($Seconds) $script:delays.Add($Seconds) }
    }

    It 'succeeds on attempt 1 without sleeping and preserves the unpinned command' {
        Install-ChocoPackageALGo example -Sleep $script:sleep
        $script:installs | Should -Be 1
        $script:delays.Count | Should -Be 0
        $script:calls[0] | Should -Be 'install example -y --no-progress --require-checksums'
        $script:calls[1] | Should -Be 'list --localonly example --exact --all --limitoutput'
    }

    It 'succeeds on attempt 4 with only the first three delays' {
        $script:succeedOn = 4
        Install-ChocoPackageALGo example -Sleep $script:sleep
        $script:installs | Should -Be 4
        ($script:delays -join ',') | Should -Be '30,60,120'
        $script:calls.Count | Should -Be 8
    }

    It 'throws after exactly 6 attempts and records all five delays' {
        $script:succeedOn = 7
        { Install-ChocoPackageALGo example -Sleep $script:sleep } |
            Should -Throw 'Could not install example after 6 attempts'
        $script:installs | Should -Be 6
        ($script:delays -join ',') | Should -Be '30,60,120,240,480'
        $script:calls.Count | Should -Be 12
    }

    It 'allows success on the last attempt' {
        $script:succeedOn = 6
        Install-ChocoPackageALGo example -Sleep $script:sleep
        $script:installs | Should -Be 6
        ($script:delays -join ',') | Should -Be '30,60,120,240,480'
    }

    It 'preserves version and argument array handling' {
        Install-ChocoPackageALGo example -Version '1.2.3' -ArgumentList @('--force', '--params=some value') -Sleep $script:sleep
        $script:calls[0] | Should -Be 'install example --version 1.2.3 -y --force --params=some value --no-progress --require-checksums'
        $script:installs | Should -Be 1
        $script:delays.Count | Should -Be 0
    }
}
