<#
  HCIS - what does this machine already have?

  READS ONLY. CHANGES NOTHING. Safe to run at any time.

  Run this on the GOV BOX. It answers the questions I need answered before I
  can build the job that emails Finance the payroll, so that I build the right
  one rather than guessing and finding out on the 29th.

  WHY IT MATTERS, IN ONE PARAGRAPH

  The payroll calculation - pension, withholding, loans, the days-or-hours
  rule - exists once, in Python, on the office server. The bank transfer files
  call that same code so the banks and Finance can never be told different
  numbers.

  If this box can run Python, the job moves across as the SAME code and there
  is still one calculation. If it cannot, that calculation has to be written a
  second time in something Windows can run - and two copies of a payroll
  calculation WILL drift apart eventually. The day they do, the banks pay one
  figure and Finance is told another.

  So: this is not a formality. It decides whether the system has one payroll
  calculation or two.
#>

$ErrorActionPreference = 'Continue'
function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }
function Rule { Write-Host '  ------------------------------------------------------------' }

Write-Host ''
Say '============================================================'
Say ' HCIS - what this machine has'
Say '============================================================'
Say (" {0}   {1}" -f (Get-Date -Format 'dd MMM yyyy HH:mm'), $env:COMPUTERNAME)
Write-Host ''

$findings = @{}

# ---- 1. Python ------------------------------------------------------------
Say 'PYTHON' 'Cyan'
$py = $null
foreach ($c in @('python', 'python3', 'py')) {
    try {
        $v = & $c --version 2>&1
        if ($LASTEXITCODE -eq 0 -and $v -match 'Python (\d+)\.(\d+)') {
            $py = $c
            Say ("  {0} -> {1}" -f $c, ([string]$v).Trim()) 'Green'
            $findings['python'] = ([string]$v).Trim()
            break
        }
    } catch { }
}
if (-not $py) {
    Say '  not found on the PATH' 'Yellow'
    # It is often installed and simply not on the PATH, which is a different
    # problem with a much easier answer.
    $guesses = @(
        "$env:LOCALAPPDATA\Programs\Python",
        'C:\Python312', 'C:\Python311', 'C:\Python310',
        'C:\Program Files\Python312', 'C:\Program Files\Python311'
    ) | Where-Object { try { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue } catch { $false } }
    if ($guesses) {
        Say '  BUT it looks installed here, just not on the PATH:' 'Yellow'
        $guesses | ForEach-Object { Say ("    " + $_) 'Yellow' }
        $findings['python'] = 'installed but not on PATH'
    } else {
        $findings['python'] = 'NOT FOUND'
    }
}

# ---- 2. the one library the transfer files need ---------------------------
Write-Host ''
Say 'THE SPREADSHEET LIBRARY (openpyxl)' 'Cyan'
if ($py) {
    $ox = & $py -c "import openpyxl; print(openpyxl.__version__)" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Say ("  openpyxl {0}" -f ([string]$ox).Trim()) 'Green'
        $findings['openpyxl'] = ([string]$ox).Trim()
    } else {
        Say '  not installed' 'Yellow'
        Say '  (one command to add it, IF this machine can reach the internet)' 'Gray'
        $findings['openpyxl'] = 'not installed'
    }
} else {
    Say '  cannot check without Python' 'Gray'
    $findings['openpyxl'] = 'unknown'
}

# ---- 3. can this box reach the internet at all? ---------------------------
#
# Asked because "install openpyxl" is a one-liner on a machine with internet
# and a completely different conversation on one without. Government boxes
# are often the second, and that is fine - it just has to be known.
Write-Host ''
Say 'CAN THIS MACHINE REACH THE INTERNET' 'Cyan'
try {
    $r = Invoke-WebRequest -Uri 'https://pypi.org' -Method Head -TimeoutSec 8 -UseBasicParsing
    Say ("  yes - pypi.org answered {0}" -f $r.StatusCode) 'Green'
    $findings['internet'] = 'yes'
} catch {
    Say '  no, or it is blocked' 'Yellow'
    Say '  (not a problem - it just changes how the library gets here)' 'Gray'
    $findings['internet'] = 'no'
}

# ---- 4. the mail server it would send through -----------------------------
Write-Host ''
Say 'MAIL' 'Cyan'
$mailConf = 'C:\HCIS\mail.json'
$haveMail = $false
try { $haveMail = Test-Path -LiteralPath $mailConf -ErrorAction SilentlyContinue } catch { }
if ($haveMail) {
    Say ("  a mail configuration already exists: {0}" -f $mailConf) 'Green'
    $findings['mail'] = 'configured'
} else {
    Say '  no mail configuration on this box yet' 'Yellow'
    $findings['mail'] = 'none'
}
foreach ($t in @(@{h='smtp.gmail.com';p=587}, @{h='smtp.office365.com';p=587})) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $ok = $c.ConnectAsync($t.h, $t.p).Wait(5000)
        $c.Close()
        if ($ok) { Say ("  can reach {0}:{1}" -f $t.h, $t.p) 'Green' }
        else     { Say ("  cannot reach {0}:{1}" -f $t.h, $t.p) 'Yellow' }
    } catch {
        Say ("  cannot reach {0}:{1}" -f $t.h, $t.p) 'Yellow'
    }
}

# ---- 5. where HCIS and PostgreSQL actually are ----------------------------
Write-Host ''
Say 'HCIS AND THE DATABASE' 'Cyan'
# -ErrorAction SilentlyContinue on the Test-Path: a path on a drive that does
# not exist throws rather than returning false, and a screenful of red is a
# poor way to tell somebody "PostgreSQL is not in the usual place".
$pgbin = $null
foreach ($cand in @('C:\PostgreSQL\16\bin', 'C:\PostgreSQL\17\bin',
                    'C:\Program Files\PostgreSQL\16\bin',
                    'C:\Program Files\PostgreSQL\17\bin')) {
    # Plain string join rather than Join-Path. Join-Path raises a
    # NON-TERMINATING error on a drive that does not exist, which try/catch
    # does not catch and -ErrorAction on the Test-Path cannot reach - so the
    # window fills with red before anything useful is printed. Removing the
    # cmdlet removes the problem.
    $probe = $cand.TrimEnd('\') + '\psql.exe'
    try {
        if (Test-Path -LiteralPath $probe -ErrorAction SilentlyContinue) {
            $pgbin = $cand; break
        }
    } catch { }
}
if ($pgbin) { Say ("  PostgreSQL tools: {0}" -f $pgbin) 'Green' }
else        { Say '  psql.exe not found in the usual places' 'Red' }
foreach ($p in @('C:\HCIS', 'C:\HCIS\wwwroot')) {
    $there = $false
    try { $there = Test-Path -LiteralPath $p -ErrorAction SilentlyContinue } catch { }
    if ($there) { Say ("  {0}" -f $p) 'Green' } else { Say ("  {0} - not there" -f $p) 'Yellow' }
}

# ---- 6. is anything already scheduled? ------------------------------------
Write-Host ''
Say 'SCHEDULED TASKS THAT LOOK LIKE OURS' 'Cyan'
try {
    $tasks = Get-ScheduledTask -ErrorAction Stop |
             Where-Object { $_.TaskName -match 'HCIS|PostgREST|payroll|cutoff' }
    if ($tasks) {
        foreach ($t in $tasks) {
            $info = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            Say ("  {0}  [{1}]  last run {2}" -f $t.TaskName, $t.State,
                 $(if ($info.LastRunTime) { $info.LastRunTime } else { 'never' })) 'Green'
        }
    } else {
        Say '  none' 'Yellow'
    }
} catch {
    Say '  could not list scheduled tasks (try running as Administrator)' 'Yellow'
}

# ---- what this means ------------------------------------------------------
Write-Host ''
Rule
Say 'WHAT THIS MEANS' 'Cyan'
Write-Host ''
if ($findings['python'] -eq 'NOT FOUND') {
    Say 'No Python on this machine.' 'Yellow'
    Say ''
    Say 'That is the one answer that changes what I build. Without it the'
    Say 'payroll calculation has to be written a second time for Windows, and'
    Say 'two copies of a payroll calculation drift apart eventually - the day'
    Say 'they do, the banks pay one figure and Finance is told another.'
    Say ''
    Say 'So the question for DICT is simply: may Python be installed on the'
    Say 'production server? It is a standard install and nothing else needs'
    Say 'it. If the answer is no, tell me and I will build the Windows-only'
    Say 'version - it just takes longer and I will want it checked twice.'
} elseif ($findings['openpyxl'] -eq 'not installed') {
    Say 'Python is here, the spreadsheet library is not.' 'Green'
    Say 'That is the easy case - one command, and the job moves across as the'
    Say 'SAME code that runs on the office server. One payroll calculation,'
    Say 'not two.'
} else {
    Say 'Python and the spreadsheet library are both here.' 'Green'
    Say 'The job moves across as the same code. Nothing to install.'
}
Write-Host ''
Rule
Say 'Nothing was changed by this check.' 'Gray'
Write-Host ''
Say 'Send me a photo of this whole window.' 'Cyan'
Write-Host ''
if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
exit 0
