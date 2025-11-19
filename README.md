# assetlib
---
A simple shared manifest for our game asset packs.

We use:

- **Google Drive** to store the actual packs (folders with files).
- This **Git repo** to keep track of what packs we have, where they are, and how to open them.

The `assetlib` PowerShell command lets us:

- List packs
- Open a pack’s Google Drive folder
- Add new packs to the manifest
- Remove packs from the manifest

---

## Setup (one-time per machine)

1. Install **Git** if you don't already have it:
  
   ```powershell
   winget install Microsoft.Git
   ```

2. Clone this repo:

   ```powershell
   cd C:\Dev   # or wherever you keep repos
   git clone https://github.com/<your-username>/assetlib.git
   cd assetlib
   ```

3. Allow local scripts to run in PowerShell:

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

4. Run the installer script:

   ```powershell
   .\Install-AssetLib.ps1
   ```

5. Close PowerShell and open a new PowerShell window.

Now you can use the assetlib command from any folder.

---

## Usage

Run these from any PowerShell prompt (not just inside the repo):

List all packs

   ```powershell
   assetlib list
   ```
   
Show details for a specific pack
   
   ```powershell
   assetlib show <pack_name>
   ```

Open a pack's Google Drive folder
   
   ```powershell
   assetlib open <pack_name>
   ```
This opens the cloud_url in your browser.

To add a new pack
   1. Upload the pack folder to Google Drive under our shared GameLibrary/Packs folder.
   2. Get the folder link from Google Drive.

Then run:
   
   ```powershell
   assetlib add
   ```

Answer the prompts:

   id → machine-friendly ID, e.g. fab_scifi_soldier_pro_pack
   
   name → human-readable name, e.g. Sci-Fi Soldier Pro Pack
   
   source → Fab, Quixel, Self, etc.
   
   Google Drive folder URL → paste the folder link
   
   categories → comma-separated from: assets, animations, vfx, systems
   
   tags → any search tags (comma-separated)
   
   notes → optional description
   
   license → defaults to Fab_personal if left blank

Commit and push the updated manifest:
   ```powershell
   git add packs.json
   git commit -m "Add Sci-Fi Soldier Pro Pack"
   git push
   ```

Remove a pack from the manifest:
   
   ```powershell
   assetlib remove <pack_name>
   ```

Note: This only removes it from packs.json.
If you also want to delete the actual files, remove the folder from Google Drive manually.
