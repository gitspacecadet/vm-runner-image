################################################################################
# AL-Go runner image, L13 THIN layer (per-BC build)
#
# Boots a base-layer version of the deploy's own gallery definition
# (var.source_gallery_image_version, built by build "windows-2022-algo" with
# bc_cache_skip=true: OS + Windows Update + every tool + the BC generic docker
# image) and only adds the per-BC part: Create-BcImage (my: bake), smoke, tests,
# software report, sysprep.
#
# What the generalized base keeps and this build relies on:
# - C:\image (toolset.json, tests, SoftwareReport, scripts\vmss), the ImageHelpers
#   and TestsHelpers modules, the installer user (Win22), docker data root.
# What it lost and this build restores:
# - The AllUsersAllHosts profile import of ImageHelpers (Invoke-Cleanup deletes it).
# - imagedata.json carries the base version: re-stamped with this IMAGE_VERSION.
# Payload goes to a staging folder so it never collides with the base's C:\image.
# No elevated provisioner here, so the install user is not touched.
################################################################################

build {
  sources = ["source.azure-arm.image"]
  name    = "windows-2022-algo-bc"

  # Phase 1: log host CPU, base OS build and the base layer this build boots.
  provisioner "powershell" {
    inline = [
      "New-Item -Path ${var.temp_dir} -ItemType Directory -Force",
      "Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, MaxClockSpeed | Format-List | Out-String | Write-Host",
      "Write-Host ('Base OS build: ' + (Get-CimInstance Win32_OperatingSystem).Version + '.' + (Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion').UBR)",
      "Write-Host 'L13 thin build on base layer ${var.gallery_image_name}/${var.source_gallery_image_version}'",
      "if ('${var.source_gallery_image_version}' -eq '') { throw 'L13 thin build needs source_gallery_image_version (base layer version)' }",
      "if (-not (Test-Path '${var.image_folder}\\toolset.json')) { throw 'Base layer has no ${var.image_folder}\\toolset.json: not an ALGo base image' }"
    ]
  }

  # Phase 1b: refuse a base layer older than 35 days (monthly base cadence).
  provisioner "powershell" {
    environment_vars = ["BASE_VERSION=${var.source_gallery_image_version}", "MAX_AGE_DAYS=35"]
    scripts = [
      "${path.root}/../scripts/build/Test-BaseLayerAge-ALGo.ps1"
    ]
  }

  # Phase 2: payload (same archive as the full build), expanded into a staging folder.
  # local.algo_payload_archive is shared with build windows-2022-algo: CI always
  # runs exactly one build via -only=, never both in one packer invocation.
  provisioner "shell-local" {
    execute_command    = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "{{.Script}}"]
    tempfile_extension = ".ps1"
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "& '${path.root}/../../../images.CI/windows/Pack-ImagePayload-ALGo.ps1' -TemplateRoot '${path.root}' -ArchivePath '${local.algo_payload_archive}'"
    ]
  }

  provisioner "file" {
    pause_before = "1m0s"
    max_retries  = 3
    generated    = true
    source       = local.algo_payload_archive
    destination  = "${var.image_folder}\\image-payload.tar"
  }

  provisioner "shell-local" {
    execute_command    = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "{{.Script}}"]
    tempfile_extension = ".ps1"
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "Remove-Item -LiteralPath '${local.algo_payload_archive}' -Force"
    ]
  }

  error-cleanup-provisioner "shell-local" {
    execute_command    = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "{{.Script}}"]
    tempfile_extension = ".ps1"
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "if (Test-Path -LiteralPath '${local.algo_payload_archive}') { Remove-Item -LiteralPath '${local.algo_payload_archive}' -Force }"
    ]
  }

  provisioner "powershell" {
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$p = '${var.image_folder}\\thin-payload'",
      "try {",
      "  if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }",
      "  New-Item -Path $p -ItemType Directory -Force | Out-Null",
      "  & 'C:\\Windows\\System32\\tar.exe' -xf '${var.image_folder}\\image-payload.tar' -C $p",
      "  if ($LASTEXITCODE -ne 0) { throw \"tar expand failed with exit code $LASTEXITCODE\" }",
      "  $expected = [int](Get-Content -LiteralPath \"$p\\payload-file-count.txt\" -Raw)",
      "  $actual = @(Get-ChildItem -LiteralPath \"$p\\assets\", \"$p\\scripts\", \"$p\\toolsets\" -File -Recurse -Force).Count",
      "  if ($expected -le 0 -or $actual -ne $expected) { throw \"Payload file count mismatch: expected $expected, expanded $actual\" }",
      "  Remove-Item -LiteralPath '${var.image_folder}\\image-payload.tar' -Force",
      "  Write-Host \"expanded $actual files into $p\"",
      "} catch { Write-Host $_; exit 1 }"
    ]
  }

  # Phase 3 (thin): refresh helpers, tests, report generator and toolset from
  # this recipe; keep the base's scripts\vmss (Install-RunnerSetupScript ran in the base).
  provisioner "powershell" {
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$p = '${var.image_folder}\\thin-payload'",
      "foreach ($m in 'ImageHelpers', 'TestsHelpers') { $d = Join-Path '${var.helper_script_folder}' $m; if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }",
      "Move-Item \"$p\\scripts\\helpers\" (Join-Path '${var.helper_script_folder}' 'ImageHelpers')",
      "New-Item -Type Directory -Path (Join-Path '${var.helper_script_folder}' 'TestsHelpers') -Force | Out-Null",
      "Move-Item \"$p\\scripts\\tests\\Helpers.psm1\" (Join-Path '${var.helper_script_folder}' 'TestsHelpers\\TestsHelpers.psm1')",
      "foreach ($d in 'tests', 'SoftwareReport') { $t = Join-Path '${var.image_folder}' $d; if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force } }",
      "Move-Item \"$p\\scripts\\tests\" '${var.image_folder}\\tests'",
      "Move-Item \"$p\\scripts\\docs-gen\" '${var.image_folder}\\SoftwareReport'",
      "Copy-Item \"$p\\toolsets\\toolset-2022-algo.json\" '${var.image_folder}\\toolset.json' -Force",
      "Remove-Item -LiteralPath $p -Recurse -Force",
      "Write-Host 'thin refresh done'"
    ]
  }

  # Phase 5a (thin): restore the ImageHelpers auto-import that Invoke-Cleanup
  # removed from the base, so each Packer PS session sees the helper functions.
  provisioner "powershell" {
    inline = [
      "$profilePath = $profile.AllUsersAllHosts",
      "if (-not (Test-Path (Split-Path $profilePath))) { New-Item -Path (Split-Path $profilePath) -ItemType Directory -Force | Out-Null }",
      "if (-not (Test-Path $profilePath)) { New-Item -Path $profilePath -ItemType File -Force | Out-Null }",
      "'Import-Module ImageHelpers -Force -ErrorAction SilentlyContinue' | Add-Content -Path $profilePath -Force",
      "Import-Module ImageHelpers -Force -ErrorAction Stop",
      "Write-Host \"ImageHelpers import restored in $profilePath\""
    ]
  }

  # Phase 5b (thin): re-stamp imagedata.json with this build's IMAGE_VERSION.
  provisioner "powershell" {
    environment_vars = [
      "IMAGE_VERSION=${var.image_version}",
      "IMAGE_OS=${var.image_os}",
      "IMAGEDATA_FILE=${var.imagedata_file}",
      "IMAGE_FOLDER=${var.image_folder}",
      "TEMP_DIR=${var.temp_dir}"
    ]
    execution_policy = "unrestricted"
    scripts = [
      "${path.root}/../scripts/build/Configure-ImageDataFile.ps1"
    ]
  }

  # Phase 10: BC Container Caching (my: bake)
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

  # Phase 10.5: BC Container smoke-test
  provisioner "powershell" {
    environment_vars = [
      "BC_CACHE_DIR=C:\\bcartifacts.cache",
      "BC_CACHE_SKIP=${var.bc_cache_skip}"
    ]
    scripts = [
      "${path.root}/../scripts/build/Smoke-BcContainer.ps1"
    ]
  }

  # Phase 11 (thin): none. Windows Update lives in the base layer; the base is
  # rebuilt monthly after Patch Tuesday (owner ruling 2026-11-25).

  # Phase 12: Cleanup and the full ALGo test set (base tools + BcCache).
  provisioner "powershell" {
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}", "INSTALL_USER=${var.install_user}", "BC_CACHE_SKIP=${var.bc_cache_skip}"]
    scripts = [
      "${path.root}/../scripts/build/Invoke-Cleanup.ps1",
      "${path.root}/../scripts/tests/RunAll-ALGo-Tests.ps1"
    ]
  }

  provisioner "powershell" {
    inline = ["if (-not (Test-Path ${var.image_folder}\\tests\\testResults.xml)) { throw '${var.image_folder}\\tests\\testResults.xml not found' }"]
  }

  # Phase 13: software report
  provisioner "powershell" {
    environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGE_FOLDER=${var.image_folder}"]
    inline           = ["pwsh -File '${var.image_folder}\\SoftwareReport\\Generate-SoftwareReport-ALGo.ps1'"]
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

  # Phase 14 (thin): idempotent system/user config + validation. NativeImages
  # ran in the base and persists.
  provisioner "powershell" {
    environment_vars = ["INSTALL_USER=${var.install_user}"]
    scripts = [
      "${path.root}/../scripts/build/Configure-System.ps1",
      "${path.root}/../scripts/build/Configure-User-ALGo.ps1",
      "${path.root}/../scripts/build/Post-Build-Validation.ps1"
    ]
    skip_clean = true
  }

  provisioner "windows-restart" {
    restart_timeout = "10m"
  }

  # Phase 15: Sysprep for generalization (second generalize of this OS lineage)
  provisioner "powershell" {
    inline = [
      "if( Test-Path $env:SystemRoot\\System32\\Sysprep\\unattend.xml ){ rm $env:SystemRoot\\System32\\Sysprep\\unattend.xml -Force}",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /mode:vm /quiet /quit",
      "while($true) { $imageState = Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State | Select ImageState; if($imageState.ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { Write-Output $imageState.ImageState; Start-Sleep -s 10 } else { break } }"
    ]
  }
}
