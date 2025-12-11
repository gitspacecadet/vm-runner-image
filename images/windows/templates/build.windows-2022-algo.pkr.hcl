################################################################################
# Minimal AL-Go Runner Image for Business Central
#
# This template creates a lightweight Windows 2022 image optimized for
# BC AL-Go workflows. It strips ~60GB of unnecessary tooling from the
# full runner-images build.
#
# Key differences from build.windows-2022.pkr.hcl:
# - Uses toolset-2022-algo.json (minimal toolset)
# - Includes BC container caching (Create-BcImage.ps1)
# - Skips: Visual Studio, Ruby, Go, PHP, Android, Selenium, etc.
# - Target size: ~35-40GB (vs 100GB+)
################################################################################

build {
  sources = ["source.azure-arm.image"]
  name = "windows-2022-algo"

  # Phase 1: Setup directories
  provisioner "powershell" {
    inline = [
      "New-Item -Path ${var.image_folder} -ItemType Directory -Force",
      "New-Item -Path ${var.temp_dir} -ItemType Directory -Force"
    ]
  }

  # Phase 2: Copy files to image
  provisioner "file" {
    destination = "${var.image_folder}\\"
    sources     = [
      "${path.root}/../assets",
      "${path.root}/../scripts",
      "${path.root}/../toolsets"
    ]
  }

  provisioner "file" {
    destination = "${var.image_folder}\\scripts\\docs-gen\\"
    source      = "${path.root}/../../../helpers/software-report-base"
  }

  # Phase 3: Organize files and use our minimal toolset
  provisioner "powershell" {
    inline = [
      "Move-Item '${var.image_folder}\\assets\\post-gen' 'C:\\post-generation'",
      "Remove-Item -Recurse '${var.image_folder}\\assets'",
      "Move-Item '${var.image_folder}\\scripts\\docs-gen' '${var.image_folder}\\SoftwareReport'",
      "Move-Item '${var.image_folder}\\scripts\\helpers' '${var.helper_script_folder}\\ImageHelpers'",
      "New-Item -Type Directory -Path '${var.helper_script_folder}\\TestsHelpers\\'",
      "Move-Item '${var.image_folder}\\scripts\\tests\\Helpers.psm1' '${var.helper_script_folder}\\TestsHelpers\\TestsHelpers.psm1'",
      "Move-Item '${var.image_folder}\\scripts\\tests' '${var.image_folder}\\tests'",
      "Remove-Item -Recurse '${var.image_folder}\\scripts'",
      # USE OUR MINIMAL TOOLSET instead of full toolset-2022.json
      "Move-Item '${var.image_folder}\\toolsets\\toolset-2022-algo.json' '${var.image_folder}\\toolset.json'",
      "Remove-Item -Recurse '${var.image_folder}\\toolsets'"
    ]
  }

  # Phase 4: Create install user
  provisioner "windows-shell" {
    inline = [
      "net user ${var.install_user} ${var.install_password} /add /passwordchg:no /passwordreq:yes /active:yes /Y",
      "net localgroup Administrators ${var.install_user} /add",
      "winrm set winrm/config/service/auth @{Basic=\"true\"}",
      "winrm get winrm/config/service/auth"
    ]
  }

  provisioner "powershell" {
    inline = ["if (-not ((net localgroup Administrators) -contains '${var.install_user}')) { exit 1 }"]
  }

  provisioner "powershell" {
    elevated_password = "${var.install_password}"
    elevated_user     = "${var.install_user}"
    inline            = ["bcdedit.exe /set TESTSIGNING ON"]
  }

  # Phase 5: Base configuration (minimal scripts)
  provisioner "powershell" {
    environment_vars = [
      "IMAGE_VERSION=${var.image_version}",
      "IMAGE_OS=${var.image_os}",
      "AGENT_TOOLSDIRECTORY=${var.agent_tools_directory}",
      "IMAGEDATA_FILE=${var.imagedata_file}",
      "IMAGE_FOLDER=${var.image_folder}",
      "TEMP_DIR=${var.temp_dir}"
    ]
    execution_policy = "unrestricted"
    scripts = [
      "${path.root}/../scripts/build/Configure-WindowsDefender.ps1",
      "${path.root}/../scripts/build/Configure-PowerShell.ps1",
      "${path.root}/../scripts/build/Install-PowerShellModules.ps1",
      "${path.root}/../scripts/build/Install-WindowsFeatures.ps1",
      "${path.root}/../scripts/build/Install-Chocolatey.ps1",
      "${path.root}/../scripts/build/Configure-BaseImage.ps1",
      "${path.root}/../scripts/build/Configure-ImageDataFile.ps1",
      "${path.root}/../scripts/build/Configure-SystemEnvironment.ps1",
      "${path.root}/../scripts/build/Configure-DotnetSecureChannel.ps1"
    ]
  }

  # Phase 6: Restart for Windows features (Containers, Hyper-V)
  provisioner "windows-restart" {
    check_registry        = true
    restart_check_command = "powershell -command \"& {while ( (Get-WindowsOptionalFeature -Online -FeatureName Containers -ErrorAction SilentlyContinue).State -ne 'Enabled' ) { Start-Sleep 30; Write-Output 'InProgress' }}\""
    restart_timeout       = "10m"
  }

  # Disable wlansvc service (Wireless-Networking feature workaround)
  provisioner "powershell" {
    inline = [
      "Set-Service -Name wlansvc -StartupType Manual",
      "if ($(Get-Service -Name wlansvc).Status -eq 'Running') { Stop-Service -Name wlansvc}"
    ]
  }

  # Phase 7: Install Docker and PowerShell Core
  # NOTE: Docker Compose removed - not needed for BC containers (uses Docker directly)
  provisioner "powershell" {
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts = [
      "${path.root}/../scripts/build/Install-Docker.ps1",
      "${path.root}/../scripts/build/Install-DockerWinCred.ps1",
      "${path.root}/../scripts/build/Install-PowershellCore.ps1"
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # Phase 8: Essential tools only (skip VS, KubernetesTools, etc.)
  provisioner "powershell" {
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts = [
      "${path.root}/../scripts/build/Install-AzureCli.ps1",
      "${path.root}/../scripts/build/Install-ChocolateyPackages.ps1"
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "10m"
  }

  # Phase 9: Core tooling for AL-Go
  # NOTE: Azure Az modules removed - not needed for standard BC AL-Go workflows
  # Re-add Install-PowershellAzModules.ps1 if using Azure Key Vault for secrets
  # NOTE: Install-DotnetSDK.ps1 removed - .NET SDK download hangs on Akamai CDN
  # BC containers include their own .NET runtime, AL-Go uses AL compiler from BC artifacts
  # NOTE: Install-NodeJS.ps1 removed - not needed for BC AL-Go workflows
  provisioner "powershell" {
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts = [
      "${path.root}/../scripts/build/Install-ActionsCache.ps1",
      "${path.root}/../scripts/build/Install-Toolset.ps1",
      "${path.root}/../scripts/build/Configure-Toolset.ps1",
      "${path.root}/../scripts/build/Install-Git.ps1",
      "${path.root}/../scripts/build/Install-GitHub-CLI.ps1",
      "${path.root}/../scripts/build/Install-RootCA.ps1",
      "${path.root}/../scripts/build/Configure-Diagnostics.ps1"
    ]
  }

  # Phase 10: BC Container Caching (THE KEY OPTIMIZATION)
  provisioner "powershell" {
    environment_vars = [
      "IMAGE_FOLDER=${var.image_folder}",
      "TEMP_DIR=${var.temp_dir}",
      "BC_COUNTRY=${var.bc_country}",
      "BC_TYPE=${var.bc_type}",
      "BC_SELECT=${var.bc_select}",
      "BC_CACHE_SKIP=${var.bc_cache_skip}"
    ]
    scripts = [
      "${path.root}/../scripts/build/Create-BcImage.ps1"
    ]
  }

  # Phase 11: Windows Updates and final configuration
  provisioner "powershell" {
    elevated_password = "${var.install_password}"
    elevated_user     = "${var.install_user}"
    environment_vars  = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts = [
      "${path.root}/../scripts/build/Install-WindowsUpdates.ps1",
      "${path.root}/../scripts/build/Configure-DynamicPort.ps1",
      "${path.root}/../scripts/build/Configure-GDIProcessHandleQuota.ps1",
      "${path.root}/../scripts/build/Configure-Shell.ps1",
      "${path.root}/../scripts/build/Configure-DeveloperMode.ps1"
    ]
  }

  provisioner "windows-restart" {
    check_registry        = true
    restart_check_command = "powershell -command \"& {if ((-not (Get-Process TiWorker.exe -ErrorAction SilentlyContinue)) -and (-not [System.Environment]::HasShutdownStarted) ) { Write-Output 'Restart complete' }}\""
    restart_timeout       = "30m"
  }

  # Phase 12: Cleanup and tests
  # NOTE: Using RunAll-ALGo-Tests.ps1 instead of RunAll-Tests.ps1
  # This only tests tools included in the minimal AL-Go toolset
  provisioner "powershell" {
    pause_before     = "2m0s"
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts = [
      "${path.root}/../scripts/build/Install-WindowsUpdatesAfterReboot.ps1",
      "${path.root}/../scripts/build/Invoke-Cleanup.ps1",
      "${path.root}/../scripts/tests/RunAll-ALGo-Tests.ps1"
    ]
  }

  provisioner "powershell" {
    inline = ["if (-not (Test-Path ${var.image_folder}\\tests\\testResults.xml)) { throw '${var.image_folder}\\tests\\testResults.xml not found' }"]
  }

  # Phase 13: Generate software report
  provisioner "powershell" {
    environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGE_FOLDER=${var.image_folder}"]
    inline           = ["pwsh -File '${var.image_folder}\\SoftwareReport\\Generate-SoftwareReport.ps1'"]
  }

  provisioner "powershell" {
    inline = [
      "if (-not (Test-Path C:\\software-report.md)) { throw 'C:\\software-report.md not found' }",
      "if (-not (Test-Path C:\\software-report.json)) { throw 'C:\\software-report.json not found' }"
    ]
  }

  provisioner "file" {
    destination = "${path.root}/../Windows2022-ALGo-Readme.md"
    direction   = "download"
    source      = "C:\\software-report.md"
  }

  provisioner "file" {
    destination = "${path.root}/../software-report-algo.json"
    direction   = "download"
    source      = "C:\\software-report.json"
  }

  # Phase 14: Final system configuration
  provisioner "powershell" {
    environment_vars = ["INSTALL_USER=${var.install_user}"]
    scripts = [
      "${path.root}/../scripts/build/Install-NativeImages.ps1",
      "${path.root}/../scripts/build/Configure-System.ps1",
      "${path.root}/../scripts/build/Configure-User.ps1",
      "${path.root}/../scripts/build/Post-Build-Validation.ps1"
    ]
    skip_clean = true
  }

  provisioner "windows-restart" {
    restart_timeout = "10m"
  }

  # Phase 15: Sysprep for generalization
  provisioner "powershell" {
    inline = [
      "if( Test-Path $env:SystemRoot\\System32\\Sysprep\\unattend.xml ){ rm $env:SystemRoot\\System32\\Sysprep\\unattend.xml -Force}",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /mode:vm /quiet /quit",
      "while($true) { $imageState = Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State | Select ImageState; if($imageState.ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { Write-Output $imageState.ImageState; Start-Sleep -s 10 } else { break } }"
    ]
  }
}
