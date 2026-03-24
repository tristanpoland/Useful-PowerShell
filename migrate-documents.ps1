#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Migrates D:\Documents to E:\Documents, updates the junction at
    C:\Users\redst\OneDrive\Documents, then removes D:\Documents.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SOURCE      = "D:\Documents"
$DEST        = "E:\Documents"
$JUNCTION1   = "C:\Users\redst\OneDrive\Documents"
$JUNCTION2   = "C:\Users\redst\Documents"
$JUNCTIONS   = @($JUNCTION1, $JUNCTION2)

function Ensure-Junction($path, $expectedTarget, $alternateTarget) {
    Write-Step "Verifying junction at $path"
    $item = Get-Item $path -ErrorAction SilentlyContinue
    if (-not $item)                       { Write-Fail "$path does not exist." }
    if ($item.LinkType -ne 'Junction')    { Write-Fail "$path is not a Junction (it's $($item.LinkType))." }

    if ($item.Target -eq $expectedTarget) {
        Write-OK "Junction $path confirmed → $expectedTarget"
        return
    }

    if ($item.Target -eq $alternateTarget) {
        Write-OK "Junction $path already points to $alternateTarget";
        return
    }

    Write-Fail "Junction at $path points to '$($item.Target)', expected '$expectedTarget' or '$alternateTarget'."
}

function Update-Junction($path, $target) {
    Write-Step "Updating junction $path → $target"
    $item = Get-Item $path -ErrorAction SilentlyContinue
    if (-not $item)                       { Write-Fail "$path does not exist." }
    if ($item.LinkType -ne 'Junction')    { Write-Fail "$path is not a Junction (it's $($item.LinkType))." }

    if ($item.Target -eq $target) {
        Write-OK "Junction $path already points to $target, no update needed."
        return
    }

    cmd /c rmdir "$path"   # removes junction without deleting contents
    if (Test-Path $path)     { Write-Fail "Could not remove old junction: $path" }

    New-Item -ItemType Junction -Path $path -Target $target | Out-Null

    $newItem = Get-Item $path
    if ($newItem.Target -ne $target) { Write-Fail "New junction target for $path is '$($newItem.Target)', expected '$target'." }
    Write-OK "Junction $path now points to $target"
}

# ─── Helper ───────────────────────────────────────────────────────────────────
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Fail($msg) { Write-Host "    [!!] $msg" -ForegroundColor Red; exit 1 }

# ─── 1. Verify junctions ──────────────────────────────────────────────────────
foreach ($j in $JUNCTIONS) {
    Ensure-Junction $j $SOURCE $DEST
}

# ─── 2. Ensure E:\ exists ─────────────────────────────────────────────────────
Write-Step "Checking destination drive E:\"
if (-not (Test-Path "E:\")) { Write-Fail "Drive E:\ not found." }
Write-OK "E:\ is present"

# ─── 3. Resolve copy tool ─────────────────────────────────────────────────────
Write-Step "Checking for rsync"
$useRsync = $false

if (Get-Command rsync -ErrorAction SilentlyContinue) {
    $useRsync = $true
    Write-OK "rsync already installed"
}
else {
    Write-Host "    rsync not found – attempting install..." -ForegroundColor Yellow
    $installed = $false

    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Host "    Trying: scoop install rsync" -ForegroundColor Yellow
        scoop install rsync 2>&1 | Out-Host
        $installed = [bool](Get-Command rsync -ErrorAction SilentlyContinue)
    }

    if (-not $installed -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "    Trying: winget install cwRsync" -ForegroundColor Yellow
        winget install --id=cwRsync.cwRsync -e --silent 2>&1 | Out-Host
        $installed = [bool](Get-Command rsync -ErrorAction SilentlyContinue)
    }

    if ($installed) {
        $useRsync = $true
        $rsyncVer = rsync --version 2>&1 | Select-Object -First 1
        Write-OK "rsync installed: $rsyncVer"
    }
    else {
        Write-Host "    rsync install failed – falling back to robocopy (built-in)." -ForegroundColor Yellow
        Write-OK "robocopy is available (built into Windows)"
    }
}

# ─── 4. Run copy ──────────────────────────────────────────────────────────────
New-Item -ItemType Directory -Path $DEST -Force | Out-Null

if ($useRsync) {
    Write-Step "Copying $SOURCE → $DEST  (rsync, resumable)"
    Write-Host "    You can safely Ctrl-C and re-run; rsync will resume where it left off." -ForegroundColor Yellow

    function To-RsyncPath($p) { $p -replace '\\','/' -replace '^([A-Za-z]):','/cygdrive/$1' }
    $src = "$(To-RsyncPath $SOURCE)/"   # trailing slash = copy contents
    $dst = "$(To-RsyncPath $DEST)"

    rsync -avhP --stats "$src" "$dst"
    if ($LASTEXITCODE -ne 0) { Write-Fail "rsync exited with code $LASTEXITCODE. Fix the error and re-run." }
}
else {
    Write-Step "Copying $SOURCE → $DEST  (robocopy, resumable)"
    Write-Host "    You can safely Ctrl-C and re-run; robocopy /Z restarts interrupted file transfers." -ForegroundColor Yellow

    # /E   = include subdirs (even empty)   /Z = restartable mode   /COPYALL = all attributes
    # /R:3 = 3 retries on failure           /W:5 = 5s wait between retries
    # /NP  = no % progress spam             /TEE = print to console + log
    $logFile = "$DEST\_robocopy_log.txt"
    robocopy $SOURCE $DEST /E /Z /COPYALL /R:3 /W:5 /NP /LOG+:"$logFile" /TEE

    # robocopy exit codes: 0-7 = success (8+ = errors)
    if ($LASTEXITCODE -ge 8) { Write-Fail "robocopy failed with exit code $LASTEXITCODE. Check log: $logFile" }
}

# ─── 5. Verify file counts match ─────────────────────────────────────────────
Write-Step "Verifying file counts"
$srcCount  = (Get-ChildItem $SOURCE -Recurse -File -ErrorAction SilentlyContinue).Count
$destCount = (Get-ChildItem $DEST   -Recurse -File -ErrorAction SilentlyContinue).Count
Write-Host "    Source files : $srcCount"
Write-Host "    Dest files   : $destCount"
if ($destCount -lt $srcCount) {
    Write-Fail "Destination has fewer files ($destCount) than source ($srcCount). Not proceeding."
}
Write-OK "File counts look good ($destCount files)"

# ─── 6. Update junctions ──────────────────────────────────────────────────────
foreach ($j in $JUNCTIONS) {
    Update-Junction $j $DEST
}

# ─── 7. Delete D:\Documents ───────────────────────────────────────────────────
Write-Step "Deleting original $SOURCE"
$confirm = Read-Host "    Type YES to permanently delete $SOURCE"
if ($confirm -ne 'YES') {
    Write-Host "    Skipped deletion. $SOURCE is still intact." -ForegroundColor Yellow
    exit 0
}

Remove-Item -Path $SOURCE -Recurse -Force
if (Test-Path $SOURCE) { Write-Fail "Deletion seemed to fail – $SOURCE still exists." }
Write-OK "$SOURCE deleted"

# ─── Done ─────────────────────────────────────────────────────────────────────
Write-Host "`n✓ Migration complete. Junctions now point to $DEST." -ForegroundColor Green
