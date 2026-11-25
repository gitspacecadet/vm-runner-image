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
