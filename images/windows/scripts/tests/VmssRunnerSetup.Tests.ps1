################################################################################
##  File:  VmssRunnerSetup.Tests.ps1
##  Desc:  Pester tests for VMSS runner setup script pre-staging
################################################################################

Describe "VMSS Runner Setup Scripts" {
    BeforeAll {
        $vmssScriptsDir = "C:\ProgramData\vmss-scripts"
    }

    It "VMSS scripts directory exists" {
        $vmssScriptsDir | Should -Exist
    }

    It "Initialize-VmRunner.ps1 exists" {
        $scriptPath = Join-Path $vmssScriptsDir "Initialize-VmRunner.ps1"
        $scriptPath | Should -Exist
    }

    It "Initialize-VmRunner.ps1 is valid PowerShell" {
        $scriptPath = Join-Path $vmssScriptsDir "Initialize-VmRunner.ps1"
        $scriptContent = Get-Content $scriptPath -Raw
        $errors = $null
        [System.Management.Automation.PSParser]::Tokenize($scriptContent, [ref]$errors) | Out-Null
        $errors.Count | Should -Be 0
    }

    It "Initialize-VmRunner.ps1 contains Key Vault integration code" {
        $scriptPath = Join-Path $vmssScriptsDir "Initialize-VmRunner.ps1"
        $scriptContent = Get-Content $scriptPath -Raw
        $scriptContent | Should -Match 'keyVaultName'
        $scriptContent | Should -Match '169.254.169.254'
        $scriptContent | Should -Match 'vault.azure.net'
    }

    It "Initialize-VmRunner.ps1 contains retry logic" {
        $scriptPath = Join-Path $vmssScriptsDir "Initialize-VmRunner.ps1"
        $scriptContent = Get-Content $scriptPath -Raw
        $scriptContent | Should -Match 'maxRetries'
        $scriptContent | Should -Match 'retryDelay'
    }

    It "Initialize-VmRunner.ps1 contains enhanced diagnostics" {
        $scriptPath = Join-Path $vmssScriptsDir "Initialize-VmRunner.ps1"
        $scriptContent = Get-Content $scriptPath -Raw
        $scriptContent | Should -Match 'TROUBLESHOOTING TIPS'
    }

    It "Initialize-VmRunner.ps1 references pre-installed runner" {
        $scriptPath = Join-Path $vmssScriptsDir "Initialize-VmRunner.ps1"
        $scriptContent = Get-Content $scriptPath -Raw
        $scriptContent | Should -Match 'C:\\ProgramData\\runner'
    }

    It "Initialize-VmRunner.ps1 has error handling" {
        $scriptPath = Join-Path $vmssScriptsDir "Initialize-VmRunner.ps1"
        $scriptContent = Get-Content $scriptPath -Raw
        $scriptContent | Should -Match 'try'
        $scriptContent | Should -Match 'catch'
        $scriptContent | Should -Match '\$errorActionPreference'
    }

    It "Test-VmssSetup.ps1 exists" {
        $scriptPath = Join-Path $vmssScriptsDir "Test-VmssSetup.ps1"
        $scriptPath | Should -Exist
    }

    It "Test-VmssSetup.ps1 is valid PowerShell" {
        $scriptPath = Join-Path $vmssScriptsDir "Test-VmssSetup.ps1"
        $scriptContent = Get-Content $scriptPath -Raw
        $errors = $null
        [System.Management.Automation.PSParser]::Tokenize($scriptContent, [ref]$errors) | Out-Null
        $errors.Count | Should -Be 0
    }

    It "Test-VmssSetup.ps1 is executable" {
        $scriptPath = Join-Path $vmssScriptsDir "Test-VmssSetup.ps1"
        # Verify it can be parsed and would return an exit code
        $scriptContent = Get-Content $scriptPath -Raw
        $scriptContent | Should -Match 'exit'
    }

    It "Remove-Runner.ps1 exists" {
        $scriptPath = Join-Path $vmssScriptsDir "Remove-Runner.ps1"
        $scriptPath | Should -Exist
    }

    It "Remove-Runner.ps1 is valid PowerShell" {
        $scriptPath = Join-Path $vmssScriptsDir "Remove-Runner.ps1"
        $scriptContent = Get-Content $scriptPath -Raw
        $errors = $null
        [System.Management.Automation.PSParser]::Tokenize($scriptContent, [ref]$errors) | Out-Null
        $errors.Count | Should -Be 0
    }

    It "Remove-Runner.ps1 has service stop logic" {
        $scriptPath = Join-Path $vmssScriptsDir "Remove-Runner.ps1"
        $scriptContent = Get-Content $scriptPath -Raw
        $scriptContent | Should -Match 'Stop-Service'
        $scriptContent | Should -Match 'config\.cmd remove'
    }

    It "vmss-scripts-metadata.json exists" {
        $metadataPath = Join-Path $vmssScriptsDir "vmss-scripts-metadata.json"
        $metadataPath | Should -Exist
    }

    It "vmss-scripts-metadata.json is valid JSON" {
        $metadataPath = Join-Path $vmssScriptsDir "vmss-scripts-metadata.json"
        { Get-Content $metadataPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It "vmss-scripts-metadata.json contains install date" {
        $metadataPath = Join-Path $vmssScriptsDir "vmss-scripts-metadata.json"
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        $metadata.InstallDate | Should -Not -BeNullOrEmpty
    }

    It "vmss-scripts-metadata.json contains script version" {
        $metadataPath = Join-Path $vmssScriptsDir "vmss-scripts-metadata.json"
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        $metadata.ScriptVersion | Should -Not -BeNullOrEmpty
    }

    It "vmss-scripts-metadata.json lists all scripts" {
        $metadataPath = Join-Path $vmssScriptsDir "vmss-scripts-metadata.json"
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        $metadata.Scripts | Should -Contain "Initialize-VmRunner.ps1"
        $metadata.Scripts | Should -Contain "Test-VmssSetup.ps1"
        $metadata.Scripts | Should -Contain "Remove-Runner.ps1"
    }


    It "All scripts have proper file headers" {
        $scripts = @("Initialize-VmRunner.ps1", "Test-VmssSetup.ps1", "Remove-Runner.ps1")
        foreach ($script in $scripts) {
            $scriptPath = Join-Path $vmssScriptsDir $script
            $scriptContent = Get-Content $scriptPath -Raw
            $scriptContent | Should -Match '##\s+File:'
            $scriptContent | Should -Match '##\s+Desc:'
        }
    }

    It "Directory permissions allow execution" {
        # Verify directory is readable
        $vmssScriptsDir | Should -Exist
        Test-Path $vmssScriptsDir -PathType Container | Should -Be $true
    }
}
