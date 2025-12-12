################################################################################
# Generate-SoftwareReport-ALGo.ps1
#
# Minimal software report generator for AL-Go runner images.
# Unlike the full Generate-SoftwareReport.ps1, this only reports on tools
# that are actually installed in our minimal AL-Go toolset.
#
# This avoids errors like:
# - "go: command not found" since Go isn't installed
# - "Cannot find path 'C:\Modules'" since we don't install Azure modules there
################################################################################

using module ./software-report-base/SoftwareReport.psm1
using module ./software-report-base/SoftwareReport.Nodes.psm1

$global:ErrorActionPreference = "Stop"
$global:ProgressPreference = "SilentlyContinue"
$ErrorView = "NormalView"
Set-StrictMode -Version Latest

# Only import modules we actually need
Import-Module (Join-Path $PSScriptRoot "SoftwareReport.Common.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "SoftwareReport.Helpers.psm1") -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "SoftwareReport.Tools.psm1") -DisableNameChecking

################################################################################
# AL-Go specific helper function for PowerShell modules
# This avoids calling Get-PowerShellModules which expects C:\Modules to exist
################################################################################
function Get-ALGoPowerShellModules {
    [Array] $result = @()

    # Get module names from our AL-Go toolset (not the full toolset)
    $algoModules = @(
        "DockerMsftProvider",
        "MarkdownPS",
        "Pester",
        "PowerShellGet",
        "PSScriptAnalyzer",
        "PSWindowsUpdate"
    )

    foreach ($moduleName in $algoModules) {
        $moduleVersions = Get-Module -Name $moduleName -ListAvailable -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Version | Sort-Object -Unique
        if ($moduleVersions) {
            $result += [ToolVersionsListNode]::new($moduleName, $moduleVersions, '^\d+', "Inline")
        }
    }

    return $result
}

# Software report
$softwareReport = [SoftwareReport]::new($(Build-OSInfoSection))

# Windows features
$optionalFeatures = $softwareReport.Root.AddHeader("Windows features")
$optionalFeatures.AddToolVersion("Windows Subsystem for Linux (WSLv1):", "Enabled")
$optionalFeatures.AddToolVersion("Containers:", "Enabled")
$optionalFeatures.AddToolVersion("Hyper-V:", "Enabled")

$installedSoftware = $softwareReport.Root.AddHeader("Installed Software")

# Language and Runtime - only what's installed in AL-Go image
$languageAndRuntime = $installedSoftware.AddHeader("Language and Runtime")
$languageAndRuntime.AddToolVersion("Bash", $(Get-BashVersion))
$languageAndRuntime.AddToolVersion("Node", $(Get-NodeVersion))
$languageAndRuntime.AddToolVersion("PowerShell Core", $(Get-PowershellCoreVersion))

# Package Management - minimal set
$packageManagement = $installedSoftware.AddHeader("Package Management")
$packageManagement.AddToolVersion("Chocolatey", $(Get-ChocoVersion))
$packageManagement.AddToolVersion("NPM", $(Get-NPMVersion))
$packageManagement.AddToolVersion("NuGet", $(Get-NugetVersion))

# Tools - only what we install
$tools = $installedSoftware.AddHeader("Tools")
$tools.AddToolVersion("7zip", $(Get-7zipVersion))
$tools.AddToolVersion("Docker", $(Get-DockerVersion))
$tools.AddToolVersion("Docker-wincred", $(Get-DockerWincredVersion))
$tools.AddToolVersion("Git", $(Get-GitVersion))
$tools.AddToolVersion("Git LFS", $(Get-GitLFSVersion))
$tools.AddToolVersion("jq", $(Get-JQVersion))

# CLI Tools
$cliTools = $installedSoftware.AddHeader("CLI Tools")
$cliTools.AddToolVersion("Azure CLI", $(Get-AzureCLIVersion))
$cliTools.AddToolVersion("Azure DevOps CLI extension", $(Get-AzureDevopsExtVersion))
$cliTools.AddToolVersion("GitHub CLI", $(Get-GHVersion))

# Shells
$installedSoftware.AddHeader("Shells").AddTable($(Get-ShellTarget))

# Cached Tools (Node.js from toolset)
$cachedTools = $installedSoftware.AddHeader("Cached Tools")
$nodeVersions = Get-ChildItem -Path "$env:AGENT_TOOLSDIRECTORY\node" -Directory -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Name | Sort-Object
if ($nodeVersions) {
    $cachedTools.AddToolVersionsListInline("Node.js", $nodeVersions, '^\d+')
}

# PowerShell Modules - use AL-Go specific function to avoid C:\Modules dependency
$psTools = $installedSoftware.AddHeader("PowerShell Tools")
$psModules = $psTools.AddHeader("PowerShell Modules")
$psModules.AddNodes($(Get-ALGoPowerShellModules))

# Docker Images - BC specific
$dockerSection = $installedSoftware.AddHeader("Cached Docker images")
$dockerImages = Get-CachedDockerImagesTableData
if ($dockerImages) {
    $dockerSection.AddTable($dockerImages)
}

# Business Central Cache info (custom section)
$bcSection = $installedSoftware.AddHeader("Business Central")
$bcCachePath = "C:\bcartifacts.cache"
$bcMetadataFile = Join-Path $bcCachePath "bc-cache-metadata.json"
if (Test-Path $bcMetadataFile) {
    $bcMetadata = Get-Content $bcMetadataFile | ConvertFrom-Json
    # Property names match Create-BcImage.ps1 metadata output
    $bcSection.AddToolVersion("BC Artifact URL", $bcMetadata.artifactUrl)
    $bcSection.AddToolVersion("BC Country", $bcMetadata.country)
    $bcSection.AddToolVersion("BC Type", $bcMetadata.type)
    $bcSection.AddToolVersion("Docker Image", $bcMetadata.dockerImage)
    $bcSection.AddToolVersion("Cache Timestamp", $bcMetadata.timestampUtc)
} else {
    $bcSection.AddNote("BC cache metadata not found")
}

# BcContainerHelper module
$bcHelperModule = Get-Module -Name BcContainerHelper -ListAvailable -ErrorAction SilentlyContinue
if ($bcHelperModule) {
    $bcSection.AddToolVersion("BcContainerHelper", $bcHelperModule.Version.ToString())
}

# Generate reports
$softwareReport.ToJson() | Out-File -FilePath "C:\software-report.json" -Encoding UTF8NoBOM
$softwareReport.ToMarkdown() | Out-File -FilePath "C:\software-report.md" -Encoding UTF8NoBOM

Write-Host "AL-Go Software Report generated successfully"
Write-Host "  JSON: C:\software-report.json"
Write-Host "  Markdown: C:\software-report.md"
