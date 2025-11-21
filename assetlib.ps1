param(
    # First positional argument: which subcommand the user wants to run.
    # We restrict this to a known list using ValidateSet so typos error early.
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet(
        "help",
        "list",
        "show",
        "open",
        "add",
        "remove",
        "licenses",
        "audit",
        "install",
        "validate",
        "uninstall",
        "mode",
        "status",
        "cache"
    )]
    [string]$Command,

    # Many commands optionally take an Id (pack id or license id, or subcommand).
    [Parameter(Position = 1)]
    [string]$Id,

    # Optional filters for `assetlib list`
    [string]$Category,
    [string]$Tag,

    # Global flags used by several commands
    [switch]$Force,
    [switch]$Preview,
    [switch]$All,
    [switch]$Deep,
    [switch]$Prune,
    [string[]]$PruneStatus,
    [switch]$DryRun
)

# Stop execution on any non-terminating error so we can catch problems early.
# Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_preference_variables#the-erroractionpreference-variable
$ErrorActionPreference = "Stop"

# Paths for our core data files, resolved relative to this script's folder.
# $PSScriptRoot is the directory containing this script.
# Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_automatic_variables
$manifestPath        = Join-Path $PSScriptRoot "packs.json"
$licenseManifestPath = Join-Path $PSScriptRoot "licenses\licenses.json"
$configPath          = Join-Path $PSScriptRoot "assetlib.config.json"

#==============================================================================
# region: Config handling
#==============================================================================

# Load configuration from assetlib.config.json.
# Currently supports:
#   - assetRootUrl : root of your shared asset store (e.g., Google Drive folder)
#   - licenseMode  : "restrictive" or "permissive"
function Get-AssetLibConfig {
    if (Test-Path $configPath) {
        try {
            # Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.management/get-content
            $json = Get-Content $configPath -Raw
            if ($json.Trim()) {
                # Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertfrom-json
                $config = $json | ConvertFrom-Json

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
        # Docs:
        #   ConvertTo-Json: https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/convertto-json
        #   Set-Content   : https://learn.microsoft.com/powershell/module/microsoft.powershell.management/set-content
        $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "Updated assetlib.config.json"
    }
    catch {
        Write-Error "Failed to write assetlib.config.json: $($_.Exception.Message)"
        throw
    }
}

# endregion Config handling
#==============================================================================

#==============================================================================
# region: Manifest helpers
#==============================================================================

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

# endregion Manifest helpers
#==============================================================================

#==============================================================================
# region: Misc helpers
#==============================================================================

# Convert common Google Drive URLs into a direct-download link suitable for
# HttpClient / Invoke-WebRequest. This lets you paste the normal "Get link"
# URL from Drive.
#
# Supported patterns:
#   - https://drive.google.com/file/d/<FILE_ID>/view?usp=sharing
#   - https://drive.google.com/open?id=<FILE_ID>
#   - Anything already starting with https://drive.google.com/uc?...
#
# For unsupported or non-Drive URLs, the original value is returned.
#
# Docs (regex in PowerShell):
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

    # Pattern 2: anything with id=<FILE_ID> in query string
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

# Write a simple log line into .assetlib/logs under the current project root.
# This is best-effort only; logging failures are swallowed so they don't break core behavior.
# Docs (Add-Content): https://learn.microsoft.com/powershell/module/microsoft.powershell.management/add-content
function Write-AssetLibProjectLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    try {
        $logDir = Join-Path $ProjectRoot ".assetlib\logs"
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        $logFile = Join-Path $logDir ("assetlib_" + (Get-Date -Format "yyyyMMdd") + ".log")
        $line = "[{0}] {1}" -f (Get-Date -Format "u"), $Message
        Add-Content -Path $logFile -Value $line
    }
    catch {
        # Intentionally ignore logging errors.
    }
}

# endregion Misc helpers
#==============================================================================

#==============================================================================
# region: Unreal project helpers
#==============================================================================

# Detect if Unreal Editor is running.
# Checks for common process names: UnrealEditor, UnrealEditor-Cmd, UE4Editor, UE5Editor.
# Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.management/get-process
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
# Docs (Get-ChildItem): https://learn.microsoft.com/powershell/module/microsoft.powershell.management/get-childitem
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

# endregion Unreal project helpers
#==============================================================================

#==============================================================================
# region: Listing & basic operations
#==============================================================================

# List all packs, optionally filtered by Category/Tag.
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

    # Filter by category if specified (categories is an array).
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

# Show the full JSON for a single pack.
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

# endregion Listing & basic operations
#==============================================================================

#==============================================================================
# region: Add / Remove pack
#==============================================================================

# Interactive add flow for a new pack:
# - opens asset store root (from config) in browser (optional)
# - collects fields for the pack
# - automatically converts Google Drive file URLs into direct-download URLs
#   for archive_url (uc?export=download&id=...)
# - adds optional engineVersion metadata (e.g. "5.3")
# - enforces license rules based on licenseMode
function Add-AssetPack {
    $packs    = Get-AssetPackManifest
    $config   = Get-AssetLibConfig
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

    # QoL: open your asset root (e.g., Google Drive 'GameLibrary/Packs') first.
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
    # User can paste:
    #   - a Drive FILE URL (file/d/<id>/view?usp=sharing), or
    #   - a ready direct download URL, or
    #   - arbitrary host URL.
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

    $catsRaw = Read-Host "categories (comma-separated: assets, animations, vfx, systems, tools, etc.)"
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

    # Optional engine version metadata:
    # Example: "5.3", "5.4", etc.
    $engineVersion = Read-Host "engine version this pack/plugin was built/tested against (optional, e.g. 5.3)"

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
        engineVersion    = $engineVersion
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

# endregion Add / Remove pack
#==============================================================================

#==============================================================================
# region: Install / Uninstall into Unreal project
#==============================================================================

# Install a pack into the current Unreal project root.
# Downloads archive_url and extracts into the appropriate folder based on packType.
# Features:
#   - License-mode enforcement (restrictive/permissive)
#   - Unreal project detection (uproject + Content/)
#   - Editor safety: blocks while Unreal Editor is running unless -Force
#   - Engine-version awareness for plugins (+ -Force override)
#   - C++ plugin vs Blueprint-only project warning
#   - Engine-style plugin archive detection: BLOCKED COMPLETELY (never installed)
#   - Local archive cache under %LOCALAPPDATA%\assetlib\cache
#   - ZIP validation (header check)
#   - Streaming download with progress bar
#   - Flattening of single top-level folder in zip to avoid double nesting
#   - -Preview mode: does everything except modify project files
function Install-AssetPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [switch]$Force,
        [switch]$Preview
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

    $licenses    = Get-AssetLicenseManifest
    $config      = Get-AssetLibConfig
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

    # Detect project engine version and whether it has C++ modules.
    $projectEngineVersionString = $null
    $projectEngineMajor = $null
    $projectEngineMinor = $null
    $projectHasCppModules = $false
    $uprojectPath = $null

    try {
        $uprojectFiles = Get-ChildItem -Path $projectRoot -Filter *.uproject
        if ($uprojectFiles.Count -ge 1) {
            $uprojectPath = $uprojectFiles[0].FullName
            $uprojectJson = Get-Content $uprojectPath -Raw | ConvertFrom-Json

            $association = $uprojectJson.EngineVersion
            if (-not $association) {
                $association = $uprojectJson.EngineAssociation
            }
            if ($association) {
                $projectEngineVersionString = "$association"
                if ($association -match '^(\d+)\.(\d+)') {
                    $projectEngineMajor = [int]$Matches[1]
                    $projectEngineMinor = [int]$Matches[2]
                }
            }

            if ($uprojectJson.Modules -and $uprojectJson.Modules.Count -gt 0) {
                $projectHasCppModules = $true
            }
        }
    }
    catch {
        Write-Warning "Could not read or parse .uproject for engine version; engine compatibility checks may be limited. Error: $($_.Exception.Message)"
    }

    $targetPath = Get-AssetPackInstallPath -Pack $pack -ProjectRoot $projectRoot

    # Safety check: ensure targetPath is under projectRoot
    if (-not $targetPath.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Error "Resolved install path '$targetPath' is not under project root '$projectRoot'. Aborting for safety."
        return
    }

    if (Test-Path $targetPath) {
        if ($Preview) {
            Write-Host "Preview: target path '$targetPath' already exists and WOULD be overwritten." -ForegroundColor Yellow
        }
        else {
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
    }

    $tempFile    = Join-Path ([System.IO.Path]::GetTempPath()) ("assetlib_" + $Id + "_" + [System.Guid]::NewGuid().ToString() + ".zip")
    $tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) ("assetlib_extract_" + $Id + "_" + [System.Guid]::NewGuid().ToString())

    # Local cache under %LOCALAPPDATA%\assetlib\cache
    $cacheRoot = Join-Path $env:LOCALAPPDATA "assetlib\cache"
    if (-not (Test-Path $cacheRoot)) {
        New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    }
    $cacheFile = Join-Path $cacheRoot ($Id + ".zip")

    $usedCache = $false

    # Try to reuse cache if available.
    if (Test-Path $cacheFile -and -not $Force) {
        $useCache = Read-Host "A cached archive for '$Id' exists. Use cached file instead of re-downloading? (Y/N) [Y]"
        if (-not $useCache -or $useCache -match '^[Yy]') {
            Copy-Item -LiteralPath $cacheFile -Destination $tempFile -Force
            $usedCache = $true
            Write-Host "Using cached archive: $cacheFile" -ForegroundColor Cyan
        }
    }

    # --- Streaming download with progress bar using HttpClient ----------------
    if (-not $usedCache) {
        try {
            Write-Host "Downloading archive for '$Id' from $($pack.archive_url)..."

            # Docs: System.Net.Http.HttpClient
            # https://learn.microsoft.com/dotnet/api/system.net.http.httpclient
            $handler = [System.Net.Http.HttpClientHandler]::new()
            $handler.AllowAutoRedirect = $true
            $client = [System.Net.Http.HttpClient]::new($handler)
            $response = $client.GetAsync($pack.archive_url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result

            if (-not $response.IsSuccessStatusCode) {
                throw "HTTP $([int]$response.StatusCode) - $($response.ReasonPhrase)"
            }

            $contentLength = $response.Content.Headers.ContentLength
            $inStream  = $response.Content.ReadAsStream()
            $outStream = [System.IO.File]::Open($cacheFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

            try {
                $buffer    = New-Object byte[] 8192
                $totalRead = 0L
                $read      = 0

                do {
                    $read = $inStream.Read($buffer, 0, $buffer.Length)
                    if ($read -gt 0) {
                        $outStream.Write($buffer, 0, $read)
                        $totalRead += $read

                        if ($contentLength -and $contentLength -gt 0) {
                            $percent = [int](($totalRead * 100) / $contentLength)
                            # Docs: Write-Progress
                            # https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/write-progress
                            Write-Progress -Activity "Downloading $Id" -Status "$percent% complete" -PercentComplete $percent
                        }
                    }
                } while ($read -gt 0)

                Write-Progress -Activity "Downloading $Id" -Completed
            }
            finally {
                if ($outStream) { $outStream.Dispose() }
                if ($inStream)  { $inStream.Dispose() }
                if ($client)    { $client.Dispose() }
            }

            # Copy cache into temp file for subsequent validation/extraction.
            Copy-Item -LiteralPath $cacheFile -Destination $tempFile -Force
        }
        catch {
            Write-Error "Failed to download archive from '$($pack.archive_url)': $($_.Exception.Message)"
            if (Test-Path $tempFile) {
                Remove-Item $tempFile -Force
            }
            # Best-effort cleanup of bad cache.
            if (Test-Path $cacheFile -and -not $usedCache) {
                Remove-Item $cacheFile -Force
            }
            return
        }
    }

    # Before extracting, sanity-check that the file looks like a ZIP.
    # ZIP files typically start with the bytes 'PK' (0x50 0x4B).
    try {
        $headerBytes = New-Object byte[] 4
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
        # Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.archive/expand-archive
        Expand-Archive -Path $tempFile -DestinationPath $tempExtract -Force
    }
    catch {
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
        # Plugin-specific metadata checks (engine version, C++ modules, engine-level distribution)
        $pluginEngineVersionString = $null
        $pluginEngineMajor = $null
        $pluginEngineMinor = $null
        $pluginHasCppModules = $false
        $pluginIsEngineStylePackage = $false

        if ($pack.packType -eq 'plugin') {
            $upluginFiles = Get-ChildItem -Path $tempExtract -Recurse -Filter *.uplugin
            if (-not $upluginFiles -or $upluginFiles.Count -eq 0) {
                Write-Error "Pack '$Id' is marked as plugin but the archive does not contain a .uplugin file. Cannot install as plugin."
                return
            }

            $upluginFile = $upluginFiles[0]
            $relativeUpluginPath = $upluginFile.FullName.Substring($tempExtract.Length).TrimStart('\', '/')
            if ($relativeUpluginPath -like '*Engine/Plugins*' -or $relativeUpluginPath -like '*Engine\Plugins*') {
                $pluginIsEngineStylePackage = $true
            }

            try {
                $upluginJson = Get-Content $upluginFile.FullName -Raw | ConvertFrom-Json
            }
            catch {
                Write-Warning "Could not parse plugin descriptor '$($upluginFile.FullName)'; plugin metadata checks may be limited. Error: $($_.Exception.Message)"
                $upluginJson = $null
            }

            if ($upluginJson) {
                Write-Host "Plugin descriptor:" -ForegroundColor Cyan
                Write-Host "  Name:        $($upluginJson.FriendlyName)"
                Write-Host "  VersionName: $($upluginJson.VersionName)"
                Write-Host "  Description: $($upluginJson.Description)"

                if ($upluginJson.EngineVersion) {
                    $pluginEngineVersionString = "$($upluginJson.EngineVersion)"
                    if ($pluginEngineVersionString -match '^(\d+)\.(\d+)') {
                        $pluginEngineMajor = [int]$Matches[1]
                        $pluginEngineMinor = [int]$Matches[2]
                    }
                }

                if ($upluginJson.Modules -and $upluginJson.Modules.Count -gt 0) {
                    $pluginHasCppModules = $true
                }
            }

            # HARD BLOCK: engine-style plugin packages are not supported by assetlib.
            if ($pluginIsEngineStylePackage) {
                Write-Warning @"
The plugin archive for '$Id' appears to be structured as an Engine-level plugin
(it contains an 'Engine/Plugins' path). assetlib does not support installing
engine-level plugins at all.

Engine-level plugins can impact ALL projects using that engine and usually
require manual installation into Engine/Plugins with elevated permissions.
"@

                $choice = Read-Host "Choose action: [K]eep in manifest only, [R]emove from manifest [K]"
                if (-not $choice -or $choice -match '^[Kk]') {
                    Write-Error "Install aborted. Pack '$Id' remains in packs.json for tracking only. Install it into Engine/Plugins manually if needed."
                    Write-AssetLibProjectLog -ProjectRoot $projectRoot -Message "Install of '$Id' blocked: engine-level plugin package (kept in manifest)."
                    return
                }
                elseif ($choice -match '^[Rr]') {
                    $currentPacks = Get-AssetPackManifest
                    $remaining = $currentPacks | Where-Object { $_.id -ne $Id }

                    if ($remaining.Count -lt $currentPacks.Count) {
                        Set-AssetPackManifest -Packs $remaining
                        Write-Host "Pack '$Id' has been removed from packs.json because it appears to be an engine-level plugin package." -ForegroundColor Yellow
                    }
                    else {
                        Write-Warning "Pack '$Id' was not found in the current manifest when attempting removal."
                    }

                    Write-Error "Install aborted. Engine-level plugin package '$Id' was removed from the manifest."
                    Write-AssetLibProjectLog -ProjectRoot $projectRoot -Message "Install of '$Id' blocked: engine-level plugin package (removed from manifest)."
                    return
                }
                else {
                    Write-Error "Install aborted. Pack '$Id' remains in packs.json for tracking only."
                    Write-AssetLibProjectLog -ProjectRoot $projectRoot -Message "Install of '$Id' blocked: engine-level plugin package (kept in manifest, choice other)."
                    return
                }
            }

            # Engine version compatibility check for plugins
            if ($projectEngineMajor -ne $null -and $pluginEngineMajor -ne $null) {
                if ($pluginEngineMajor -ne $projectEngineMajor) {
                    $msg = "Plugin '$Id' targets engine major version $pluginEngineMajor (from .uplugin) but the project appears to use $projectEngineMajor.x."
                    if (-not $Force) {
                        Write-Error "$msg Install blocked. Use -Force to override if you know this plugin is compatible."
                        Write-AssetLibProjectLog -ProjectRoot $projectRoot -Message "Install of '$Id' blocked: $msg"
                        return
                    }
                    else {
                        Write-Warning "$msg Proceeding due to -Force; plugin may not be compatible."
                    }
                }
                elseif ($pluginEngineMinor -gt $projectEngineMinor) {
                    $msg = "Plugin '$Id' targets engine $pluginEngineMajor.$pluginEngineMinor, which is NEWER than the project engine $projectEngineMajor.$projectEngineMinor."
                    if (-not $Force) {
                        Write-Error "$msg Install blocked. Use -Force if you understand the risk."
                        Write-AssetLibProjectLog -ProjectRoot $projectRoot -Message "Install of '$Id' blocked: $msg"
                        return
                    }
                    else {
                        Write-Warning "$msg Proceeding due to -Force; plugin may rely on features not present in this engine version."
                    }
                }
                elseif ($pluginEngineMinor -lt $projectEngineMinor) {
                    $msg = "Plugin '$Id' targets engine $pluginEngineMajor.$pluginEngineMinor, which is OLDER than the project engine $projectEngineMajor.$projectEngineMinor."
                    if (-not $Force) {
                        Write-Error "$msg Install blocked by default. Re-run with -Force if you want to try it anyway (many plugins do work on newer minor versions)."
                        Write-AssetLibProjectLog -ProjectRoot $projectRoot -Message "Install of '$Id' blocked: $msg"
                        return
                    }
                    else {
                        Write-Warning "$msg Proceeding due to -Force; test the plugin thoroughly."
                    }
                }
            }

            # Warn if plugin has C++ modules but project appears to be Blueprint-only.
            if ($pluginHasCppModules -and -not $projectHasCppModules) {
                Write-Warning @"
Plugin '$Id' contains C++ modules, but the project appears to be Blueprint-only
(no 'Modules' array in the .uproject). Unreal may require converting this project
to a C++ project (e.g., by adding a C++ class once) for the plugin to fully work.
"@
            }
        }

        # Soft engineVersion checks for content packs (and plugin pack engineVersion tag).
        if ($pack.engineVersion -and $projectEngineMajor -ne $null) {
            if ($pack.engineVersion -match '^(\d+)\.(\d+)') {
                $packMajor = [int]$Matches[1]
                $packMinor = [int]$Matches[2]

                if ($packMajor -ne $projectEngineMajor -or $packMinor -ne $projectEngineMinor) {
                    Write-Warning "Pack '$Id' was tagged for engine $packMajor.$packMinor but the project appears to use $projectEngineMajor.$projectEngineMinor. Content often works across minor versions, but test carefully."
                }
            }
        }

        # Inspect extracted structure to avoid double-nesting like:
        #   Content\AssetLib\<id>\<id>\<content>
        $topEntries = Get-ChildItem -Path $tempExtract
        $topDirs    = $topEntries | Where-Object { $_.PSIsContainer }
        $topFiles   = $topEntries | Where-Object { -not $_.PSIsContainer }

        if ($Preview) {
            Write-Host ""
            Write-Host "PREVIEW for '$Id':" -ForegroundColor Cyan
            Write-Host "  Target path: $targetPath"
            if ($topDirs.Count -eq 1 -and $topFiles.Count -eq 0) {
                Write-Host "  Archive contains a single top-level folder '$($topDirs[0].Name)' and would be FLATTENED into the target path to avoid double nesting."
            }
            else {
                Write-Host "  Archive contains multiple top-level entries and would be copied as-is into the target path."
            }

            Write-Host ""
            Write-Host "  Top-level entries in archive extract root:"
            foreach ($e in $topEntries) {
                $kind = if ($e.PSIsContainer) { "DIR " } else { "FILE" }
                Write-Host ("    {0}  {1}" -f $kind, $e.Name)
            }

            Write-AssetLibProjectLog -ProjectRoot $projectRoot -Message "Preview install for '$Id' completed (no changes to project)."
            return
        }

        # Ensure targetPath exists before moving content.
        if (-not (Test-Path $targetPath)) {
            New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
        }

        if ($topDirs.Count -eq 1 -and $topFiles.Count -eq 0) {
            $wrapperDir = $topDirs[0]
            Write-Host "Detected single top-level folder '$($wrapperDir.Name)' in archive. Flattening into '$targetPath' to avoid double nesting..."

            Get-ChildItem -Path $wrapperDir.FullName | ForEach-Object {
                $dest = Join-Path $targetPath $_.Name
                Move-Item -LiteralPath $_.FullName -Destination $dest -Force
            }
        }
        else {
            Write-Host "Archive has multiple top-level entries or files; copying structure into '$targetPath'..."
            Get-ChildItem -Path $tempExtract | ForEach-Object {
                $dest = Join-Path $targetPath $_.Name
                Move-Item -LiteralPath $_.FullName -Destination $dest -Force
            }
        }

        Write-Host "Installed pack '$Id' to '$targetPath' (licenseMode=$licenseMode)." -ForegroundColor Green
        Write-AssetLibProjectLog -ProjectRoot $projectRoot -Message "Installed pack '$Id' to '$targetPath' (licenseMode=$licenseMode, preview=$Preview, usedCache=$usedCache)."
    }
    catch {
        Write-Error "Failed while moving or processing extracted content for '$Id' into '$targetPath': $($_.Exception.Message)"
        Write-AssetLibProjectLog -ProjectRoot $projectRoot -Message "Install of '$Id' failed: $($_.Exception.Message)"
    }
    finally {
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

    # Prevent uninstalling while Unreal Editor is running unless -Force is used.
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

# endregion Install / Uninstall
#==============================================================================

#==============================================================================
# region: Audit & prune
#==============================================================================

# Audit all packs against license rules:
# - NO-LICENSE: licenseId missing
# - UNKNOWN-LICENSE: licenseId not found in licenses.json
# - NON-COMMERCIAL: commercialAllowed == false
# - OK: commercialAllowed == true
#
# Pure audit only. Pruning is handled by Invoke-AssetPackPrune.
function Test-AssetPackLicenses {
    $packs    = Get-AssetPackManifest
    $licenses = Get-AssetLicenseManifest

    if (-not $packs -or $packs.Count -eq 0) {
        Write-Host "No packs in manifest to audit." -ForegroundColor Yellow
        return @()
    }

    $issues  = 0
    $results = New-Object System.Collections.Generic.List[object]

    Write-Host "Asset pack license audit:" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------"

    foreach ($p in $packs) {
        $status    = Get-AssetPackLicenseStatus -Pack $p -Licenses $licenses
        $id        = $p.id
        $name      = $p.name
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

    return ,$results
}

# Validate a single pack (quick or deep).
function Invoke-AssetPackValidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [switch]$Deep
    )

    $projectRoot = Get-UnrealProjectRoot

    $packs = Get-AssetPackManifest
    $pack  = $packs | Where-Object { $_.id -eq $Id }
    if (-not $pack) {
        Write-Error "No pack found with id: $Id"
        return
    }

    $licenses = Get-AssetLicenseManifest
    $status   = Get-AssetPackLicenseStatus -Pack $pack -Licenses $licenses

    Write-Host "Pack: $($pack.id)" -ForegroundColor Cyan
    Write-Host "  Name:          $($pack.name)"
    Write-Host "  Source:        $($pack.source)"
    Write-Host "  packType:      $($pack.packType)"
    Write-Host "  licenseId:     $($pack.licenseId)"
    Write-Host "  licenseStatus: $($status.Status)"
    Write-Host "  engineVersion: $($pack.engineVersion)"
    Write-Host "  archive_url:   $($pack.archive_url)"

    if (-not $pack.archive_url) {
        Write-Warning "Pack '$Id' has no archive_url set; install/validate cannot check archive content."
    }

    if (-not $Deep) {
        Write-Host ""
        Write-Host "Use 'assetlib validate $Id -Deep' for a full deep-dive (download + plugin checks + structure preview)." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Running deep validation (download + preview install) for '$Id'..." -ForegroundColor Cyan

    try {
        # Reuse Install-AssetPack in Preview mode so we exercise the exact same path.
        Install-AssetPack -Id $Id -Preview
    }
    catch {
        Write-Error "Deep validation for '$Id' failed: $($_.Exception.Message)"
    }
}

# Validate all packs in packs.json (quick or deep).
function Invoke-AssetPackValidateAll {
    param(
        [switch]$Deep
    )

    $packs    = Get-AssetPackManifest
    $licenses = Get-AssetLicenseManifest

    if (-not $packs -or $packs.Count -eq 0) {
        Write-Host "No packs in manifest to validate." -ForegroundColor Yellow
        return
    }

    Write-Host "Validating all packs in manifest..." -ForegroundColor Cyan

    foreach ($p in $packs) {
        $status      = Get-AssetPackLicenseStatus -Pack $p -Licenses $licenses
        $hasArchive  = [bool]$p.archive_url
        $archiveFlag = if ($hasArchive) { "archive_url=YES" } else { "archive_url=NO" }

        "{0,-30} {1,-18} {2,-15} {3}" -f $p.id, "[$($status.Status)]", "packType=$($p.packType)", $archiveFlag

        if ($Deep) {
            Write-Host ""
            Invoke-AssetPackValidate -Id $p.id -Deep
            Write-Host ""
            Write-Host "----------------------------------------"
        }
    }

    if (-not $Deep) {
        Write-Host ""
        Write-Host "Use 'assetlib validate --all -Deep' for full per-pack previews (downloads required)." -ForegroundColor Yellow
    }
}

# Prune installed pack directories from the current Unreal project based on license status.
# Default: removes NON-COMMERCIAL, UNKNOWN-LICENSE, and NO-LICENSE pack installs.
#   -DryRun : just prints what WOULD be removed.
function Invoke-AssetPackPrune {
    param(
        [string[]]$StatusesToRemove = @("NON-COMMERCIAL", "UNKNOWN-LICENSE", "NO-LICENSE"),
        [switch]$DryRun
    )

    $projectRoot = Get-UnrealProjectRoot
    if (-not $projectRoot) {
        Write-Error "Prune must be run from an Unreal project root (folder with a .uproject file and a Content/ folder)."
        return
    }

    # Editor safety when pruning installed content/plugins.
    if (Test-UnrealEditorRunning -and -not $DryRun) {
        Write-Error "Unreal Editor appears to be running. Close the editor before pruning installed packs (recommended to avoid file locks)."
        return
    }

    $packs    = Get-AssetPackManifest
    $licenses = Get-AssetLicenseManifest

    if (-not $packs -or $packs.Count -eq 0) {
        Write-Host "No packs in manifest to prune." -ForegroundColor Yellow
        return
    }

    Write-Host "Pruning installed packs with license statuses: $($StatusesToRemove -join ', ')" -ForegroundColor Cyan

    $toRemove = @()

    foreach ($p in $packs) {
        $st = Get-AssetPackLicenseStatus -Pack $p -Licenses $licenses
        if ($StatusesToRemove -contains $st.Status) {
            $installPath = Get-AssetPackInstallPath -Pack $p -ProjectRoot $projectRoot
            if (Test-Path $installPath) {
                $toRemove += [PSCustomObject]@{
                    Id     = $p.id
                    Path   = $installPath
                    Status = $st.Status
                }
            }
        }
    }

    if ($toRemove.Count -eq 0) {
        Write-Host "No installed pack directories matched the specified statuses." -ForegroundColor Green
        return
    }

    foreach ($item in $toRemove) {
        if ($DryRun) {
            Write-Host "[DRY-RUN] Would remove '$($item.Path)' for pack '$($item.Id)' (status=$($item.Status))."
        }
        else {
            Write-Host "Removing '$($item.Path)' for pack '$($item.Id)' (status=$($item.Status))..."
            try {
                # Safety: ensure path is inside project root.
                if (-not $item.Path.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-Error "Skipping removal of '$($item.Id)': resolved path '$($item.Path)' is not under project root '$projectRoot'."
                    continue
                }

                Remove-Item -LiteralPath $item.Path -Recurse -Force
                Write-AssetLibProjectLog -ProjectRoot $projectRoot -Message "Pruned installed path '$($item.Path)' for pack '$($item.Id)' (status=$($item.Status))."
            }
            catch {
                Write-Error "Failed to remove '$($item.Path)' for pack '$($item.Id)': $($_.Exception.Message)"
                Write-AssetLibProjectLog -ProjectRoot $projectRoot -Message "FAILED prune of '$($item.Path)' for pack '$($item.Id)': $($_.Exception.Message)"
            }
        }
    }

    if ($DryRun) {
        Write-Host "Dry-run complete. No files were actually deleted." -ForegroundColor Yellow
    }
    else {
        Write-Host "Prune complete." -ForegroundColor Green
    }
}

# endregion Audit & prune
#==============================================================================

#==============================================================================
# region: License mode
#==============================================================================

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

# endregion License mode
#==============================================================================

#==============================================================================
# region: Status & cache helpers
#==============================================================================

# Show assetlib + project status summary.
function Show-AssetLibStatus {
    $config   = Get-AssetLibConfig
    $packs    = Get-AssetPackManifest
    $licenses = Get-AssetLicenseManifest

    Write-Host "assetlib status" -ForegroundColor Cyan
    Write-Host "----------------"

    Write-Host "Script root:        $PSScriptRoot"
    Write-Host "packs.json:         $manifestPath"
    Write-Host "licenses manifest:  $licenseManifestPath"
    Write-Host "config:             $configPath"

    Write-Host ""
    Write-Host "Config:"
    Write-Host "  assetRootUrl:     $($config.assetRootUrl)"
    Write-Host "  licenseMode:      $($config.licenseMode)"

    Write-Host ""
    Write-Host "Manifest:"
    Write-Host "  packs count:      $($packs.Count)"
    Write-Host "  licenses count:   $($licenses.Count)"

    # Cache info
    $cacheRoot = Join-Path $env:LOCALAPPDATA "assetlib\cache"
    Write-Host ""
    Write-Host "Cache:"
    Write-Host "  root:             $cacheRoot"

    if (Test-Path $cacheRoot) {
        $cacheFiles = Get-ChildItem -Path $cacheRoot -File -ErrorAction SilentlyContinue
        $cacheCount = $cacheFiles.Count
        # Docs: https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/measure-object
        $cacheSizeBytes = ($cacheFiles | Measure-Object -Property Length -Sum).Sum
        $cacheSizeMB = if ($cacheSizeBytes) { [math]::Round($cacheSizeBytes / 1MB, 2) } else { 0 }
        Write-Host "  archives:         $cacheCount"
        Write-Host "  size:             $cacheSizeMB MB"
    }
    else {
        Write-Host "  (no cache directory yet)"
    }

    $projectRoot = Get-UnrealProjectRoot
    Write-Host ""
    Write-Host "Project:"
    if (-not $projectRoot) {
        Write-Host "  Not currently in an Unreal project root (no .uproject + Content/ found)."
    }
    else {
        Write-Host "  root:             $projectRoot"

        try {
            $uprojectFiles = Get-ChildItem -Path $projectRoot -Filter *.uproject
            if ($uprojectFiles.Count -ge 1) {
                $uprojectPath = $uprojectFiles[0].FullName
                $uprojectJson = Get-Content $uprojectPath -Raw | ConvertFrom-Json

                $association = $uprojectJson.EngineVersion
                if (-not $association) {
                    $association = $uprojectJson.EngineAssociation
                }

                Write-Host "  .uproject:        $uprojectPath"
                Write-Host "  EngineVersion:    $association"

                if ($uprojectJson.Modules -and $uprojectJson.Modules.Count -gt 0) {
                    Write-Host "  C++ modules:      yes (mixed C++ + Blueprints)"
                }
                else {
                    Write-Host "  C++ modules:      no (Blueprint-only, unless manually converted later)"
                }
            }
        }
        catch {
            Write-Warning "  Could not parse .uproject for additional status: $($_.Exception.Message)"
        }

        $editorRunning = Test-UnrealEditorRunning
        Write-Host "  Unreal editor:    " -NoNewline
        if ($editorRunning) {
            Write-Host "appears to be RUNNING" -ForegroundColor Yellow
        }
        else {
            Write-Host "not detected"
        }
    }
}

# Manage the local archive cache under %LOCALAPPDATA%\assetlib\cache.
function Invoke-AssetLibCache {
    param(
        [string]$Action,
        [switch]$Force
    )

    $cacheRoot = Join-Path $env:LOCALAPPDATA "assetlib\cache"

    if (-not $Action) {
        # Default: show cache info (same as status, but with more detail if needed).
        Write-Host "assetlib cache" -ForegroundColor Cyan
        Write-Host "--------------"
        Write-Host "Cache root: $cacheRoot"

        if (-not (Test-Path $cacheRoot)) {
            Write-Host "No cache directory exists yet."
            return
        }

        $files = Get-ChildItem -Path $cacheRoot -File -ErrorAction SilentlyContinue
        $count = $files.Count
        $sizeBytes = ($files | Measure-Object -Property Length -Sum).Sum
        $sizeMB = if ($sizeBytes) { [math]::Round($sizeBytes / 1MB, 2) } else { 0 }

        Write-Host "Archives:  $count"
        Write-Host "Size:      $sizeMB MB"
        return
    }

    if ($Action.ToLowerInvariant() -eq 'clear') {
        Write-Host "assetlib cache clear" -ForegroundColor Cyan
        Write-Host "---------------------"
        Write-Host "Cache root: $cacheRoot"

        if (-not (Test-Path $cacheRoot)) {
            Write-Host "No cache directory exists; nothing to clear."
            return
        }

        $files = Get-ChildItem -Path $cacheRoot -File -ErrorAction SilentlyContinue
        $count = $files.Count
        $sizeBytes = ($files | Measure-Object -Property Length -Sum).Sum
        $sizeMB = if ($sizeBytes) { [math]::Round($sizeBytes / 1MB, 2) } else { 0 }

        if ($count -eq 0) {
            Write-Host "Cache is already empty."
            return
        }

        Write-Host "This will delete $count cached archive(s) (~$sizeMB MB) from '$cacheRoot'." -ForegroundColor Yellow

        if (-not $Force) {
            $confirm = Read-Host "Proceed with clearing the cache? (Y/N) [N]"
            if ($confirm -notmatch '^[Yy]') {
                Write-Host "Cache clear cancelled."
                return
            }
        }

        try {
            # Only delete the files inside, not the root folder itself.
            Remove-Item -Path (Join-Path $cacheRoot '*') -Recurse -Force -ErrorAction Stop
            Write-Host "Cache cleared." -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to clear cache: $($_.Exception.Message)"
        }

        return
    }

    Write-Error "Unknown cache action '$Action'. Use 'assetlib cache' or 'assetlib cache clear [-Force]'."
}

# endregion Status & cache
#==============================================================================

#==============================================================================
# region: Help
#==============================================================================

# Expanded, topic-aware help.
function Show-AssetLibHelp {
    <#
    .SYNOPSIS
        Show help for the assetlib tool.

    .DESCRIPTION
        Provides a high-level overview when called with no topic, or detailed
        help for a specific command when called as:

            assetlib help <command>

        Example:

            assetlib help install
            assetlib help audit
            assetlib help validate
            assetlib help status
            assetlib help cache
    #>
    param(
        [string]$Topic
    )

    if (-not $Topic) {
@"
assetlib - simple asset pack manifest helper
--------------------------------------------

Usage:
  assetlib help
  assetlib help <command>

Commands:
  help        Show this help, or detailed help for a specific command
  list        List all packs (with optional category/tag filters)
  show        Show full JSON for a specific pack
  open        Open a pack's Google Drive folder in your browser
  add         Add a new pack to packs.json (interactive)
  remove      Remove a pack from packs.json (manifest only)
  uninstall   Remove a pack from the CURRENT PROJECT only (files only)
  licenses    List license definitions or show full text for one license
  audit       Audit all packs for license safety; optionally prune installs
  install     Install a pack into the current Unreal project (Content/ or Plugins/)
  validate    Validate packs and (optionally) their archives in depth
  mode        Show or change license mode (restrictive/permissive)
  status      Show assetlib + project status summary (config, modes, cache)
  cache       Inspect or clear the assetlib local archive cache

Quick examples:
  assetlib list
  assetlib list -Category vfx
  assetlib list -Tag sci-fi
  assetlib show fab_scifi_soldier_pro_pack
  assetlib open fab_scifi_soldier_pro_pack
  assetlib add
  assetlib remove fab_old_test_pack
  assetlib uninstall fab_old_test_pack
  assetlib licenses
  assetlib licenses Fab_Standard_License
  assetlib audit
  assetlib audit -Prune -DryRun
  assetlib install Mco_Mocap_Basics
  assetlib install Mco_Mocap_Basics -Preview
  assetlib validate Mco_Mocap_Basics -Deep
  assetlib status
  assetlib cache clear

For detailed help on a specific command:
  assetlib help install
  assetlib help audit
  assetlib help validate
  assetlib help status
  assetlib help cache
"@ | Write-Host
        return
    }

    switch ($Topic.ToLower()) {
        "list" {
@"
assetlib help list
------------------
Usage:
  assetlib list
  assetlib list -Category <category>
  assetlib list -Tag <tag>

Description:
  Lists packs from packs.json with optional filters:

    -Category:
        Filters by entries in the pack's categories array.
        Example values: assets, animations, vfx, systems, plugin

    -Tag:
        Filters by entries in the pack's tags array.

Examples:
  assetlib list
  assetlib list -Category vfx
  assetlib list -Tag sci-fi
"@ | Write-Host
        }
        "show" {
@"
assetlib help show
------------------
Usage:
  assetlib show <id>

Description:
  Prints the full JSON entry for a pack from packs.json.
  This is useful for debugging pack fields like licenseId, archive_url,
  engineVersion, packType, and pluginFolderName.

Example:
  assetlib show fab_scifi_soldier_pro_pack
"@ | Write-Host
        }
        "open" {
@"
assetlib help open
------------------
Usage:
  assetlib open <id>

Description:
  Opens the pack's cloud_url in your default browser. Typically this is a
  Google Drive folder URL where the asset pack lives.

Notes:
  - cloud_url is meant for human-friendly browsing (folder view).
  - archive_url is used by 'assetlib install' for direct downloads (zip).

Example:
  assetlib open fab_scifi_soldier_pro_pack
"@ | Write-Host
        }
        "add" {
@"
assetlib help add
-----------------
Usage:
  assetlib add

Description:
  Starts an interactive flow to add a new pack to packs.json. You will be
  prompted for:

    - id
    - name
    - source (e.g. Fab, Quixel, Self)
    - cloud_url (Google Drive folder URL)
    - archive_url (direct download URL or Drive FILE URL)
    - categories (comma-separated)
    - tags (comma-separated)
    - notes
    - engineVersion (optional, e.g. 5.3)
    - packType (content or plugin)
    - pluginFolderName (for plugins)
    - licenseId (must match licenses/licenses.json)

archive_url behavior:
  - You can paste either:
      - A Google Drive FILE URL (file/d/<id>/view?usp=sharing), or
      - A prebuilt direct download URL, or
      - Another host (S3, itch.io, etc.).
  - For Drive file URLs, assetlib converts them into a direct download form
    automatically so you don’t have to extract the FILE ID manually.

License enforcement:
  - licenseMode = restrictive:
      - Refuses to add packs whose license status is:
          - NON-COMMERCIAL
          - UNKNOWN-LICENSE
          - NO-LICENSE
  - licenseMode = permissive:
      - Allows adding all packs but prints warnings for the above statuses.

Engine metadata:
  - engineVersion is optional metadata used by 'install' for soft warnings
    on content packs and plugins (e.g. "built/tested on 5.3").

Plugin metadata:
  - packType = content (default) or plugin.
  - If packType = plugin, you can specify pluginFolderName (defaults to id),
    which determines the folder under Project/Plugins/ where it is installed.

Example:
  assetlib add
"@ | Write-Host
        }
        "remove" {
@"
assetlib help remove
--------------------
Usage:
  assetlib remove <id>

Description:
  Removes a pack from packs.json. This does NOT delete any files from your
  local Unreal project or from Google Drive; it only removes the manifest
  entry.

Example:
  assetlib remove fab_old_test_pack
"@ | Write-Host
        }
        "uninstall" {
@"
assetlib help uninstall
-----------------------
Usage:
  assetlib uninstall <id> [-Force]

Description:
  Removes a pack's installed files from the CURRENT Unreal project, without
  touching packs.json. The install location is inferred from packType:

    packType = content :  Content/AssetLib/<id>/
    packType = plugin  :  Plugins/<pluginFolderName or id>/

Behavior:
  - Must be run from an Unreal project root (folder with a .uproject + Content/).
  - If the target folder does not exist, nothing is deleted.
  - Without -Force:
      - You are prompted before deleting the folder.
  - With -Force:
      - The folder is removed without prompting.

Editor safety:
  - If Unreal Editor appears to be running:
      - Without -Force:
          - Uninstall is blocked; you are asked to close the editor.
      - With -Force:
          - A warning is shown and uninstall continues.

Example:
  assetlib uninstall Mco_Mocap_Basics
  assetlib uninstall Mco_Mocap_Basics -Force
"@ | Write-Host
        }
        "licenses" {
@"
assetlib help licenses
----------------------
Usage:
  assetlib licenses
  assetlib licenses <licenseId>

Description:
  - Without arguments:
      Lists all license definitions in licenses/licenses.json, including
      whether each one is marked as commercialAllowed (COMMERCIAL vs
      NON-COMMERCIAL).
  - With a licenseId:
      Prints details and the full text of the associated license .txt file.

Examples:
  assetlib licenses
  assetlib licenses Fab_Standard_License
"@ | Write-Host
        }
        "audit" {
@"
assetlib help audit
-------------------
Usage:
  assetlib audit
  assetlib audit -Prune [-DryRun] [-PruneStatus <status1,status2,...>]

Description:
  'assetlib audit' without any flags:
    - Prints a license audit report for all packs in packs.json, classifying
      each as:
        - OK
        - NON-COMMERCIAL
        - UNKNOWN-LICENSE
        - NO-LICENSE

  'assetlib audit -Prune':
    - Must be run from an Unreal project root.
    - Removes installed pack directories under the project root whose
      pack license status matches the configured prune status set.
    - By default, the statuses removed are:
        - NON-COMMERCIAL
        - UNKNOWN-LICENSE
        - NO-LICENSE
    - Only removes the installed directories (e.g. Content/AssetLib/<id>),
      never edit packs.json.

Options:
  -PruneStatus:
    - Comma-separated list of statuses to remove instead of the defaults.
    - Valid statuses: OK, NON-COMMERCIAL, UNKNOWN-LICENSE, NO-LICENSE
    - Example:
        assetlib audit -Prune -PruneStatus NON-COMMERCIAL,UNKNOWN-LICENSE

  -DryRun:
    - Prints which directories WOULD be removed, but does not delete anything.

Editor safety:
  - Recommended: close Unreal Editor before pruning, especially for plugin
    directories.

Examples:
  assetlib audit
  assetlib audit -Prune -DryRun
  assetlib audit -Prune
  assetlib audit -Prune -PruneStatus NON-COMMERCIAL,UNKNOWN-LICENSE
"@ | Write-Host
        }
        "install" {
@"
assetlib help install
---------------------
Usage:
  assetlib install <id> [-Force] [-Preview]

Description:
  Installs a pack into the current Unreal project root by:

    - Downloading archive_url from packs.json (with a progress bar + cache)
    - Extracting it into:
        packType = content :  Content/AssetLib/<id>/
        packType = plugin  :  Plugins/<pluginFolderName or id>/

Requirements:
  - Must be run from an Unreal project root:
      - Directory contains at least one *.uproject
      - Directory contains a Content/ folder
  - The pack must exist in packs.json.
  - The pack must have archive_url set.

License behavior:
  - licenseMode = restrictive:
      - Only installs packs whose license status is 'OK'
        (licenseId known and commercialAllowed = true).
  - licenseMode = permissive:
      - Installs anything but warns on NON-COMMERCIAL, UNKNOWN-LICENSE,
        and NO-LICENSE entries.

Engine compatibility (plugins):
  - For plugins (packType=plugin):
      - The .uplugin file is inspected for EngineVersion.
      - The .uproject is inspected for EngineVersion / EngineAssociation.
      - Major-version mismatch (e.g. plugin 4.x vs project 5.x):
          - INSTALL IS BLOCKED by default; -Force is required to override.
      - Plugin newer than project (e.g. 5.4 plugin on 5.3 project):
          - INSTALL IS BLOCKED by default; -Force is required to override.
      - Plugin older than project (e.g. 5.2 plugin on 5.3 project):
          - INSTALL IS BLOCKED by default; -Force is required to override,
            with a warning that many plugins do work on newer minor versions
            but must be tested.

Engine compatibility (content):
  - For content packs (packType=content):
      - Optional engineVersion in packs.json (e.g. "5.3") is used for soft
        warnings if it does not match the project engine. Content is often
        portable across minor versions, so installs are not blocked.

C++ vs Blueprint-only projects:
  - If a plugin has C++ modules (Modules array in its .uplugin) and the
    .uproject has no Modules (Blueprint-only project), assetlib prints a
    warning that the project may need to be converted to C++ (e.g. by
    adding a C++ class) for the plugin to fully work.

Engine-level plugins (BLOCKED):
  - Some plugin zips are structured for Engine-level installs and contain
    paths like 'Engine/Plugins/...'.
  - assetlib DOES NOT support installing engine-level plugins at all.
      - When such a package is detected:
          - The install is hard-blocked (no -Force override).
          - You are prompted to:
              - Keep the pack in packs.json for tracking only, or
              - Remove the pack from packs.json entirely.
      - If you need such a plugin, install it manually into Engine/Plugins.

Editor safety:
  - If Unreal Editor is running:
      - Without -Force:
          - Install is blocked; you are asked to close the editor.
      - With -Force:
          - A warning is shown and the install continues.
  - Recommended: close Unreal before installing, especially for plugins.

Overwrite behavior:
  - If the target folder already exists:
      - Without -Force:
          - You are prompted before removing the existing folder.
      - With -Force:
          - Existing folder is removed without prompting.

Preview mode:
  - 'assetlib install <id> -Preview' runs the full validation pipeline but
    does NOT modify your project files:
      - Uses (and/or downloads) the archive.
      - Validates it as a ZIP.
      - Extracts it into a temporary folder.
      - Runs plugin engine checks and C++ vs Blueprint-only warnings.
      - Shows how the archive would be laid out in the target path and
        whether flattening would occur.
  - No changes are made to Content/ or Plugins/ in Preview mode.

Local cache:
  - Downloaded archives are cached under:
        %LOCALAPPDATA%\assetlib\cache\<id>.zip
  - On subsequent installs, you can:
      - Reuse the cached file (default), or
      - Force a re-download with -Force.

Download progress:
  - The download uses a streaming HTTP client and Write-Progress to show a
    progress bar in the terminal.

ZIP/API references:
  Invoke-WebRequest / HttpClient:
    https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/invoke-webrequest
    https://learn.microsoft.com/dotnet/api/system.net.http.httpclient
  Expand-Archive:
    https://learn.microsoft.com/powershell/module/microsoft.powershell.archive/expand-archive
  Write-Progress:
    https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/write-progress

Examples:
  assetlib install Mco_Mocap_Basics
  assetlib install Mco_Mocap_Basics -Preview
  assetlib install MyPluginPack -Force
"@ | Write-Host
        }
        "validate" {
@"
assetlib help validate
----------------------
Usage:
  assetlib validate <id> [-Deep]
  assetlib validate --all [-Deep]

Description:
  Quick mode (no -Deep):
    - Shows manifest fields for each pack:
        - id, name, source, packType, licenseId, licenseStatus
        - engineVersion, archive_url presence
    - Does NOT download archives or touch the filesystem.

  Deep mode (-Deep):
    - Reuses 'assetlib install <id> -Preview' internally to:
        - (Re)use cached archive or download it with progress
        - Validate that it is a ZIP
        - Extract into a temporary folder
        - Run plugin engine checks and C++ vs Blueprint-only warnings
        - Detect engine-level plugin packages (and block them)
        - Preview the top-level directory structure and flattening behavior
      - No project files are modified (no Content/ or Plugins/ changes).

Notes:
  - Deep validation requires network access and can take time.
  - Deep validation is safest when run from an Unreal project root so that
    engine compatibility can be compared with the .uproject.

Examples:
  assetlib validate Mco_Mocap_Basics
  assetlib validate Mco_Mocap_Basics -Deep
  assetlib validate --all
  assetlib validate --all -Deep
"@ | Write-Host
        }
        "mode" {
@"
assetlib help mode
------------------
Usage:
  assetlib mode
  assetlib mode restrictive
  assetlib mode permissive

Description:
  Shows or sets the assetlib license mode:

    restrictive :
      - Only packs with status 'OK' (licenseId known, commercialAllowed = true)
        are allowed for add/install.
      - 'assetlib add' will REFUSE to add NON-COMMERCIAL, UNKNOWN-LICENSE, or
        NO-LICENSE packs.
      - 'assetlib install' will REFUSE to install the same statuses.

    permissive  :
      - All packs can be added/installed, but license issues are still
        surfaced by 'assetlib audit', and warnings are printed when adding
        or installing NON-COMMERCIAL / UNKNOWN-LICENSE / NO-LICENSE packs.
      - Use this mode for prototype projects, non-commercial experiments,
        or when you explicitly want to track content you cannot ship.

Examples:
  assetlib mode
  assetlib mode restrictive
  assetlib mode permissive
"@ | Write-Host
        }
        "status" {
@"
assetlib help status
--------------------
Usage:
  assetlib status

Description:
  Shows a quick status overview for assetlib and (when run from an Unreal
  project root) the current project:

  Possible information:
    - assetlib script root (PSScriptRoot)
    - paths to packs.json, licenses.json, and assetlib.config.json
    - Current licenseMode (restrictive or permissive)
    - Number of packs and license definitions loaded
    - Local cache root: %LOCALAPPDATA%\assetlib\cache
    - Approximate cache size and number of cached archives
    - If in an Unreal project:
        - The detected .uproject file
        - The project engine version (EngineVersion / EngineAssociation)
        - Whether the project has C++ modules (mixed C++ + Blueprints)
        - Whether Unreal Editor appears to be running

Notes:
  - This command is intended as a quick “sanity check” to see if assetlib
    is installed correctly and to verify which modes/settings are active.
"@ | Write-Host
        }
        "cache" {
@"
assetlib help cache
-------------------
Usage:
  assetlib cache
  assetlib cache clear
  assetlib cache clear -Force

Description:
  Manages the local archive cache used by 'assetlib install' and
  'assetlib validate -Deep'. Cached archives are stored under:

    %LOCALAPPDATA%\assetlib\cache

  'assetlib cache' (no arguments):
    - Shows:
        - Cache root path
        - Number of cached archives
        - Approximate total size on disk

  'assetlib cache clear':
    - Deletes cached archives from the cache directory.
    - Without -Force:
        - Prompts before deleting.
    - With -Force:
        - Clears the cache without prompting.

Notes:
  - The cache is safe to delete at any time; it just means future installs
    or deep validations will need to re-download archives.
  - Does NOT affect packs.json or any project files.

Examples:
  assetlib cache
  assetlib cache clear
  assetlib cache clear -Force
"@ | Write-Host
        }
        "help" {
@"
assetlib help help
------------------
Usage:
  assetlib help
  assetlib help <command>

Description:
  Shows either:
    - A high-level overview of all commands (no arguments)
    - Detailed documentation for a specific command (with topic)

Examples:
  assetlib help
  assetlib help install
  assetlib help audit
  assetlib help validate
  assetlib help status
  assetlib help cache
"@ | Write-Host
        }
        default {
            Write-Host "Unknown help topic: '$Topic'. Showing general help instead." -ForegroundColor Yellow
            Show-AssetLibHelp
        }
    }
}

# endregion Help
#==============================================================================

#==============================================================================
# region: Top-level dispatcher
#==============================================================================

try {
    switch ($Command) {
        "help" {
            Show-AssetLibHelp -Topic $Id
        }

        "list" {
            Get-AssetPackList -Category $Category -Tag $Tag
        }

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

        "add" {
            Add-AssetPack
        }

        "remove" {
            if (-not $Id) {
                Write-Error "You must provide an id, e.g. assetlib remove Mco_Mocap_Basics"
            }
            else {
                Remove-AssetPack -Id $Id -Force:$Force
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

        "licenses" {
            if ($Id) {
                Get-AssetLicense -Id $Id
            }
            else {
                Get-AssetLicenseList
            }
        }

        "audit" {
            # Always run the standard license audit report.
            Test-AssetPackLicenses | Out-Null

            if ($Prune) {
                $statuses = if ($PruneStatus -and $PruneStatus.Count -gt 0) {
                    $PruneStatus
                }
                else {
                    @("NON-COMMERCIAL", "UNKNOWN-LICENSE", "NO-LICENSE")
                }

                Invoke-AssetPackPrune -StatusesToRemove $statuses -DryRun:$DryRun
            }
        }

        "install" {
            if (-not $Id) {
                Write-Error "You must provide an id, e.g. assetlib install Mco_Mocap_Basics"
            }
            else {
                Install-AssetPack -Id $Id -Force:$Force -Preview:$Preview
            }
        }

        "mode" {
            GetSet-AssetLibMode -Mode $Id
        }

        "status" {
            Show-AssetLibStatus
        }

        "cache" {
            if ($Id) {
                Invoke-AssetLibCache -Action $Id -Force:$Force
            }
            else {
                Invoke-AssetLibCache
            }
        }

        "validate" {
            if ($All) {
                Invoke-AssetPackValidateAll -Deep:$Deep
            }
            elseif ($Id) {
                Invoke-AssetPackValidate -Id $Id -Deep:$Deep
            }
            else {
                Write-Host "Usage: assetlib validate <id> [-Deep]  OR  assetlib validate --all [-Deep]" -ForegroundColor Yellow
            }
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

# endregion Top-level dispatcher
#==============================================================================
