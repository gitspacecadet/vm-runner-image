################################################################################
## Fork-owned community-feed retry policy; upstream ChocoHelpers stays unchanged.
## Six attempts, with 930 seconds of waiting only when all attempts fail.
################################################################################

function Install-ChocoPackageALGo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $PackageName,
        [string[]] $ArgumentList,
        [string] $Version,
        [scriptblock] $Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )

    $delays = @(30, 60, 120, 240, 480)
    $attempts = $delays.Count + 1
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        Write-Host "Running [#$attempt/$attempts]: choco install $PackageName -y $ArgumentList"
        if ($Version) {
            choco install $PackageName --version $Version -y @ArgumentList --no-progress --require-checksums
        } else {
            choco install $PackageName -y @ArgumentList --no-progress --require-checksums
        }
        $pkg = choco list --localonly $PackageName --exact --all --limitoutput
        if ($pkg) {
            Write-Host "Package installed: $pkg"
            return
        }
        if ($attempt -eq $attempts) {
            throw "Could not install $PackageName after $attempt attempts"
        }
        $delay = $delays[$attempt - 1]
        Write-Host "Retry $PackageName after attempt $attempt/$attempts; next attempt $($attempt + 1)/$attempts in $delay seconds"
        & $Sleep $delay
    }
}

# Dot-sourcing exposes only the retry function to offline tests.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $commonPackages = (Get-ToolsetContent).choco.common_packages
        foreach ($package in $commonPackages) {
            Install-ChocoPackageALGo $package.name -Version $package.version -ArgumentList $package.args
        }
    } catch {
        Write-Host $_
        exit 1
    }
    Invoke-PesterTests -TestFile "ChocoPackages"
}
