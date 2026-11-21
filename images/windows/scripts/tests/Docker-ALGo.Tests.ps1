################################################################################
##  File:  Docker-ALGo.Tests.ps1
##  Desc:  Docker tests for AL-Go minimal image (without Docker Compose)
################################################################################

Describe "Docker" {
    It "docker is installed" {
        "docker --version" | Should -ReturnZeroExitCode
    }

    It "docker service is up" {
        "docker images" | Should -ReturnZeroExitCode
    }

    It "docker symlink" {
        "C:\Windows\SysWOW64\docker.exe ps" | Should -ReturnZeroExitCode
    }
}

Describe "DockerWinCred" {
    It "docker-wincred" {
        "docker-credential-wincred version" | Should -ReturnZeroExitCode
    }
}

Describe "DockerImages" {
    Context "docker images" {
        $testCases = @((Get-Content 'C:\ProgramData\BcContainerHelper\BcContainerHelper.config.json' -Raw | ConvertFrom-Json).genericImageName) | ForEach-Object { @{ ImageName = $_ } }

        It "<ImageName>" -TestCases $testCases {
            docker image inspect "$ImageName" --format "{{.Id}}" | Should -Match "^sha256:"
            $LASTEXITCODE | Should -Be 0
        }
    }
}
