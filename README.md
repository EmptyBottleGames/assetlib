
# AssetLib – Unreal Project Asset Pack Manager (PowerShell)

AssetLib is a PowerShell-based helper tool for managing external asset packs and plugins for Unreal Engine projects.  
It keeps a manifest (`packs.json`), enforces license rules, validates archives, and safely installs/uninstalls packs directly into project folders—while preventing dangerous operations (like modifying an open editor session or installing engine-level plugins).

---

## 📦 Features

### ✔ Manifest-driven asset management  
All asset packs are tracked inside `packs.json` with metadata:

- `id`
- `name`
- `source`
- `cloud_url` (Google Drive folder)
- `archive_url` (direct download link)
- `categories`, `tags`
- `licenseId`
- `packType` (`content` or `plugin`)
- `pluginFolderName`
- `engineVersion` (optional)

---

## 🔒 License Modes

AssetLib supports **two modes**:

### **Restrictive (recommended)**
Only packs with *commercialAllowed: true* are allowed for:
- `add`
- `install`
- `prune`

Blocks:
- NO-LICENSE  
- UNKNOWN-LICENSE  
- NON-COMMERCIAL  

### **Permissive**
Allows all licenses, but prints warnings.

---

## 📁 Installation

Place `assetlib.ps1` in any folder that is included in your PowerShell `$env:PATH`, or update your PowerShell profile:

```powershell
notepad $PROFILE
```

Add:

```powershell
function assetlib {
    & "C:\Path\To\assetlib.ps1" @args
}
```

Reload:

```powershell
. $PROFILE
```

---

## 🚀 Commands Overview

### `assetlib help`
Show general help or help about a specific command:

```powershell
assetlib help install
assetlib help audit
```

---

## 📃 List Packs – `assetlib list`

```powershell
assetlib list
assetlib list -Category vfx
assetlib list -Tag sci-fi
```

---

## 🔍 Show Pack – `assetlib show <id>`

Prints the full JSON entry from `packs.json`.

---

## 🌐 Open Pack Folder – `assetlib open <id>`

Opens the pack’s `cloud_url` (usually a Google Drive folder).

---

## ➕ Add New Pack – `assetlib add`

Interactive workflow:

- id  
- name  
- cloud_url  
- archive_url (auto-converts Drive links to direct-download format)  
- categories, tags  
- notes  
- engineVersion  
- packType: `content` or `plugin`  
- pluginFolderName  
- licenseId  

Blocks non-commercial/unlicensed packs in restrictive mode.

---

## ➖ Remove From Manifest – `assetlib remove <id>`

Removes the manifest entry only.  
Does **NOT** delete project files.

---

## 📚 Licenses – `assetlib licenses`

List all defined licenses or view full details:

```powershell
assetlib licenses
assetlib licenses Fab_Standard_License
```

---

## 🧪 Audit Licenses – `assetlib audit`

Runs a safety audit:

- OK  
- NON-COMMERCIAL  
- UNKNOWN-LICENSE  
- NO-LICENSE  

### Prune Mode

Removes installed packs from *project folders only*:

```powershell
assetlib audit -Prune
assetlib audit -Prune -DryRun
```

---

## 📦 Install Pack – `assetlib install <id> [-Force] [-Preview]`

Installs a pack into the current Unreal Engine project.

### ✔ Content Pack Installation
```
Content/AssetLib/<id>/
```

### ✔ Plugin Installation
```
Plugins/<pluginFolderName>/
```

### 🛑 Engine-level plugins  
If the plugin archive contains:

```
Engine/Plugins/...
```

AssetLib will **BLOCK the install completely**  
You may:

- Keep the pack in manifest  
- Remove it from manifest  

But AssetLib will *never* install to the engine-level.

### 🛑 Editor safety  
Install is blocked if Unreal Editor is running unless `-Force` is used.  
Recommended: **close Unreal** before install.

### 🧠 Engine compatibility (plugins)
- Blocks older/newer major versions unless `-Force`
- Warns on minor version mismatch
- Warns if plugin requires C++ but project is Blueprint-only

### 🧰 Preview mode
Does a *full validation* without touching your project:

```powershell
assetlib install MyPack -Preview
```

---

## 🔧 Uninstall – `assetlib uninstall <id>`

Removes installed directory but leaves manifest entry intact.

---

## 🧹 Cache – `assetlib cache`

### View cache
```powershell
assetlib cache
```

### Clear cache
```powershell
assetlib cache clear
assetlib cache clear -Force
```

Cache is stored at:

```
%LOCALAPPDATA%ssetlib\cache
```

---

## 🧪 Validate Packs – `assetlib validate`

### Single pack

```powershell
assetlib validate MyPack
assetlib validate MyPack -Deep
```

### All packs

```powershell
assetlib validate --all
assetlib validate --all -Deep
```

Deep mode internally uses `install -Preview`.

---

## 👁 Status – `assetlib status`

Shows:

- Script path  
- Config file  
- Current licenseMode  
- Cache info  
- Number of packs  
- If in project:
  - Engine version
  - whether Unreal Editor is running
  - whether project has C++ modules

Great for verifying setup.

---

## ⚙ Changing License Mode

```powershell
assetlib mode restrictive
assetlib mode permissive
```

---

## 📁 File Structure Example

```
assetlib/
│ assetlib.ps1
│ packs.json
│ assetlib.config.json
│
└── licenses/
   │ licenses.json
   └── <license text files>
```

Project-side:

```
MyGame/
│ MyGame.uproject
│
├── Content/
│   └── AssetLib/
│       └── <installed packs...>
│
└── Plugins/
    └── <installed plugins...>
```

---

## 🧠 Best Practices

- Keep licenseMode **restrictive** unless prototyping
- Use `-Preview` before installing unknown plugins
- Never install engine plugins via assetlib
- Commit only:
  - packs.json  
  - assetlib.config.json  
  - licenses  
- Use `assetlib audit` before shipping

---

## 🏁 Summary

AssetLib is designed to:

- Keep your team compliant  
- Prevent dangerous engine/plugin installs  
- Make asset handling predictable  
- Provide transparent validation and preview tools  

This helps keep your Unreal Engine project clean and production-safe.

---

© 2025 - AssetLib Internal Tool
