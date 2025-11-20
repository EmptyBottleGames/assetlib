param(
    # First positional argument: which subcommand the user wants to run.
    # We restrict this to a known list using ValidateSet so typos error early.
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("help", "list", "show", "open", "add", "remove", "licenses", "audit")]
    [string]$Command,

    # Many commands optionally take an Id (pack id or license id).
    [Parameter(Position = 1)]
    [string]$Id,

    # Optional filters for `assetlib list`
    [string]$Category,
    [string]$Tag
)

# Stop execution on any non-terminating error.
# Docs: about_Preference_Variables -> $ErrorActionPreference
$ErrorActionPreference = "Stop"

# Paths for our core data files, resolved relative to this script's folder.
# $PSScriptRoot is the directory containing this script.
$manifestPath = Join-Path $PSScriptRoot "packs.json"
$licenseManifestPath = Join-Path $PSScriptRoot "licenses\licenses.json"
$configPath = Join-Path $PSScriptRoot "assetlib.config.json"

# Load configuration from assetlib.config.json
# Currently only supports "assetRootUrl" (root of your shared asset store).
function Get-AssetLibConfig {
    if (Test-Path $configPath) {
        try {
            $json = Get-Content $configPath -Raw
            if ($json.Trim()) {
                # Convert JSON string into a PowerShell object
                # Docs: ConvertFrom-Json
                return $json | ConvertFrom-Json
            }
        } catch {
            Write-Host "Warning: could not read assetlib.config.json, using defaults." -ForegroundColor Yellow
        }
    }

    # Default config if file missing or unreadable
    return [pscustomobject]@{
        assetRootUrl = "https://drive.google.com/drive/my-drive"
    }
}

# Load all packs from packs.json (if present)
function Get-AssetPackManifest {
    if (-not (Test-Path $manifestPath)) {
        return @()
    }
    $json = Get-Content $manifestPath -Raw
    if (-not $json.Trim()) {
        return @()
    }
    return $json | ConvertFrom-Json
}

# Save pack list back to packs.json
function Set-AssetPackManifest {
    param(
        [Parameter(Mandatory = $true)]
        $Packs
    )

    # Convert PowerShell objects to JSON and write to file.
    # Docs: ConvertTo-Json
    $Packs | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
    Write-Host "Updated packs.json"
}

# Load license definitions from licenses/licenses.json
function Get-AssetLicenseManifest {
    if (-not (Test-Path $licenseManifestPath)) {
        Write-Host "License manifest not found at $licenseManifestPath" -ForegroundColor Red
        return @()
    }
    $json = Get-Content $licenseManifestPath -Raw
    if (-not $json.Trim()) {
        return @()
    }
    return $json | ConvertFrom-Json
}

# List all packs, optionally filtered by Category/Tag
function Get-AssetPackList {
    param(
        [string]$Category,
        [string]$Tag
    )

    $packs = Get-AssetPackManifest
    if (-not $packs -or $packs.Count -eq 0) {
        Write-Host "No packs in manifest yet."
        return
    }

    # Filter by category if specified
    if ($Category) {
        # categories is an array, so we use -contains
        $packs = $packs | Where-Object { $_.categories -contains $Category }
    }
    # Filter by tag if specified
    if ($Tag) {
        $packs = $packs | Where-Object { $_.tags -contains $Tag }
    }

    if (-not $packs -or $packs.Count -eq 0) {
        Write-Host "No packs match the specified filters."
        return
    }

    # Pretty-print each pack as: "<id> [cats] - name"
    foreach ($p in $packs) {
        $cats = ($p.categories -join ", ")
        $name = $p.name
        "{0,-30} [{1}]  - {2}" -f $p.id, $cats, $name
    }
}

# Show the full JSON for a single pack
function Get-AssetPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $packs = Get-AssetPackManifest
    $pack = $packs | Where-Object { $_.id -eq $Id }
    if (-not $pack) {
        Write-Host "No pack found with id: $Id" -ForegroundColor Red
        return
    }
    # Dump pack as JSON so you can see everything
    $pack | ConvertTo-Json -Depth 5
}

# Open a pack's cloud_url in the default browser
# Uses Start-Process, which is the idiomatic way to open URLs.
# Docs: Start-Process
function Open-AssetPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $packs = Get-AssetPackManifest
    $pack = $packs | Where-Object { $_.id -eq $Id }
    if (-not $pack) {
        Write-Host "No pack found with id: $Id" -ForegroundColor Red
        return
    }
    if (-not $pack.cloud_url) {
        Write-Host "Pack '$Id' has no cloud_url set." -ForegroundColor Red
        return
    }
    Write-Host "Opening $($pack.cloud_url) in your browser..."
    Start-Process $pack.cloud_url
}

# Print a table of all licenses and whether they are commercial-safe.
function Get-AssetLicenseList {
    $licenses = Get-AssetLicenseManifest
    if (-not $licenses -or $licenses.Count -eq 0) {
        Write-Host "No licenses defined. Edit licenses/licenses.json to add licenses." -ForegroundColor Yellow
        return
    }

    foreach ($lic in $licenses) {
        $flag = if ($lic.commercialAllowed) { "COMMERCIAL" } else { "NON-COMMERCIAL" }
        "{0,-20} {1,-15}  - {2}" -f $lic.id, "[$flag]", $lic.name
    }
}

# Show details for a single license, plus full license text from its .txt file
function Get-AssetLicense {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $licenses = Get-AssetLicenseManifest
    if (-not $licenses -or $licenses.Count -eq 0) {
        Write-Host "No licenses defined." -ForegroundColor Yellow
        return
    }

    $lic = $licenses | Where-Object { $_.id -eq $Id }
    if (-not $lic) {
        Write-Host "No license found with id: $Id" -ForegroundColor Red
        return
    }

    Write-Host "License: $($lic.name)"
    Write-Host "Id:      $($lic.id)"
    Write-Host "Desc:    $($lic.description)"
    Write-Host "Commercial Allowed: $($lic.commercialAllowed)"
    Write-Host ""
    Write-Host "---- Full License Text ----"

    $licenseFilePath = Join-Path (Split-Path $licenseManifestPath -Parent) $lic.file
    if (Test-Path $licenseFilePath) {
        Get-Content $licenseFilePath
    } else {
        Write-Host "License file not found at $licenseFilePath" -ForegroundColor Red
    }
}

# Interactive add flow for a new pack:
# - offers to open the asset store root (from config) in browser
# - collects fields for the pack
# - enforces license commercialAllowed == true
function Add-AssetPack {
    $packs = Get-AssetPackManifest
    $config = Get-AssetLibConfig

    $id = Read-Host "id (e.g. fab_scifi_soldier_pro_pack)"
    if (-not $id) {
        Write-Host "id is required." -ForegroundColor Red
        return
    }
    if ($packs | Where-Object { $_.id -eq $id }) {
        Write-Host "A pack with id '$id' already exists." -ForegroundColor Red
        return
    }

    $name = Read-Host "name (nice human-readable name)"
    $source = Read-Host "source (Fab/Quixel/Self/etc) [Fab]"
    if (-not $source) { $source = "Fab" }

    # QoL: open your asset root (e.g., Google Drive 'GameLibrary/Packs') first,
    # so you can create/find the folder and copy its URL.
    $openDrive = Read-Host "Open asset store root in your browser now to create/find the folder URL? (Y/N) [N]"
    if ($openDrive -match '^[Yy]') {
        $driveUrl = $config.assetRootUrl
        if (-not $driveUrl) {
            $driveUrl = "https://drive.google.com/drive/my-drive"
        }
        Write-Host "Opening $driveUrl..."
        Start-Process $driveUrl
        Write-Host "After creating/finding the folder, copy its URL and paste it below."
    }

    $cloudUrl = Read-Host "Google Drive folder URL"

    $catsRaw = Read-Host "categories (comma-separated: assets, animations, vfx, systems, plugins, etc.)"
    $categories = @()
    if ($catsRaw) {
        $categories = $catsRaw.Split(",") |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    }

    $tagsRaw = Read-Host "tags (comma-separated)"
    $tags = @()
    if ($tagsRaw) {
        $tags = $tagsRaw.Split(",") |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    }

    $notes = Read-Host "notes (optional)"

    Write-Host ""
    Write-Host "Available licenses:" -ForegroundColor Cyan
    Get-AssetLicenseList
    Write-Host ""
    $licenseId = Read-Host "license id (must match one of the IDs above)"

    $licenses = Get-AssetLicenseManifest
    if (-not $licenses -or $licenses.Count -eq 0) {
        Write-Host "No licenses defined; cannot add pack safely." -ForegroundColor Red
        return
    }

    $lic = $licenses | Where-Object { $_.id -eq $licenseId }
    if (-not $lic) {
        Write-Host "License id '$licenseId' not found in licenses/licenses.json." -ForegroundColor Red
        return
    }

    # Core enforcement rule: only allow commercialAllowed == true
    if (-not $lic.commercialAllowed) {
        Write-Host "License '$licenseId' is marked as NON-COMMERCIAL. This pack cannot be added for a for-profit game." -ForegroundColor Red
        return
    }

    $newPack = [PSCustomObject]@{
        id         = $id
        name       = $name
        source     = $source
        cloud_url  = $cloudUrl
        categories = $categories
        tags       = $tags
        notes      = $notes
        licenseId  = $licenseId
    }

    $packs += $newPack
    Set-AssetPackManifest -Packs $packs
    Write-Host "Added pack $id with license '$licenseId'." -ForegroundColor Green
}

# Remove a pack by id (manifest only; does NOT delete Google Drive folder)
function Remove-AssetPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $packs = Get-AssetPackManifest
    $before = $packs.Count
    $remaining = $packs | Where-Object { $_.id -ne $Id }

    if ($remaining.Count -eq $before) {
        Write-Host "No pack found with id: $Id" -ForegroundColor Red
        return
    }

    Set-AssetPackManifest -Packs $remaining
    Write-Host "Removed pack $Id from manifest (Drive folder not deleted)." -ForegroundColor Yellow
}

# Audit all packs against license rules:
# - NO-LICENSE: licenseId missing
# - UNKNOWN-LICENSE: licenseId not found in licenses.json
# - NON-COMMERCIAL: commercialAllowed == false
# - OK: commercialAllowed == true
function Test-AssetPackLicenses {
    $packs = Get-AssetPackManifest
    $licenses = Get-AssetLicenseManifest

    if (-not $packs -or $packs.Count -eq 0) {
        Write-Host "No packs in manifest to audit." -ForegroundColor Yellow
        return
    }

    $issues = 0

    Write-Host "Asset pack license audit:" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------"

    foreach ($p in $packs) {
        $id = $p.id
        $name = $p.name
        $licenseId = $p.licenseId

        if (-not $licenseId) {
            Write-Host ("{0,-30} {1,-25}  {2}" -f $id, "[NO-LICENSE]", $name) -ForegroundColor Red
            $issues++
            continue
        }

        $lic = $licenses | Where-Object { $_.id -eq $licenseId }

        if (-not $lic) {
            Write-Host ("{0,-30} {1,-25}  {2}" -f $id, "[UNKNOWN-LICENSE]", "$name (licenseId: $licenseId)") -ForegroundColor Red
            $issues++
            continue
        }

        if (-not $lic.commercialAllowed) {
            Write-Host ("{0,-30} {1,-25}  {2}" -f $id, "[NON-COMMERCIAL]", "$name (licenseId: $licenseId)") -ForegroundColor Red
            $issues++
        } else {
            Write-Host ("{0,-30} {1,-25}  {2}" -f $id, "[OK]", "$name (licenseId: $licenseId)")
        }
    }

    Write-Host "------------------------------------------------------------"
    if ($issues -gt 0) {
        Write-Host "$issues issue(s) found. Review before shipping." -ForegroundColor Red
    } else {
        Write-Host "All packs pass license audit (commercialAllowed = true)." -ForegroundColor Green
    }
}

# Simple help text – easier than wiring up full Get-Help comment-based help for now.
function Show-AssetLibHelp {
    @"
assetlib - simple asset pack manifest helper

Usage:
  assetlib help
  assetlib list [-Category <assets|animations|vfx|systems>] [-Tag <tag>]
  assetlib show <id>
  assetlib open <id>
  assetlib add
  assetlib remove <id>
  assetlib licenses [<licenseId>]
  assetlib audit

Examples:
  assetlib list
  assetlib list -Category vfx
  assetlib list -Tag sci-fi
  assetlib show fab_scifi_soldier_pro_pack
  assetlib open fab_scifi_soldier_pro_pack
  assetlib add
  assetlib remove fab_old_test_pack
  assetlib licenses
  assetlib licenses Example_Commercial
  assetlib audit
"@ | Write-Host
}

# Top-level command dispatcher
switch ($Command) {
    "help"     { Show-AssetLibHelp }
    "list"     { Get-AssetPackList -Category $Category -Tag $Tag }
    "show"     {
        if (-not $Id) {
            Write-Host "You must provide an id, e.g. assetlib show fab_scifi_pack" -ForegroundColor Yellow
        } else {
            Get-AssetPack -Id $Id
        }
    }
    "open"     {
        if (-not $Id) {
            Write-Host "You must provide an id, e.g. assetlib open fab_scifi_pack" -ForegroundColor Yellow
        } else {
            Open-AssetPack -Id $Id
        }
    }
    "add"      { Add-AssetPack }
    "remove"   {
        if (-not $Id) {
            Write-Host "You must provide an id, e.g. assetlib remove fab_old_pack" -ForegroundColor Yellow
        } else {
            Remove-AssetPack -Id $Id
        }
    }
    "licenses" {
        if ($Id) {
            Get-AssetLicense -Id $Id
        } else {
            Get-AssetLicenseList
        }
    }
    "audit"    { Test-AssetPackLicenses }
}
