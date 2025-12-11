################################################################################
##  File:  CLI.Tools-ALGo.Tests.ps1
##  Desc:  CLI tools tests for AL-Go minimal image.
##         Only tests CLIs actually installed in toolset-2022-algo.json.
##         Full runner-images uses CLI.Tools.Tests.ps1 which tests AWS, Aliyun, etc.
################################################################################

Describe "Azure CLI" {
    It "Azure CLI" {
        "az --version" | Should -ReturnZeroExitCode
    }
}

Describe "Azure DevOps CLI" {
    It "az devops" {
        "az devops -h" | Should -ReturnZeroExitCode
    }
}

Describe "GitHub CLI" {
    It "gh" {
        "gh --version" | Should -ReturnZeroExitCode
    }
}
