################################################################################
# BcCache.Tests.ps1
# Pester tests to validate Business Central cache was created correctly
#
# BC_CACHE_SKIP=true (Packer var bc_cache_skip) opts out of the my: bake and
# the smoke container, so the cache dir, metadata and my: image never exist.
# Those checks are skipped in that case. The generic BC image (toolset
# docker.images) and BcContainerHelper are installed either way, so their
# checks always run. Truthy values match Create-BcImage.ps1 /
# Smoke-BcContainer.ps1 exactly.
################################################################################

BeforeDiscovery {
    $bcCacheSkip = [bool]($env:BC_CACHE_SKIP -and $env:BC_CACHE_SKIP.ToString().ToLower() -in @('1','true','yes','y'))
}

Describe "Business Central Cache" {
    BeforeAll {
        $cacheDir = "C:\bcartifacts.cache"
        $metadataPath = Join-Path $cacheDir "bc-cache-metadata.json"
    }

    Context "Cache Directory" -Skip:$bcCacheSkip {
        It "Cache directory exists" {
            Test-Path $cacheDir | Should -BeTrue
        }

        It "Cache directory is not empty" {
            (Get-ChildItem $cacheDir -Recurse | Measure-Object).Count | Should -BeGreaterThan 0
        }
    }

    Context "Metadata File" -Skip:$bcCacheSkip {
        It "Metadata file exists" {
            Test-Path $metadataPath | Should -BeTrue
        }

        It "Metadata file is valid JSON" {
            { Get-Content $metadataPath -Raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It "Metadata contains required fields" {
            $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
            $metadata.timestampUtc | Should -Not -BeNullOrEmpty
            $metadata.artifactUrl | Should -Not -BeNullOrEmpty
            $metadata.genericImage | Should -Not -BeNullOrEmpty
            $metadata.dockerImage | Should -Not -BeNullOrEmpty
        }
    }

    Context "Docker Images" {
        It "Generic BC image is present" {
            $images = docker images --format "{{.Repository}}:{{.Tag}}"
            $bcImages = $images | Where-Object { $_ -match "businesscentral" }
            $bcImages | Should -Not -BeNullOrEmpty
        }

        It "Custom BC image with 'my' prefix exists" -Skip:$bcCacheSkip {
            $images = docker images --format "{{.Repository}}"
            $myImages = $images | Where-Object { $_ -eq "my" }
            $myImages | Should -Not -BeNullOrEmpty
        }
    }

    Context "BcContainerHelper Module" {
        It "BcContainerHelper module is installed" {
            Get-Module -ListAvailable -Name BcContainerHelper | Should -Not -BeNullOrEmpty
        }

        It "BcContainerHelper module can be imported" {
            { Import-Module BcContainerHelper -Force -ErrorAction Stop } | Should -Not -Throw
        }
    }
}
