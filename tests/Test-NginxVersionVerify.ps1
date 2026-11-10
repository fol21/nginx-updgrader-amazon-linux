# Spec-as-code for verification actions in Update-Nginx.ps1.
# Run: powershell -NoProfile -File .\tests\Test-NginxVersionVerify.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$ps1Path = Join-Path $repoRoot "Update-Nginx.ps1"
$src = Get-Content -LiteralPath $ps1Path -Raw

# Load the pure compare helpers from the product script (single source of truth).
$pattern = '(?ms)(# Parses "1\.30\.6".*?)^function Invoke-VerificationStage'
$m = [regex]::Match($src, $pattern)
if (-not $m.Success) {
    throw "Could not extract version helpers from Update-Nginx.ps1"
}
Invoke-Expression $m.Groups[1].Value

function Assert-Equal {
    param([string]$Got, [string]$Expected, [string]$Case)
    if ($Got -ne $Expected) {
        throw "FAIL: $Case -> got '$Got', expected '$Expected'"
    }
    Write-Host "OK  $Case -> $Got"
}

$target = "1.30.6"

# Decision table: (current, reachable) -> action
Assert-Equal (Get-UpdateAction -CurrentVersion "1.30.6" -TargetVersion $target -Reachable:$true) `
    "AlreadyCurrentOrGreater" "equal to target"
Assert-Equal (Get-UpdateAction -CurrentVersion "1.30.7" -TargetVersion $target -Reachable:$true) `
    "AlreadyCurrentOrGreater" "greater than target (keep newer)"
Assert-equal (Get-UpdateAction -CurrentVersion "1.31.0" -TargetVersion $target -Reachable:$true) `
    "AlreadyCurrentOrGreater" "much greater than target"
Assert-equal (Get-UpdateAction -CurrentVersion "1.28.0" -TargetVersion $target -Reachable:$true) `
    "Upgrade" "lower minor"
Assert-equal (Get-UpdateAction -CurrentVersion "1.9.0" -TargetVersion $target -Reachable:$true) `
    "Upgrade" "lower with fewer digits (numeric, not string)"
Assert-equal (Get-UpdateAction -CurrentVersion "(not installed)" -TargetVersion $target -Reachable:$true) `
    "Install" "missing nginx"
Assert-equal (Get-UpdateAction -CurrentVersion "(unknown)" -TargetVersion $target -Reachable:$true) `
    "Upgrade" "unparsed version string"
Assert-equal (Get-UpdateAction -CurrentVersion "1.30.6" -TargetVersion $target -Reachable:$false) `
    "SkipUnreachable" "SSH failed"

if (-not (Test-NginxVersionAtLeast -Current "1.30.7" -Minimum "1.30.6")) {
    throw "FAIL: Test-NginxVersionAtLeast 1.30.7 >= 1.30.6"
}
if (Test-NginxVersionAtLeast -Current "1.28.0" -Minimum "1.30.6") {
    throw "FAIL: Test-NginxVersionAtLeast 1.28.0 >= 1.30.6 should be false"
}

Write-Host "All verification cases passed."
exit 0
