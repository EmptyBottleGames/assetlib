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
$manifestPath = Join-Path $PSScriptRoot "packs.json"
$licenseManifestPath = Join-Path $PSScriptRoot "licenses\licenses.json"
$configPath = Join-Path $PSScriptRoot "assetlib.config.json"

# region: Config handling ------------------------------------------------------

# Load configuration from assetlib.config.json.
#   - megaRootPath : root MEGA folder where all packs live (default: "/AssetLib")
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

                if (-not $config.PSObject.Properties.Name -contains 'megaRootPath' -or -not $config.megaRootPath) {
                    $config.megaRootPath = "/AssetLib"
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
        megaRootPath = "/AssetLib"
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

# region: Misc helpers ---------------------------------------------------------

function Select-PathZipOrFolder {
    Add-Type -AssemblyName System.Windows.Forms

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.CheckFileExists = $false
    $dialog.ValidateNames = $false
    $dialog.Multiselect = $false
    $dialog.FileName = "Select Folder"
    $dialog.Filter = "Folders"

    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    if ($dialog.FileName -eq "Select Folder") {
        return Split-Path $dialog.FileName
    }

    return $dialog.FileName
}

function Show-DataTable {
    param([System.Data.DataTable]$Table)
    $text = $Table | Format-Table -AutoSize | Out-String
    Write-Host $text
}


# Returns the current Unreal project root if we're in one (or $null if not).
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

# Discover candidate local pack folders in a UE project:
# - Top-level subfolders under Content/, excluding Content/AssetLib
# - Top-level subfolders under Plugins/ (plugin roots)
function Get-LocalPackCandidatesFromProject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $candidates = New-Object System.Collections.Generic.List[object]

    $contentRoot = Join-Path $ProjectRoot 'Content'
    if (Test-Path $contentRoot) {
        $contentDirs = Get-ChildItem -Path $contentRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'AssetLib' }

        foreach ($dir in $contentDirs) {
            $candidates.Add([pscustomobject]@{
                    Id       = $dir.Name
                    Path     = "Content\$($dir.Name)"
                    FullPath = $dir.FullName
                    Kind     = 'content'
                })
        }
    }

    $pluginsRoot = Join-Path $ProjectRoot 'Plugins'
    if (Test-Path $pluginsRoot) {
        $pluginRoots = Get-ChildItem -Path $pluginsRoot -Directory -ErrorAction SilentlyContinue
        foreach ($p in $pluginRoots) {
            $hasUplugin = @(Get-ChildItem -Path $p.FullName -Filter *.uplugin -Recurse -ErrorAction SilentlyContinue).Count -gt 0
            $kind = if ($hasUplugin) { 'plugin' } else { 'content' }

            $candidates.Add([pscustomobject]@{
                    Id       = $p.Name
                    Path     = "Plugins\$($p.Name)"
                    FullPath = $p.FullName
                    Kind     = $kind
                })
        }
    }

    return $candidates
}

# Prompt user to choose a local pack folder from project candidates.
# Returns [PSCustomObject] @{ Path = <string>; Kind = 'content'|'plugin' } or $null.
function Select-LocalPackPathFromProject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $candidates = Get-LocalPackCandidatesFromProject -ProjectRoot $ProjectRoot
    if (-not $candidates -or $candidates.Count -eq 0) {
        Write-Host "No candidate pack folders found under Content/ or Plugins/ (excluding Content/AssetLib)." -ForegroundColor Yellow
        return $null
    }

    Write-Host ""
    Write-Host "Discovered pack candidates in this project:" -ForegroundColor Cyan
    # Create a table to display candidates with indices
    $table = New-Object System.Data.DataTable
    $table.Columns.Add("Index") | Out-Null
    $table.Columns.Add("Name") | Out-Null
    $table.Columns.Add("Kind") | Out-Null

    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $c = $candidates[$i]
        $table.Rows.Add($i, $c.Id, $c.Kind) | Out-Null
    }
    
    Show-DataTable -Table $table

    $index = Read-Host "Enter the index of the folder you want to use for this pack (or blank to cancel)"
    if (-not $index -and $index -ne 0) {
        Write-Host "No selection made; skipping project-based discovery." -ForegroundColor Yellow
        return $null
    }

    if (-not [int]::TryParse($index, [ref]$null) -or
        [int]$index -lt 0 -or
        [int]$index -ge $candidates.Count) {

        Write-Error "Invalid index '$index'."
        return $null
    }

    $chosen = $candidates[[int]$index]
    return [pscustomobject]@{
        Id   = $chosen.Id
        Path = $chosen.FullPath
        Kind = $chosen.Kind
    }
}

# endregion --------------------------------------------------------------------

# region: Manifest helpers -----------------------------------------------------

function Get-AssetPackManifest {
    if (-not (Test-Path $manifestPath)) {
        return , @()
    }
    $json = Get-Content $manifestPath -Raw
    if (-not $json.Trim()) {
        return , @()
    }
    $returnJson = $json | ConvertFrom-Json
    return $returnJson ? $returnJson : , @()
}

function Set-AssetPackManifest {
    param(
        [Parameter(Mandatory = $true)]
        $Packs
    )

    try {
        , $Packs |
        ConvertTo-Json -Depth 5 |
        Set-Content -Path $manifestPath -Encoding UTF8

        Write-Host "Updated packs.json" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to write packs.json: $($_.Exception.Message)"
        throw
    }
}

function Get-AssetLicenseManifest {
    if (-not (Test-Path $licenseManifestPath)) {
        Write-Error "License manifest not found at $licenseManifestPath"
        return , @()
    }
    $json = Get-Content $licenseManifestPath -Raw
    if (-not $json.Trim()) {
        return , @()
    }
    $returnJson = $json | ConvertFrom-Json
    return $returnJson ? $returnJson : , @()
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
            License   = $licenseId -replace '_', ' '
            LicenseId = $licenseId
        }
    }

    if (-not $lic.commercialAllowed) {
        return [pscustomobject]@{
            Status    = 'NON-COMMERCIAL'
            License   = $lic.name
            LicenseId = $licenseId
        }
    }

    return [pscustomobject]@{
        Status    = 'OK'
        License   = $lic.name
        LicenseId = $licenseId
    }
}

# endregion --------------------------------------------------------------------

# region: MEGAcmd helpers ------------------------------------------------------

function Test-MegaCmdCliAvailable {
    try {
        $null = mega-help 2>$null
        return $?
    }
    catch {
        return $false
    }
}

# Build the full MEGA path for a pack using config.megaRootPath and pack.megaSubPath or pack.id
function Get-MegaPathForPack {
    param(
        [Parameter(Mandatory = $true)]
        $Pack,
        [Parameter(Mandatory = $true)]
        $Config
    )

    $root = if ($Config.megaRootPath) { $Config.megaRootPath } else { "/AssetLib" }
    $root = $root.TrimEnd('/')

    $sub = $null
    if ($Pack.PSObject.Properties.Name -contains 'megaSubPath' -and $Pack.megaSubPath) {
        $sub = $Pack.megaSubPath
    }
    else {
        $sub = $Pack.id
    }

    $sub = $sub.Trim('/')
    if (-not $sub) { $sub = $Pack.id }

    return "$root/$sub"
}

# Use MEGAcmd to upload a local folder into a remote MEGA folder.
function Invoke-MegaPutFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalFolder,
        [Parameter(Mandatory = $true)]
        [string]$RemoteFolder,
        [switch]$Force
    )

    if (-not (Test-MegaCmdCliAvailable)) {
        throw "MEGAcmd CLI does not appear to be available. Ensure MEGAcmd is installed, on PATH, and that you are logged in (mega-login)."
    }

    if (-not (Test-Path $LocalFolder -PathType Container)) {
        throw "Local path '$LocalFolder' is not a folder. assetlib now expects pack content as a folder (not a .zip)."
    }

    Write-Host "Preparing to upload pack folder to MEGA:" -ForegroundColor Cyan
    Write-Host "  Local : $LocalFolder"
    Write-Host "  Remote: $RemoteFolder"
    Write-Host ""

    # Check if remote already exists.
    $remoteExists = $false
    try {
        $null = mega-ls $RemoteFolder 2>$null
        $remoteExists = $?
    }
    catch {
        $remoteExists = $false
    }

    if ($remoteExists) {
        if (-not $Force) {
            $answer = Read-Host "Remote path '$RemoteFolder' already exists. Overwrite it? (Y/N) [N]"
            if ($answer -notmatch '^[Yy]') {
                throw "Upload cancelled by user; remote path already exists."
            }
        }

        Write-Host "Removing existing remote folder '$RemoteFolder' via mega-rm..." -ForegroundColor Yellow
        try {
            $outputRm = mega-rm $RemoteFolder 2>&1
            if (-not $?) {
                Write-Host $outputRm
                throw "mega-rm failed when attempting to remove '$RemoteFolder'."
            }
        }
        catch {
            throw "Failed to remove remote path '$RemoteFolder': $($_.Exception.Message)"
        }
    }

    Write-Host "Uploading via mega-put..." -ForegroundColor Cyan
    try {
        $outputPut = mega-put $LocalFolder $RemoteFolder 2>&1
        if (-not $?) {
            Write-Host $outputPut
            throw "mega-put failed for '$LocalFolder' -> '$RemoteFolder'."
        }
    }
    catch {
        throw "MEGA upload failed: $($_.Exception.Message)"
    }

    Write-Host "Upload completed to '$RemoteFolder'." -ForegroundColor Green
}

# Use MEGAcmd to download the MEGA path for a pack into a local temporary directory.
# Returns the local folder path containing the pack content.
function Invoke-MegaGetPackFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteFolder,
        [Parameter(Mandatory = $true)]
        [string]$DestRoot
    )

    if (-not (Test-MegaCmdCliAvailable)) {
        throw "MEGAcmd CLI does not appear to be available. Ensure MEGAcmd is installed, on PATH, and that you are logged in (mega-login)."
    }

    if (-not (Test-Path $DestRoot)) {
        New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
    }

    Write-Host "Using MEGAcmd to download pack folder:" -ForegroundColor Cyan
    Write-Host "  Remote: $RemoteFolder"
    Write-Host "  Local : $DestRoot"
    Write-Host ""

    try {
        $output = mega-get $RemoteFolder $DestRoot 2>&1
        $exitOk = $?
    }
    catch {
        $output = $_.Exception.Message
        $exitOk = $false
    }

    if (-not $exitOk) {
        Write-Host $output
        throw "mega-get failed. Verify the MEGA path '$RemoteFolder' and that you are logged into MEGAcmd."
    }

    # mega-get will typically create a subfolder under DestRoot.
    $items = Get-ChildItem -Path $DestRoot -Directory -ErrorAction SilentlyContinue
    if (-not $items -or $items.Count -eq 0) {
        throw "mega-get reported success but no folders were downloaded to '$DestRoot'. Check the remote path."
    }

    if ($items.Count -eq 1) {
        return $items[0].FullName
    }

    # If multiple folders came down, this is unexpected – but we still choose the first.
    Write-Warning "Multiple folders downloaded under '$DestRoot'; using the first: '$($items[0].FullName)'."
    return $items[0].FullName
}

# Generate a MEGA export link for a given remote folder and open it in the browser.
# The link is NOT stored in packs.json; it is ephemeral from assetlib's perspective.
function Open-MegaFolderInBrowser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteFolder
    )

    if (-not (Test-MegaCmdCliAvailable)) {
        Write-Host "MEGAcmd CLI does not appear to be available. Cannot generate export link." -ForegroundColor Red
        return
    }

    Write-Host "Requesting MEGA export link for '$RemoteFolder'..." -ForegroundColor Cyan

    $output = ""
    try {
        $output = mega-export -a $RemoteFolder 2>&1
        $exitOk = $?
    }
    catch {
        $output = $_.Exception.Message
        $exitOk = $false
    }

    if (-not $exitOk) {
        Write-Host $output
        Write-Host "mega-export failed for '$RemoteFolder'." -ForegroundColor Red
        return
    }

    # Try to find a URL in the output (MEGA-style link).
    $link = $null
    $_matches = [regex]::Matches($output, 'https://mega\.nz/\S+')
    if ($_matches.Count -gt 0) {
        $link = $_matches[0].Value
    }

    if (-not $link) {
        Write-Host $output
        Write-Host "mega-export did not produce a recognizable MEGA URL." -ForegroundColor Red
        return
    }

    Write-Host "Opening MEGA link in your default browser:" -ForegroundColor Green
    Write-Host "  $link"
    Start-Process $link
    [void](Read-Host "Press Enter to continue after you've finished with the MEGA link")
    try {
        $outDel = mega-export -d $RemoteFolder 2>&1
        if (-not $?) {
            Write-Host $outDel -ForegroundColor Red
            Write-Warning "mega-export -d did not succeed; export link may still be active."
        }
        else {
            Write-Host "Export link revoked." -ForegroundColor Green
        }
    }
    catch {
        Write-Host "Failed to revoke export link: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# endregion --------------------------------------------------------------------

# region: Unreal project helpers (remaining) ----------------------------------

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
    $pack = $packs | Where-Object { $_.id -eq $Id }
    if (-not $pack) {
        Write-Error "No pack found with id: $Id"
        return
    }

    $pack | ConvertTo-Json -Depth 5
}

# Open the pack's MEGA folder in the browser by exporting its MEGA path on demand.
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

    $config = Get-AssetLibConfig
    $remotePath = Get-MegaPathForPack -Pack $pack -Config $config

    Open-MegaFolderInBrowser -RemoteFolder $remotePath
}

function Get-AssetLicenseList {
    $licenses = Get-AssetLicenseManifest
    if (-not $licenses -or $licenses.Count -eq 0) {
        Write-Host "No licenses defined. Edit licenses/licenses.json to add licenses." -ForegroundColor Red
        return
    }
    # Create a data table to display licenses
    $table = New-Object System.Data.DataTable
    $table.Columns.Add("Index") | Out-Null
    $table.Columns.Add("Id") | Out-Null
    $table.Columns.Add("Status") | Out-Null
    $table.Columns.Add("Name") | Out-Null

    for ($i = 0; $i -lt $licenses.Count; $i++) {
        $lic = $licenses[$i]
        $flag = if ($lic.commercialAllowed) { "COMMERCIAL" } else { "NON-COMMERCIAL" }
        $table.Rows.Add($i, $lic.id, $flag, $lic.name) | Out-Null
    }
    # Show the licenses table
    Show-DataTable -Table $table
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

# Interactive wizar
function Add-AssetPackHelper {
    param(
        [Parameter(Mandatory = $true)]
        $Packs,
        [string]$Id = $null,
        [string]$UploadFolderPath = $null
    )
    
    # Define dummy object to store new pack data. We'll fill it in interactively.
    $interactivePackData = [PSCustomObject]@{
        id               = $Id
        name             = $Id -replace '_', ' '
        uploadFolderPath = $UploadFolderPath
    }

    if ($Id) {
        $interactivePackData.id = Read-Host "id (usually the folder name) [${Id}]"
        if (-not $interactivePackData.id) {
            $interactivePackData.id = $Id
        }
    }
    else {
        $interactivePackData.id = Read-Host "id (usually the folder name. e.g. fab_scifi_soldier_pro_pack)"
    }

    if (-not $interactivePackData.id) {
        Write-Error "id is required."
        return
    }
    
    # Check for existing pack with this id.
    if ($Packs | Where-Object { $_.id -eq $interactivePackData.id }) {
        Write-Error "A pack with id '$($interactivePackData.id)' already exists."
        return
    }

    $nameFromId = $interactivePackData.id -replace '_', ' '
    $name = Read-Host "name (nice human-readable name) [$nameFromId]"
    if (-not $name) { $name = $nameFromId }
    $interactivePackData.name = $name

    if (-not $UploadFolderPath) {
        $useDialog = Read-Host "Do you want to select the local pack folder via a dialog? (Y/N) [N]"
        if ($useDialog -match '^[Yy]') {
            $pickedPath = Select-PathZipOrFolder
            if (-not $pickedPath) {
                Write-Error "No folder selected; cancelling."
                return
            }
            $interactivePackData.uploadFolderPath = $pickedPath
            Write-Host "Selected: $($interactivePackData.uploadFolderPath)"
            
        }
        else {
            $interactivePackData.uploadFolderPath = Read-Host "Enter the full local path to the folder containing the pack content"
        }
    }
    else {
        $interactivePackData.uploadFolderPath = Read-Host "Enter the full local path to the pack folder [$($interactivePackData.uploadFolderPath)]"
        if (-not $interactivePackData.uploadFolderPath) {
            $interactivePackData.uploadFolderPath = $UploadFolderPath
        }
    }

    if (-not $interactivePackData.uploadFolderPath) {
        Write-Error "No local folder path supplied; cancelling."
        return
    }

    if (Test-Path $interactivePackData.uploadFolderPath -PathType Leaf) {
        $ext = [System.IO.Path]::GetExtension($interactivePackData.uploadFolderPath)
        if ($ext -ieq ".zip") {
            Write-Error "assetlib now expects pack content as a folder (not a .zip). Please extract the zip and rerun 'assetlib add'."
            return
        }
        else {
            Write-Error "Local path '$($interactivePackData.uploadFolderPath)' is a file; a folder path is required."
            return
        }
    }

    if (-not (Test-Path $interactivePackData.uploadFolderPath -PathType Container)) {
        Write-Error "Local folder '$($interactivePackData.uploadFolderPath)' does not exist."
        return
    }

    return $interactivePackData
}

# Interactive add flow for a new pack, MEGA-native and folder-based:
# - If in a UE project root, offers to auto-select a local pack folder from Content/ or Plugins/
#   (ignores Content/AssetLib).
# - Otherwise, lets the user pick a folder via dialog or manual input.
# - Uploads the folder to $config.megaRootPath/<megaSubPath-or-id> via mega-put.
# - Stores only metadata + megaSubPath, no URLs or archive paths.
function Add-AssetPack {
    $packs = Get-AssetPackManifest
    $config = Get-AssetLibConfig
    $licenses = Get-AssetLicenseManifest

    if (-not $licenses -or $licenses.Count -eq 0) {
        Write-Error "No licenses defined; cannot add pack safely."
        return
    }

    $projectRoot = Get-UnrealProjectRoot
    $defaultPackType = 'content'
    $interactivePackData = [PSCustomObject]@{
        id               = $null
        name             = $null
        uploadFolderPath = $null
        defaultPackType  = $defaultPackType
    }
    
    if ($projectRoot) {
        Write-Host ""
        Write-Host "Detected Unreal project root at: $projectRoot" -ForegroundColor Cyan
        $autoUse = Read-Host "Select a pack folder from this project's Content/ or Plugins/? (Y/N) [Y]"
        if (-not $autoUse -or $autoUse -match '^[Yy]') {
            $selection = Select-LocalPackPathFromProject -ProjectRoot $projectRoot
            if ($selection) {
                Write-Host "Using local folder: $($selection.Path) ($($selection.Kind))" -ForegroundColor Green
                $interactivePackData.uploadFolderPath = $selection.Path
                $interactivePackData.defaultPackType = $selection.Kind
            }

        }
        $interactivePackData = Add-AssetPackHelper -Packs $packs -Id $selection.Id -UploadFolderPath $selection.Path
    }
    else {
        # This is where we do default wizard for non-project folder selection.
        $interactivePackData = Add-AssetPackHelper -Packs $packs
    }

    $source = Read-Host "source (Fab/Quixel/Self/etc) [Fab]"
    if (-not $source) { $source = "Fab" }

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

    $engineVersion = Read-Host "engine version this pack/plugin was built/tested against (optional, e.g. 5.6 or a range like 5.0-5.7)"
    
    $finished = $false
    $licStatus = [pscustomobject]@{
        Status    = 'NO-LICENSE'
        License   = $null
        LicenseId = $null
    }
    while (-not $finished) {
        Write-Host ""
        Write-Host "Available licenses:" -ForegroundColor Cyan
        Get-AssetLicenseList
        $licenseMode = $config.licenseMode
        $licenseIndex = Read-Host $($licenseMode -eq "restrictive" ? "Enter the index of the license to assign to this pack" : "Enter the index of the license to assign to this pack (Leave blank for no license)")
        # Guard against invalid input
        if (-not $licenseIndex -and $licenseMode -eq 'restrictive') {
            Write-Host "In restrictive mode, a license must be assigned." -ForegroundColor Red
            continue
        }
        if (-not $licenseIndex -and $licenseMode -eq 'permissive') {
            $finished = $true
        }
        if ($licenseIndex) {
            if (-not [int]::TryParse($licenseIndex, [ref]$null) -or
                [int]$licenseIndex -lt 0 -or
                [int]$licenseIndex -ge $licenses.Count) {

                Write-Host "Invalid index '$licenseIndex'" -ForegroundColor Red
                continue
            }
            $licenseIndex = [int]$licenseIndex
        }
        try {
            $lic = $licenses[$licenseIndex]
            $finished = $true
        }
        catch {
            continue
        }
        $licStatus = Get-AssetPackLicenseStatus -Pack ([pscustomobject]@{ 
            licenseId = $lic.id
            license   = $lic.name
        }) -Licenses $licenses
       
    }
    if ($licenseMode -eq 'restrictive') {
        switch ($licStatus.Status) {
            'NO-LICENSE' {
                Write-Error "No licenseId provided; cannot add pack in restrictive mode."
                return
            }
            'UNKNOWN-LICENSE' {
                Write-Error "License id '$($licStatus.License)' not found in licenses/licenses.json (restrictive mode)."
                return
            }
            'NON-COMMERCIAL' {
                Write-Error "License '$($licStatus.License)' is marked as NON-COMMERCIAL. This pack cannot be added in restrictive mode."
                return
            }
            'OK' { Write-Host "Selected license '$($licStatus.License)'" -ForegroundColor Green }
        }
    }
    else {
        switch ($licStatus.Status) {
            'NO-LICENSE' {
                Write-Warning "No licenseId provided; pack added in permissive mode but flagged as NO-LICENSE."
            }
            'UNKNOWN-LICENSE' {
                Write-Warning "License '$($licStatus.License)' not found in licenses/licenses.json; pack added in permissive mode but flagged as UNKNOWN-LICENSE."
            }
            'NON-COMMERCIAL' {
                Write-Warning "License '$($licStatus.License)' is NON-COMMERCIAL; pack added in permissive mode but only safe for non-commercial contexts."
            }
            'OK' { Write-Host "Selected license '$($licStatus.License)'" -ForegroundColor Green }
        }
    }

    $packTypePromptDefault = $defaultPackType
    $packType = Read-Host "pack type (content/plugin) [$($interactivePackData.defaultPackType ? $interactivePackData.defaultPackType : $defaultPackType)]"
    if (-not $packType) { $packType = $packTypePromptDefault }

    $pluginFolderName = $null
    if ($packType -eq 'plugin') {
        $pluginFolderName = Read-Host "plugin folder name under Plugins/ (optional) [$($interactivePackData.id)]"
        if (-not $pluginFolderName) { $pluginFolderName = $interactivePackData.id }
    }

    $megaSubPath = Read-Host "Remote MEGA subpath under root '$($config.megaRootPath)' (optional) [$($interactivePackData.id)]"
    if ($megaSubPath) {
        $megaSubPath = $megaSubPath.Trim('/')
    }
    if (-not $megaSubPath) {
        $megaSubPath = $interactivePackData.id
    }

    $newPack = [PSCustomObject]@{
        id               = $interactivePackData.id
        name             = $interactivePackData.name
        source           = $source
        categories       = $categories
        tags             = $tags
        notes            = $notes
        licenseId        = $lic.id
        packType         = $packType
        pluginFolderName = $pluginFolderName
        engineVersion    = $engineVersion
        megaSubPath      = $megaSubPath  # relative under megaRootPath
    }

    $remotePath = Get-MegaPathForPack -Pack $newPack -Config $config

    try {
        Invoke-MegaPutFolder -LocalFolder $interactivePackData.uploadFolderPath -RemoteFolder $remotePath -Force:$Force
    }
    catch {
        Write-Error "Failed to upload pack folder to MEGA: $($_.Exception.Message)"
        return
    }

    $packs += $newPack
    Set-AssetPackManifest -Packs $packs
    Write-Host "Added pack $($interactivePackData.id) with license '$($lic.id)' in mode '$($config.licenseMode)'. Remote MEGA path: $remotePath" -ForegroundColor Green
}

function Remove-AssetPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [switch]$Force
    )

    $packs = Get-AssetPackManifest
    $before = $packs.Count
    $packToRemove = $packs | Where-Object { $_.id -eq $Id }
    $remaining = , $packs | Where-Object { $_.id -ne $Id }
    
    if ($remaining.Count -eq $before) {
        Write-Error "No pack found with id: $Id"
        return
    }

    if (-not $Force) {
        $confirm = Read-Host "Remove pack '$Id' from assetlib (removes manifest entry and MEGA folder)? (Y/N) [N]"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "Removal cancelled."
            return
        }
    }

    $config = Get-AssetLibConfig

    if ($packToRemove) {
        $remotePath = Get-MegaPathForPack -Pack $packToRemove -Config $config
        if (Test-MegaCmdCliAvailable) {
            Write-Host "Removing MEGA folder at '$remotePath' via mega-rm..." -ForegroundColor Cyan
            try {
                $output = mega-rm -r -f $remotePath 2>&1
                $exitOk = $?
            }
            catch {
                $output = $_.Exception.Message
                $exitOk = $false
            }

            if (-not $exitOk) {
                # check output for "No such file or directory" to avoid false warning
                if ($output -notmatch 'No such file or directory') {
                    Write-Warning "mega-rm failed to remove MEGA folder for pack '$Id'. Error: $output"
                }
                else {
                    Write-Host "MEGA folder for pack '$Id' does not exist; nothing to remove." -ForegroundColor Cyan
                }
            }
            else {
                Write-Host "Removed MEGA folder for pack '$Id'." -ForegroundColor Green
            }
        }
        else {
            Write-Warning "MEGAcmd CLI not available; skipping remote removal for '$Id'."
        }
    }

    Set-AssetPackManifest -Packs $($remaining ? $remaining : , @()) 
    Write-Host "Removed pack $Id from manifest." -ForegroundColor Green
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

    $remotePath = Get-MegaPathForPack -Pack $pack -Config $config

    # Detect project engine version / C++ modules (unchanged logic).
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

    $tempBaseDir = [System.IO.Path]::GetTempPath()
    $tempDownload = Join-Path $tempBaseDir ("assetlib_dl_" + $Id + "_" + [System.Guid]::NewGuid().ToString())

    $localPackFolder = $null
    try {
        $localPackFolder = Invoke-MegaGetPackFolder -RemoteFolder $remotePath -DestRoot $tempDownload
    }
    catch {
        Write-Error "Failed to download pack folder for '$Id' using MEGAcmd: $($_.Exception.Message)"
        if (Test-Path $tempDownload) {
            Remove-Item $tempDownload -Recurse -Force
        }
        return
    }

    try {
        # Plugin-specific metadata checks (unchanged logic, now scanning folder).
        $pluginEngineVersionString = $null
        $pluginEngineMajor = $null
        $pluginEngineMinor = $null
        $pluginHasCppModules = $false
        $pluginIsEngineStylePackage = $false

        if ($pack.packType -eq 'plugin') {
            $upluginFiles = Get-ChildItem -Path $localPackFolder -Recurse -Filter *.uplugin
            if (-not $upluginFiles -or $upluginFiles.Count -eq 0) {
                Write-Error "Pack '$Id' is marked as plugin but the MEGA folder does not contain a .uplugin file. Cannot install as plugin."
                return
            }

            $upluginFile = $upluginFiles[0]
            $relativeUpluginPath = $upluginFile.FullName.Substring($localPackFolder.Length).TrimStart('\', '/')
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
The plugin folder for '$Id' appears to be structured as an Engine-level plugin
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
                    $remaining = $currentPacks | Where-Object { $_.id -ne $Id }

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

        $localRootEntries = Get-ChildItem -Path $localPackFolder

        if (-not (Test-Path $targetPath)) {
            New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
        }

        if ($localRootEntries.Count -eq 1 -and $localRootEntries[0].PSIsContainer) {
            $wrapperDir = $localRootEntries[0]
            Write-Host "Detected single top-level folder '$($wrapperDir.Name)' in MEGA pack. Flattening into '$targetPath' to avoid double nesting..."

            Get-ChildItem -Path $wrapperDir.FullName | ForEach-Object {
                $dest = Join-Path $targetPath $_.Name
                Move-Item -LiteralPath $_.FullName -Destination $dest -Force
            }
        }
        else {
            Write-Host "Copying MEGA pack structure into '$targetPath'..." -ForegroundColor Cyan
            Get-ChildItem -Path $localPackFolder | ForEach-Object {
                $dest = Join-Path $targetPath $_.Name
                Move-Item -LiteralPath $_.FullName -Destination $dest -Force
            }
        }

        Write-Host "Installed pack '$Id' to '$targetPath' (licenseMode=$licenseMode)." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed while moving or processing downloaded content for '$Id' into '$targetPath': $($_.Exception.Message)"
    }
    finally {
        if (Test-Path $tempDownload) {
            Remove-Item $tempDownload -Recurse -Force
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
    $pack = $packs | Where-Object { $_.id -eq $Id }
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

    $packs = Get-AssetPackManifest
    $licensesManifest = Get-AssetLicenseManifest
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
        $status = Get-AssetPackLicenseStatus -Pack $p -Licenses $licensesManifest
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
"@ | Write-Host
        }

        "open" {
            @"
assetlib help open
------------------
Usage:
  assetlib open <id>

Description:
  Opens the pack's MEGA folder in your default browser.

Details:
  - assetlib computes the MEGA path for the pack using:
      megaRootPath (from assetlib.config.json, default '/AssetLib')
      and pack.megaSubPath or pack.id (relative under that root).
  - Then it runs 'mega-export' on that folder to obtain a link,
    opens the link in the browser, and optionally revokes the export.
  - No URLs are stored in packs.json; links are generated on demand.
"@ | Write-Host
        }

        "add" {
            @"
assetlib help add
-----------------
Usage:
  assetlib add [-Force]

Description:
  Interactive wizard to add a new pack to packs.json and upload its content to MEGA.

What it does:
  - If run from a UE project root:
      - Offers to auto-discover pack folders under Content/ and Plugins/
        (ignores Content/AssetLib because those are assumed installed via assetlib).
  - Otherwise:
      - Lets you choose a local folder via GUI dialog or manual path.
  - Validates:
      - id uniqueness
      - licenseId according to licenseMode (restrictive/permissive)
      - local path is a folder (not a .zip)
  - Uploads the folder to MEGA via 'mega-put' into:
      <megaRootPath>/<megaSubPath-or-id>
  - Saves pack metadata in packs.json including 'megaSubPath' but not any URLs.

Notes:
  - The pack content on MEGA is stored as a folder; installs use 'mega-get'
    on the folder, not a zip file.
"@ | Write-Host
        }

        "remove" {
            @"
assetlib help remove
--------------------
Usage:
  assetlib remove <id> [-Force]

Description:
  Removes a pack entry from packs.json and attempts to remove its MEGA folder.

Details:
  - The MEGA folder is derived from megaRootPath + pack.megaSubPath or pack.id.
  - Uses 'mega-rm' to delete the remote folder if MEGAcmd is available.
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
  Shows license metadata and license text from licenses/licenses.json.
"@ | Write-Host
        }

        "install" {
            @"
assetlib help install
---------------------
Usage:
  assetlib install <id> [-Force]

Description:
  Installs a pack into the current Unreal project by:

    1. Computing the MEGA folder path for the pack:
         megaRootPath + megaSubPath (or id if megaSubPath not set).
    2. Using MEGAcmd 'mega-get' to download that folder into a temporary
       local directory.
    3. Inspecting it for plugin metadata if packType=plugin (same as before).
    4. Copying the content into:
         packType = content :  Content/AssetLib/<id>/
         packType = plugin  :  Plugins/<pluginFolderName or id>/

Notes:
  - No zip files are used anymore; everything is folder-based.
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

  megaRootPath:
    - Also stored in assetlib.config.json (default '/AssetLib').
    - All pack MEGA paths are derived from it and the pack's megaSubPath or id.
"@ | Write-Host
        }

        default {
            @"
assetlib - shared asset pack manifest & Unreal helper (MEGA-native, folder-based)
=================================================================================

Overview
--------
assetlib is a small PowerShell tool that:

  - Tracks asset packs in packs.json
  - Stores license metadata in licenses/licenses.json
  - Uses MEGAcmd to:
      - Upload local pack folders to MEGA (mega-put)
      - Download pack folders from MEGA (mega-get)
      - Export pack folders as short-lived-ish browser links (mega-export)
  - Installs/uninstalls packs into an Unreal project
  - Audits and prunes installed packs based on license rules
  - Enforces a configurable license mode: restrictive or permissive

Key MEGA concepts
-----------------
  - megaRootPath (config):
      Root folder on MEGA where all packs live. Default: '/AssetLib'.

  - megaSubPath (per-pack):
      Optional relative subpath under megaRootPath.
      If not set, the pack uses '<megaRootPath>/<id>'.

  - MEGA folder layout:
      For a pack with id = 'fab_scifi_soldier_pro_pack':
        - megaRootPath = '/AssetLib'
        - megaSubPath  = 'fab_scifi_soldier_pro_pack'
        => Remote MEGA folder: '/AssetLib/fab_scifi_soldier_pro_pack'

  - No archive_url, no cloud_url:
      assetlib no longer stores URLs or zip locations.
      Everything is folder-based and derived from MEGA paths.

Core commands
-------------
  assetlib help
  assetlib help <command>

  assetlib list [-Category <category>] [-Tag <tag>]
  assetlib show <id>
  assetlib open <id>

  assetlib add [-Force]
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
  - Commands that only touch JSON/config are safe while Unreal Editor is open:
      help, list, show, open, add, remove, licenses, audit (without -Prune), mode

  - Commands that modify a project (Content/ or Plugins/) are editor-sensitive:
      install, uninstall, audit -Prune

    For those, assetlib:
      - Detects Unreal Editor processes.
      - Blocks operations if the editor appears to be running, unless -Force is used.
      - With -Force, prints a warning and proceeds.

MEGAcmd expectations
--------------------
  - MEGAcmd must be installed and on PATH.
  - The user must be logged in (mega-login).
  - The installer script (Install-AssetLib.ps1) is responsible for bootstrap:
      - Installing MEGAcmd
      - Adding it to PATH
      - Guiding the user through MEGAcmd login.
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
