# Offline round-trip of the actual template commands; never invokes Packer/Azure.
param([ValidateSet('2022','2025')][string] $Year = '2022')
$ErrorActionPreference = 'Stop'
$templateRoot = (Resolve-Path "$PSScriptRoot/../../images/windows/templates").Path
$template = Get-Content -LiteralPath (Join-Path $templateRoot "build.windows-$Year-algo.pkr.hcl") -Raw
$phase2 = ($template -split '# Phase 2:')[1] -split '# Phase 3:' | Select-Object -First 1
$work = Join-Path ([IO.Path]::GetTempPath()) ('algo payload test ' + [guid]::NewGuid())
$archive = Join-Path $work 'payload.tar'
$expanded = Join-Path $work 'expanded'
$reference = Join-Path $work 'reference'
New-Item -ItemType Directory -Path $work, $expanded, $reference | Out-Null

function Get-InlineScript {
    param([string] $Body)
    $lines = foreach ($line in ($Body -split '\r?\n')) {
        if ($line.TrimStart().StartsWith('"')) {
            $decoded = $line.Trim().TrimEnd(',') | ConvertFrom-Json
            $decoded.Replace('${path.root}', $templateRoot).Replace('${local.algo_payload_archive}', $archive).Replace('${var.image_folder}', $expanded)
        }
    }
    return $lines -join "`r`n"
}

function Get-TreeHashes {
    param([string] $Root)
    Get-ChildItem -LiteralPath $Root -File -Recurse -Force | ForEach-Object {
        $_.FullName.Substring($Root.Length) + ' ' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    } | Sort-Object
}

try {
    $locals = [regex]::Matches($phase2, '(?ms)^  provisioner "shell-local" \{(.*?)^  \}')
    $expandBlock = [regex]::Match($phase2, '(?ms)^  provisioner "powershell" \{(.*?)^  \}')
    if ($locals.Count -ne 2 -or -not $expandBlock.Success) { throw 'Expected pack, cleanup and expand blocks' }
    $packScript = Join-Path $work 'pack.ps1'
    $expandScript = Join-Path $work 'expand.ps1'
    Set-Content -LiteralPath $packScript -Value (Get-InlineScript $locals[0].Groups[1].Value) -Encoding ASCII
    $expandCode = Get-InlineScript $expandBlock.Groups[1].Value
    Set-Content -LiteralPath $expandScript -Value $expandCode -Encoding ASCII

    # Match execute_command exactly, including its script-file argument and PS 5.1.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $packScript
    if ($LASTEXITCODE -ne 0) { throw 'Pack command failed' }
    Copy-Item -LiteralPath $archive -Destination (Join-Path $expanded 'image-payload.tar')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $expandScript
    if ($LASTEXITCODE -ne 0) { throw 'Expand command failed' }

    foreach ($directory in @('assets', 'scripts', 'toolsets')) {
        Copy-Item -LiteralPath (Join-Path $templateRoot "../$directory") -Destination $reference -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $templateRoot '../../../helpers/software-report-base') -Destination (Join-Path $reference 'scripts/docs-gen') -Recurse -Force
    $referenceHashes = @(Get-TreeHashes $reference)
    $differences = @(Compare-Object $referenceHashes @(Get-TreeHashes $expanded))
    if ($differences.Count) { $differences | Out-Host; throw 'Payload layout/hash mismatch' }
    Write-Host "Layout/hash parity: $($referenceHashes.Count) files, $($differences.Count) differences"

    # Delete one expanded file immediately before the exact template count check.
    Copy-Item -LiteralPath $archive -Destination (Join-Path $expanded 'image-payload.tar')
    $deleteOne = "Get-ChildItem -LiteralPath '$expanded\assets' -File -Recurse | Select-Object -First 1 | Remove-Item -Force`r`n"
    $negativeCode = $expandCode.Replace('  $expected =', $deleteOne + '  $expected =')
    $negativeScript = Join-Path $work 'missing-file.ps1'
    Set-Content -LiteralPath $negativeScript -Value $negativeCode -Encoding ASCII
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $negativeScript
    $negativeExit = $LASTEXITCODE
    if ($negativeExit -ne 1) { throw "Missing-file check returned $negativeExit instead of 1" }
    Write-Host "Missing-file fail-closed check: exit $negativeExit (expected 1)"

    $cleanupScript = Join-Path $work 'cleanup.ps1'
    Set-Content -LiteralPath $cleanupScript -Value (Get-InlineScript $locals[1].Groups[1].Value) -Encoding ASCII
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cleanupScript
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $archive)) { throw 'Host cleanup failed' }
    Write-Host 'Host archive cleanup: PASS'
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not [IO.Path]::GetFullPath($work).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Test path is outside the temp directory: $work"
    }
    Remove-Item -LiteralPath $work -Recurse -Force
}
