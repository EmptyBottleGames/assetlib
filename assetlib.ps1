param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("list", "show", "open", "add", "remove")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Id
)

$ErrorActionPreference = "Stop"
$manifestPath = Join-Path $PSScriptRoot "packs.json"

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

function Save-AssetPackManifest {
    param(
        [Parameter(Mandatory = $true)]
        $Packs
    )

    $Packs | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
    Write-Host "Updated packs.json"
}

function Get-AssetPackList {
    $packs = Get-AssetPackManifest
    if (-not $packs -or $packs.Count -eq 0) {
        Write-Host "No packs in manifest yet."
        return
    }

    foreach ($p in $packs) {
        $cats = ($p.categories -join ", ")
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
        Write-Host "No pack found with id: $Id" -ForegroundColor Red
        return
    }
    $pack | ConvertTo-Json -Depth 5
}

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

function Add-AssetPack {
    $packs = Get-AssetPackManifest

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

    $cloudUrl = Read-Host "Google Drive folder URL"

    $catsRaw = Read-Host "categories (comma-separated: assets, animations, vfx, systems)"
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
    $license = Read-Host "license [Fab_personal]"
    if (-not $license) { $license = "Fab_personal" }

    $newPack = [PSCustomObject]@{
        id         = $id
        name       = $name
        source     = $source
        cloud_url  = $cloudUrl
        categories = $categories
        tags       = $tags
        notes      = $notes
        license    = $license
    }

    $packs += $newPack
    Save-AssetPackManifest -Packs $packs
    Write-Host "Added pack $id" -ForegroundColor Green
}

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

    Save-AssetPackManifest -Packs $remaining
    Write-Host "Removed pack $Id from manifest (Drive folder not deleted)." -ForegroundColor Yellow
}

switch ($Command) {
    "list"   { Get-AssetPackList }
    "show"   {
        if (-not $Id) {
            Write-Host "You must provide an id, e.g. assetlib show fab_scifi_pack" -ForegroundColor Yellow
        } else {
            Get-AssetPack -Id $Id
        }
    }
    "open"   {
        if (-not $Id) {
            Write-Host "You must provide an id, e.g. assetlib open fab_scifi_pack" -ForegroundColor Yellow
        } else {
            Open-AssetPack -Id $Id
        }
    }
    "add"    { Add-AssetPack }
    "remove" {
        if (-not $Id) {
            Write-Host "You must provide an id, e.g. assetlib remove fab_old_pack" -ForegroundColor Yellow
        } else {
            Remove-AssetPack -Id $Id
        }
    }
}
