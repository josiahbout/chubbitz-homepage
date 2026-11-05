# Daily Sky Supporter sync - the part Windows Task Scheduler runs.
#
# Runs scripts/sync-supporters.pl, then commits and pushes only if it actually
# changed something. Everything it does is written to a log file so a run that
# happened while you were asleep can still be read back.
#
# Run it by hand first:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\siahm\Documents\chubbitz-homepage\scripts\sync-supporters.ps1"
#
# Then set it up in Task Scheduler - see the "SCHEDULING" notes at the bottom.
#
# It reads the export folder only. It never writes there, and it handles no
# Discord tokens or API keys of any kind.
#
# A note on error handling: git and perl both write ordinary progress chatter
# to stderr - "From https://github.com/..." is git saying it fetched, not git
# complaining. PowerShell can be talked into treating any of that as a fatal
# error, so this script judges every program by its EXIT CODE alone and keeps
# stderr purely as something to write in the log.

$ErrorActionPreference = 'Continue'

$repo    = Split-Path -Parent $PSScriptRoot
$logDir  = Join-Path $env:LOCALAPPDATA 'chubbitz-supporter-sync'
$logFile = Join-Path $logDir 'sync.log'
$errFile = Join-Path $logDir 'last-stderr.txt'

if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -ErrorAction Stop | Out-Null
}

function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

# Writes each non-empty line of a program's output into the log, indented.
function Write-LogBlock {
    param([string]$Text, [string]$Prefix = '  ')
    if (-not $Text) { return }
    foreach ($line in ($Text -split "`r?`n")) {
        # The perl script stamps its own lines with the time; Write-Log stamps
        # them again, so drop its copy and keep one timestamp per line.
        $clean = $line -replace '^\s*\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s+', ''
        if ($clean.Trim()) { Write-Log "$Prefix$($clean.TrimEnd())" }
    }
}

# Reads back whatever the last program sent to stderr, then clears it.
function Read-Stderr {
    if (-not (Test-Path $errFile)) { return '' }
    $text = Get-Content $errFile -Raw
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    return $text
}

# Keep the log from growing forever: once it passes 1 MB, start a new one and
# keep the previous as sync.log.old.
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
    Move-Item $logFile "$logFile.old" -Force
}

# Perl comes with Git for Windows but isn't on the ordinary PATH, so Task
# Scheduler would never find it by name. Look where Git keeps it, and fall
# back to a perl on PATH for anyone who has installed one properly.
function Find-Perl {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\usr\bin\perl.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\usr\bin\perl.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\usr\bin\perl.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $onPath = Get-Command perl -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

Write-Log '--- sync starting ---'

try {
    Set-Location $repo -ErrorAction Stop

    $perl = Find-Perl
    if (-not $perl) {
        throw 'Could not find perl. It ships with Git for Windows at "C:\Program Files\Git\usr\bin\perl.exe" - check Git is installed.'
    }
    Write-Log "Using perl at $perl"

    # Someone else may have pushed since the last run (the sitemap bot, the
    # raised-amount bot, or you). Start from their work, never on top of it.
    Write-Log 'Fetching the latest site...'
    & git pull --ff-only origin main 2>$errFile | Out-Null
    $pullCode = $LASTEXITCODE
    $pullErr  = Read-Stderr
    if ($pullCode -ne 0) {
        Write-Log "Could not fast-forward, so nothing was changed (git exit $pullCode)."
        Write-LogBlock $pullErr '  git: '
        Write-Log '--- sync finished (failed) ---'
        exit 1
    }

    Write-Log 'Reading the supporter export...'
    # Forward slashes: the perl inside Git for Windows is a Cygwin build and
    # does not treat a backslash as a path separator.
    $syncScript = (Join-Path $PSScriptRoot 'sync-supporters.pl') -replace '\\', '/'
    $syncOut    = & $perl $syncScript 2>$errFile | Out-String
    $syncCode   = $LASTEXITCODE
    $syncErr    = Read-Stderr

    Write-LogBlock $syncOut
    Write-LogBlock $syncErr '  ! '

    if ($syncCode -ne 0) {
        Write-Log "The sync script failed (exit $syncCode). Nothing was committed."
        Write-Log '--- sync finished (failed) ---'
        exit $syncCode
    }

    # Only these paths are ever committed, so anything else you happen to be
    # working on in this folder is left alone.
    $paths  = @('index.html', 'data/supporters.json', 'media/supporters')
    $status = (& git status --porcelain -- $paths 2>$errFile | Out-String)
    Read-Stderr | Out-Null

    if (-not $status.Trim()) {
        Write-Log 'Nothing changed, so there is nothing to push.'
        Write-Log '--- sync finished (no changes) ---'
        exit 0
    }

    Write-Log 'Changes found. Committing...'
    & git add -- $paths 2>$errFile | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LogBlock (Read-Stderr) '  git: '
        throw "git add failed (exit $LASTEXITCODE)"
    }
    Read-Stderr | Out-Null

    $message = "Update the supporters ({0})" -f (Get-Date -Format 'yyyy-MM-dd')

    # The no-reply address keeps the real one out of public history. Passed per
    # command so nothing about the saved git config is touched.
    & git -c user.name="josiahbout" -c user.email="josiahbout@users.noreply.github.com" commit -q -m $message 2>$errFile | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LogBlock (Read-Stderr) '  git: '
        throw "git commit failed (exit $LASTEXITCODE)"
    }
    Read-Stderr | Out-Null

    & git push -q origin main 2>$errFile | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LogBlock (Read-Stderr) '  git: '
        throw "git push failed (exit $LASTEXITCODE) - is the network up, and is GitHub still signed in?"
    }
    Read-Stderr | Out-Null

    $sha = (& git rev-parse --short HEAD 2>$null).Trim()
    Write-Log "Pushed $sha. GitHub Pages will rebuild in a minute or two."
    Write-Log '--- sync finished (pushed) ---'
    exit 0
}
catch {
    Write-Log "STOPPED: $($_.Exception.Message)"
    Write-Log '--- sync finished (failed) ---'
    exit 1
}

# SCHEDULING
# ----------
# Task Scheduler > Create Task (not "Basic Task"):
#
#   General
#     Name: Chubbitz supporter sync
#     "Run only when user is logged on"  <- keeps access to your saved
#                                           GitHub sign-in, which "whether
#                                           logged on or not" can lose
#
#   Triggers > New
#     Daily, at a quiet time well after the bot's own refresh
#     Tick "Enabled"
#
#   Actions > New
#     Action:    Start a program
#     Program:   powershell.exe
#     Arguments: -NoProfile -ExecutionPolicy Bypass -File "C:\Users\siahm\Documents\chubbitz-homepage\scripts\sync-supporters.ps1"
#
#   Settings
#     TICK "Run task as soon as possible after a scheduled start is missed"
#       ^ without this, a PC that is off or asleep at the scheduled time
#         simply skips that day entirely
#     Tick "Stop the task if it runs longer than" 1 hour
#
# The task survives restarts - Task Scheduler keeps it on disk, not in memory.
# The log is at %LOCALAPPDATA%\chubbitz-supporter-sync\sync.log
