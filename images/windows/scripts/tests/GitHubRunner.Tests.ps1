################################################################################
##  File:  GitHubRunner.Tests.ps1
##  Desc:  Pester tests for GitHub Actions Runner ZIP download
##
##  NOTE: This tests that the ZIP was downloaded, NOT extracted.
##  Extraction happens at VMSS runtime, not during image build.
################################################################################

Describe "GitHub Actions Runner ZIP" {
    BeforeAll {
        $runnerPath = "C:\ProgramData\runner"
        $metadataPath = Join-Path $runnerPath "runner-metadata.json"
        if (-not (Test-Path $metadataPath)) {
            throw "Runner metadata not found at $metadataPath — Install-GitHubRunner.ps1 did not complete."
        }
        $runnerVersion = (Get-Content -Path $metadataPath -Raw | ConvertFrom-Json).Version
        if ([string]::IsNullOrWhiteSpace($runnerVersion)) {
            throw "Version field missing or empty in $metadataPath."
        }
        $expectedZipName = "actions-runner-win-x64-$runnerVersion.zip"
    }

    It "Runner directory exists" {
        $runnerPath | Should -Exist
    }

    It "Runner ZIP file exists" {
        $zipPath = Join-Path $runnerPath $expectedZipName
        $zipPath | Should -Exist
    }

    It "Runner ZIP file is not empty" {
        $zipPath = Join-Path $runnerPath $expectedZipName
        $fileSize = (Get-Item $zipPath).Length
        $fileSize | Should -BeGreaterThan 1MB
    }

    It "runner-metadata.json exists" {
        Join-Path $runnerPath "runner-metadata.json" | Should -Exist
    }

    It "runner-metadata.json contains version" {
        $metadataPath = Join-Path $runnerPath "runner-metadata.json"
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        $metadata.Version | Should -Be $runnerVersion
    }

    It "runner-metadata.json indicates runtime extraction" {
        $metadataPath = Join-Path $runnerPath "runner-metadata.json"
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        $metadata.ExtractionMethod | Should -Match "Runtime"
    }

    It "Runner ZIP contains expected files" {
        $zipPath = Join-Path $runnerPath $expectedZipName
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)

        $hasConfigCmd = $false
        $hasRunCmd = $false
        $hasListener = $false

        foreach ($entry in $zip.Entries) {
            if ($entry.Name -eq "config.cmd") { $hasConfigCmd = $true }
            if ($entry.Name -eq "run.cmd") { $hasRunCmd = $true }
            if ($entry.Name -eq "Runner.Listener.exe") { $hasListener = $true }
        }

        $zip.Dispose()

        $hasConfigCmd | Should -Be $true
        $hasRunCmd | Should -Be $true
        $hasListener | Should -Be $true
    }
}
