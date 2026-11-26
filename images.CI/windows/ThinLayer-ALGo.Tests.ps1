################################################################################
##  File:  ThinLayer-ALGo.Tests.ps1
##  Desc:  Offline checks for build-time lever L13 (two-layer build):
##         - the azure-arm source switches to the deploy's gallery definition
##           only when source_gallery_image_version is set (default: marketplace,
##           so the full build is unchanged);
##         - the thin build boots the base and runs only the per-BC part
##           (no Windows Update, no tool installs, no docker pull);
##         - exactly one build is named windows-2022-algo (the workflow's -only);
##         - the new HCL is ASCII-only with balanced braces (PS 5.1 rule).
##  Run:   Invoke-Pester images.CI/windows
################################################################################

BeforeAll {
    $repoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $templateDir = Join-Path $repoRoot 'images\windows\templates'
    $sourcePath  = Join-Path $templateDir 'source.windows.pkr.hcl'
    $varPath     = Join-Path $templateDir 'variable.windows-algo.pkr.hcl'
    $thinPath    = Join-Path $templateDir 'build.windows-2022-algo-bc.pkr.hcl'
    $fullPath    = Join-Path $templateDir 'build.windows-2022-algo.pkr.hcl'
    $source      = Get-Content -LiteralPath $sourcePath -Raw
    $thin        = Get-Content -LiteralPath $thinPath -Raw

    function Get-ScriptOrder([string] $Text) {
        # Script basenames and windows-restart markers in file order.
        [regex]::Matches($Text, '(?m)([A-Za-z0-9-]+\.ps1)|provisioner "windows-restart"') |
            ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { 'RESTART' } }
    }
}

Describe 'L13 source switch' {
    It 'declares source_gallery_image_version with an empty default' {
        $v = Get-Content -LiteralPath $varPath -Raw
        $v | Should -Match '(?s)variable "source_gallery_image_version" \{\s*type\s*=\s*string\s*default\s*=\s*""'
    }

    It 'keeps the marketplace fields only when no gallery version is set' {
        foreach ($f in 'image_publisher', 'image_offer', 'image_sku') {
            $source | Should -Match ("(?m)^\s*$f\s*=\s*var\.source_gallery_image_version == """" \? split\(") -Because "$f must fall back to the marketplace SKU"
        }
        $source | Should -Match '(?m)^\s*image_version\s*=\s*var\.source_gallery_image_version == "" \? var\.source_image_version : ""'
    }

    It 'adds shared_image_gallery only when a gallery version is set, from the deploy gallery vars' {
        $source | Should -Match '(?s)dynamic "shared_image_gallery" \{\s*for_each = var\.source_gallery_image_version == "" \? \[\] : \[var\.source_gallery_image_version\]'
        foreach ($pair in @('subscription\s*=\s*var\.subscription_id', 'resource_group\s*=\s*var\.gallery_resource_group_name', 'gallery_name\s*=\s*var\.gallery_name', 'image_name\s*=\s*var\.gallery_image_name', 'image_version\s*=\s*shared_image_gallery\.value')) {
            $source | Should -Match $pair
        }
    }
}

Describe 'L13 thin build' {
    It 'is a separate build, and exactly one build is named windows-2022-algo' {
        $names = foreach ($f in Get-ChildItem -LiteralPath $templateDir -Filter 'build.windows-2022-algo*.pkr.hcl') {
            [regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw), '(?m)^\s*name\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        }
        @($names | Where-Object { $_ -eq 'windows-2022-algo' }).Count | Should -Be 1 -Because 'the workflow builds -only=windows-2022-algo.azure-arm.image'
        $names | Should -Contain 'windows-2022-algo-bc'
        @($names).Count | Should -Be 2
    }

    It 'fails fast without a base layer version' {
        $thin | Should -Match "if \('\$\{var\.source_gallery_image_version\}' -eq ''\) \{ throw"
    }

    It 'runs the per-BC part in order: image data, bake, smoke, cleanup, tests, sysprep' {
        $order = @(Get-ScriptOrder $thin)
        $want = 'Configure-ImageDataFile.ps1', 'Create-BcImage.ps1', 'Smoke-BcContainer.ps1', 'Invoke-Cleanup.ps1', 'RunAll-ALGo-Tests.ps1', 'Configure-System.ps1', 'Post-Build-Validation.ps1'
        $idx = $want | ForEach-Object { [array]::IndexOf($order, $_) }
        $idx | Should -Not -Contain -1
        ($idx | Sort-Object) -join ',' | Should -Be ($idx -join ',')
        $thin | Should -Match 'Sysprep\.exe /oobe /generalize /mode:vm /quiet /quit'
    }

    It 'installs nothing the base layer owns' {
        foreach ($s in 'Install-WindowsUpdates.ps1', 'Install-WindowsUpdatesAfterReboot-ALGo.ps1', 'Install-Docker-ALGo.ps1', 'Install-PowershellAzModules.ps1', 'Install-DotnetSDK.ps1', 'Invoke-BackgroundDockerPull-ALGo.ps1', 'Install-WindowsFeatures.ps1', 'Install-NativeImages.ps1') {
            $thin | Should -Not -Match ([regex]::Escape($s)) -Because "$s belongs to the base layer"
        }
        $thin | Should -Not -Match 'elevated_user' -Because 'the thin build does not (re)create the install user'
    }

    It 'restores the ImageHelpers profile import before any helper-using script' {
        $iProfile = $thin.IndexOf("'Import-Module ImageHelpers -Force -ErrorAction SilentlyContinue' | Add-Content")
        $iProfile | Should -BeGreaterThan 0
        $iProfile | Should -BeLessThan $thin.IndexOf('Configure-ImageDataFile.ps1')
    }

    It 'expands the payload into a staging folder, never over the base C:\image tree' {
        $thin | Should -Match "\`$p = '\$\{var\.image_folder\}\\\\thin-payload'"
        $thin | Should -Match 'tar\.exe'' -xf ''\$\{var\.image_folder\}\\\\image-payload\.tar'' -C \$p'
    }

    It 'keeps the full build unchanged in its BC-and-tools phases' {
        $full = Get-Content -LiteralPath $fullPath -Raw
        foreach ($s in 'Install-WindowsUpdates.ps1', 'Install-Docker-ALGo.ps1', 'Create-BcImage.ps1', 'Invoke-BackgroundDockerPull-ALGo.ps1') {
            $full | Should -Match ([regex]::Escape($s))
        }
    }
}

Describe 'L13 base-age guard' {
    BeforeAll {
        $guard = Join-Path $repoRoot 'images\windows\scripts\build\Test-BaseLayerAge-ALGo.ps1'
        function Invoke-Guard([string] $Version, [string] $Now, [string] $Max = '') {
            $saved = @{ B = $env:BASE_VERSION; N = $env:ALGO_NOW_UTC; M = $env:MAX_AGE_DAYS }
            try {
                $env:BASE_VERSION = $Version; $env:ALGO_NOW_UTC = $Now; $env:MAX_AGE_DAYS = $Max
                & $guard 6>$null
            } finally { $env:BASE_VERSION = $saved.B; $env:ALGO_NOW_UTC = $saved.N; $env:MAX_AGE_DAYS = $saved.M }
        }
    }

    It 'accepts the spike base the day it was built' {
        { Invoke-Guard '1.20261126.0923' '2026-11-26T10:59Z' } | Should -Not -Throw
    }

    It 'accepts a base 35 days old and refuses one 36 days old' {
        { Invoke-Guard '1.20261126.0923' '2026-12-31T09:23Z' } | Should -Not -Throw
        { Invoke-Guard '1.20261126.0923' '2027-01-01T09:30Z' } | Should -Throw '*days old (limit 35)*'
    }

    It 'honours MAX_AGE_DAYS' {
        { Invoke-Guard '1.20261126.0923' '2026-12-01T10:00Z' '3' } | Should -Throw '*limit 3*'
    }

    It 'fails closed on a version without a date stamp' {
        { Invoke-Guard '' '2026-11-26T10:59Z' } | Should -Throw '*cannot prove its age*'
        { Invoke-Guard 'latest' '2026-11-26T10:59Z' } | Should -Throw '*cannot prove its age*'
        { Invoke-Guard '1.2.3' '2026-11-26T10:59Z' } | Should -Throw '*cannot prove its age*'
    }

    It 'refuses a base dated in the future' {
        { Invoke-Guard '1.20261226.0923' '2026-11-26T10:59Z' } | Should -Throw '*future*'
    }

    It 'runs in the thin build before the payload and the bake, with the 35-day limit' {
        $iGuard = $thin.IndexOf('Test-BaseLayerAge-ALGo.ps1')
        $iGuard | Should -BeGreaterThan 0
        $iGuard | Should -BeLessThan $thin.IndexOf('Pack-ImagePayload-ALGo.ps1')
        $thin | Should -Match '"BASE_VERSION=\$\{var\.source_gallery_image_version\}", "MAX_AGE_DAYS=35"'
    }

    It 'is ASCII-only and parses' {
        $bytes = [IO.File]::ReadAllBytes($guard)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $errs = $null
        [void][Management.Automation.Language.Parser]::ParseFile($guard, [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
    }
}

Describe 'L13 base layer tests (bc_cache_skip=true)' {
    # Base build 45781514526 failed: the BcContainerHelper checks ran although
    # Create-BcImage.ps1 returns before installing it on BC_CACHE_SKIP.
    It 'skips every bake-dependent BcCache check; only generic-image checks run' {
        $bcTests = Join-Path $repoRoot 'images\windows\scripts\tests\BcCache.Tests.ps1'
        $saved = $env:BC_CACHE_SKIP
        try {
            $env:BC_CACHE_SKIP = 'true'
            $cfg = New-PesterConfiguration
            $cfg.Run.Path = $bcTests
            $cfg.Run.SkipRun = $true
            $cfg.Run.PassThru = $true
            $cfg.Output.Verbosity = 'None'
            $found = Invoke-Pester -Configuration $cfg
        } finally { $env:BC_CACHE_SKIP = $saved }
        $all = @($found.Tests)
        $all.Count | Should -BeGreaterThan 0
        $run = @($all | Where-Object { -not $_.Skip } | ForEach-Object { $_.ExpandedPath })
        $run | Should -Not -BeNullOrEmpty -Because 'the generic BC image checks must still run on the base'
        $run | Where-Object { $_ -notmatch 'generic' } | Should -BeNullOrEmpty -Because 'only generic-image checks may run without the bake'
        @($all | Where-Object { $_.ExpandedPath -match 'BcContainerHelper' -and -not $_.Skip }).Count | Should -Be 0
    }
}

Describe 'L13 file hygiene' {
    It '<Name> is ASCII-only with balanced braces' -ForEach @(
        @{ Name = 'build.windows-2022-algo-bc.pkr.hcl' },
        @{ Name = 'source.windows.pkr.hcl' },
        @{ Name = 'variable.windows-algo.pkr.hcl' }
    ) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $templateDir $Name))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $text = [Text.Encoding]::ASCII.GetString($bytes)
        ([regex]::Matches($text, '\{')).Count | Should -Be ([regex]::Matches($text, '\}')).Count
    }
}
