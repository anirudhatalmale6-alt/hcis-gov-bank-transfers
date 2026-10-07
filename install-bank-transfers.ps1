<#
  HCIS - install the bank transfer work on this box.

  Everything built for the monthly bank transfer files, which until now has
  existed only on the office server:

    * four database changes - where a care giver is paid, what the transfer
      file calls each bank, a record of what was actually sent, and a history
      of every change to an account
    * the Bank Transfers screen in the Payroll menu

  WHAT THIS DOES NOT INSTALL, AND WHY

  The job that emails Finance at the payroll cut-off is NOT in here. It runs
  on the office server as a scheduled Linux task, and this is a Windows
  machine - a Linux cron job does not copy across, it has to be rebuilt as a
  Windows scheduled task. That is a separate piece of work and it depends on
  which machine is going to send the payroll after launch.

  So after this, the screen works and the database is ready, and the transfer
  files are still produced on the office server until that is settled.

  SAFE TO RUN MORE THAN ONCE. Every change is written to be applied again
  without doing anything the second time.

  Driven by INSTALL.bat.
#>

param(
    [string]$Db         = 'hcis_db',
    [string]$DbUser     = 'postgres',
    [string]$PgBin      = '',
    [string]$Root       = 'C:\HCIS',
    [string]$DbPassword = '',
    [switch]$NoFrontend
)

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }
function Rule { Write-Host '  ------------------------------------------------------------' }

$MIGRATIONS = @(
    '43_care_giver_bank_details.sql',
    '44_seft_codes_and_no_branch.sql',
    '45_transfers_recorded_and_bank_changes.sql',
    '46_bank_change_says_who.sql'
)

# ---- tools ---------------------------------------------------------------
if (-not $PgBin) {
    $PgBin = @('C:\PostgreSQL\16\bin', 'C:\PostgreSQL\17\bin',
               'C:\Program Files\PostgreSQL\16\bin', 'C:\Program Files\PostgreSQL\17\bin') |
             Where-Object { Test-Path (Join-Path $_ 'psql.exe') } | Select-Object -First 1
}
if (-not $PgBin) { Say 'psql.exe was not found on this machine.' 'Red'; exit 1 }
$psql   = Join-Path $PgBin 'psql.exe'
$pgdump = Join-Path $PgBin 'pg_dump.exe'
$dbDir  = Join-Path $PSScriptRoot 'db'

$missing = $MIGRATIONS | Where-Object { -not (Test-Path (Join-Path $dbDir $_)) }
if ($missing) {
    Say 'These files are missing from the db folder:' 'Red'
    $missing | ForEach-Object { Say "  $_" 'Red' }
    Say 'Right-click the zip, Extract All, and run it from the extracted folder.' 'Red'
    exit 1
}

if ($DbPassword) { $env:PGPASSWORD = $DbPassword }
. (Join-Path $PSScriptRoot 'db-access.ps1')
if (-not (Set-DbPassword)) { exit 1 }

Write-Host ''
Say '============================================================'
Say ' HCIS - bank transfers'
Say '============================================================'
Write-Host ''

& $psql -U $DbUser -d $Db -c 'select 1' *> $null
if ($LASTEXITCODE -ne 0) { Say "Cannot reach the database $Db on this machine." 'Red'; exit 1 }

# ---- what has to be here already -----------------------------------------
#
# These four changes build on the ones that came before. Finding out which is
# missing BEFORE touching anything is worth more than a clean error half way
# through - particularly ref_bank, which is where the 25 banks and the
# accountant's own codes live, and which the first change points a foreign key
# at.
$need = @{
    'care_workers'  = 'the care giver records'
    'payment_runs'  = 'the monthly payroll runs'
    'ref_bank'      = 'the list of banks with the accountant''s codes'
    'system_users'  = 'the staff accounts'
}
$absent = @()
foreach ($t in $need.Keys) {
    $n = (& $psql -tA -U $DbUser -d $Db -c "SELECT CASE WHEN to_regclass('public.$t') IS NULL THEN 'no' ELSE 'yes' END" 2>&1).Trim()
    if ($n -ne 'yes') { $absent += ("{0} - {1}" -f $t, $need[$t]) }
}
if ($absent) {
    Rule
    Say 'STOPPING. Nothing has been changed.' 'Red'
    Write-Host ''
    Say 'This database is missing things these changes build on:' 'Red'
    $absent | ForEach-Object { Say ("  " + $_) 'Red' }
    Write-Host ''
    Say 'If ref_bank is the one missing, this box has not had the bank' 'Yellow'
    Say 'reference data loaded yet. Send me a photo of this window.' 'Yellow'
    Rule
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}

# The record of what was sent points at payment_runs, and a foreign key needs
# something unique to point AT. If that table has no primary key, the third
# change fails with
#
#     there is no unique constraint matching given keys for referenced table
#
# which is accurate and tells the reader nothing. Checking here turns it into
# a sentence, before anything has been written. Found by running this against
# a database where the key genuinely was absent.
$pk = (& $psql -tA -U $DbUser -d $Db -c @"
SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_constraint
                          WHERE conrelid = 'public.payment_runs'::regclass
                            AND contype = 'p')
            THEN 'yes' ELSE 'no' END
"@ 2>&1).Trim()
if ($pk -ne 'yes') {
    Rule
    Say 'STOPPING. Nothing has been changed.' 'Red'
    Write-Host ''
    Say 'The payment_runs table on this box has no primary key, and the record' 'Red'
    Say 'of what was sent to the banks has to point at it.' 'Red'
    Write-Host ''
    Say 'That usually means this box has an older or partly-built copy of that' 'Yellow'
    Say 'table. Send me a photo of this window - it is a one-line fix, but I' 'Yellow'
    Say 'want to see the table before changing it.' 'Yellow'
    Rule
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}

# How many banks, because an empty ref_bank passes the test above and then
# leaves every care giver unassignable.
$banks = (& $psql -tA -U $DbUser -d $Db -c "SELECT count(*) FROM ref_bank" 2>&1).Trim()
Say ("Banks on this box: {0}" -f $banks)
if ([int]$banks -lt 1) {
    Say 'ref_bank is empty. The screen would have nothing to offer.' 'Red'
    Say 'Tell me before going further.' 'Red'
    exit 1
}

# ---- backup --------------------------------------------------------------
Write-Host ''
Say 'Taking a backup first...'
$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = Join-Path $PSScriptRoot ("hcis_before_banktransfers_{0}.dump" -f $stamp)
& $pgdump -U $DbUser -d $Db -Fc -f $backup
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $backup) -or (Get-Item $backup).Length -eq 0) {
    Say 'The backup failed or came out empty. Nothing has been changed.' 'Red'
    exit 1
}
Say ("Backup: {0} ({1:N0} bytes)" -f $backup, (Get-Item $backup).Length) 'Green'

# ---- the four changes ----------------------------------------------------
Write-Host ''
Say 'Applying the database changes...'
Write-Host ''
foreach ($m in $MIGRATIONS) {
    Say "   $m"
    & $psql -q -U $DbUser -d $Db -v ON_ERROR_STOP=1 -f (Join-Path $dbDir $m)
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Rule
        Say "STOPPED at $m. That step wrote nothing; the ones before it stand." 'Red'
        Say 'To put the database back exactly as it was:' 'Yellow'
        Say ("  pg_restore -U {0} -d {1} --clean --if-exists `"{2}`"" -f $DbUser, $Db, $backup) 'Yellow'
        Say 'Send me a photo of this window.' 'Yellow'
        Rule
        if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
        exit 1
    }
}
Say 'All four applied.' 'Green'

# ---- prove they are there ------------------------------------------------
Write-Host ''
Say 'Checking...'
$check = & $psql -tA -U $DbUser -d $Db -c @"
SELECT
  CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                     WHERE table_name='care_workers' AND column_name='account_number')
       THEN 'yes' ELSE 'NO' END || '|' ||
  CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                     WHERE table_name='ref_bank' AND column_name='seft_code')
       THEN 'yes' ELSE 'NO' END || '|' ||
  CASE WHEN to_regclass('public.payment_run_transfers') IS NOT NULL
       THEN 'yes' ELSE 'NO' END || '|' ||
  CASE WHEN to_regclass('public.care_worker_bank_changes') IS NOT NULL
       THEN 'yes' ELSE 'NO' END || '|' ||
  (SELECT count(*)::text FROM ref_bank WHERE seft_code IS NOT NULL)
"@ 2>&1
$parts = ([string]$check).Trim().Split('|')
if ($parts.Count -lt 5 -or ($parts[0..3] -contains 'NO')) {
    Say 'Something did not take. Send me a photo of this window.' 'Red'
    Say ("  (" + $check + ")") 'Red'
    exit 1
}
Say '  where a care giver is paid ......... yes' 'Green'
Say '  what the transfer file calls a bank. yes' 'Green'
Say '  record of what was sent ............ yes' 'Green'
Say '  history of account changes ......... yes' 'Green'
Say ("  banks with a transfer code ......... {0} of {1}" -f $parts[4], $banks) 'Green'

# ---- the screen ----------------------------------------------------------
if ($NoFrontend) {
    Write-Host ''
    Say 'Frontend skipped as asked.' 'Yellow'
} else {
    Write-Host ''
    Say 'Installing the Bank Transfers screen...'
    & (Join-Path $PSScriptRoot 'deploy-frontend.ps1') -Root $Root
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Say 'The database side is DONE and correct. Only the screen failed,' 'Yellow'
        Say 'and the message above says why. Nothing is broken - the rest of' 'Yellow'
        Say 'HCIS carries on as before.' 'Yellow'
        if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
        exit 1
    }
}

Write-Host ''
Rule
Say 'Done.' 'Green'
Write-Host ''
Say 'Now run STEP-2-reload-api.bat. Not optional - PostgREST learned the' 'Yellow'
Say 'old database structure when it started and will keep answering from' 'Yellow'
Say 'it until told to look again, so the new screen would come up empty.' 'Yellow'
Write-Host ''
Say 'Then sign in and look under Payroll for "Bank Transfers". It will say' 'Cyan'
Say 'no transfer files have been built yet, which is correct - that fills' 'Cyan'
Say 'in once the bank details are loaded and the files are produced.' 'Cyan'
Write-Host ''
Say ("Backup, if anything needs undoing: {0}" -f $backup)
Rule
Write-Host ''
if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
exit 0
