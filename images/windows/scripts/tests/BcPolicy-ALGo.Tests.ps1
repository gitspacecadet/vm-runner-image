BeforeDiscovery {
    $bcCacheSkip = [bool]($env:BC_CACHE_SKIP -and $env:BC_CACHE_SKIP.ToLower() -in @('1','true','yes','y'))
}
Describe 'AL-Go immutable base and process policy' {
    BeforeAll {
        Import-Module ImageHelpers -ErrorAction Stop
        . (Join-Path (Get-Module ImageHelpers).ModuleBase 'BcPolicy-ALGo.ps1')
        $script:policy = Get-Content 'C:\ProgramData\BcContainerHelper\BcContainerHelper.config.json' -Raw | ConvertFrom-Json
    }
    It 'selects the intended generic in the actual imported helper' {
        Import-Module BcContainerHelper -Force -ErrorAction Stop
        (Get-BestGenericImageName) | Should -Be $policy.genericImageName
        $bcContainerHelperConfig.defaultNewContainerParameters.isolation | Should -Be 'process'
    }
    It 'uses a supported host/container pair and exact generic digest' {
        $raw = docker image inspect $policy.genericImageName --format '{{json .}}'
        $LASTEXITCODE | Should -Be 0
        $image = $raw | ConvertFrom-Json
        $image.RepoDigests | Should -Contain $policy.genericImageName
        $hostVersion = [version](Get-CimInstance Win32_OperatingSystem).Version
        { Assert-ALGoContainerCompatibility $hostVersion ([version]$image.OsVersion) } | Should -Not -Throw
    }
    It 'retains the policy, exact baked image and process-isolated smoke' -Skip:$bcCacheSkip {
        $metadata = Get-Content 'C:\bcartifacts.cache\bc-cache-metadata.json' -Raw | ConvertFrom-Json
        $metadata.genericImage | Should -Be $policy.genericImageName
        $raw = docker inspect bcsmoke --format '{{json .}}'
        $LASTEXITCODE | Should -Be 0
        $container = $raw | ConvertFrom-Json
        $container.HostConfig.Isolation | Should -Be 'process'
        $container.Image | Should -Be $metadata.dockerImageId
    }
}

Describe 'AL-Go host runtime inventory' {
    It 'has all requested .NET SDK channels' {
        $sdks = dotnet --list-sdks
        $LASTEXITCODE | Should -Be 0
        foreach ($channel in (Get-ToolsetContent).dotnet.versions) {
            @($sdks | Where-Object { $_ -match ('^' + [regex]::Escape($channel) + '\.') }).Count | Should -BeGreaterThan 0
        }
    }
    It 'runs the requested PowerShell Core family' {
        $version = pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
        $LASTEXITCODE | Should -Be 0
        $version | Should -Match ('^' + [regex]::Escape((Get-ToolsetContent).pwsh.version) + '\.')
    }
}
