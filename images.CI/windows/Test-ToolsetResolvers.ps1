<#
.SYNOPSIS
    Offline preflight for the AL-Go image build's toolset-driven resolvers.

.DESCRIPTION
    Runs the version/URL lookup blocks of the build scripts that
    build.windows-2022-algo.pkr.hcl executes, against a toolset file, and checks
    that every resolver yields a reachable artifact (and checksum where the
    script verifies one). Nothing is installed and no Azure credentials are used.

    Purpose: catch toolset DATA drift (a pinned value that moving upstream
    metadata no longer lists, e.g. pwsh 7.4 after its LTS EOL) in about a minute,
    instead of 20+ minutes into a Packer build.

    Fidelity rules:
      - Helpers are the real ones, dot-sourced from scripts/helpers/InstallHelpers.ps1.
      - Functions defined inside a build script are lifted out via the AST
        (the script's install body never runs).
      - Inline lookup blocks are copied verbatim from the build script; keep them
        in sync when the script changes.
      - Run under Windows PowerShell 5.1, unauthenticated, like Packer does.
        Uses about 25 GitHub API calls (release lists are cached in TEMP_DIR).

    Exit code: 0 when no check FAILs (WARNs allowed), 1 otherwise.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File images.CI\windows\Test-ToolsetResolvers.ps1

.EXAMPLE
    # Validate a toolset from another ref
    git show pipeline-v1.0.1:images/windows/toolsets/toolset-2022-algo.json > $env:TEMP\t.json
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File images.CI\windows\Test-ToolsetResolvers.ps1 -ToolsetPath $env:TEMP\t.json
#>
param(
    [string] $ToolsetPath = (Join-Path $PSScriptRoot "..\..\images\windows\toolsets\toolset-2022-algo.json"),
    [string] $ScriptsPath = (Join-Path $PSScriptRoot "..\..\images\windows\scripts")
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$work = Join-Path ([IO.Path]::GetTempPath()) ("toolset-preflight-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:IMAGE_FOLDER = $work
$env:TEMP_DIR = $work
Copy-Item -Path $ToolsetPath -Destination (Join-Path $work "toolset.json")

. (Join-Path $ScriptsPath "helpers\InstallHelpers.ps1")
$buildPath = Join-Path $ScriptsPath "build"

function Get-ScriptFunctionText {
    param([string] $Path, [string] $Name)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $fn = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
    if (-not $fn) { throw "Function $Name not found in $Path" }
    return $fn.Extent.Text
}

function Test-Url {
    # HEAD first, then a 1-byte ranged GET on ANY HEAD failure: some hosts answer
    # HEAD with a misleading status (PSGallery returns 404 to HEAD, 302 to GET).
    # A genuinely missing artifact still fails the GET.
    param([string] $Url)
    foreach ($method in @("HEAD", "GET")) {
        try {
            $request = [System.Net.HttpWebRequest]::Create($Url)
            $request.Method = $method
            $request.AllowAutoRedirect = $true
            $request.UserAgent = "toolset-preflight"
            $request.Timeout = 30000
            if ($method -eq "GET") { $request.AddRange(0, 0) }
            $response = $request.GetResponse()
            $code = [int]$response.StatusCode
            $response.Close()
            return "HTTP $code"
        } catch [System.Net.WebException] {
            if ($method -eq "HEAD") { continue }
            throw "Unreachable ($method) $Url : $($_.Exception.Message)"
        }
    }
}

function Format-Hash {
    param([string] $Hash, [string] $What)
    if (-not $Hash) { throw "No checksum found for $What" }
    return "sha=" + $Hash.Substring(0, 12) + "..."
}

$results = New-Object System.Collections.Generic.List[object]
function Invoke-Check {
    param([string] $Step, [string] $Item, [scriptblock] $Check)
    try {
        $detail = (& $Check 6>$null) -join " "
        $result = if ($detail -like "WARN:*") { "WARN" } else { "PASS" }
        $results.Add([pscustomobject]@{ Result = $result; Step = $Step; Item = $Item; Detail = $detail })
    } catch {
        $results.Add([pscustomobject]@{ Result = "FAIL"; Step = $Step; Item = $Item; Detail = $_.Exception.Message })
    }
}

try {
    $toolset = Get-ToolsetContent

    # --- Install-Docker.ps1 ---------------------------------------------------
    Invoke-Check "Install-Docker" "moby $($toolset.docker.components.docker)" {
        $toolsetVersion = (Get-ToolsetContent).docker.components.docker
        $mobyVersion = (Get-GithubReleasesByVersion -Repo "moby/moby" -Version "${toolsetVersion}").version
        $dockerceUrl = "https://download.docker.com/win/static/stable/x86_64/"
        $dockerceBinaries = Invoke-WebRequest -Uri $dockerceUrl -UseBasicParsing
        $mobyRelease = $dockerceBinaries.Links.href -match "${mobyVersion}\.zip" | Select-Object -Last 1
        if (-not $mobyRelease) { return "WARN: docker-${mobyVersion}.zip not listed; script falls back to the newest zip" }
        "$mobyRelease $(Test-Url ($dockerceUrl + $mobyRelease))"
    }
    Invoke-Check "Install-Docker" "install-docker-ce.ps1" {
        $source = Get-Content (Join-Path $buildPath "Install-Docker.ps1") -Raw
        $url = [regex]::Match($source, '\$instScriptUrl\s*=\s*"([^"]+)"').Groups[1].Value
        if (-not $url) { throw "instScriptUrl not found in Install-Docker.ps1" }
        if ($url -notmatch '/[0-9a-f]{40}/') { return "WARN: not commit-pinned: $url" }
        "pinned $(Test-Url $url)"
    }

    # --- Install-PowerShellModules.ps1 -----------------------------------------
    foreach ($module in $toolset.powershellModules) {
        $versions = if ($module.versions) { $module.versions } else { @("latest") }
        foreach ($version in $versions) {
            Invoke-Check "Install-PowerShellModules" "$($module.name) $version" {
                $url = "https://www.powershellgallery.com/api/v2/package/$($module.name)"
                if ($version -ne "latest") { $url += "/$version" }
                Test-Url $url
            }
        }
    }

    # --- Install-Chocolatey.ps1 / Install-ChocolateyPackages.ps1 ---------------
    Invoke-Check "Install-Chocolatey" "install.ps1" { Test-Url "https://chocolatey.org/install.ps1" }
    foreach ($package in $toolset.choco.common_packages) {
        Invoke-Check "Install-ChocolateyPackages" $package.name {
            Test-Url "https://community.chocolatey.org/api/v2/package/$($package.name)"
        }
    }

    # --- Install-PowershellCore.ps1 (verbatim lookup block) --------------------
    Invoke-Check "Install-PowershellCore" "pwsh $($toolset.pwsh.version)" {
        $metadata = Invoke-RestMethod https://raw.githubusercontent.com/PowerShell/PowerShell/master/tools/metadata.json
        $pwshMajorMinor = (Get-ToolsetContent).pwsh.version
        $releases = $metadata.LTSReleaseTag -replace '^v'
        $downloadUrl = $null
        foreach ($release in $releases) {
            if ($release -like "${pwshMajorMinor}*") {
                $downloadUrl = "https://github.com/PowerShell/PowerShell/releases/download/v${release}/PowerShell-${release}-win-x64.msi"
                break
            }
        }
        if (-not $downloadUrl) { throw "No LTS tag matching '$pwshMajorMinor' (LTSReleaseTag: $($releases -join ', '))" }
        $installerName = Split-Path $downloadUrl -Leaf
        $hash = Get-ChecksumFromUrl -Type "SHA256" -Url ($downloadUrl -replace $installerName, "hashes.sha256") -FileName $installerName
        "$installerName $(Test-Url $downloadUrl) $(Format-Hash $hash $installerName)"
    }

    # --- Install-AzureCli.ps1 ---------------------------------------------------
    Invoke-Check "Install-AzureCli" "latest MSI" { Test-Url "https://aka.ms/installazurecliwindowsx64" }

    # --- Install-PowershellAzModules.ps1 ---------------------------------------
    foreach ($module in $toolset.azureModules) {
        foreach ($version in (@($module.versions) + @($module.zip_versions))) {
            if (-not $version) { continue }
            Invoke-Check "Install-PowershellAzModules" "$($module.name) $version" {
                Test-Url "https://www.powershellgallery.com/api/v2/package/$($module.name)/$version"
            }
        }
    }

    # --- Install-DotnetSDK.ps1 (Get-SDKVersionsToInstall lifted via AST) -------
    . ([scriptblock]::Create((Get-ScriptFunctionText (Join-Path $buildPath "Install-DotnetSDK.ps1") "Get-SDKVersionsToInstall")))
    Invoke-Check "Install-DotnetSDK" "dotnet-install.ps1" { Test-Url "https://dot.net/v1/dotnet-install.ps1" }
    foreach ($dotnetVersion in $toolset.dotnet.versions) {
        Invoke-Check "Install-DotnetSDK" "channel $dotnetVersion" {
            $sdks = @(Get-SDKVersionsToInstall -DotnetVersion $dotnetVersion)
            if (-not $sdks) { throw "No SDK versions resolved from releases.json for $dotnetVersion" }
            $releasesJsonUri = "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/${dotnetVersion}/releases.json"
            $releasesData = (Invoke-DownloadWithRetry $releasesJsonUri) | Get-Item | Get-Content | ConvertFrom-Json
            $missing = @()
            foreach ($sdk in $sdks) {
                $hash = $releasesData.releases.sdks.Where({ $_.version -eq $sdk }).files.Where({ $_.name -eq 'dotnet-sdk-win-x64.zip' }).hash
                if (-not $hash) { $missing += $sdk }
            }
            if ($missing) { throw "No dotnet-sdk-win-x64.zip SHA512 in releases.json for SDK(s): $($missing -join ', ')" }
            "SDKs $($sdks -join ', ')"
        }
    }

    # --- Install-ActionsCache.ps1 ----------------------------------------------
    Invoke-Check "Install-ActionsCache" "action-versions latest" {
        $url = Resolve-GithubReleaseAssetUrl -Repo "actions/action-versions" -Version "latest" -Asset "action-versions.zip"
        "$(Split-Path $url -Leaf) $(Test-Url $url)"
    }

    # --- Install-Toolset.ps1 (verbatim asset lookup) ---------------------------
    $toolsToInstall = @("Python", "Node", "Go")
    foreach ($tool in @($toolset.toolcache | Where-Object { $toolsToInstall -contains $_.name })) {
        foreach ($toolVersion in $tool.versions) {
            Invoke-Check "Install-Toolset" "$($tool.name) $toolVersion" {
                $assets = Invoke-RestMethod $tool.url
                $asset = $assets `
                | Where-Object version -like $toolVersion `
                | Select-Object -ExpandProperty files `
                | Where-Object { ($_.platform -eq $tool.platform) -and ($_.arch -eq $tool.arch) -and ($_.toolset -eq $tool.toolset) } `
                | Select-Object -First 1
                if (-not $asset) { throw "Asset for $($tool.name) $toolVersion $($tool.arch) not found in versions manifest" }
                "$($asset.filename) $(Test-Url $asset.download_url)"
            }
        }
    }

    # --- Install-NodeJS.ps1 (verbatim lookup block) ----------------------------
    Invoke-Check "Install-NodeJS" "node default $($toolset.node.default)" {
        $defaultVersion = (Get-ToolsetContent).node.default
        $nodeVersion = (Get-GithubReleasesByVersion -Repo "nodejs/node" -Version "${defaultVersion}").version | Select-Object -First 1
        if (-not $nodeVersion) { throw "No nodejs/node release matching '$defaultVersion'" }
        $downloadUrl = "https://nodejs.org/dist/v${nodeVersion}/node-v${nodeVersion}-x64.msi"
        $packageName = Split-Path $downloadUrl -Leaf
        $hash = Get-ChecksumFromUrl -Type "SHA256" -Url ($downloadUrl -replace $packageName, "SHASUMS256.txt") -FileName $packageName
        "$packageName $(Test-Url $downloadUrl) $(Format-Hash $hash $packageName)"
    }

    # --- Install-Git.ps1 --------------------------------------------------------
    Invoke-Check "Install-Git" "git-for-windows latest" {
        $downloadUrl = Resolve-GithubReleaseAssetUrl -Repo "git-for-windows/git" -Version "latest" -UrlMatchPattern "Git-*-64-bit.exe"
        $fileName = Split-Path $downloadUrl -Leaf
        $hash = Get-ChecksumFromGithubRelease -Repo "git-for-windows/git" -Version "latest" -FileName $fileName -HashType "SHA256"
        "$fileName $(Test-Url $downloadUrl) $(Format-Hash $hash $fileName)"
    }

    # --- Install-GitHub-CLI.ps1 -------------------------------------------------
    Invoke-Check "Install-GitHub-CLI" "cli/cli latest" {
        $downloadUrl = Resolve-GithubReleaseAssetUrl -Repo "cli/cli" -Version "latest" -UrlMatchPattern "gh_*_windows_amd64.msi"
        $checksumsUrl = Resolve-GithubReleaseAssetUrl -Repo "cli/cli" -Version "latest" -UrlMatchPattern "gh_*_checksums.txt"
        $fileName = Split-Path $downloadUrl -Leaf
        $hash = Get-ChecksumFromUrl -Type "SHA256" -Url $checksumsUrl -FileName $fileName
        "$fileName $(Test-Url $downloadUrl) $(Format-Hash $hash $fileName)"
    }

    # --- Install-GitHubRunner.ps1 ----------------------------------------------
    Invoke-Check "Install-GitHubRunner" "actions/runner latest" {
        $latestRelease = Invoke-RestMethod -Uri 'https://api.github.com/repos/actions/runner/releases/latest' `
            -Headers @{ 'User-Agent' = 'packer-image-builder'; 'Accept' = 'application/vnd.github+json' } -UseBasicParsing
        $runnerVersion = $latestRelease.tag_name.TrimStart('v')
        if ([string]::IsNullOrWhiteSpace($runnerVersion)) { throw "Failed to resolve runner version" }
        $url = "https://github.com/actions/runner/releases/download/v$runnerVersion/actions-runner-win-x64-$runnerVersion.zip"
        "v$runnerVersion $(Test-Url $url)"
    }
} finally {
    Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
}

$results | Format-Table -AutoSize -Wrap Result, Step, Item, Detail | Out-String -Width 220 | Write-Output
$fail = @($results | Where-Object Result -eq "FAIL").Count
$warn = @($results | Where-Object Result -eq "WARN").Count
$pass = @($results | Where-Object Result -eq "PASS").Count
Write-Output ("VERDICT: {0} PASS / {1} WARN / {2} FAIL  (toolset: {3}; PowerShell {4})" -f $pass, $warn, $fail, $ToolsetPath, $PSVersionTable.PSVersion)
if ($fail -gt 0) { exit 1 }
exit 0
