# Dynamic Chocolatey package tests - tests only packages defined in toolset
# This ensures tests match what is actually installed

# Get packages from toolset
$chocoPackages = (Get-ToolsetContent).choco.common_packages | ForEach-Object { $_.name }

# Test 7-Zip if installed
Describe "7-Zip" -Skip:($chocoPackages -notcontains "7zip.install") {
    It "7z" {
        "7z" | Should -ReturnZeroExitCode
    }
}

# Test Aria2 if installed
Describe "Aria2" -Skip:($chocoPackages -notcontains "aria2") {
    It "Aria2" {
        "aria2c --version" | Should -ReturnZeroExitCode
    }
}

# Test AzCopy if installed
Describe "AzCopy" -Skip:($chocoPackages -notcontains "azcopy10") {
    It "AzCopy" {
        "azcopy --version" | Should -ReturnZeroExitCode
    }
}

# Test Bicep if installed
Describe "Bicep" -Skip:($chocoPackages -notcontains "bicep") {
    It "Bicep" {
        "bicep --version" | Should -ReturnZeroExitCode
    }
}

# Test GitVersion if installed (Win19 only)
Describe "GitVersion" -Skip:(-not (Test-IsWin19) -or ($chocoPackages -notcontains "GitVersion.Portable")) {
    It "gitversion is installed" {
        "gitversion /version" | Should -ReturnZeroExitCode
    }
}

# Test InnoSetup if installed
Describe "InnoSetup" -Skip:($chocoPackages -notcontains "innosetup") {
    It "InnoSetup" {
        (Get-Command -Name iscc).CommandType | Should -BeExactly "Application"
    }
}

# Test Jq if installed
Describe "Jq" -Skip:($chocoPackages -notcontains "jq") {
    It "Jq" {
        "jq -n ." | Should -ReturnZeroExitCode
    }
}

# Test Nuget if installed
Describe "Nuget" -Skip:($chocoPackages -notcontains "NuGet.CommandLine") {
    It "Nuget" {
       "nuget" | Should -ReturnZeroExitCode
    }
}

# Test Packer if installed
Describe "Packer" -Skip:($chocoPackages -notcontains "packer") {
    It "Packer" {
       "packer --version" | Should -ReturnZeroExitCode
    }
}

# Test Perl if installed
Describe "Perl" -Skip:($chocoPackages -notcontains "strawberryperl") {
    It "Perl" {
       "perl --version" | Should -ReturnZeroExitCode
    }
}

# Test Pulumi if installed
Describe "Pulumi" -Skip:($chocoPackages -notcontains "pulumi") {
    It "pulumi" {
       "pulumi version" | Should -ReturnZeroExitCode
    }
}

# Test Svn if installed (not on Win25)
Describe "Svn" -Skip:((Test-IsWin25) -or ($chocoPackages -notcontains "svn")) {
    It "svn" {
        "svn --version --quiet" | Should -ReturnZeroExitCode
    }
}

# Test Swig if installed
Describe "Swig" -Skip:($chocoPackages -notcontains "swig") {
    It "Swig" {
        "swig -version" | Should -ReturnZeroExitCode
    }
}

# Test VSWhere if installed
Describe "VSWhere" -Skip:($chocoPackages -notcontains "vswhere") {
    It "vswhere" {
        "vswhere" | Should -ReturnZeroExitCode
    }
}

# Test Julia if installed
Describe "Julia" -Skip:($chocoPackages -notcontains "julia") {
    It "Julia path exists" {
        "C:\Julia" | Should -Exist
    }

    It "Julia" {
        "julia --version" | Should -ReturnZeroExitCode
    }
}

# Test CMake if installed
Describe "CMake" -Skip:($chocoPackages -notcontains "cmake.install") {
    It "cmake" {
        "cmake --version" | Should -ReturnZeroExitCode
    }
}

# Test ImageMagick if installed
Describe "ImageMagick" -Skip:($chocoPackages -notcontains "imagemagick") {
    It "ImageMagick" {
        "magick -version" | Should -ReturnZeroExitCode
    }
}

# Test Ninja if installed (requires cmake too)
Describe "Ninja" -Skip:(($chocoPackages -notcontains "ninja") -or ($chocoPackages -notcontains "cmake.install")) {
    BeforeAll {
        $ninjaProjectPath = $(Join-Path $env:TEMP_DIR "ninjaproject")
        New-item -Path $ninjaProjectPath -ItemType Directory -Force
@'
cmake_minimum_required(VERSION 3.10)
project(NinjaTest NONE)
'@ | Out-File -FilePath "$ninjaProjectPath/CMakeLists.txt" -Encoding utf8

        $ninjaProjectBuildPath = $(Join-Path $ninjaProjectPath "build")
        New-item -Path $ninjaProjectBuildPath -ItemType Directory -Force
        Set-Location $ninjaProjectBuildPath
    }

    It "Make a simple ninja project" {
    "cmake -GNinja $ninjaProjectPath" | Should -ReturnZeroExitCode
    }

    It "build.ninja file should exist" {
        $buildFilePath = $(Join-Path $ninjaProjectBuildPath "build.ninja")
        $buildFilePath | Should -Exist
    }

    It "Ninja" {
        "ninja --version" | Should -ReturnZeroExitCode
    }
}
