################################################################################
##  File:  Configure-User-ALGo.ps1
##  Desc:  AL-Go minimal user configuration (no Visual Studio dependencies)
##
##  This is a minimal version of Configure-User.ps1 for AL-Go runner images.
##  The full Configure-User.ps1 requires Visual Studio to be installed because
##  it warms up devenv.exe and copies VS-related registry keys. Since AL-Go
##  images don't include Visual Studio (to minimize size), we skip those steps.
##
##  What this script DOES:
##  - Handles Windows 2025 privacy consent settings
##  - Cleans up the installer user profile (Windows 2025)
##
##  What this script SKIPS (VS-dependent):
##  - Visual Studio devenv.exe warmup
##  - VS registry key copying
##  - TortoiseSVN configuration
################################################################################

Write-Host "Configure-User-ALGo.ps1 - Starting"

# Accept by default "Send Diagnostic data to Microsoft" consent for Windows 2025
if (Test-IsWin25) {
    Write-Host "Configuring Windows 2025 privacy consent settings..."

    # Load the default user hive to configure privacy settings
    Mount-RegistryHive `
        -FileName "C:\Users\Default\NTUSER.DAT" `
        -SubKey "HKLM\DEFAULT"

    $registryKeyPath = 'HKLM:\DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy'
    if (-not (Test-Path $registryKeyPath)) {
        New-Item -Path $registryKeyPath -ItemType Directory -Force | Out-Null
    }

    New-ItemProperty -Path $registryKeyPath -Name PrivacyConsentPresentationVersion -PropertyType DWORD -Value 3 -Force | Out-Null
    New-ItemProperty -Path $registryKeyPath -Name PrivacyConsentSettingsValidMask -PropertyType DWORD -Value 4 -Force | Out-Null
    New-ItemProperty -Path $registryKeyPath -Name PrivacyConsentSettingsVersion -PropertyType DWORD -Value 5 -Force | Out-Null

    Dismount-RegistryHive "HKLM\DEFAULT"
    Write-Host "Privacy consent settings configured"
}

# Remove the "installer" (var.install_user) user profile for Windows 2025 image
if (Test-IsWin25) {
    Write-Host "Removing installer user profile..."
    Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.LocalPath -match $env:INSTALL_USER } | Remove-CimInstance -Confirm:$false
    & net user $env:INSTALL_USER /DELETE
    Write-Host "Installer user profile removed"
}

Write-Host "Configure-User-ALGo.ps1 - completed"
