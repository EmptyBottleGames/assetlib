# assetlib

A simple shared manifest for our game asset packs.

We use:

- **Google Drive** to store the actual packs (folders with files).
- This **Git repo** to keep track of what packs we have, where they are, and how to open them.
- A **license registry** to ensure we only use assets that allow commercial use (our game will be sold on Steam).
- A small **config file (`assetlib.config.json`)** to remember the root URL of our shared asset store.

The `assetlib` PowerShell command lets us:

- List packs (with filters)
- Open a pack’s Google Drive folder
- Add new packs (with license validation)
- Remove packs from the manifestA
- List and view license definitions
- **Audit all packs for license safety**

Functions follow PowerShell-approved verb–noun patterns internally (e.g. `Get-AssetPackList`, `Add-AssetPack`, `Get-AssetLicense`, `Test-AssetPackLicenses`).

---

## Setup (one-time per machine)

1. Install **Git** if you don't already have it.

2. Clone this repo:

   ```powershell
   cd C:\Dev   # or wherever you keep repos
   git clone https://github.com/<your-username>/assetlib.git
   cd assetlib
   ```

3. (Maybe once) allow local scripts to run in PowerShell:

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

4. Run the installer script:

   ```powershell
   .\Install-AssetLib.ps1
   ```

   During install, you will be prompted for:

   - **Asset store root URL** – paste the URL of your shared asset store root, e.g. the Google Drive folder where all packs live  
     (for example: `https://drive.google.com/drive/folders/<GameLibrary-Packs-Folder-ID>`)

   This value is saved to `assetlib.config.json` and is used when `assetlib add` offers to open the asset store in your browser.

5. Close PowerShell and open a new PowerShell window.

Now you can use the `assetlib` command from **any folder**.

---

## Config (`assetlib.config.json`)

Created automatically on first install (or you can edit it manually later).

Example:

```json
{
  "assetRootUrl": "https://drive.google.com/drive/folders/EXAMPLE_ASSET_ROOT"
}
```

- `assetRootUrl` – root URL for your shared asset store (e.g. a Google Drive folder containing all asset pack folders).

`assetlib add` uses this when you choose to open the asset store in your browser.

---

## Usage

Run these from any PowerShell prompt (not just inside the repo):

### General help

```powershell
assetlib help
```

Shows a summary of commands and examples.

---

### List all packs

```powershell
assetlib list
```

With filters:

```powershell
# Only VFX packs
assetlib list -Category vfx

# Only packs tagged "sci-fi"
assetlib list -Tag sci-fi
```

---

### Show details for a specific pack

```powershell
assetlib show fab_scifi_soldier_pro_pack
```

Prints the full JSON object for that pack (including `licenseId`).

---

### Open a pack’s Google Drive folder

```powershell
assetlib open fab_scifi_soldier_pro_pack
```

This opens the pack’s `cloud_url` in your browser.

---

### Add a new pack (with license validation)

1. Upload the pack folder to Google Drive (typically under your shared asset store root).
2. Run:

   ```powershell
   assetlib add
   ```

3. When prompted:

   - You can optionally open the **asset store root** in your browser (using the URL from `assetlib.config.json`) to create/find the pack folder.
   - Then paste the **Google Drive folder URL** for this specific pack.
   - You’ll also choose:
     - `id` → machine-friendly ID, e.g. `fab_scifi_soldier_pro_pack`
     - `name` → `Sci-Fi Soldier Pro Pack`
     - `source` → `Fab`, `Quixel`, `Self`, etc.
     - `categories` → comma-separated: `assets, animations, vfx, systems`
     - `tags` → comma-separated search tags
     - `notes` → optional description
     - `license id` → must match an ID in `licenses/licenses.json`

4. If the chosen license is marked as **non-commercial**, `assetlib` will REFUSE to add the pack.

5. Commit and push the updated manifest:

   ```powershell
   git add packs.json
   git commit -m "Add Sci-Fi Soldier Pro Pack"
   git push
   ```

---

### Remove a pack from the manifest

```powershell
assetlib remove fab_old_test_pack
```

> Note: This only removes it from `packs.json`.  
> If you also want to delete the actual files, remove the folder from Google Drive manually.

---

### License commands

List all known licenses:

```powershell
assetlib licenses
```

Show details and full text for a specific license:

```powershell
assetlib licenses Example_Commercial
```

---

### Audit all packs for license safety

Use this before shipping / builds to quickly check that every pack:

- Has a valid `licenseId`
- Uses a license that allows commercial use (based on `commercialAllowed`)

```powershell
assetlib audit
```

The audit report will show each pack with:

- `OK` – license is known and `commercialAllowed` is true
- `NON-COMMERCIAL` – license does not allow commercial use
- `UNKNOWN-LICENSE` – `licenseId` is not defined in `licenses/licenses.json`
- `NO-LICENSE` – `licenseId` is missing from the pack entry

You can treat any non-OK status as something to fix before release.

---

## `packs.json` format

Each pack entry looks like this:

```json
{
  "id": "fab_scifi_soldier_pro_pack",
  "name": "Sci-Fi Soldier Pro Pack",
  "source": "Fab",
  "cloud_url": "https://drive.google.com/drive/folders/...",
  "categories": ["assets", "animations", "systems"],
  "tags": ["sci-fi", "character", "soldier", "weapons"],
  "notes": "High-quality sci-fi soldier with meshes, anims, and sample blueprints.",
  "licenseId": "Example_Commercial"
}
```

---

## `licenses/licenses.json` format

```json
[
  {
    "id": "Example_Commercial",
    "name": "Example Commercial License",
    "description": "Example of a license that allows commercial use. Replace with a real license definition.",
    "file": "Example_Commercial.txt",
    "commercialAllowed": true
  },
  {
    "id": "Example_NonCommercial",
    "name": "Example Non-Commercial License",
    "description": "Example of a license that does NOT allow commercial use.",
    "file": "Example_NonCommercial.txt",
    "commercialAllowed": false
  }
]
```

Replace these with the real licenses you rely on.

---

## Notes on license enforcement

- During `assetlib add`, the tool **blocks** adding a pack whose license entry has `commercialAllowed: false`.
- `assetlib audit` re-checks all existing packs against the current license manifest.
- The tool does **not** parse legal text; it only enforces the `commercialAllowed` flag you configure.

Always ensure license definitions and texts are correct, and consult legal advice if needed.
