################################################################################
##  File:  Test-BaseLayerAge-ALGo.ps1
##  Desc:  L13 thin build guard: refuse a base layer older than MAX_AGE_DAYS.
##         The base is rebuilt monthly after Patch Tuesday (owner ruling
##         2026-11-26), so a thin build on an older base would ship a stale OS.
##         The gallery version is the build time stamp: 1.YYYYMMDD.HHMM (UTC).
##  Env:   BASE_VERSION  (required) gallery version of the base layer
##         MAX_AGE_DAYS  (default 35)
##         ALGO_NOW_UTC  (tests only) 'yyyy-MM-ddTHH:mmZ' to replace the clock
################################################################################

$ErrorActionPreference = 'Stop'

$baseVersion = "$env:BASE_VERSION".Trim()
$maxAgeDays = 35
if ("$env:MAX_AGE_DAYS".Trim() -ne '') { $maxAgeDays = [int]$env:MAX_AGE_DAYS }

if ($baseVersion -notmatch '^\d+\.(\d{8})\.(\d{4})$') {
    throw "Base layer version '$baseVersion' is not 1.YYYYMMDD.HHMM: cannot prove its age, refusing to build on it"
}
$culture = [Globalization.CultureInfo]::InvariantCulture
$styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
$built = [datetime]::ParseExact($Matches[1] + $Matches[2], 'yyyyMMddHHmm', $culture, $styles)

if ("$env:ALGO_NOW_UTC".Trim() -ne '') {
    $now = [datetime]::ParseExact($env:ALGO_NOW_UTC, "yyyy-MM-dd'T'HH:mm'Z'", $culture, $styles)
} else {
    $now = [datetime]::UtcNow
}

$ageDays = [math]::Round(($now - $built).TotalDays, 1)
if ($ageDays -lt -1) {
    throw "Base layer $baseVersion is dated in the future ($built UTC, now $now UTC): refusing"
}
if ($ageDays -gt $maxAgeDays) {
    throw "Base layer $baseVersion is $ageDays days old (limit $maxAgeDays): rebuild the base (build variant base) first"
}
Write-Host "[L13] Base layer $baseVersion built $($built.ToString('yyyy-MM-dd HH:mm', $culture)) UTC, $ageDays days old (limit $maxAgeDays): OK"
