param(
    # First positional argument: which subcommand the user wants to run.
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

$ErrorActionPreference = "Stop"

# Paths for core data files, resolved relative to this script's folder.
$manifestPath        = Join-Path $PSScriptRoot "packs.json"
$licenseManifestPath = Join-Path $PSScriptRoot "licenses\licenses.json"
$configPath          = Join-Path $PSScriptRoot "assetlib.config.json"

# region: Config handling ------------------------------------------------------

# Load configuration from assetlib.config.json.
#   - assetRootUrl : root of your shared asset store (e.g., MEGA folder URL or path)
#   - licenseMode  : "restrictive" or "permissive"
function Get-AssetLibConfig {
    if (Test-Path $configPath) {
        try {
            $json = Get-Content $configPath -Raw
            if ($json.Trim()) {
                $config = $json | ConvertFrom-Json

                if (-not $config.PSObject.Properties.Name -contains 'licenseMode' -or -not $config.licenseMode) {
                    $config | Add-Member -NotePropertyName 'licenseMode' -NotePropertyValue 'restrictive'
                }

                if (-not $config.PSObject.Properties.Name -contains 'assetRootUrl' -or -not $config.assetRootUrl) {
                    $config.assetRootUrl = "https://mega.nz/folder/<your-folder-id>#<your-key>"
                }

                return $config
            }
        }
        catch {
            Write-Warning "Warning: could not read assetlib.config.json, using defaults. Error: $($_.Exception.Message)"
        }
    }

    # Default config if file missing or unreadable - now MEGA-focused.
    return [pscustomobject]@{
        assetRootUrl = "https://mega.nz/folder/<your-folder-id>#<your-key>"
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
        $Config |
        ConvertTo-Json -Depth 5 |
        Set-Content -Path $configPath -Encoding UTF8

        Write-Host "Updated assetlib.config.json"
    }
    catch {
        Write-Error "Failed to write assetlib.config.json: $($_.Exception.Message)"
        throw
    }
}

# endregion --------------------------------------------------------------------

# region: Manifest helpers -----------------------------------------------------

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

function Set-AssetPackManifest {
    param(
        [Parameter(Mandatory = $true)]
        $Packs
    )

    try {
        $Packs |
        ConvertTo-Json -Depth 5 |
        Set-Content -Path $manifestPath -Encoding UTF8

        Write-Host "Updated packs.json"
    }
    catch {
        Write-Error "Failed to write packs.json: $($_.Exception.Message)"
        throw
    }
}

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

# region: MEGAcmd helpers ------------------------------------------------------

# Minimal CLI availability check – used before we call mega-get.
function Test-MegaCmdCliAvailable {
    try {
        $null = mega-help 2>$null
        return $?
    }
    catch {
        return $false
    }
}

# Use MEGAcmd to download the archive for a pack to a temporary directory.
# - remoteSpec is the MEGA path or MEGA file URL stored in pack.archive_url.
# - destDir is a local directory (created if missing).
# Returns: full path to the downloaded ZIP file, or throws on failure.
function Invoke-MegaGetArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteSpec,
        [Parameter(Mandatory = $true)]
        [string]$DestDir
    )

    if (-not (Test-MegaCmdCliAvailable)) {
        throw "MEGAcmd CLI does not appear to be available. Ensure MEGAcmd is installed, on PATH, and that you are logged in (mega-login)."
    }

    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    Write-Host "Using MEGAcmd to download archive:" -ForegroundColor Cyan
    Write-Host "  Remote: $RemoteSpec"
    Write-Host "  Local : $DestDir"
    Write-Host ""

    try {
        $output = mega-get $RemoteSpec $DestDir 2>&1
        $exitOk = $?
    }
    catch {
        $output = $_.Exception.Message
        $exitOk = $false
    }

    if (-not $exitOk) {
        Write-Host $output
        throw "mega-get failed. Verify the archive_url (MEGA path or file link) and that you are logged into MEGAcmd."
    }

    # Find what mega-get actually downloaded.
    $items = Get-ChildItem -Path $DestDir -File -Recurse -ErrorAction SilentlyContinue

    if (-not $items -or $items.Count -eq 0) {
        throw "mega-get reported success but no files were downloaded to '$DestDir'. Check the remote path or link."
    }

    # Prefer a .zip file if one exists.
    $zip = $items | Where-Object { $_.Extension -ieq ".zip" } | Select-Object -First 1
    if ($zip) {
        return $zip.FullName
    }

    # Fallback: if there is exactly one file, use it.
    if ($items.Count -eq 1) {
        return $items[0].FullName
    }

    throw "Multiple non-zip files were downloaded to '$DestDir'. Please ensure archive_url points to a single .zip file on MEGA."
}

# endregion --------------------------------------------------------------------

# region: Unreal project helpers ----------------------------------------------

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
        return $true
    }
}

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
        $assetLibRoot = Join-Path (Join-Path $ProjectRoot 'Content') 'AssetLib'
        return Join-Path $assetLibRoot $Pack.id
    }
}

# endregion --------------------------------------------------------------------

# region: Listing & basic operations ------------------------------------------

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

    if ($Category) {
        $packs = $packs | Where-Object { $_.categories -contains $Category }
    }

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

function Get-AssetPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $packs = Get-AssetPackManifest
    $pack  = $packs | Where-Object { $_.id -eq $Id }
    if (-not $pack) {
        Write-Error "No pack found with id: $Id"
        return
    }

    $pack | ConvertTo-Json -Depth 5
}

# Open a pack's cloud_url in the default browser.
# For MEGA, cloud_url should typically be a MEGA folder link.
function Open-AssetPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $packs = Get-AssetPackManifest
    $pack  = $packs | Where-Object { $_.id -eq $Id }
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

# Interactive add flow for a new pack, now MEGA-focused:
# - offers to open the asset store root (from config) in browser (MEGA folder URL)
# - collects fields for the pack
# - archive_url is now "MEGA archive spec":
#     - either a MEGA file URL (e.g. https://mega.nz/file/...)
#     - or a MEGA path (e.g. /Root/GameLibrary/Packs/MyPack.zip)
# - still enforces license rules (restrictive/permissive)
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

    $name   = Read-Host "name (nice human-readable name)"
    $source = Read-Host "source (Fab/Quixel/Self/etc) [Fab]"
    if (-not $source) { $source = "Fab" }

    # Open MEGA asset root in browser, so you can navigate to the pack folder/file.
    $openRoot = Read-Host "Open asset store root in your browser now (MEGA)? (Y/N) [N]"
    if ($openRoot -match '^[Yy]') {
        $rootUrl = $config.assetRootUrl
        if (-not $rootUrl) {
            $rootUrl = "https://mega.nz/folder/<your-folder-id>#<your-key>"
        }
        Write-Host "Opening $rootUrl..."
        Start-Process $rootUrl
        Write-Host "After preparing the pack on MEGA, copy the folder/file link and paste it below."
    }

    # MEGA folder/file link for human navigation.
    $cloudUrl = Read-Host "MEGA folder or file URL for this pack (cloud_url)"

    # archive_url: MEGA archive spec used by mega-get.
    # This should typically be:
    #   - a MEGA file URL to a .zip
    #   - or a MEGA path (e.g. /Root/GameLibrary/Packs/<id>.zip)
    $archiveUrl = Read-Host "MEGA archive spec used for install (archive_url – file URL or MEGA path to .zip)"

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

function Remove-AssetPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [switch]$Force
    )

    $packs     = Get-AssetPackManifest
    $before    = $packs.Count
    $remaining = $packs | Where-Object { $_.id -ne $Id }

    if ($remaining.Count -eq $before) {
        Write-Error "No pack found with id: $Id"
        return
    }

    if (-not $Force) {
        $confirm = Read-Host "Remove pack '$Id' from assetlib (Removes from manifest and MEGA files)? (Y/N) [N]"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "Removal cancelled."
            return
        }
    }
    # Remove from MEGA
    $packToRemove = $packs | Where-Object { $_.id -eq $Id }
    if ($packToRemove.archive_url) {
        Write-Host "Removing MEGA archive at '$($packToRemove.archive_url)' via MEGAcmd..." -ForegroundColor Cyan
        try {
            $output = mega-rm $packToRemove.archive_url 2>&1
            $exitOk = $?
        }
        catch {
            $output = $_.Exception.Message
            $exitOk = $false
        }

        if (-not $exitOk) {
            Write-Host $output
            Write-Warning "mega-rm failed to remove MEGA archive for pack '$Id'. You may need to remove it manually."
        }
        else {
            Write-Host "Removed MEGA archive for pack '$Id'." -ForegroundColor Green
        }
    }
    else {
        Write-Warning "Pack '$Id' has no archive_url set; skipping MEGA removal."
    }
    # Remove from manifest
    Set-AssetPackManifest -Packs $remaining
    Write-Host "Removed pack $Id from manifest (no project or MEGA files were deleted)." -ForegroundColor Yellow
}

# endregion --------------------------------------------------------------------

# region: Install / Uninstall into Unreal project -----------------------------

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
    $pack  = $packs | Where-Object { $_.id -eq $Id }
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

    # Detect project engine version / C++ modules (unchanged logic).
    $projectEngineVersionString = $null
    $projectEngineMajor         = $null
    $projectEngineMinor         = $null
    $projectHasCppModules       = $false
    $uprojectPath               = $null

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

    # Use MEGAcmd to download the archive to a temp location.
    $tempBaseDir   = [System.IO.Path]::GetTempPath()
    $tempDownload  = Join-Path $tempBaseDir ("assetlib_download_" + $Id + "_" + [System.Guid]::NewGuid().ToString())
    $tempExtract   = Join-Path $tempBaseDir ("assetlib_extract_" + $Id + "_" + [System.Guid]::NewGuid().ToString())
    $tempArchive   = $null

    try {
        $tempArchive = Invoke-MegaGetArchive -RemoteSpec $pack.archive_url -DestDir $tempDownload
    }
    catch {
        Write-Error "Failed to download archive for '$Id' using MEGAcmd: $($_.Exception.Message)"
        if (Test-Path $tempDownload) {
            Remove-Item $tempDownload -Recurse -Force
        }
        return
    }

    # Optional ZIP header check remains – still useful even with MEGA.
    try {
        $headerBytes = New-Object byte[] 4
        $fs = [System.IO.File]::OpenRead($tempArchive)
        try {
            $read = $fs.Read($headerBytes, 0, $headerBytes.Length)
        }
        finally {
            $fs.Dispose()
        }
    }
    catch {
        Write-Error "Downloaded file could not be read from '$tempArchive': $($_.Exception.Message)"
        return
    }

    if ($read -lt 2 -or
        $headerBytes[0] -ne 0x50 -or $headerBytes[1] -ne 0x4B) {

        $debugCopy = Join-Path $projectRoot ("assetlib_failed_download_" + $Id + ".bin")
        Copy-Item -LiteralPath $tempArchive -Destination $debugCopy -Force

        Write-Error @"
Downloaded file for pack '$Id' does not look like a ZIP archive.

Saved the raw downloaded file to:
  $debugCopy

Check this file with 7-Zip or Explorer to confirm it is a valid ZIP archive.
Verify that:
  - The MEGA file itself is actually a .zip
  - archive_url in packs.json points to that .zip (MEGA file URL or MEGA path)
"@
        return
    }

    try {
        Write-Host "Extracting archive to temporary folder '$tempExtract'..."
        Expand-Archive -Path $tempArchive -DestinationPath $tempExtract -Force
    }
    catch {
        $debugCopy = Join-Path $projectRoot ("assetlib_failed_extract_" + $Id + ".zip")
        Copy-Item -LiteralPath $tempArchive -Destination $debugCopy -Force

        Write-Error @"
Failed to extract archive for '$Id' into temporary folder '$tempExtract': $($_.Exception.Message)

A copy of the downloaded file was saved to:
  $debugCopy

Try opening that file with 7-Zip or Explorer to confirm it is a valid ZIP archive.
If it is not, double-check archive_url in packs.json and the pack on MEGA.
"@
        return
    }

    try {
        # Plugin-specific metadata checks (unchanged logic).
        $pluginEngineVersionString = $null
        $pluginEngineMajor         = $null
        $pluginEngineMinor         = $null
        $pluginHasCppModules       = $false
        $pluginIsEngineStylePackage = $false

        if ($pack.packType -eq 'plugin') {
            $upluginFiles = Get-ChildItem -Path $tempExtract -Recurse -Filter *.uplugin
            if (-not $upluginFiles -or $upluginFiles.Count -eq 0) {
                Write-Error "Pack '$Id' is marked as plugin but the archive does not contain a .uplugin file. Cannot install as plugin."
                return
            }

            $upluginFile         = $upluginFiles[0]
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
                    return
                }
                elseif ($choice -match '^[Rr]') {
                    $currentPacks = Get-AssetPackManifest
                    $remaining    = $currentPacks | Where-Object { $_.id -ne $Id }

                    if ($remaining.Count -lt $currentPacks.Count) {
                        Set-AssetPackManifest -Packs $remaining
                        Write-Host "Pack '$Id' has been removed from packs.json because it appears to be an engine-level plugin package." -ForegroundColor Yellow
                    }
                    else {
                        Write-Warning "Pack '$Id' was not found in the current manifest when attempting removal."
                    }

                    Write-Error "Install aborted. Engine-level plugin package '$Id' was removed from the manifest."
                    return
                }
                else {
                    Write-Error "Install aborted. Pack '$Id' remains in packs.json for tracking only."
                    return
                }
            }

            if ($projectEngineMajor -ne $null -and $pluginEngineMajor -ne $null) {
                if ($pluginEngineMajor -ne $projectEngineMajor) {
                    $msg = "Plugin '$Id' targets engine major version $pluginEngineMajor (from .uplugin) but the project appears to use $projectEngineMajor.x."
                    if (-not $Force) {
                        Write-Error "$msg Install blocked. Use -Force to override if you know this plugin is compatible."
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
                        return
                    }
                    else {
                        Write-Warning "$msg Proceeding due to -Force; test the plugin thoroughly."
                    }
                }
            }

            if ($pluginHasCppModules -and -not $projectHasCppModules) {
                Write-Warning @"
Plugin '$Id' contains C++ modules, but the project appears to be Blueprint-only
(no 'Modules' array in the .uproject). Unreal may require converting this project
to a C++ project (e.g., by adding a C++ class once) for the plugin to fully work.
"@
            }
        }

        if ($pack.engineVersion -and $projectEngineMajor -ne $null) {
            if ($pack.engineVersion -match '^(\d+)\.(\d+)') {
                $packMajor = [int]$Matches[1]
                $packMinor = [int]$Matches[2]

                if ($packMajor -ne $projectEngineMajor -or $packMinor -ne $projectEngineMinor) {
                    Write-Warning "Pack '$Id' was tagged for engine $packMajor.$packMinor but the project appears to use $projectEngineMajor.$projectEngineMinor. Content often works across minor versions, but test carefully."
                }
            }
        }

        $topEntries = Get-ChildItem -Path $tempExtract
        $topDirs    = $topEntries | Where-Object { $_.PSIsContainer }
        $topFiles   = $topEntries | Where-Object { -not $_.PSIsContainer }

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
    }
    catch {
        Write-Error "Failed while moving or processing extracted content for '$Id' into '$targetPath': $($_.Exception.Message)"
    }
    finally {
        if (Test-Path $tempArchive) {
            Remove-Item $tempArchive -Force
        }
        if (Test-Path $tempDownload) {
            Remove-Item $tempDownload -Recurse -Force
        }
        if (Test-Path $tempExtract) {
            Remove-Item $tempExtract -Recurse -Force
        }
    }
}

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
    $pack  = $packs | Where-Object { $_.id -eq $Id }
    if (-not $pack) {
        Write-Error "No pack found with id: $Id"
        return
    }

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

function Test-AssetPackLicenses {
    param(
        [switch]$Prune,
        [string[]]$Licenses,
        [switch]$Force
    )

    $packs    = Get-AssetPackManifest
    $licensesManifest = Get-AssetLicenseManifest
    $config   = Get-AssetLibConfig

    if (-not $packs -or $packs.Count -eq 0) {
        Write-Host "No packs in manifest to audit." -ForegroundColor Yellow
        return
    }

    $issues  = 0
    $results = New-Object System.Collections.Generic.List[object]

    Write-Host "Asset pack license audit:" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------"

    foreach ($p in $packs) {
        $status    = Get-AssetPackLicenseStatus -Pack $p -Licenses $licensesManifest
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

    if (-not $Prune) {
        return
    }

    if ($config.licenseMode -ne 'restrictive') {
        Write-Error "audit -Prune is only allowed in 'restrictive' license mode (current mode: '$($config.licenseMode)'). Use 'assetlib mode restrictive' to switch."
        return
    }

    $projectRoot = Get-UnrealProjectRoot
    if (-not $projectRoot) {
        Write-Error "audit -Prune must be run from the root of an Unreal project (folder with a .uproject file and a Content/ folder)."
        return
    }

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

        $installPath = Get-AssetPackInstallPath -Pack $pack -ProjectRoot $projectRoot
        if (-not (Test-Path $installPath)) {
            continue
        }

        $shouldRemove = $false

        if ($Licenses -and $Licenses.Count -gt 0) {
            if (-not $lid) {
                if ($Licenses -contains 'NO-LICENSE') { $shouldRemove = $true }
            }
            elseif (-not ($licensesManifest | Where-Object { $_.id -eq $lid })) {
                if ($Licenses -contains 'UNKNOWN-LICENSE') { $shouldRemove = $true }
            }
            else {
                if ($Licenses -contains $lid) { $shouldRemove = $true }
            }
        }
        else {
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

function Show-AssetLibHelp {
    param(
        [string]$Topic
    )

    $topicKey = $Topic
    if ($topicKey) {
        $topicKey = $topicKey.ToLowerInvariant()
    }

    switch ($topicKey) {
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
"@ | Write-Host
        }

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
"@ | Write-Host
        }

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
  - cloud_url is now expected to be a MEGA folder/file link.
  - The URL is opened using Start-Process, which launches the default browser.
"@ | Write-Host
        }

        "add" {
            @"
assetlib help add
-----------------
Usage:
  assetlib add

Description:
  Interactive wizard to add a new pack to packs.json, now MEGA-focused.

What it does:
  - Optionally opens the asset store root from assetlib.config.json (MEGA folder).
  - Prompts for:
      id, name, source
      cloud_url   (MEGA folder/file URL for human browsing)
      archive_url (MEGA file URL or MEGA path to the .zip archive used by mega-get)
      categories, tags, notes
      licenseId
      packType (content/plugin)
      pluginFolderName (for plugins)
      engineVersion (optional tag)
"@ | Write-Host
        }

        "remove" {
            @"
assetlib help remove
--------------------
Usage:
  assetlib remove <id> [-Force]

Description:
  Removes a pack entry from packs.json only. Does NOT touch any Unreal project
  files or MEGA content.
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
  Manages viewing of license metadata and text from licenses/licenses.json.
"@ | Write-Host
        }

        "install" {
            @"
assetlib help install
---------------------
Usage:
  assetlib install <id> [-Force]

Description:
  Installs a pack into the current Unreal project root by:

    1. Using MEGAcmd (mega-get) to download the pack's archive_url
       (MEGA file URL or MEGA path to a .zip) into a temporary folder.
    2. Validating the downloaded file looks like a ZIP.
    3. Extracting it into:
         packType = content :  Content/AssetLib/<id>/
         packType = plugin  :  Plugins/<pluginFolderName or id>/

Requirements:
  - Must run from an Unreal project root (folder with .uproject + Content/).
  - pack.id must exist in packs.json.
  - pack.archive_url must be set to a MEGA .zip (URL or path).
  - MEGAcmd CLI must be installed, on PATH, and logged in (mega-login).

Other behavior:
  - Honors restrictive/permissive licenseMode for install.
  - Performs the same engine / plugin / C++ checks as before.
  - Still blocks or warns if Unreal Editor is running, depending on -Force.
"@ | Write-Host
        }

        "uninstall" {
            @"
assetlib help uninstall
-----------------------
Usage:
  assetlib uninstall <id> [-Force]

Description:
  Removes an installed pack's files from the current Unreal project, based on
  its packType (Content/AssetLib/<id>/ or Plugins/<pluginFolderName or id>/).
"@ | Write-Host
        }

        "audit" {
            @"
assetlib help audit
-------------------
Usage:
  assetlib audit
  assetlib audit -Prune [-Licenses <id|NO-LICENSE|UNKNOWN-LICENSE> ...] [-Force]

Description:
  Audits licenses for all packs in packs.json and optionally prunes installed
  packs from the current project if licenseMode is 'restrictive'.
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
  Shows or sets the global licenseMode in assetlib.config.json.
"@ | Write-Host
        }

        default {
            @"
assetlib - shared asset pack manifest & Unreal helper (MEGA edition)
====================================================================

Overview
--------
assetlib is a small PowerShell tool that:

  - Tracks asset packs in packs.json
  - Stores license metadata in licenses/licenses.json
  - Opens MEGA folder/file links for packs
  - Uses MEGAcmd (mega-get) to download .zip archives from MEGA
  - Installs/uninstalls packs into an Unreal project
  - Audits and prunes installed packs based on license rules
  - Enforces a configurable license mode: restrictive or permissive

Key MEGA concepts
-----------------
  - cloud_url:
      MEGA folder/file URL for human browsing (opened via 'assetlib open').

  - archive_url:
      MEGA spec used by MEGAcmd to download the .zip for install, typically:
        * a MEGA file URL to a .zip, or
        * a MEGA path like /Root/GameLibrary/Packs/<id>.zip

  - MEGAcmd:
      assetlib assumes MEGAcmd is installed, on PATH, and logged in.
      The installer script (Install-AssetLib.ps1) takes care of that for you.

Core commands
-------------
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
"@ | Write-Host
        }
    }
}

# endregion --------------------------------------------------------------------

# region: Top-level dispatcher -------------------------------------------------

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
    Write-Error "assetlib failed: $($_.Exception.Message)"
    throw
}

# endregion --------------------------------------------------------------------
