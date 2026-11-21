# Prototype policy shared by bake, curated tests, and fresh-boot validation.
function Assert-ALGoContainerCompatibility {
    param([version] $HostVersion, [version] $ContainerVersion)
    if ($HostVersion.Build -notin @(20348,26100) -or
        $ContainerVersion.Build -notin @(20348,26100) -or
        ($HostVersion.Build -eq 20348 -and $ContainerVersion.Build -ne 20348)) {
        throw "Unsupported process-isolation pair: host $HostVersion / container $ContainerVersion"
    }
}

function Get-ALGoBcPolicy {
    param([string] $GenericImage)
    if ($GenericImage -cnotmatch '^mcr\.microsoft\.com/businesscentral@sha256:[0-9a-f]{64}$') {
        throw 'AL-Go prototype requires an immutable MCR Business Central digest'
    }
    return [ordered]@{
        genericImageName = $GenericImage
        defaultNewContainerParameters = @{ isolation = 'process' }
    }
}
