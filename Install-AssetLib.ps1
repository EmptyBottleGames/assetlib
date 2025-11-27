$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Paths & basic setup
# -----------------------------------------------------------------------------

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
$repoRoot = Split-Path $scriptPath -Parent
$configPath = Join-Path $repoRoot "assetlib.config.json"

# -----------------------------------------------------------------------------
# Helper: check if MEGAcmd CLI is actually usable (primary truth)
# -----------------------------------------------------------------------------

function Test-MegaCmdCliAvailable {
    <#
        Returns $true if running 'mega-help' appears to work, $false otherwise.

        IMPORTANT:
        - We treat "command works" as the main indicator.
        - We DO NOT trust the presence of the MEGAcmd folder alone, since
          sloppy uninstalls can leave it behind.
    #>
    try {
        # Init MEGAcmd server process.
        $proc = Start-Process mega-version `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput "$env:TEMP\mega-safe.out" `
            -RedirectStandardError "$env:TEMP\mega-safe.err"

        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill() } catch {}
        }
      
        $output = mega-help
        if ($? -or ($output -and $output -match 'MEGAcmd')) {
            return $true
        }

    }
    catch {
        # Command not found / not on PATH / not installed.
        return $false
    }
    return $false
}

# -----------------------------------------------------------------------------
# Helper: add MEGAcmd folder to *current* process PATH if needed
# -----------------------------------------------------------------------------

function Add-MegaCmdToCurrentPath {
    $megaDir = Join-Path $env:LOCALAPPDATA 'MEGAcmd'
    if (-not (Test-Path $megaDir)) {
        return
    }

    $pathParts = $env:PATH -split ';'
    if ($pathParts -contains $megaDir) {
        return
    }

    if ($env:PATH -and $env:PATH[-1] -ne ';') {
        $env:PATH += ';'
    }
    $env:PATH += $megaDir
}

# -----------------------------------------------------------------------------
# Helper: ensure MEGAcmd is installed (silent installer + bounded wait),
# and usable by CLI (mega-help)
# -----------------------------------------------------------------------------

function Install-MegaCmdIfMissing {
    <#
        Ensures MEGAcmd CLI is available.

        Strategy:
        1. If 'mega-help' already works, do nothing.
        2. Otherwise, if %LOCALAPPDATA%\MEGAcmd exists:
           - Add it to PATH for this process and check again.
        3. If it still doesn't work:
           - Download MEGAcmdSetup64.exe into %TEMP%.
           - Run it with /S (silent) using ProcessStartInfo.
           - Hard timeout: 60 seconds.
           - If it doesn't exit in time, kill it and ask user to run manually.
        4. After install, add MEGAcmd folder to *this* process PATH and
           re-check 'mega-help'.
    #>

    if (Test-MegaCmdCliAvailable) {
        Write-Host "MEGAcmd already available." -ForegroundColor Green
        return
    }

    # Try to salvage an existing install by adding folder to PATH
    Add-MegaCmdToCurrentPath
    if (Test-MegaCmdCliAvailable) {
        Write-Host "MEGAcmd CLI became available after adding %LOCALAPPDATA%\MEGAcmd to PATH." -ForegroundColor Green
        return
    }

    $tempDir = [System.IO.Path]::GetTempPath()
    $installer = Join-Path $tempDir "MEGAcmdSetup64.exe"
    $downloadUrl = "https://mega.nz/MEGAcmdSetup64.exe"

    Write-Host "MEGAcmd does not appear to be installed or on PATH." -ForegroundColor Yellow
    Write-Host "Downloading MEGAcmd installer from $downloadUrl ..." -ForegroundColor Cyan

    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installer -UseBasicParsing
    }
    catch {
        Write-Error "Failed to download MEGAcmd installer: $($_.Exception.Message)"
        return
    }

    if (-not (Test-Path $installer)) {
        Write-Error "MEGAcmd installer download failed; file not found at: $installer"
        return
    }

    Write-Host "Running MEGAcmd installer silently (/S). This may take up to ~60 seconds..." -ForegroundColor Cyan

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $installer
    $psi.Arguments = "/S"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) {
            Write-Error "Failed to start MEGAcmd installer process."
            return
        }
    }
    catch {
        Write-Error "Failed to start MEGAcmd installer: $($_.Exception.Message)"
        return
    }

    # Hard timeout: 60 seconds
    $timeoutMs = 60000
    $exited = $proc.WaitForExit($timeoutMs)

    # Grab any output that might be available (non-blocking now that WaitForExit returned)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()

    if (-not $exited) {
        # Kill the process to avoid "hanging" forever.
        try { $proc.Kill() } catch {}

        Write-Error @"
MEGAcmd installer did not exit within $($timeoutMs / 1000) seconds and has been terminated.

STDOUT:
$stdout

STDERR:
$stderr

Please try running the installer manually:
  $installer

After installation completes, open a new PowerShell session and verify:
  mega-help

Then re-run this Install-AssetLib.ps1 script.
"@
        return
    }
    
    if (-not $proc.ExitCode -eq 0) {
        Write-Host "MEGAcmd installer exited with non-zero exit code $($proc.ExitCode)." -ForegroundColor DarkRed
        if ($stderr) {
            Write-Host "Installer STDERR:" -ForegroundColor DarkRed
            Write-Host $stderr
        }
    }
    else {
        Write-Host "MEGAcmd installer completed successfully." -ForegroundColor Green
        if ($stdout) {
            Write-Host "Installer STDOUT:" -ForegroundColor DarkGray
            Write-Host $stdout
        }
    }
    

    if ($proc.ExitCode -ne 0) {
        Write-Error @"
MEGAcmd installer exited with non-zero code $($proc.ExitCode).

Please run the installer manually:
  $installer

Then open a new PowerShell session and verify:
  mega-help

After that, re-run this Install-AssetLib.ps1 script.
"@
        return
    }
    # Try to make the CLI available in this process too.
    Add-MegaCmdToCurrentPath
    if (-not (Test-MegaCmdCliAvailable)) {
        Write-Warning @"
MEGAcmd installer completed (exit code 0), but 'mega-help' still does not work
in this PowerShell session.

Most likely, your PATH changes will apply only to NEW sessions.

Suggested steps:
  1. Close this PowerShell window.
  2. Open a NEW PowerShell window.
  3. Run: mega-help
  4. Then re-run this Install-AssetLib.ps1 script to finish setup.
"@
        return
    }

    Write-Host "MEGAcmd installed and mega-help is now working in this session." -ForegroundColor Green
}
# -----------------------------------------------------------------------------
# Helper: Update Path env to include MEGAcmd for current session
# -----------------------------------------------------------------------------
function Add-ToCurrentSessionPath {
    # Refresh current process PATH from system + user env
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')

    $env:Path = if ($machinePath -and $userPath) {
        "$machinePath;$userPath"
    }
    elseif ($machinePath) {
        $machinePath
    }
    else {
        $userPath
    }

}
# -----------------------------------------------------------------------------
# Helper: update profile (assetlib function + MEGAcmd PATH snippet)
# -----------------------------------------------------------------------------

function Update-ProfileForAssetLibAndMega {
    <#
        Ensures the PowerShell profile contains:
          - a single 'assetlib' function pointing at this repo's assetlib.ps1
          - a single MEGAcmd PATH snippet

        Strategy:
          - Keep everything BEFORE the last 'function assetlib' as-is.
          - Delete everything from that 'function assetlib' onward.
          - Append a fresh, clean assetlib function + MEGAcmd PATH block.
    #>

    # Read entire profile as a single string (or empty if it doesn't exist yet)
    $profileContent = Get-Content -Path $PROFILE -Raw -ErrorAction SilentlyContinue
    if (-not $profileContent) {
        $profileContent = ""
    }

    # Find the last occurrence of 'function assetlib' (case-insensitive)
    $marker = 'function assetlib'
    $index = $profileContent.LastIndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)

    if ($index -ge 0) {
        # Keep everything before the assetlib block
        $prefix = $profileContent.Substring(0, $index)
    }
    else {
        # No previous assetlib block; keep the profile as-is
        $prefix = $profileContent
    }

    # Normalize trailing whitespace and leave two blank lines before our block
    $prefix = $prefix.TrimEnd() + "`r`n`r`n"

    # Fresh assetlib function pointing at this repo's assetlib.ps1
    $assetlibFunction = @"
function assetlib {
    if (`$args.Count -eq 0) {
        throw 'assetlib requires a command. Run ''assetlib help'' for usage.'
    }
    & "$scriptPath" @args
}
"@

    # Fresh MEGAcmd PATH snippet (single instance)
    $megaPathSnippet = @"
# Ensure MEGAcmd is on PATH for this session
if (`$env:LOCALAPPDATA -and (Test-Path (Join-Path `$env:LOCALAPPDATA 'MEGAcmd'))) {
    if (-not (`$env:PATH -split ';' | Where-Object { `$_ -eq (Join-Path `$env:LOCALAPPDATA 'MEGAcmd') })) {
        if (`$env:PATH -and `$env:PATH[-1] -ne ';') {
            `$env:PATH += ';'
        }
        `$env:PATH += (Join-Path `$env:LOCALAPPDATA 'MEGAcmd')
    }
}
"@

    $final = $prefix + $assetlibFunction + "`r`n" + $megaPathSnippet + "`r`n"
    Set-Content -Path $PROFILE -Value $final -Encoding UTF8
    # Reload the profile in the current session to apply changes immediately
    Write-Host "Restarting PowerShell to apply profile changes..." -ForegroundColor Cyan
    Add-ToCurrentSessionPath
    Write-Host "Updated PowerShell profile successfully." -ForegroundColor Green
}


# -----------------------------------------------------------------------------
# Helper: MEGAcmd login wizard (runs mega-login for the user)
# -----------------------------------------------------------------------------

function Invoke-MegaCmdLoginWizard {
    <#
        Guides the user through logging into MEGAcmd by calling:

            mega-login <email> <password>

        Behavior:
        - Skips entirely if MEGAcmd CLI is not available.
        - Skips if already logged in.
        - Prompts once to see if the user *wants* to log in.
        - Then enters a retry loop:
            * Asks for email + password
            * Runs mega-login
            * On failure, shows output and asks if they want to try again
            * User can cancel at any prompt by pressing Enter or answering N

        Notes:
        - We prompt for a password using -AsSecureString so it doesn't echo,
          then convert it briefly to plain text to pass to mega-login.
        - The password string is cleared as soon as mega-login returns.
    #>

    if (-not (Test-MegaCmdCliAvailable)) {
        Write-Warning "MEGAcmd CLI is not available (mega-help failed). Skipping login wizard."
        return
    }
    
    # Check if already logged in
    $session = mega-session 2>$null
    if ($session -and $session -notmatch 'Not logged in') {
        Write-Host "You appear to be already logged into MEGAcmd." -ForegroundColor Green
        Write-Host "Current session info: $session"
        return
    }

    Write-Host ""
    Write-Host "MEGAcmd login setup" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------"
    Write-Host "assetlib can use MEGAcmd to download packs from MEGA."
    Write-Host "You only need to log into MEGAcmd once per machine."
    Write-Host ""
    $answer = Read-Host "Would you like to log into MEGAcmd now? (Y/N) [Y]"
    if ($answer -and $answer -notmatch '^[Yy]') {
        Write-Host "Skipping MEGAcmd login. You can log in later by running: mega-login" -ForegroundColor Yellow
        return
    }

    while ($true) {
        # --- Email -----------------------------------------------------------
        $email = Read-Host "MEGA account email (or press Enter to cancel)"
        if (-not $email) {
            Write-Host "No email entered; cancelling MEGAcmd login wizard." -ForegroundColor Yellow
            return
        }

        # --- Password (SecureString) ----------------------------------------
        $securePwd = Read-Host "MEGA account password (input will not echo; press Enter to cancel)" -AsSecureString

        # If user just pressed Enter, SecureString may still exist but be empty - treat that as cancel.
        $pwdLength = 0
        try {
            $pwdLength = $securePwd.Length
        }
        catch {
            $pwdLength = 0
        }

        if (-not $securePwd -or $pwdLength -eq 0) {
            Write-Host "No password entered; cancelling MEGAcmd login wizard." -ForegroundColor Yellow
            return
        }

        # Convert SecureString to plain text briefly to call mega-login
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd)
        try {
            $plainPwd = [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        Write-Host ""
        Write-Host "Running 'mega-login $email ****' via MEGAcmd..." -ForegroundColor Cyan

        try {
            $output = mega-login $email $plainPwd 2>&1
            $exitCode = $?
        }
        catch {
            $output = $_.Exception.Message
            $exitCode = $false
        }
        finally {
            # Best-effort wipe of password string
            $plainPwd = $null
        }

        if ($exitCode) {
            Write-Host "MEGAcmd login appears to have succeeded." -ForegroundColor Green

            # Optional: re-check session and show a short confirmation
            $session = mega-session 2>$null
            if ($session -and $session -notmatch 'Not logged in') {
                Write-Host "Current session info: $session"
            }

            return
        }

        # Login failed - show output and offer retry / give up
        Write-Warning @"
MEGAcmd login returned a non-zero exit code ($exitCode).

Output:
$output
"@

        $retry = Read-Host "Login failed. Try again? (Y/N) [Y]"
        if ($retry -and $retry -notmatch '^[Yy]') {
            Write-Host "Giving up on MEGAcmd login for now. You can try again later with:" -ForegroundColor Yellow
            Write-Host "  mega-login"
            return
        }

        Write-Host ""
        Write-Host "Let's try logging in again..." -ForegroundColor Cyan
        Write-Host ""
    }
}


# -----------------------------------------------------------------------------
# One-time assetlib config (asset store root + license mode) - MEGA-focused
# -----------------------------------------------------------------------------

if (-not (Test-Path $configPath)) {
    Write-Host "Configuring asset store root URL for assetlib..." -ForegroundColor Cyan

    $defaultRoot = "https://mega.nz/folder/<your-folder-id>#<your-key>"
    Write-Host "Enter the root URL of your asset store (e.g. shared MEGA folder for all packs)."
    Write-Host "Example (MEGA):  https://mega.nz/folder/<folder-id>#<key>"
    $assetRootUrl = Read-Host "Asset store root URL [$defaultRoot]"

    if (-not $assetRootUrl) {
        $assetRootUrl = $defaultRoot
    }

    $config = [pscustomobject]@{
        assetRootUrl = $assetRootUrl
        licenseMode  = "restrictive"  # default to safest mode
    }

    $config |
    ConvertTo-Json -Depth 3 |
    Set-Content -Path $configPath -Encoding UTF8

    Write-Host "Saved asset store root URL and license mode to assetlib.config.json" -ForegroundColor Green
}
else {
    Write-Host "assetlib.config.json already exists; keeping existing configuration." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# Run MEGAcmd install (if needed), profile updates, and login wizard
# -----------------------------------------------------------------------------

Install-MegaCmdIfMissing
Update-ProfileForAssetLibAndMega
Invoke-MegaCmdLoginWizard

Write-Host ""
Write-Host "assetlib installation/update complete." -ForegroundColor Cyan
Write-Host ""
Write-Host "If you have issues with MEGAcmd or assetlib, it is recommended to:" -ForegroundColor Cyan
Write-Host "Close and reopen PowerShell (so PATH/profile changes apply)."
Write-Host ""
Write-Host "Profile file used: $PROFILE"
