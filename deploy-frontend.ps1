<#
  HCIS - deploy the application build, safely.

  The previous version deleted the live JS/CSS bundles and only then tried to
  copy the new ones in. When that copy was refused the site was left with no
  bundles at all - a blank page. This version never removes anything until the
  new build is in place and verified, and it proves it can write to the target
  BEFORE it touches a single file.

  It also stops deleting the previous backup. The old script wiped
  wwwroot_old to make a fresh one, which meant a second run after a failure
  would destroy the only good copy. Backups are timestamped and kept.
#>
param(
    [string]$Root   = 'C:\HCIS',
    [string]$Source = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Source) { $Source = Join-Path $PSScriptRoot 'wwwroot' }
$Target = Join-Path $Root 'wwwroot'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say ''
Say '============================================================'
Say ' HCIS frontend deploy'
Say '============================================================'
Say ''

# ---- 1. the new build must be complete before we consider touching the live one
if (-not (Test-Path -LiteralPath $Source)) { Say "ERROR: cannot find the new build at $Source" 'Red'; exit 1 }
$srcIndex = Join-Path $Source 'index.html'
if (-not (Test-Path -LiteralPath $srcIndex)) { Say "ERROR: $Source has no index.html - wrong folder?" 'Red'; exit 1 }
$srcAssets = Get-ChildItem -LiteralPath (Join-Path $Source 'assets') -File -ErrorAction SilentlyContinue
if (-not $srcAssets) { Say "ERROR: $Source\assets is empty - the new build is incomplete." 'Red'; exit 1 }
Say ("New build looks complete: {0} files in assets." -f $srcAssets.Count) 'Green'

if (-not (Test-Path -LiteralPath $Target)) { Say "ERROR: $Target does not exist. Check where IIS serves HCIS from." 'Red'; exit 1 }

# ---- 2. elevation, reported rather than assumed
$elevated = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
if ($elevated) { Say 'Running as Administrator.' 'Green' } else { Say 'NOT running as Administrator.' 'Yellow' }

# ---- 3. prove we can write BEFORE removing anything. This is the whole point.
Say ''
Say 'Checking we are allowed to write to the live folder...'
$probe = Join-Path $Target ('.hcis_write_test_' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText($probe, 'test')
    Remove-Item -LiteralPath $probe -Force
    Say 'Write test passed.' 'Green'
} catch {
    Say ''
    Say 'CANNOT WRITE TO THE LIVE FOLDER - stopping. Nothing has been changed.' 'Red'
    Say ''
    Say 'The site is untouched and still working. Two things to try:'
    Say ''
    Say '  1. Close this window. Start > type powershell > RIGHT-CLICK'
    Say '     Windows PowerShell > "Run as administrator", then run this again.'
    Say ''
    Say '  2. If it still fails as administrator, IIS is holding the files open.'
    Say '     Run:  iisreset /stop'
    Say '     then this script again, then:  iisreset /start'
    Say ''
    Say ("  (target: {0})" -f $Target)
    Say ''
    exit 1
}

# ---- 4. timestamped backup, never deleting an earlier one
$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = Join-Path $Root ("wwwroot_backup_" + $stamp)
Say ''
Say "Backing up the current site to $backup ..."
Copy-Item -LiteralPath $Target -Destination $backup -Recurse -Force
$bCount = (Get-ChildItem -LiteralPath $backup -Recurse -File).Count
if ($bCount -lt 1) { Say 'Backup came out empty - stopping rather than risk it.' 'Red'; exit 1 }
Say ("Backup holds {0} files." -f $bCount) 'Green'

# ---- 5. copy the new build OVER the old one. Nothing is deleted first, so a
#         failure here leaves a working site rather than an empty one.
Say ''
Say 'Copying the new build in...'
try {
    Copy-Item -Path (Join-Path $Source '*') -Destination $Target -Recurse -Force
} catch {
    Say ''
    Say 'COPY FAILED.' 'Red'
    Say $_.Exception.Message
    Say ''
    Say 'The site should still be working - nothing was deleted. If it is not,'
    Say ("restore with:  xcopy `"{0}`" `"{1}`" /E /I /Q /Y" -f $backup, $Target)
    exit 1
}

# ---- 6. verify what the browser will actually ask for is really on disk
Say ''
Say 'Verifying the deployed page...'
$html = Get-Content -Raw -LiteralPath (Join-Path $Target 'index.html')
$refs = [regex]::Matches($html, '(?:src|href)="([^"]*assets/[^"]+)"') |
        ForEach-Object { $_.Groups[1].Value }
if (-not $refs) { Say 'Could not find any asset references in index.html - check the page manually.' 'Yellow' }
$missing = @()
foreach ($r in $refs) {
    $rel = $r -replace '^/', '' -replace '/', '\'
    if (-not (Test-Path -LiteralPath (Join-Path $Target $rel))) { $missing += $r }
}
if ($missing.Count -gt 0) {
    Say ''
    Say 'The page references files that are not on disk:' 'Red'
    $missing | ForEach-Object { Say ("   " + $_) }
    Say ''
    Say ("Put the old site back with:  xcopy `"{0}`" `"{1}`" /E /I /Q /Y" -f $backup, $Target)
    exit 1
}
Say ("All {0} referenced files are present." -f $refs.Count) 'Green'

# ---- 6b. config.js is this server's OWN settings - the address the browser
#          talks to and this box's access key. It is deliberately NOT in the
#          package, so a deploy must leave it exactly where it was. Check that
#          it is still there rather than trusting that it is.
$cfg = Join-Path $Target 'config.js'
if (-not (Test-Path -LiteralPath $cfg)) {
    Say ''
    Say 'config.js has gone missing from the live folder.' 'Red'
    Say 'The site will not be able to reach the database until it is back.'
    Say ("Restore it with:  copy `"{0}\config.js`" `"{1}`"" -f $backup, $Target)
    exit 1
}
$cfgLine = (Select-String -LiteralPath $cfg -Pattern 'supabaseUrl' | Select-Object -First 1).Line
Say ("This server's own config.js is untouched:" ) 'Green'
Say ("   " + $cfgLine.Trim())

# ---- 7. only now, with a verified good deploy, clear out superseded bundles
$keep = @{}
foreach ($r in $refs) { $keep[[IO.Path]::GetFileName($r)] = $true }
foreach ($f in $srcAssets) { $keep[$f.Name] = $true }
$stale = Get-ChildItem -LiteralPath (Join-Path $Target 'assets') -File |
         Where-Object { -not $keep.ContainsKey($_.Name) }
if ($stale) {
    Say ("Removing {0} superseded bundle file(s)..." -f $stale.Count)
    $stale | Remove-Item -Force -ErrorAction SilentlyContinue
}

Say ''
Say '============================================================'
Say ' DONE - the new build is live.'
Say ' Open the site and press Ctrl+F5 to bypass the browser cache.'
Say ("
 Previous version kept at: {0}" -f $backup)
Say '============================================================'
Say ''
# Run with PowerShell closes the window the instant this exits, which hides
# everything above - including any failure. Wait for a key so it can be read.
if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
exit 0
