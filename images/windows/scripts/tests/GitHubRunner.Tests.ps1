################################################################################
##  File:  GitHubRunner.Tests.ps1
##  Desc:  Pester tests for GitHub Actions Runner pre-installation
################################################################################

Describe "GitHub Actions Runner" {
    BeforeAll {
        $runnerPath = "C:\ProgramData\runner"
    }

    It "Runner directory exists" {
        $runnerPath | Should -Exist
    }

    It "config.cmd exists" {
        Join-Path $runnerPath "config.cmd" | Should -Exist
    }

    It "run.cmd exists" {
        Join-Path $runnerPath "run.cmd" | Should -Exist
    }

    It "Runner.Listener.exe exists" {
        Join-Path $runnerPath "Runner.Listener.exe" | Should -Exist
    }

    It "bin directory exists" {
        Join-Path $runnerPath "bin" | Should -Exist
    }

    It "externals directory exists" {
        Join-Path $runnerPath "externals" | Should -Exist
    }

    It "runner-metadata.json exists" {
        Join-Path $runnerPath "runner-metadata.json" | Should -Exist
    }

    It "runner-metadata.json contains version" {
        $metadataPath = Join-Path $runnerPath "runner-metadata.json"
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        $metadata.Version | Should -Not -BeNullOrEmpty
    }

    It "runner-metadata.json contains install date" {
        $metadataPath = Join-Path $runnerPath "runner-metadata.json"
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        $metadata.InstallDate | Should -Not -BeNullOrEmpty
    }

    It "Runner directory contains required binaries" {
        $requiredFiles = @(
            "Runner.Listener.exe",
            "Runner.Worker.exe",
            "Runner.PluginHost.exe"
        )

        foreach ($file in $requiredFiles) {
            $filePath = Join-Path $runnerPath $file
            $filePath | Should -Exist
        }
    }
}
