$ErrorActionPreference = "Stop"

# Ensure the directory that contains the PowerShell profile exists.
# $PROFILE is the full path to the current user's profile script.
# Docs: about_Profiles
$profileDir = Split-Path -Parent $PROFILE
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}

# Ensure the profile script file itself exists.
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

# Resolve full path to assetlib.ps1 in this repo (where you run this installer).
$scriptPath = (Resolve-Path ".\assetlib.ps1").Path
$repoRoot   = Split-Path $scriptPath -Parent
$configPath = Join-Path $repoRoot "assetlib.config.json"

# One-time config: ask user for their asset store root URL
# and store it in assetlib.config.json, if not already present.
if (-not (Test-Path $configPath)) {
    Write-Host "Configuring asset store root URL for assetlib..." -ForegroundColor Cyan

    $defaultRoot = "https://drive.google.com/drive/my-drive"
    Write-Host "Enter the root URL of your asset store (e.g. shared Google Drive folder for all packs)."
    Write-Host "Example: https://drive.google.com/drive/folders/<your-asset-root-folder-id>"
    $assetRootUrl = Read-Host "Asset store root URL [$defaultRoot]"

    if (-not $assetRootUrl) {
        $assetRootUrl = $defaultRoot
    }

    # Save config as JSON
    @{ assetRootUrl = $assetRootUrl } |
        ConvertTo-Json -Depth 3 |
        Set-Content -Path $configPath -Encoding UTF8

    Write-Host "Saved asset store root URL to assetlib.config.json" -ForegroundColor Green
} else {
    Write-Host "assetlib.config.json already exists; keeping existing asset store root URL." -ForegroundColor Yellow
}

# Define a global "assetlib" function by adding it to the user's profile.
# This means that in any new PowerShell session, typing "assetlib" will
# call this script with whatever arguments you pass (e.g., `assetlib list`).
$func = @"
function assetlib {
    & "$scriptPath" @Args
}
"@

# Append the function definition to the profile file.
Add-Content -Path $PROFILE -Value $func

Write-Host "assetlib command installed into your PowerShell profile."
Write-Host "Close and reopen PowerShell to start using 'assetlib'."
Write-Host "Profile file used: $PROFILE"
