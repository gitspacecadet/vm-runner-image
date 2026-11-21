BeforeAll {
    $script:helpers = (Resolve-Path "$PSScriptRoot/../../images/windows/scripts/helpers").Path
    . "$script:helpers/BcPolicy-ALGo.ps1"
    $script:setPolicy = "$PSScriptRoot/../../images/windows/scripts/build/Set-BcPolicy-ALGo.ps1"
    $script:digest = 'mcr.microsoft.com/businesscentral@sha256:' + ('a' * 64)
    function Get-ToolsetContent { }
}

Describe 'AL-Go process compatibility policy' {
    It 'supports host <HostBuild> and base <BaseBuild> despite different revisions' -TestCases @(
        @{ HostBuild = 20348; BaseBuild = 20348 },
        @{ HostBuild = 26100; BaseBuild = 20348 },
        @{ HostBuild = 26100; BaseBuild = 26100 }
    ) {
        param($HostBuild, $BaseBuild)
        { Assert-ALGoContainerCompatibility "10.0.$HostBuild.123" "10.0.$BaseBuild.456" } | Should -Not -Throw
    }
    It 'rejects unsupported host <HostBuild> and base <BaseBuild>' -TestCases @(
        @{ HostBuild = 20348; BaseBuild = 26100 },
        @{ HostBuild = 26100; BaseBuild = 17763 },
        @{ HostBuild = 17763; BaseBuild = 20348 },
        @{ HostBuild = 99999; BaseBuild = 26100 }
    ) {
        param($HostBuild, $BaseBuild)
        { Assert-ALGoContainerCompatibility "10.0.$HostBuild.1" "10.0.$BaseBuild.1" } | Should -Throw '*Unsupported*'
    }
    It 'rejects mutable, malformed and non-MCR references: <Image>' -TestCases @(
        @{ Image = 'mcr.microsoft.com/businesscentral:ltsc2022' },
        @{ Image = 'mcr.microsoft.com/businesscentral@sha256:abc' },
        @{ Image = 'example.invalid/businesscentral@sha256:' + ('a' * 64) },
        @{ Image = '' }
    ) {
        param($Image)
        { Get-ALGoBcPolicy $Image } | Should -Throw '*immutable*'
    }
    It 'sets an immutable generic and process default without credentials or compiler optimizations' {
        $policy = Get-ALGoBcPolicy $digest
        $policy.genericImageName | Should -BeExactly $digest
        $policy.defaultNewContainerParameters.isolation | Should -BeExactly 'process'
        @($policy.Keys).Count | Should -Be 2
        @($policy.defaultNewContainerParameters.Keys).Count | Should -Be 1
    }
}

Describe 'Persisted helper policy' {
    BeforeEach {
        $script:savedGeneric = $env:BC_GENERIC_IMAGE
        $env:BC_GENERIC_IMAGE = ''
        Mock Get-Module { [pscustomobject]@{ ModuleBase = (Resolve-Path './images/windows/scripts/helpers').Path } } -ParameterFilter { $Name -eq 'ImageHelpers' }
        Mock Get-ToolsetContent { @{ docker = @{ images = @('mcr.microsoft.com/businesscentral@sha256:' + ('a' * 64)) } } }
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }
    AfterEach { $env:BC_GENERIC_IMAGE = $script:savedGeneric }
    It 'persists the control digest and process mode in the helper acquisition-independent path' {
        & $setPolicy -HelperDirectory $folder
        $config = Get-Content (Join-Path $folder 'BcContainerHelper.config.json') -Raw | ConvertFrom-Json
        $config.genericImageName | Should -BeExactly $digest
        $config.defaultNewContainerParameters.isolation | Should -BeExactly 'process'
    }
    It 'uses the explicit treatment digest consistently instead of the toolset default' {
        $env:BC_GENERIC_IMAGE = 'mcr.microsoft.com/businesscentral@sha256:' + ('b' * 64)
        & $setPolicy -HelperDirectory $folder
        $config = Get-Content (Join-Path $folder 'BcContainerHelper.config.json') -Raw | ConvertFrom-Json
        $config.genericImageName | Should -BeExactly $env:BC_GENERIC_IMAGE
    }
    It 'fails before writing when a mutable override is requested' {
        $env:BC_GENERIC_IMAGE = 'mcr.microsoft.com/businesscentral:ltsc2025'
        { & $setPolicy -HelperDirectory $folder } | Should -Throw '*immutable*'
        Test-Path (Join-Path $folder 'BcContainerHelper.config.json') | Should -BeFalse
    }
    It 'does not overwrite an existing operator policy' {
        New-Item -ItemType Directory $folder | Out-Null
        $path = Join-Path $folder 'BcContainerHelper.config.json'
        '{"operator":"owned"}' | Set-Content $path
        { & $setPolicy -HelperDirectory $folder } | Should -Throw '*pre-existing*'
        (Get-Content $path -Raw).Trim() | Should -BeExactly '{"operator":"owned"}'
    }
}
