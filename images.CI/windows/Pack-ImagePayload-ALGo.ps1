# Fork-owned host-side packer for the ALGo template (Windows PowerShell 5.1).
param(
    [Parameter(Mandatory)] [string] $TemplateRoot,
    [Parameter(Mandatory)] [string] $ArchivePath
)

$ErrorActionPreference = 'Stop'
$stage = Join-Path ([IO.Path]::GetTempPath()) ('algo-payload-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    foreach ($directory in @('assets', 'scripts', 'toolsets')) {
        Copy-Item -LiteralPath (Join-Path $TemplateRoot "../$directory") -Destination $stage -Recurse -Force
    }
    # No trailing slash in the old file source: preserve software-report-base itself.
    Copy-Item -LiteralPath (Join-Path $TemplateRoot '../../../helpers/software-report-base') -Destination (Join-Path $stage 'scripts/docs-gen') -Recurse -Force
    $count = @(Get-ChildItem -LiteralPath $stage -File -Recurse -Force).Count
    Set-Content -LiteralPath (Join-Path $stage 'payload-file-count.txt') -Value $count -Encoding ASCII
    & tar -cf $ArchivePath -C $stage assets scripts toolsets payload-file-count.txt
    if ($LASTEXITCODE -ne 0) { throw "tar pack failed with exit code $LASTEXITCODE" }
    Write-Host "Packed $count files into $ArchivePath"
} finally {
    # Only remove the unique staging directory created under the host temp directory.
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not [IO.Path]::GetFullPath($stage).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Staging path is outside the temp directory: $stage"
    }
    Remove-Item -LiteralPath $stage -Recurse -Force
}
