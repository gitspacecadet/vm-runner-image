################################################################################
##  File:  BackgroundDockerPull-ALGo.Tests.ps1
##  Desc:  Offline checks for build-time lever L12 (background docker pull):
##         - Install-Docker-ALGo.ps1 must equal upstream Install-Docker.ps1 with
##           only the docker.images pull block replaced (drift guard);
##         - the new scripts are ASCII-only and parse under the PS parser;
##         - the ALGo template starts the pull after the last restart before the
##           BC bake, waits before Create-BcImage, with no restart in between.
##  Run:   Invoke-Pester images.CI/windows
################################################################################

BeforeAll {
    $repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $buildDir     = Join-Path $repoRoot 'images\windows\scripts\build'
    $upstreamPath = Join-Path $buildDir 'Install-Docker.ps1'
    $overlayPath  = Join-Path $buildDir 'Install-Docker-ALGo.ps1'
    $pullPath     = Join-Path $buildDir 'Invoke-BackgroundDockerPull-ALGo.ps1'
    $templatePath = Join-Path $repoRoot 'images\windows\templates\build.windows-2022-algo.pkr.hcl'
    $marker       = '# ALGo: docker.images are pulled in the background by Invoke-BackgroundDockerPull-ALGo.ps1'

    function Get-BodyLines([string] $Path) {
        # Drop the leading '#' header block and the blank line after it.
        $lines = @(Get-Content -LiteralPath $Path)
        $i = 0
        while ($i -lt $lines.Count -and $lines[$i].StartsWith('#')) { $i++ }
        while ($i -lt $lines.Count -and $lines[$i].Trim() -eq '') { $i++ }
        return @($lines[$i..($lines.Count - 1)])
    }
}

Describe 'Install-Docker-ALGo overlay' {
    It 'equals upstream Install-Docker.ps1 with only the pull block replaced' {
        $up = Get-BodyLines $upstreamPath
        $start = [array]::IndexOf($up, 'if (-not (Test-IsWin25)) {')
        $start | Should -BeGreaterThan 0 -Because 'upstream pull block anchor moved; re-port the overlay'
        $end = $start + 1
        while ($end -lt $up.Count -and $up[$end] -ne '}') { $end++ }
        ($up[$start..$end] -join "`n") | Should -Match 'docker pull \$dockerImage' -Because 'the block removed must be the pull block'
        $expected = @($up[0..($start - 1)]) + @($marker) + @($up[($end + 1)..($up.Count - 1)])
        $actual = Get-BodyLines $overlayPath
        ($actual -join "`n") | Should -Be ($expected -join "`n")
    }

    It 'does not pull images itself' {
        (Get-Content -Raw -LiteralPath $overlayPath) | Should -Not -Match 'docker pull'
    }
}

Describe 'L12 scripts are PS 5.1 safe' {
    It '<Name> is ASCII-only' -TestCases @(
        @{ Name = 'Install-Docker-ALGo.ps1' }
        @{ Name = 'Invoke-BackgroundDockerPull-ALGo.ps1' }
    ) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $buildDir $Name))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It '<Name> parses with no errors' -TestCases @(
        @{ Name = 'Install-Docker-ALGo.ps1' }
        @{ Name = 'Invoke-BackgroundDockerPull-ALGo.ps1' }
    ) {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $buildDir $Name), [ref] $null, [ref] $errors) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It 'background pull script handles both modes and fails closed on an unknown mode' {
        $text = Get-Content -Raw -LiteralPath $pullPath
        $text | Should -Match "'Start'"
        $text | Should -Match "'Wait'"
        $text | Should -Match 'throw "Unknown PULL_MODE'
        $text | Should -Match 'Invoke-PesterTests -TestFile "Docker" -TestName "DockerImages"'
        $text | Should -Match 'Unregister-ScheduledTask'
    }
}

Describe 'Background pull behaviour (mocked)' {
    BeforeAll {
        # Stubs for image-only helpers and docker, so Mock has commands to replace.
        function global:Get-ToolsetContent { }
        function global:Test-IsWin25 { }
        function global:Invoke-PesterTests { param($TestFile, $TestName) }
        function global:docker { }
    }
    AfterAll {
        Remove-Item Function:\global:Get-ToolsetContent, Function:\global:Test-IsWin25, Function:\global:Invoke-PesterTests, Function:\global:docker -ErrorAction SilentlyContinue
        Remove-Item Env:\PULL_MODE, Env:\PULL_WORK_DIR, Env:\PULL_TIMEOUT_MIN -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $env:PULL_WORK_DIR = Join-Path ([IO.Path]::GetTempPath()) ('bgpull-' + [guid]::NewGuid())
        $env:PULL_TIMEOUT_MIN = '45'
        $global:BgPulled = @()
        Mock Get-ToolsetContent { [pscustomobject]@{ docker = [pscustomobject]@{ images = @('mcr.microsoft.com/businesscentral:ltsc2022') } } }
        Mock Test-IsWin25 { $false }
        Mock Invoke-PesterTests { }
        Mock Start-Sleep { }
        Mock Unregister-ScheduledTask { }
        Mock Stop-ScheduledTask { }
        Mock docker {
            if ($args[0] -eq 'pull') { $global:BgPulled += $args[1]; $global:LASTEXITCODE = 0; return }
            if ($args[0] -eq 'images') { if ($global:BgPulled -contains $args[2]) { 'sha256:abc' } }
        }
    }
    AfterEach {
        Remove-Item -LiteralPath $env:PULL_WORK_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Wait falls back at once when the task is not running and wrote no exit file' {
        $env:PULL_MODE = 'Wait'
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        & $pullPath
        $global:BgPulled | Should -Be @('mcr.microsoft.com/businesscentral:ltsc2022')
        Should -Invoke Start-Sleep -Times 0 -Exactly -ParameterFilter { $Seconds -eq 10 }   # no poll loop
        Should -Invoke Invoke-PesterTests -Times 1 -Exactly -ParameterFilter { $TestName -eq 'DockerImages' }
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly
        Test-Path $env:PULL_WORK_DIR | Should -BeFalse
    }

    It 'Wait does not re-pull when the task finished and the image is present' {
        $env:PULL_MODE = 'Wait'
        New-Item -ItemType Directory -Path $env:PULL_WORK_DIR | Out-Null
        Set-Content -Path (Join-Path $env:PULL_WORK_DIR 'pull.exit') -Value 0
        $global:BgPulled = @('mcr.microsoft.com/businesscentral:ltsc2022')
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        & $pullPath
        $global:BgPulled.Count | Should -Be 1
        Should -Invoke Invoke-PesterTests -Times 1 -Exactly
        Test-Path $env:PULL_WORK_DIR | Should -BeFalse
    }

    It 'Wait throws when the fallback pull fails (never ships without the image)' {
        $env:PULL_MODE = 'Wait'
        Mock Get-ScheduledTask { $null }
        Mock docker { if ($args[0] -eq 'pull') { $global:LASTEXITCODE = 1 } }
        { & $pullPath } | Should -Throw '*Docker pull failed*'
    }

    It 'Start warns instead of failing the build when the task cannot be registered' {
        $env:PULL_MODE = 'Start'
        Mock Register-ScheduledTask { throw 'access denied' }
        Mock Start-ScheduledTask { }
        Mock Get-ScheduledTask { $null }
        { & $pullPath 3>$null } | Should -Not -Throw
        Should -Invoke Start-ScheduledTask -Times 0 -Exactly
    }

    It 'fails closed on an unknown PULL_MODE' {
        $env:PULL_MODE = 'Bogus'
        { & $pullPath } | Should -Throw '*Unknown PULL_MODE*'
    }
}

Describe 'ALGo template wiring' {
    BeforeAll {
        $tpl = Get-Content -Raw -LiteralPath $templatePath
        $iStart   = $tpl.IndexOf('PULL_MODE=Start')
        $iWait    = $tpl.IndexOf('PULL_MODE=Wait')
        $iBc      = $tpl.IndexOf('/scripts/build/Create-BcImage.ps1')
        $iAz      = $tpl.IndexOf('/scripts/build/Install-PowershellAzModules.ps1')
        $iChoco   = $tpl.IndexOf('/scripts/build/Install-ChocolateyPackages.ps1')
    }

    It 'uses the overlay, not upstream Install-Docker.ps1' {
        $tpl | Should -Match '/scripts/build/Install-Docker-ALGo\.ps1'
        $tpl | Should -Not -Match '/scripts/build/Install-Docker\.ps1'
    }

    It 'starts the pull after the Chocolatey phase and before the Az modules' {
        $iStart | Should -BeGreaterThan $iChoco
        $iStart | Should -BeLessThan $iAz
    }

    It 'waits for the pull before Create-BcImage' {
        $iWait | Should -BeGreaterThan $iStart
        $iWait | Should -BeLessThan $iBc
    }

    It 'has no windows-restart between Start and Wait (a restart kills the pull)' {
        $tpl.Substring($iStart, $iWait - $iStart) | Should -Not -Match 'windows-restart'
    }
}
