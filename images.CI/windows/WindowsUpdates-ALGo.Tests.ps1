BeforeAll {
    $file = "$PSScriptRoot/../../images/windows/scripts/build/Install-WindowsUpdates-ALGo.ps1"
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-WindowsUpdates' }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    function Test-IsWin22 { }
    function Get-WindowsUpdate {
        [CmdletBinding()]
        param([switch] $MicrosoftUpdate, [string[]] $NotKBArticleID,
            [switch] $AcceptAll, [switch] $Install, [switch] $IgnoreUserInput, [switch] $IgnoreReboot)
    }
    function Get-WindowsUpdateStates { }
}
Describe 'OS-specific Windows Update selection' {
    BeforeEach {
        Mock Start-Service { }
        Mock Get-WindowsUpdate { [pscustomobject]@{ Title = 'Cumulative Update KB999'; KB = 'KB999' } }
        Mock Get-WindowsUpdateStates { [pscustomobject]@{ Title = 'Cumulative Update KB999'; State = 'Installed' } }
    }
    It 'preserves the 2022 WinRE exception on scan and install' {
        Mock Test-IsWin22 { $true }
        Install-WindowsUpdates
        Should -Invoke Get-WindowsUpdate -Exactly -Times 2 -ParameterFilter { $MicrosoftUpdate -and $NotKBArticleID -contains 'KB5034439' }
        Should -Invoke Get-WindowsUpdate -Exactly -Times 1 -ParameterFilter { $Install -and $IgnoreReboot -and $AcceptAll }
    }
    It 'does not exclude that 2022 KB on the 2025 host' {
        Mock Test-IsWin22 { $false }
        Install-WindowsUpdates
        Should -Invoke Get-WindowsUpdate -Exactly -Times 2 -ParameterFilter { $MicrosoftUpdate -and -not $NotKBArticleID }
    }
    It 'retains a no-update path without installing anything' {
        Mock Test-IsWin22 { $false }
        Mock Get-WindowsUpdate { }
        Install-WindowsUpdates
        Should -Invoke Get-WindowsUpdate -Exactly -Times 0 -ParameterFilter { $Install }
    }
    It 'fails a required cumulative-update failure' {
        Mock Test-IsWin22 { $false }
        Mock Get-WindowsUpdateStates { [pscustomobject]@{ Title = 'Cumulative Update KB999'; State = 'Failed' } }
        { Install-WindowsUpdates } | Should -Throw '*failed to install*'
    }
}
