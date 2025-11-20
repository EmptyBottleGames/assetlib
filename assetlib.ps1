param(
    # First positional argument: which subcommand the user wants to run.
    # We restrict this to a known list using ValidateSet so typos error early.
    # Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_parameters
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("help", "list", "show", "open", "add", "remove", "licenses", "audit", "install", "uninstall", "mode")]
    [string]$Command,

    # Many commands optionally take an Id (pack id or license id).
    [Parameter(Position = 1)]
    [string]$Id,

    # Optional filters for `assetlib list`
    [string]$Category,
    [string]$Tag,

    # For `assetlib audit -Prune`
    [switch]$Prune,

    # For `assetlib audit -Prune -Licenses <ids>`
    [string[]]$Licenses,

    # For destructive operations (`install`, `uninstall`, `remove`, `audit -Prune`)
    [switch]$Force
)

# Stop execution on any non-terminating error so we can catch problems early.
# Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_preference_variables#the-erroractionpreference-variable
$ErrorActionPreference = "Stop"

# Paths for our core data files, resolved relative to this script's folder.
# $PSScriptRoot is the directory containing this script.
# Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_automatic_variables
$manifestPath = Join-Path $PSScriptRoot "packs.json"
$licenseManifestPath = Join-Path $PSScriptRoot "licenses\licenses.json"
$configPath = Join-Path $PSScriptRoot "assetlib.config.json"

# region: Config handling ------------------------------------------------------

# Load configuration from assetlib.config.json.
# Currently supports:
#   - assetRootUrl : root of your shared asset store (e.g., Google Drive folder)
#   - licenseMode  : "restrictive" or "permissive"
function Get-AssetLibConfig {
    if (Test-Path $configPath) {
        try {
            $json = Get-Content $configPath -Raw  # Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.management/get-content
            if ($json.Trim()) {
                $config = $json | ConvertFrom-Json # Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertfrom-json

                # Ensure licenseMode property exists; default to "restrictive" to be safe.
                if (-not $config.PSObject.Properties.Name -contains 'licenseMode' -or -not $config.licenseMode) {
                    $config | Add-Member -NotePropertyName 'licenseMode' -NotePropertyValue 'restrictive'
                }
                return $config
            }
        }
        catch {
            Write-Warning "Warning: could not read assetlib.config.json, using defaults. Error: $($_.Exception.Message)"
        }
    }

    # Default config if file missing or unreadable
    return [pscustomobject]@{
        assetRootUrl = "https://drive.google.com/drive/my-drive"
        licenseMode  = "restrictive"
    }
}

# Save configuration back to assetlib.config.json.
function Set-AssetLibConfig {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    try {
        $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8
        # Docs:
        #   ConvertTo-Json: https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertto-json
        #   Set-Content   : https://learn.microsoft.com/powershell/module/microsoft.powershell.management/set-content
        Write-Host "Updated assetlib.config.json"
    }
    catch {
        Write-Error "Failed to write assetlib.config.json: $($_.Exception.Message)"
        throw
    }
}

# endregion --------------------------------------------------------------------

# region: Manifest helpers -----------------------------------------------------

# Load all packs from packs.json (if present).
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

# Save pack list back to packs.json.
function Set-AssetPackManifest {
    param(
        [Parameter(Mandatory = $true)]
        $Packs
    )

    try {
        $Packs | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
        Write-Host "Updated packs.json"
    }
    catch {
        Write-Error "Failed to write packs.json: $($_.Exception.Message)"
        throw
    }
}

# Load license definitions from licenses/licenses.json.
function Get-AssetLicenseManifest {
    if (-not (Test-Path $licenseManifestPath)) {
        Write-Error "License manifest not found at $licenseManifestPath"
        return @()
    }
    $json = Get-Content $licenseManifestPath -Raw
    if (-not $json.Trim()) {
        return @()
    }
    return $json | ConvertFrom-Json
}

# Given a pack + license manifest, classify its license status.
# Returns a PSCustomObject with Status and License (metadata or $null).
function Get-AssetPackLicenseStatus {
    param(
        [Parameter(Mandatory = $true)] $Pack,
        [Parameter(Mandatory = $true)] $Licenses
    )

    $licenseId = $Pack.licenseId

    if (-not $licenseId) {
        return [pscustomobject]@{
            Status    = 'NO-LICENSE'
            License   = $null
            LicenseId = $null
        }
    }

    $lic = $Licenses | Where-Object { $_.id -eq $licenseId }
    if (-not $lic) {
        return [pscustomobject]@{
            Status    = 'UNKNOWN-LICENSE'
            License   = $null
            LicenseId = $licenseId
        }
    }

    if (-not $lic.commercialAllowed) {
        return [pscustomobject]@{
            Status    = 'NON-COMMERCIAL'
            License   = $lic
            LicenseId = $licenseId
        }
    }

    return [pscustomobject]@{
        Status    = 'OK'
        License   = $lic
        LicenseId = $licenseId
    }
}

# endregion --------------------------------------------------------------------

# region: Misc helpers ---------------------------------------------------------

# Convert common Google Drive URLs into a direct-download link suitable for
# Invoke-WebRequest. This lets you paste the normal "Get link" URL from Drive.
#
# Supported patterns:
#   - https://drive.google.com/file/d/<FILE_ID>/view?usp=sharing
#   - https://drive.google.com/open?id=<FILE_ID>
#   - Anything already starting with https://drive.google.com/uc?...
#
# For unsupported or non-Drive URLs, the original value is returned.
# This keeps the function safe for other hosts (e.g. S3, itch.io, etc.).
#
# Docs for [regex] in PowerShell:
#   https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_regular_expressions
function Convert-ToGoogleDriveDirectDownloadUrl {
    param(
        [string]$Url
    )

    if (-not $Url) {
        return $null
    }

    # Already a direct-download link? Keep as-is.
    if ($Url -match '^https://drive\.google\.com/uc\?') {
        return $Url
    }

    # Warn if it looks like a FOLDER url - those won't work as archive_url.
    if ($Url -match '^https://drive\.google\.com/drive/folders/') {
        Write-Warning "The provided URL looks like a Google Drive FOLDER link. archive_url should point to a ZIP FILE, not a folder."
        # We still return the original so the caller can decide what to do.
        return $Url
    }

    # Pattern 1: https://drive.google.com/file/d/<FILE_ID>/view?usp=sharing
    $fileMatch = [regex]::Match($Url, 'https://drive\.google\.com/file/d/([^/]+)')
    if ($fileMatch.Success) {
        $fileId = $fileMatch.Groups[1].Value
        if ($fileId) {
            return "https://drive.google.com/uc?export=download&id=$fileId"
        }
    }

    # Pattern 2: ...id=<FILE_ID> in the query string (open?id=... or similar)
    $idIndex = $Url.IndexOf('id=')
    if ($idIndex -ge 0) {
        $idPart = $Url.Substring($idIndex + 3)
        $ampIndex = $idPart.IndexOf('&')
        if ($ampIndex -ge 0) {
            $idPart = $idPart.Substring(0, $ampIndex)
        }
        if ($idPart) {
            return "https://drive.google.com/uc?export=download&id=$idPart"
        }
    }

    # Fallback: not a recognized Drive file URL - just return original.
    return $Url
}


# endregion --------------------------------------------------------------------

# region: Unreal project helpers ----------------------------------------------

# Detect if Unreal Editor is running.
# Checks for common process names: UnrealEditor, UnrealEditor-Cmd, UE4Editor, UE5Editor
function Test-UnrealEditorRunning {
    try {
        $procs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^UnrealEditor' -or
            $_.Name -match '^UE[45]Editor'
        }

        return ($procs.Count -gt 0)
    }
    catch {
        # If we cannot detect, fail safe and assume it's running
        return $true
    }
}

# Detect the current Unreal project root.
# We define it as a directory that:
#  - Contains at least one *.uproject file
#  - Contains a Content/ folder
function Get-UnrealProjectRoot {
    param(
        [string]$Path = (Get-Location).Path
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    $uprojects = Get-ChildItem -Path $Path -Filter *.uproject -File -ErrorAction SilentlyContinue
    if (-not $uprojects -or $uprojects.Count -eq 0) {
        return $null
    }

    $contentPath = Join-Path $Path 'Content'
    if (-not (Test-Path $contentPath)) {
        return $null
    }

    return $Path
}

# Given a pack and an Unreal project root, compute the expected install path.
# For content packs:  Content/AssetLib/<pack.id>/
# For plugin packs:   Plugins/<pluginFolderName or pack.id>/
function Get-AssetPackInstallPath {
    param(
        [Parameter(Mandatory = $true)][object]$Pack,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $packType = if ($Pack.PSObject.Properties.Name -contains 'packType' -and $Pack.packType) {
        $Pack.packType
    }
    else {
        'content'
    }

    if ($packType -eq 'plugin') {
        $pluginFolderName = if ($Pack.PSObject.Properties.Name -contains 'pluginFolderName' -and $Pack.pluginFolderName) {
            $Pack.pluginFolderName
        }
        else {
            $Pack.id
        }

        $pluginsRoot = Join-Path $ProjectRoot 'Plugins'
        return Join-Path $pluginsRoot $pluginFolderName
    }
    else {
        # Default to content pack under Content/AssetLib/<id>/
        $assetLibRoot = Join-Path (Join-Path $ProjectRoot 'Content') 'AssetLib'
        return Join-Path $assetLibRoot $Pack.id
    }
}

# endregion --------------------------------------------------------------------

# region: Listing & basic operations ------------------------------------------

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

    # Filter by category if specified.
    # categories is expected to be an array in packs.json.
    if ($Category) {
        $packs = $packs | Where-Object { $_.categories -contains $Category }
    }

    # Filter by tag if specified.
    if ($Tag) {
        $packs = $packs | Where-Object { $_.tags -contains $Tag }
    }

    if (-not $packs -or $packs.Count -eq 0) {
        Write-Host "No packs match the specified filters."
        return
    }

    foreach ($p in $packs) {
        $cats = if ($p.categories -is [System.Array]) { ($p.categories -join ", ") } else { [string]$p.categories }
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
        Write-Error "No pack found with id: $Id"
        return
    }

    # Dump pack as JSON so you can see everything.
    $pack | ConvertTo-Json -Depth 5
}

# Open a pack's cloud_url in the default browser.
# Uses Start-Process, which is the idiomatic way to open URLs.
# Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-process
function Open-AssetPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $packs = Get-AssetPackManifest
    $pack = $packs | Where-Object { $_.id -eq $Id }
    if (-not $pack) {
        Write-Error "No pack found with id: $Id"
        return
    }
    if (-not $pack.cloud_url) {
        Write-Error "Pack '$Id' has no cloud_url set."
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
        "{0,-30} {1,-15}  - {2}" -f $lic.id, "[$flag]", $lic.name
    }
}

# Show details for a single license, plus full license text from its .txt file.
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
        Write-Error "No license found with id: $Id"
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
    }
    else {
        Write-Error "License file not found at $licenseFilePath"
    }
}

# endregion --------------------------------------------------------------------

# region: Add / Remove pack ----------------------------------------------------

# Interactive add flow for a new pack:
# - offers to open the asset store root (from config) in browser
# - collects fields for the pack
# - automatically converts Google Drive file URLs into direct-download URLs
#   for archive_url (uc?export=download&id=...)
# - enforces license rules based on licenseMode
function Add-AssetPack {
    $packs = Get-AssetPackManifest
    $config = Get-AssetLibConfig
    $licenses = Get-AssetLicenseManifest

    if (-not $licenses -or $licenses.Count -eq 0) {
        Write-Error "No licenses defined; cannot add pack safely."
        return
    }

    $id = Read-Host "id (e.g. fab_scifi_soldier_pro_pack)"
    if (-not $id) {
        Write-Error "id is required."
        return
    }
    if ($packs | Where-Object { $_.id -eq $id }) {
        Write-Error "A pack with id '$id' already exists."
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

    $cloudUrl = Read-Host "Google Drive folder URL (cloud_url)"

    # archive_url handling:
    # We allow the user to paste either:
    #   - a full Drive FILE URL (e.g. 'file/d/<id>/view?usp=sharing'), or
    #   - a prebuilt direct download URL, or
    #   - any other host URL (S3, itch.io, etc.).
    #
    # If it looks like a Google Drive file URL, we convert it to the direct
    # download form for you so you don't have to manually extract FILE_ID.
    $archiveUrlRaw = Read-Host "Direct download archive URL or Drive FILE URL (archive_url, optional)"
    $archiveUrl = $null
    if ($archiveUrlRaw) {
        $archiveUrl = Convert-ToGoogleDriveDirectDownloadUrl -Url $archiveUrlRaw
        if ($archiveUrl -ne $archiveUrlRaw) {
            Write-Host "Converted Google Drive URL to direct download form:" -ForegroundColor Cyan
            Write-Host "  $archiveUrl"
        }
        else {
            Write-Host "archive_url stored as:" -ForegroundColor Cyan
            Write-Host "  $archiveUrl"
        }
    }

    $catsRaw = Read-Host "categories (comma-separated: assets, animations, vfx, systems, plugin, etc.)"
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

    $licStatus = [pscustomobject]@{
        Status    = 'NO-LICENSE'
        License   = $null
        LicenseId = $null
    }
    if ($licenseId) {
        $licStatus = Get-AssetPackLicenseStatus -Pack ([pscustomobject]@{ licenseId = $licenseId }) -Licenses $licenses
    }

    $licenseMode = $config.licenseMode

    if ($licenseMode -eq 'restrictive') {
        # In restrictive mode, we only allow packs with Status 'OK'.
        switch ($licStatus.Status) {
            'NO-LICENSE' {
                Write-Error "No licenseId provided; cannot add pack in restrictive mode."
                return
            }
            'UNKNOWN-LICENSE' {
                Write-Error "License id '$licenseId' not found in licenses/licenses.json (restrictive mode)."
                return
            }
            'NON-COMMERCIAL' {
                Write-Error "License '$licenseId' is marked as NON-COMMERCIAL. This pack cannot be added in restrictive mode."
                return
            }
            'OK' { }
        }
    }
    else {
        # Permissive mode: allow but warn on non-OK statuses.
        switch ($licStatus.Status) {
            'NO-LICENSE' {
                Write-Warning "No licenseId provided; pack added in permissive mode but flagged as NO-LICENSE."
            }
            'UNKNOWN-LICENSE' {
                Write-Warning "License id '$licenseId' not found in licenses/licenses.json; pack added in permissive mode but flagged as UNKNOWN-LICENSE."
            }
            'NON-COMMERCIAL' {
                Write-Warning "License '$licenseId' is NON-COMMERCIAL; pack added in permissive mode but only safe for non-commercial contexts."
            }
            'OK' { }
        }
    }

    # Determine packType and pluginFolderName
    $packType = Read-Host "pack type (content/plugin) [content]"
    if (-not $packType) { $packType = 'content' }

    $pluginFolderName = $null
    if ($packType -eq 'plugin') {
        $pluginFolderName = Read-Host "plugin folder name under Plugins/ (optional, default = id) [$id]"
        if (-not $pluginFolderName) { $pluginFolderName = $id }
    }

    $newPack = [PSCustomObject]@{
        id               = $id
        name             = $name
        source           = $source
        cloud_url        = $cloudUrl
        archive_url      = $archiveUrl
        categories       = $categories
        tags             = $tags
        notes            = $notes
        licenseId        = $licenseId
        packType         = $packType
        pluginFolderName = $pluginFolderName
    }

    $packs += $newPack
    Set-AssetPackManifest -Packs $packs
    Write-Host "Added pack $id with license '$licenseId' in mode '$licenseMode'." -ForegroundColor Green
}


# Remove a pack by id from the manifest only; does NOT delete Google Drive or project files.
function Remove-AssetPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [switch]$Force
    )

    $packs = Get-AssetPackManifest
    $before = $packs.Count
    $remaining = $packs | Where-Object { $_.id -ne $Id }

    if ($remaining.Count -eq $before) {
        Write-Error "No pack found with id: $Id"
        return
    }

    if (-not $Force) {
        $confirm = Read-Host "Remove pack '$Id' from manifest only (does not delete any files)? (Y/N) [N]"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "Removal cancelled."
            return
        }
    }

    Set-AssetPackManifest -Packs $remaining
    Write-Host "Removed pack $Id from manifest (no project or Drive files were deleted)." -ForegroundColor Yellow
}

# endregion --------------------------------------------------------------------

# region: Install / Uninstall into Unreal project -----------------------------

# Install a pack into the current Unreal project root.
# Downloads archive_url and extracts into the appropriate folder based on packType.
function Install-AssetPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [switch]$Force
    )

    $projectRoot = Get-UnrealProjectRoot
    if (-not $projectRoot) {
        Write-Error "This command must be run from the root of an Unreal project (folder with a .uproject file and a Content/ folder)."
        return
    }

    # Editor safety: don't install while Unreal Editor is running unless -Force is used.
    if (Test-UnrealEditorRunning) {
        if (-not $Force) {
            Write-Error "Unreal Editor appears to be running. Close the editor before installing a pack, or run again with -Force to override."
            return
        }
        else {
            Write-Warning "Unreal Editor appears to be running. Forcing installation anyway."
        }
    }

    $packs = Get-AssetPackManifest
    $pack = $packs | Where-Object { $_.id -eq $Id }
    if (-not $pack) {
        Write-Error "No pack found with id: $Id"
        return
    }

    $licenses = Get-AssetLicenseManifest
    $config = Get-AssetLibConfig
    $licenseMode = $config.licenseMode

    $status = Get-AssetPackLicenseStatus -Pack $pack -Licenses $licenses

    if ($licenseMode -eq 'restrictive') {
        if ($status.Status -ne 'OK') {
            Write-Error "Cannot install pack '$Id' in restrictive mode; license status is '$($status.Status)'."
            return
        }
    }
    else {
        if ($status.Status -ne 'OK') {
            Write-Warning "Installing pack '$Id' in permissive mode with license status '$($status.Status)'. Use only for non-production/prototype contexts."
        }
    }

    if (-not $pack.archive_url) {
        Write-Error "Pack '$Id' has no archive_url configured. Set archive_url in packs.json or via 'assetlib add' and try again."
        return
    }

    $targetPath = Get-AssetPackInstallPath -Pack $pack -ProjectRoot $projectRoot

    # Safety check: ensure targetPath is under projectRoot
    if (-not $targetPath.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Error "Resolved install path '$targetPath' is not under project root '$projectRoot'. Aborting for safety."
        return
    }

    if (Test-Path $targetPath) {
        if (-not $Force) {
            $confirm = Read-Host "Target '$targetPath' already exists. Overwrite? (Y/N) [N]"
            if ($confirm -notmatch '^[Yy]') {
                Write-Host "Install cancelled."
                return
            }
        }

        try {
            Remove-Item -LiteralPath $targetPath -Recurse -Force
        }
        catch {
            Write-Error "Failed to remove existing target path '$targetPath': $($_.Exception.Message)"
            return
        }
    }

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("assetlib_" + $Id + "_" + [System.Guid]::NewGuid().ToString() + ".zip")
    $tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) ("assetlib_extract_" + $Id + "_" + [System.Guid]::NewGuid().ToString())

    try {
        Write-Host "Downloading archive for '$Id' from $($pack.archive_url)..."
        # Docs: Invoke-WebRequest
        # https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/invoke-webrequest
        Invoke-WebRequest -Uri $pack.archive_url -OutFile $tempFile -UseBasicParsing
    }
    catch {
        Write-Error "Failed to download archive from '$($pack.archive_url)': $($_.Exception.Message)"
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force
        }
        return
    }

    # Before extracting, sanity-check that the file looks like a ZIP.
    # ZIP files typically start with the bytes 'PK' (0x50 0x4B).
    # We use System.IO.File APIs here so it works on both Windows PowerShell and PowerShell 7+.
    try {
        $headerBytes = New-Object byte[] 4

        # Docs: System.IO.File.OpenRead
        # https://learn.microsoft.com/dotnet/api/system.io.file.openread
        $fs = [System.IO.File]::OpenRead($tempFile)
        try {
            $read = $fs.Read($headerBytes, 0, $headerBytes.Length)
        }
        finally {
            $fs.Dispose()
        }
    }
    catch {
        Write-Error "Downloaded file could not be read from '$tempFile': $($_.Exception.Message)"
        return
    }

    if ($read -lt 2 -or
        $headerBytes[0] -ne 0x50 -or $headerBytes[1] -ne 0x4B) {

        # Keep a copy of what we downloaded so you can inspect it.
        $debugCopy = Join-Path $projectRoot ("assetlib_failed_download_" + $Id + ".bin")
        Copy-Item -LiteralPath $tempFile -Destination $debugCopy -Force

        Write-Error @"
Downloaded file for pack '$Id' does not look like a ZIP archive.
This often means Google Drive returned an HTML page (login/confirm) instead of the file.

Saved the raw downloaded file to:
  $debugCopy

Check this file in a browser or text editor to see what Drive is returning.
Verify that:
  - The Drive file itself is actually a .zip
  - Sharing is set to 'Anyone with the link can view'
  - The archive_url in packs.json uses a FILE id, not a FOLDER url.
"@
        return
    }


    try {
        Write-Host "Extracting archive to temporary folder '$tempExtract'..."
        # Docs: Expand-Archive
        # https://learn.microsoft.com/powershell/module/microsoft.powershell.archive/expand-archive
        Expand-Archive -Path $tempFile -DestinationPath $tempExtract -Force
    }
    catch {
        # Keep a copy of the downloaded file for debugging on extraction errors.
        $debugCopy = Join-Path $projectRoot ("assetlib_failed_extract_" + $Id + ".zip")
        Copy-Item -LiteralPath $tempFile -Destination $debugCopy -Force

        Write-Error @"
Failed to extract archive for '$Id' into temporary folder '$tempExtract': $($_.Exception.Message)

A copy of the downloaded file was saved to:
  $debugCopy

Try opening that file with 7-Zip or Explorer to confirm it is a valid ZIP archive.
If it is not, double-check the archive_url in packs.json and the Drive sharing settings.
"@
        return
    }

    try {
        # Now we inspect the extracted structure to avoid double-nesting like:
        #   Content\AssetLib\<id>\<id>\<content>
        #
        # Strategy:
        #   - If the temp extract root contains exactly ONE top-level directory
        #     and NO files, treat that directory as a wrapper folder and move
        #     its CONTENTS into targetPath (flattening).
        #   - Otherwise, move everything from the temp extract root into targetPath.
        #
        # This means typical "zipped a folder" archives behave nicely without
        # forcing you to zip at the exact project-relative structure.

        $topEntries = Get-ChildItem -Path $tempExtract
        $topDirs = $topEntries | Where-Object { $_.PSIsContainer }
        $topFiles = $topEntries | Where-Object { -not $_.PSIsContainer }

        # Ensure targetPath exists before moving content.
        if (-not (Test-Path $targetPath)) {
            New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
        }

        if ($topDirs.Count -eq 1 -and $topFiles.Count -eq 0) {
            # Single wrapper directory case: flatten it.
            $wrapperDir = $topDirs[0]
            Write-Host "Detected single top-level folder '$($wrapperDir.Name)' in archive. Flattening into '$targetPath' to avoid double nesting..."

            Get-ChildItem -Path $wrapperDir.FullName | ForEach-Object {
                $dest = Join-Path $targetPath $_.Name
                Move-Item -LiteralPath $_.FullName -Destination $dest -Force
            }
        }
        else {
            # Mixed files/folders or multiple top-level entries: move them all as-is.
            Write-Host "Archive has multiple top-level entries or files; copying structure into '$targetPath'..."
            Get-ChildItem -Path $tempExtract | ForEach-Object {
                $dest = Join-Path $targetPath $_.Name
                Move-Item -LiteralPath $_.FullName -Destination $dest -Force
            }
        }

        Write-Host "Installed pack '$Id' to '$targetPath' (licenseMode=$licenseMode)." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed while moving extracted content into '$targetPath': $($_.Exception.Message)"
    }
    finally {
        # Clean up temp locations if they exist.
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force
        }
        if (Test-Path $tempExtract) {
            Remove-Item $tempExtract -Recurse -Force
        }
    }
}

# Uninstall a pack from the current Unreal project root.
# Deletes the installed folder determined by packType, without touching packs.json.
function Uninstall-AssetPackFromProject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [switch]$Force
    )

    $projectRoot = Get-UnrealProjectRoot
    if (-not $projectRoot) {
        Write-Error "This command must be run from the root of an Unreal project (folder with a .uproject file and a Content/ folder)."
        return
    }

    $packs = Get-AssetPackManifest
    $pack = $packs | Where-Object { $_.id -eq $Id }
    if (-not $pack) {
        Write-Error "No pack found with id: $Id"
        return
    }

    # Prevent uninstalling while Unreal Editor is running unless -Force is used
    if (Test-UnrealEditorRunning) {
        if (-not $Force) {
            Write-Error "Unreal Editor appears to be running. Close the editor before uninstalling a pack, or run again with -Force to override."
            return
        }
        else {
            Write-Warning "Unreal Editor appears to be running. Forcing uninstall anyway."
        }
    }


    $targetPath = Get-AssetPackInstallPath -Pack $pack -ProjectRoot $projectRoot

    if (-not (Test-Path $targetPath)) {
        Write-Host "Pack '$Id' does not appear to be installed in this project (no folder at '$targetPath')."
        return
    }

    if (-not $Force) {
        Write-Host "This will delete all files under: $targetPath" -ForegroundColor Yellow
        $confirm = Read-Host "Proceed with uninstall? (Y/N) [N]"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "Uninstall cancelled."
            return
        }
    }

    # Safety: ensure we are deleting under projectRoot
    if (-not $targetPath.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Error "Resolved uninstall path '$targetPath' is not under project root '$projectRoot'. Aborting for safety."
        return
    }

    try {
        Remove-Item -LiteralPath $targetPath -Recurse -Force
        Write-Host "Uninstalled pack '$Id' from this project (removed '$targetPath')." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to uninstall pack '$Id' from '$targetPath': $($_.Exception.Message)"
    }
}

# endregion --------------------------------------------------------------------

# region: Audit & prune -------------------------------------------------------

# Audit all packs against license rules:
# - NO-LICENSE: licenseId missing
# - UNKNOWN-LICENSE: licenseId not found in licenses.json
# - NON-COMMERCIAL: commercialAllowed == false
# - OK: commercialAllowed == true
#
# If -Prune is provided, and licenseMode is 'restrictive', removes installed packs
# from the current Unreal project based on license selection rules.
function Test-AssetPackLicenses {
    param(
        [switch]$Prune,
        [string[]]$Licenses,
        [switch]$Force
    )

    $packs = Get-AssetPackManifest
    $licenses = Get-AssetLicenseManifest
    $config = Get-AssetLibConfig

    if (-not $packs -or $packs.Count -eq 0) {
        Write-Host "No packs in manifest to audit." -ForegroundColor Yellow
        return
    }

    $issues = 0
    $results = New-Object System.Collections.Generic.List[object]

    Write-Host "Asset pack license audit:" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------"

    foreach ($p in $packs) {
        $status = Get-AssetPackLicenseStatus -Pack $p -Licenses $licenses

        $id = $p.id
        $name = $p.name
        $licenseId = $p.licenseId

        switch ($status.Status) {
            'NO-LICENSE' {
                Write-Host ("{0,-30} {1,-25}  {2}" -f $id, "[NO-LICENSE]", $name) -ForegroundColor Red
                $issues++
            }
            'UNKNOWN-LICENSE' {
                Write-Host ("{0,-30} {1,-25}  {2}" -f $id, "[UNKNOWN-LICENSE]", "$name (licenseId: $licenseId)") -ForegroundColor Red
                $issues++
            }
            'NON-COMMERCIAL' {
                Write-Host ("{0,-30} {1,-25}  {2}" -f $id, "[NON-COMMERCIAL]", "$name (licenseId: $licenseId)") -ForegroundColor Red
                $issues++
            }
            'OK' {
                Write-Host ("{0,-30} {1,-25}  {2}" -f $id, "[OK]", "$name (licenseId: $licenseId)")
            }
        }

        $results.Add([pscustomobject]@{
                Pack      = $p
                Status    = $status.Status
                License   = $status.License
                LicenseId = $status.LicenseId
            })
    }

    Write-Host "------------------------------------------------------------"
    if ($issues -gt 0) {
        Write-Host "$issues issue(s) found. Review before shipping." -ForegroundColor Red
    }
    else {
        Write-Host "All packs pass license audit (commercialAllowed = true)." -ForegroundColor Green
    }

    if (-not $Prune) {
        return
    }

    # From here on we are in prune mode: delete installed packs in the current project.
    if ($config.licenseMode -ne 'restrictive') {
        Write-Error "audit -Prune is only allowed in 'restrictive' license mode (current mode: '$($config.licenseMode)'). Use 'assetlib mode restrictive' to switch."
        return
    }

    $projectRoot = Get-UnrealProjectRoot
    if (-not $projectRoot) {
        Write-Error "audit -Prune must be run from the root of an Unreal project (folder with a .uproject file and a Content/ folder)."
        return
    }

    # Prevent pruning while Unreal Editor is running unless -Force is used
    if (Test-UnrealEditorRunning) {
        if (-not $Force) {
            Write-Error "Unreal Editor appears to be running. Close the editor before pruning installed packs, or run again with -Force to override."
            return
        }
        else {
            Write-Warning "Unreal Editor appears to be running. Forcing prune anyway."
        }
    }


    $targetsToRemove = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $results) {
        $pack = $entry.Pack
        $status = $entry.Status
        $lid = $entry.LicenseId

        # Determine if this pack is installed in the current project.
        $installPath = Get-AssetPackInstallPath -Pack $pack -ProjectRoot $projectRoot
        if (-not (Test-Path $installPath)) {
            continue
        }

        $shouldRemove = $false

        if ($Licenses -and $Licenses.Count -gt 0) {
            # Explicit license selection.
            if (-not $lid) {
                if ($Licenses -contains 'NO-LICENSE') { $shouldRemove = $true }
            }
            elseif (-not ($licenses | Where-Object { $_.id -eq $lid })) {
                if ($Licenses -contains 'UNKNOWN-LICENSE') { $shouldRemove = $true }
            }
            else {
                if ($Licenses -contains $lid) { $shouldRemove = $true }
            }
        }
        else {
            # Default behavior: remove all installed packs that are not commercial-safe.
            if ($status -ne 'OK') {
                $shouldRemove = $true
            }
        }

        if ($shouldRemove) {
            $targetsToRemove.Add([pscustomobject]@{
                    Pack   = $pack
                    Path   = $installPath
                    Status = $status
                })
        }
    }

    if ($targetsToRemove.Count -eq 0) {
        Write-Host "No installed packs in this project match prune criteria."
        return
    }

    Write-Host ""
    Write-Host "The following installed packs will be removed from this Unreal project:" -ForegroundColor Yellow
    foreach ($t in $targetsToRemove) {
        Write-Host ("- {0} ({1}) at {2}" -f $t.Pack.id, $t.Status, $t.Path)
    }

    if (-not $Force) {
        $confirm = Read-Host "Proceed with pruning these packs from this project? (Y/N) [N]"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "Prune cancelled."
            return
        }
    }

    foreach ($t in $targetsToRemove) {
        $path = $t.Path

        # Safety: ensure we only delete inside the project root.
        if (-not $path.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Error "Skipping removal of '$($t.Pack.id)': resolved path '$path' is not under project root '$projectRoot'."
            continue
        }

        try {
            Remove-Item -LiteralPath $path -Recurse -Force
            Write-Host "Removed '$($t.Pack.id)' from '$path'." -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to remove '$($t.Pack.id)' from '$path': $($_.Exception.Message)"
        }
    }
}

# endregion --------------------------------------------------------------------

# region: License mode --------------------------------------------------------

# Show or set license mode (restrictive/permissive).
function GetSet-AssetLibMode {
    param(
        [string]$Mode
    )

    $config = Get-AssetLibConfig

    if (-not $Mode) {
        Write-Host "Current license mode: $($config.licenseMode)"
        Write-Host "  restrictive : only commercial-safe packs allowed for add/install/prune."
        Write-Host "  permissive  : allow all packs but still audit and warn."
        return
    }

    $normalized = $Mode.ToLowerInvariant()
    if ($normalized -notin @('restrictive', 'permissive')) {
        Write-Error "Invalid mode '$Mode'. Use 'restrictive' or 'permissive'."
        return
    }

    $config.licenseMode = $normalized
    Set-AssetLibConfig -Config $config
    Write-Host "Set license mode to '$normalized'." -ForegroundColor Green
}

# endregion --------------------------------------------------------------------

# region: Help -----------------------------------------------------------------

# Expanded, topic-aware help.
# Supports:
#   assetlib help
#   assetlib help list
#   assetlib help show
#   assetlib help open
#   assetlib help add
#   assetlib help remove
#   assetlib help licenses
#   assetlib help audit
#   assetlib help install
#   assetlib help uninstall
#   assetlib help mode
function Show-AssetLibHelp {
    param(
        [string]$Topic
    )

    # Normalize for matching.
    $topicKey = $Topic
    if ($topicKey) {
        $topicKey = $topicKey.ToLowerInvariant()
    }

    switch ($topicKey) {
        # ---------------------------------------------------------------------
        "list" {
            @"
assetlib help list
------------------
Usage:
  assetlib list [-Category <category>] [-Tag <tag>]

Description:
  Lists packs from packs.json, optionally filtered by category and/or tag.

Examples:
  assetlib list
  assetlib list -Category animations
  assetlib list -Tag sci-fi

Details:
  - Category and Tag are both optional.
  - Categories and tags are arrays in packs.json.
  - Under the hood, 'list' uses Where-Object to filter:
      Where-Object { $_.categories -contains $Category }
      Where-Object { $_.tags -contains $Tag }
"@ | Write-Host
        }

        # ---------------------------------------------------------------------
        "show" {
            @"
assetlib help show
------------------
Usage:
  assetlib show <id>

Description:
  Prints the full JSON for a single pack from packs.json.

Examples:
  assetlib show Mco_Mocap_Basics

Details:
  - <id> must match the 'id' property of a pack in packs.json.
  - Output is generated via ConvertTo-Json with a depth of 5, so you see:
      - cloud_url
      - archive_url
      - categories
      - tags
      - licenseId
      - packType
      - pluginFolderName
"@ | Write-Host
        }

        # ---------------------------------------------------------------------
        "open" {
            @"
assetlib help open
------------------
Usage:
  assetlib open <id>

Description:
  Opens the pack's cloud_url in your default browser.

Examples:
  assetlib open Mco_Mocap_Basics

Details:
  - <id> must match the 'id' in packs.json.
  - cloud_url is expected to be a Google Drive folder view link.
  - The URL is opened using Start-Process, which launches the default browser.
"@ | Write-Host
        }

        # ---------------------------------------------------------------------
        "add" {
            @"
assetlib help add
-----------------
Usage:
  assetlib add

Description:
  Interactive wizard to add a new pack to packs.json.

What it does:
  - Optionally opens the asset store root from assetlib.config.json.
  - Prompts for:
      id, name, source
      cloud_url (folder view / Google Drive)
      archive_url (direct download ZIP, used by 'install')
      categories (comma-separated)
      tags (comma-separated)
      notes
      licenseId
      packType (content/plugin)
      pluginFolderName (for plugins)
  - Applies license rules based on licenseMode from assetlib.config.json:
      restrictive : only 'OK' licenses allowed (commercialAllowed = true).
      permissive  : allows all, but warns on NON-COMMERCIAL/UNKNOWN/NO-LICENSE.

Notes:
  - This command only edits packs.json and does not touch any Unreal project.
  - Safe to run while Unreal Editor is open.
"@ | Write-Host
        }

        # ---------------------------------------------------------------------
        "remove" {
            @"
assetlib help remove
--------------------
Usage:
  assetlib remove <id> [-Force]

Description:
  Removes a pack entry from packs.json only. Does NOT touch any project files
  or Google Drive content.

Examples:
  assetlib remove Mco_Mocap_Basics
  assetlib remove Mco_Mocap_Basics -Force

Details:
  - Without -Force:
      - You are prompted to confirm removal.
  - With -Force:
      - The confirmation prompt is skipped.
  - This is manifest maintenance only, safe with Unreal open.
"@ | Write-Host
        }

        # ---------------------------------------------------------------------
        "licenses" {
            @"
assetlib help licenses
----------------------
Usage:
  assetlib licenses
  assetlib licenses <licenseId>

Description:
  Manages viewing of license metadata and text.

  assetlib licenses
    - Lists all license definitions from licenses/licenses.json.
    - Shows id, COMMERCIAL/NON-COMMERCIAL status, and name.

  assetlib licenses <licenseId>
    - Shows details for a specific license and prints the full text of the
      associated .txt file.

Notes:
  - This command is read-only and safe with Unreal open.
  - License enforcement for 'add', 'install', and 'audit -Prune' is based on:
      licenseId matching licenses/licenses.json
      commercialAllowed flag in each license entry.
"@ | Write-Host
        }

        # ---------------------------------------------------------------------
        "install" {
            @"
assetlib help install
---------------------
Usage:
  assetlib install <id> [-Force]

Description:
  Installs a pack into the current Unreal project root by:
    - Downloading archive_url from packs.json
    - Extracting it into:
        packType = content :  Content/AssetLib/<id>/
        packType = plugin  :  Plugins/<pluginFolderName or id>/

Requirements:
  - You must run this from an Unreal project root:
      - Directory contains at least one *.uproject
      - Directory contains a Content/ folder
  - The pack must exist in packs.json.
  - The pack must have archive_url set.

License behavior:
  - licenseMode = restrictive:
      - Only installs packs whose license status is 'OK'
        (licenseId known and commercialAllowed = true).
  - licenseMode = permissive:
      - Installs anything but warns on NON-COMMERCIAL/UNKNOWN/NO-LICENSE.

Editor safety:
  - If Unreal Editor is running:
      - Without -Force: install is blocked and you are asked to close the editor.
      - With -Force   : a warning is shown and install proceeds anyway.
  - Recommended: close Unreal before installing, especially for plugins.

Overwrite behavior:
  - If target folder already exists:
      - Without -Force:
          - You are prompted before removing the existing folder.
      - With -Force:
          - Existing folder is removed without prompting.
"@ | Write-Host
        }

        # ---------------------------------------------------------------------
        "uninstall" {
            @"
assetlib help uninstall
-----------------------
Usage:
  assetlib uninstall <id> [-Force]

Description:
  Removes an installed pack from the current Unreal project by deleting the
  folder where it was installed:

    packType = content :  Content/AssetLib/<id>/
    packType = plugin  :  Plugins/<pluginFolderName or id>/

Requirements:
  - Must be run from an Unreal project root (has *.uproject + Content/).
  - The pack id must exist in packs.json.
  - The computed install folder must exist to be removed.

License:
  - Licenses are NOT re-checked for uninstall; this is purely a project cleanup
    operation.

Editor safety:
  - If Unreal Editor is running:
      - Without -Force: uninstall is blocked with an error.
      - With -Force   : a warning is printed and uninstall proceeds.
  - Strongly recommended: close Unreal Editor before uninstalling to avoid
    deleting in-use assets or plugins.

Prompting:
  - Without -Force:
      - You are prompted before deleting the install folder.
  - With -Force:
      - Deletes without prompting.
"@ | Write-Host
        }

        # ---------------------------------------------------------------------
        "audit" {
            @"
assetlib help audit
-------------------
Usage:
  assetlib audit
  assetlib audit -Prune [-Licenses <id|NO-LICENSE|UNKNOWN-LICENSE> ...] [-Force]

Description:
  Read-only audit:
    assetlib audit
      - Classifies each pack as:
          OK
          NON-COMMERCIAL
          UNKNOWN-LICENSE
          NO-LICENSE
      - DOES NOT delete anything.
      - Safe to run with Unreal Editor open.

  Prune mode (destructive, project-specific):
    assetlib audit -Prune [...]
      - Only allowed when:
          licenseMode = 'restrictive'
          current directory is an Unreal project root
          Unreal Editor is not running (unless -Force)
      - Deletes installed packs from THIS PROJECT ONLY based on license rules.

Default prune behavior (no -Licenses):
  - Removes installed packs whose license status is NOT 'OK':
      NON-COMMERCIAL, UNKNOWN-LICENSE, NO-LICENSE.

Explicit prune selection with -Licenses:
  - Removes only installed packs whose license matches one of:
      - Named license ids (e.g. Fab_Standard_License)
      - Special pseudo-ids:
          NO-LICENSE      : packs with missing licenseId
          UNKNOWN-LICENSE : packs whose licenseId is not in licenses.json

Editor safety:
  - If Unreal Editor is running:
      - Without -Force: prune is blocked with an error.
      - With -Force   : a warning is printed and prune proceeds.

Prompts:
  - Without -Force:
      - Shows a list of installed packs to be removed and prompts for confirmation.
  - With -Force:
      - Skips confirmation.
"@ | Write-Host
        }

        # ---------------------------------------------------------------------
        "mode" {
            @"
assetlib help mode
------------------
Usage:
  assetlib mode
  assetlib mode restrictive
  assetlib mode permissive

Description:
  Manages the global licenseMode stored in assetlib.config.json.

  assetlib mode
    - Shows the current license mode and a short explanation.

  assetlib mode restrictive
    - Sets licenseMode to 'restrictive'.
    - Effects:
        - 'add' only accepts packs with OK licenses.
        - 'install' only installs packs with OK licenses.
        - 'audit -Prune' is allowed (and required for pruning).

  assetlib mode permissive
    - Sets licenseMode to 'permissive'.
    - Effects:
        - 'add' and 'install' allow any license but warn on problematic ones.
        - 'audit -Prune' is disabled for safety.
"@ | Write-Host
        }

        # ---------------------------------------------------------------------
        default {
            @"
assetlib - shared asset pack manifest & Unreal helper
=====================================================

Overview
--------
assetlib is a small PowerShell tool that:

  - Tracks asset packs in packs.json
  - Stores license metadata in licenses/licenses.json
  - Opens Google Drive folders for packs
  - Installs/uninstalls packs into an Unreal project
  - Audits and prunes installed packs based on license rules
  - Enforces a configurable license mode: restrictive or permissive

By design:
  - ZERO dependencies beyond PowerShell and built-in modules.
  - Friendly for non-technical teammates (copy/paste commands).
  - NEVER edits Unreal engine folders, only the current project.

IMPORTANT:
  - Calling 'assetlib' with no arguments throws:
      assetlib requires a command. Run 'assetlib help' for usage.

Quick command summary
---------------------
  assetlib help
  assetlib help <command>

  assetlib list [-Category <category>] [-Tag <tag>]
  assetlib show <id>
  assetlib open <id>

  assetlib add
  assetlib remove <id> [-Force]

  assetlib licenses [<licenseId>]

  assetlib install <id> [-Force]
  assetlib uninstall <id> [-Force]

  assetlib audit
  assetlib audit -Prune [-Licenses <id|NO-LICENSE|UNKNOWN-LICENSE> ...] [-Force]

  assetlib mode
  assetlib mode restrictive
  assetlib mode permissive

Editor safety
-------------
Commands that ONLY read or edit JSON/config are safe while Unreal Editor is open:

  - help, list, show, open
  - add, remove
  - licenses
  - audit (without -Prune)
  - mode

Commands that modify a project (Content/ or Plugins/) are editor-sensitive:

  - install, uninstall, audit -Prune

For those, assetlib:

  - Detects Unreal Editor processes (UnrealEditor*, UE4Editor, UE5Editor).
  - Blocks operations when the editor appears to be running, unless -Force is used.
  - With -Force, prints a warning and proceeds.

Recommended workflow
--------------------
  - Use 'assetlib add' and 'assetlib remove' to maintain packs.json.
  - Use 'assetlib licenses' to understand license definitions.
  - Use 'assetlib mode' to switch between restrictive and permissive license behavior.
  - Before shipping:
      - Run 'assetlib audit' to check license health.
  - For a specific Unreal project:
      - Close Unreal Editor.
      - From the project root:
          - Use 'assetlib install <id>' to bring in new content/plugins.
          - Use 'assetlib uninstall <id>' to remove a specific pack.
          - Use 'assetlib audit -Prune' to clean out non-commercial/unknown/no-license
            packs from THIS PROJECT ONLY.

For detailed help on any command:
  - assetlib help list
  - assetlib help show
  - assetlib help open
  - assetlib help add
  - assetlib help remove
  - assetlib help licenses
  - assetlib help install
  - assetlib help uninstall
  - assetlib help audit
  - assetlib help mode
"@ | Write-Host
        }
    }
}

# endregion --------------------------------------------------------------------

# region: Top-level dispatcher -------------------------------------------------

try {
    switch ($Command) {
        "help" { Show-AssetLibHelp -Topic $Id }
        "list" { Get-AssetPackList -Category $Category -Tag $Tag }
        "show" {
            if (-not $Id) {
                Write-Error "You must provide an id, e.g. assetlib show Mco_Mocap_Basics"
            }
            else {
                Get-AssetPack -Id $Id
            }
        }
        "open" {
            if (-not $Id) {
                Write-Error "You must provide an id, e.g. assetlib open Mco_Mocap_Basics"
            }
            else {
                Open-AssetPack -Id $Id
            }
        }
        "add" { Add-AssetPack }
        "remove" {
            if (-not $Id) {
                Write-Error "You must provide an id, e.g. assetlib remove Mco_Mocap_Basics"
            }
            else {
                Remove-AssetPack -Id $Id -Force:$Force
            }
        }
        "licenses" {
            if ($Id) {
                Get-AssetLicense -Id $Id
            }
            else {
                Get-AssetLicenseList
            }
        }
        "audit" {
            Test-AssetPackLicenses -Prune:$Prune -Licenses $Licenses -Force:$Force
        }
        "install" {
            if (-not $Id) {
                Write-Error "You must provide an id, e.g. assetlib install Mco_Mocap_Basics"
            }
            else {
                Install-AssetPack -Id $Id -Force:$Force
            }
        }
        "uninstall" {
            if (-not $Id) {
                Write-Error "You must provide an id, e.g. assetlib uninstall Mco_Mocap_Basics"
            }
            else {
                Uninstall-AssetPackFromProject -Id $Id -Force:$Force
            }
        }
        "mode" {
            GetSet-AssetLibMode -Mode $Id
        }
        default {
            Write-Error "Unknown command: $Command"
        }
    }
}
catch {
    # Top-level catch for unexpected errors. We rethrow after logging so calling tools can see a non-zero exit.
    Write-Error "assetlib failed: $($_.Exception.Message)"
    throw
}

# endregion --------------------------------------------------------------------
