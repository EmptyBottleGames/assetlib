$ErrorActionPreference = "Stop"

# Ensure profile directory exists
$profileDir = Split-Path -Parent $PROFILE
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}

# Ensure profile file exists
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

# Resolve full path to assetlib.ps1 in this repo
$scriptPath = (Resolve-Path ".\assetlib.ps1").Path

$func = @"
function assetlib {
    & "$scriptPath" @Args
}
"@

Add-Content -Path $PROFILE -Value $func
Write-Host "assetlib command installed into your PowerShell profile."
Write-Host "Close and reopen PowerShell to start using 'assetlib'."
