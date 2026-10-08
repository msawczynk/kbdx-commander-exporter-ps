#Requires -Version 5.1
<#
.SYNOPSIS
    One-time setup for automated Keeper -> KDBX backups on Windows.

.DESCRIPTION
    0. Backs up: KDBX vault export + sharing relationships (Export-KeeperSharing.ps1).
    1. Saves the KDBX password DPAPI-encrypted (readable only by this Windows user on this machine).
    2. Restricts the backup folder to this user, SYSTEM and Administrators.
    3. Registers a Windows Scheduled Task that runs Invoke-KeeperKdbxBackup.ps1.
    4. Optionally runs the task once to test it.

    Run it as the Windows user that will own the backups, AFTER enabling
    Commander persistent login for that user (see README).

.EXAMPLE
    # Daily at 02:00, keep 14 backups, only runs while you're logged on
    .\Register-KeeperKdbxBackupTask.ps1 -BackupDir D:\KeeperBackups -RunNow

.EXAMPLE
    # Weekly on Sunday 03:00, keep 8, runs even when logged off (asks for your Windows password)
    .\Register-KeeperKdbxBackupTask.ps1 -BackupDir D:\KeeperBackups -Schedule Weekly -DaysOfWeek Sunday -At 03:00 -KeepLast 8 -RunWhenLoggedOff
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$BackupDir,
    [ValidateSet('Daily', 'Weekly')] [string]$Schedule = 'Daily',
    [string]$At = '02:00',
    [DayOfWeek[]]$DaysOfWeek = @('Sunday'),
    [ValidateRange(1, 3650)] [int]$KeepLast = 14,
    [string]$TaskName = 'Keeper Vault Backup',
    [ValidateRange(1, 24)] [int]$TimeLimitHours = 2,
    [switch]$RunWhenLoggedOff,
    [switch]$RunNow,
    [switch]$SkipPassword,                 # keep the existing saved password
    # pass-through to the backup
    [string]$KeyFile,
    [string]$Folder,
    [switch]$OwnedOnly,
    [string]$MaxAttachmentSize,
    [string]$ConfigPath,
    # sharing export
    [switch]$SkipSharing,
    [switch]$IncludeCompliance,            # admin + Compliance Reporting add-on
    [switch]$IncludeRecordAccess           # also needs ARAM add-on
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    throw "This setup is Windows-only (Task Scheduler + DPAPI). See README for macOS/Linux."
}

$runner = Join-Path $PSScriptRoot 'Invoke-KeeperKdbxBackup.ps1'
$export = Join-Path $PSScriptRoot 'Export-KeeperToKdbx.ps1'
$share  = Join-Path $PSScriptRoot 'Export-KeeperSharing.ps1'
foreach ($f in $runner, $export, $share) { if (-not (Test-Path -LiteralPath $f)) { throw "Missing $f" } }

# --- Resolve keeper.exe now (Task Scheduler may have a different PATH) ------
$keeperCmd = Get-Command keeper -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $keeperCmd) { throw "'keeper' not found on PATH. Install with: pip install keepercommander pykeepass" }
$keeperExe = $keeperCmd.Source
Write-Host "Using Commander: $keeperExe"

# --- 1. Save KDBX password (DPAPI, CurrentUser) -----------------------------
$pwDir  = Join-Path $env:LOCALAPPDATA 'KeeperKdbxBackup'
$pwFile = Join-Path $pwDir 'kdbx-password.xml'
if (-not (Test-Path -LiteralPath $pwDir)) { New-Item -ItemType Directory -Path $pwDir | Out-Null }

if ($SkipPassword -and (Test-Path -LiteralPath $pwFile)) {
    Write-Host "Keeping existing password file $pwFile"
} else {
    $p1 = Read-Host "KDBX file password for the backups" -AsSecureString
    $p2 = Read-Host "Confirm password" -AsSecureString
    $plain = { param($s) $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
               try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
               finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) } }
    if ((& $plain $p1) -ne (& $plain $p2)) { throw "Passwords do not match." }
    if ((& $plain $p1).Length -lt 12) { Write-Warning "Password is shorter than 12 characters." }
    $p1 | Export-Clixml -LiteralPath $pwFile -Force
    Write-Host "Saved encrypted password to $pwFile" -ForegroundColor Green
    Write-Host "Store this password in your Keeper vault too - you need it to open the backups." -ForegroundColor Yellow
}

# --- 2. Backup folder + ACL -------------------------------------------------
$BackupDir = [IO.Path]::GetFullPath($BackupDir)
if (-not (Test-Path -LiteralPath $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir | Out-Null }
$me = "$env:USERDOMAIN\$env:USERNAME"
& icacls.exe $BackupDir /inheritance:r /grant:r "${me}:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "Could not restrict permissions on $BackupDir (icacls exit $LASTEXITCODE)." }
else { Write-Host "Restricted $BackupDir to $me, SYSTEM, Administrators." }

# --- Event log source (best effort; needs admin) ----------------------------
try {
    if (-not [Diagnostics.EventLog]::SourceExists('KeeperKdbxBackup')) {
        New-EventLog -LogName Application -Source 'KeeperKdbxBackup'
    }
} catch { Write-Host "Event log source not created (needs admin). Failures will still be in the log files." }

# --- 3. Scheduled task ------------------------------------------------------
$psExe = (Get-Process -Id $PID).Path     # powershell.exe or pwsh.exe, whichever ran this
$q = { param($v) '"' + $v + '"' }
$argList = @(
    '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
    '-File', (& $q $runner),
    '-BackupDir', (& $q $BackupDir),
    '-KeepLast', $KeepLast,
    '-KeeperExe', (& $q $keeperExe)
)
if ($KeyFile)           { $argList += @('-KeyFile', (& $q ([IO.Path]::GetFullPath($KeyFile)))) }
if ($Folder)            { $argList += @('-Folder', (& $q $Folder)) }
if ($OwnedOnly)         { $argList += '-OwnedOnly' }
if ($MaxAttachmentSize) { $argList += @('-MaxAttachmentSize', $MaxAttachmentSize) }
if ($SkipSharing)         { $argList += '-SkipSharing' }
if ($IncludeCompliance)   { $argList += '-IncludeCompliance' }
if ($IncludeRecordAccess) { $argList += '-IncludeRecordAccess' }
if ($ConfigPath)        { $argList += @('-ConfigPath', (& $q ([IO.Path]::GetFullPath($ConfigPath)))) }

$action = New-ScheduledTaskAction -Execute $psExe -Argument ($argList -join ' ') -WorkingDirectory $PSScriptRoot
$time   = [datetime]::ParseExact($At, 'HH:mm', $null)
$trigger = if ($Schedule -eq 'Daily') {
    New-ScheduledTaskTrigger -Daily -At $time
} else {
    New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DaysOfWeek -At $time
}
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Hours $TimeLimitHours) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

$common = @{
    TaskName    = $TaskName
    Action      = $action
    Trigger     = $trigger
    Settings    = $settings
    Description = "Exports the Keeper vault of $me to KDBX plus sharing relationships in $BackupDir (keeps $KeepLast)."
    Force       = $true
}

if ($RunWhenLoggedOff) {
    # Password logon is required so DPAPI and the Windows keychain (Commander login) are available.
    $cred = Get-Credential -UserName $me -Message "Windows password for $me (stored by Task Scheduler)"
    Register-ScheduledTask @common -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Limited | Out-Null
} else {
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask @common -Principal $principal | Out-Null
}
Write-Host "Registered task '$TaskName' ($Schedule at $At)." -ForegroundColor Green

# --- 4. Optional test run ---------------------------------------------------
if ($RunNow) {
    Write-Host "Starting a test run..."
    Start-ScheduledTask -TaskName $TaskName
    do { Start-Sleep -Seconds 5; $t = Get-ScheduledTask -TaskName $TaskName } while ($t.State -eq 'Running')
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    if ($info.LastTaskResult -eq 0) {
        Write-Host "Test run succeeded. Backups: $BackupDir" -ForegroundColor Green
    } elseif ($info.LastTaskResult -eq 2) {
        Write-Warning "KDBX OK, but some sharing exports failed. See sharing\manifest.json and the log in $(Join-Path $BackupDir 'logs')."
    } else {
        Write-Warning "Test run failed (result $($info.LastTaskResult)). See logs in $(Join-Path $BackupDir 'logs')."
    }
}
