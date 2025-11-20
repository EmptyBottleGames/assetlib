$ErrorActionPreference = "Stop"

# Ensure the directory that contains the PowerShell profile exists.
# $PROFILE is the full path to the current user's profile script.
# Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_profiles
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

# One-time config: ask user for their asset store root URL and store it in
# assetlib.config.json, if not already present. Also initialize licenseMode.
if (-not (Test-Path $configPath)) {
    Write-Host "Configuring asset store root URL for assetlib..." -ForegroundColor Cyan

    $defaultRoot = "https://drive.google.com/drive/my-drive"
    Write-Host "Enter the root URL of your asset store (e.g. shared Google Drive folder for all packs)."
    Write-Host "Example: https://drive.google.com/drive/folders/<your-asset-root-folder-id>"
    $assetRootUrl = Read-Host "Asset store root URL [$defaultRoot]"

    if (-not $assetRootUrl) {
        $assetRootUrl = $defaultRoot
    }

    $config = [pscustomobject]@{
        assetRootUrl = $assetRootUrl
        licenseMode  = "restrictive"  # default to safest mode
    }

    # Save config as JSON
    $config |
        ConvertTo-Json -Depth 3 |
        Set-Content -Path $configPath -Encoding UTF8

    # Docs:
    #   ConvertTo-Json: https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertto-json
    #   Set-Content   : https://learn.microsoft.com/powershell/module/microsoft.powershell.management/set-content
    Write-Host "Saved asset store root URL and license mode to assetlib.config.json" -ForegroundColor Green
}
else {
    Write-Host "assetlib.config.json already exists; keeping existing configuration." -ForegroundColor Yellow
}

# Define a global "assetlib" function by adding it to the user's profile.
# This means that in any new PowerShell session, typing "assetlib" will
# call this script with whatever arguments you pass (e.g., `assetlib list`).
#
# We explicitly throw a helpful error if assetlib is called with NO arguments,
# so it fails with a clear message instead of a cryptic parameter binding error.
# Note the use of the backtick (`) to escape `$args` inside the here-string so
# it is not expanded when this installer runs.
$func = @"
function assetlib {
    if (`$args.Count -eq 0) {
        throw "assetlib requires a command. Run 'assetlib help' for usage."
    }
    & "$scriptPath" @args
}
"@

# Append the function definition to the profile file.
Add-Content -Path $PROFILE -Value $func

Write-Host "assetlib command installed into your PowerShell profile."
Write-Host "Close and reopen PowerShell to start using 'assetlib'."
Write-Host "Profile file used: $PROFILE"
