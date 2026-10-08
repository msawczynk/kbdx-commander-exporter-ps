#Requires -Version 5.1
<#
.SYNOPSIS
    Unattended Keeper backup: KDBX vault export + sharing relationships. Run by Windows Task Scheduler.

.DESCRIPTION
    Each run creates  <BackupDir>\<yyyyMMdd-HHmmss>\
        keeper-vault.kdbx             (Export-KeeperToKdbx.ps1)
        sharing\*.json|*.csv          (Export-KeeperSharing.ps1, unless -SkipSharing)
        sharing\manifest.json
    Keeps the newest -KeepLast run folders. Log per run in <BackupDir>\logs.

    Exit code: 0 = all OK, 2 = KDBX OK but some sharing exports failed, 1 = failed.

    The KDBX password is read from a DPAPI-encrypted file created by
    Register-KeeperKdbxBackupTask.ps1. Requires Commander persistent login.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$BackupDir,
    [string]$PasswordFile = (Join-Path $env:LOCALAPPDATA 'KeeperKdbxBackup\kdbx-password.xml'),
    [ValidateRange(1, 3650)] [int]$KeepLast = 14,
    [string]$LogDir,
    [ValidateRange(1, 3650)] [int]$KeepLogsDays = 30,
    # sharing export
    [switch]$SkipSharing,
    [switch]$IncludeCompliance,
    [switch]$IncludeRecordAccess,
    # pass-through to Export-KeeperToKdbx.ps1
    [string]$KeyFile,
    [string]$Folder,
    [switch]$OwnedOnly,
    [string]$MaxAttachmentSize,
    [string]$ConfigPath,
    [string]$KeeperExe = 'keeper'
)

$ErrorActionPreference = 'Stop'
if (-not $LogDir) { $LogDir = Join-Path $BackupDir 'logs' }
foreach ($d in $BackupDir, $LogDir) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir  = Join-Path $BackupDir $stamp
$logFile = Join-Path $LogDir "backup-$stamp.log"
Start-Transcript -LiteralPath $logFile -Force | Out-Null

function Write-FailureEvent([string]$msg, [int]$id, [string]$type) {
    try {
        if ([Diagnostics.EventLog]::SourceExists('KeeperKdbxBackup')) {
            Write-EventLog -LogName Application -Source 'KeeperKdbxBackup' -EventId $id -EntryType $type -Message "$msg Log: $logFile"
        }
    } catch { }
}

$exitCode = 0
try {
    Write-Host "Keeper backup started $(Get-Date -Format o) as $env:USERDOMAIN\$env:USERNAME"
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    # --- 1. KDBX ------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $PasswordFile)) {
        throw "Password file not found: $PasswordFile. Run Register-KeeperKdbxBackupTask.ps1 first (as this user)."
    }
    $kdbxPassword = Import-Clixml -LiteralPath $PasswordFile
    if ($kdbxPassword -isnot [SecureString]) { throw "Password file does not contain a SecureString." }

    $exportParams = @{
        OutFile      = (Join-Path $runDir 'keeper-vault.kdbx')
        KdbxPassword = $kdbxPassword
        KeeperExe    = $KeeperExe
        NoPrompt     = $true
    }
    if ($KeyFile)           { $exportParams.KeyFile           = $KeyFile }
    if ($Folder)            { $exportParams.Folder            = $Folder }
    if ($OwnedOnly)         { $exportParams.OwnedOnly         = $true }
    if ($MaxAttachmentSize) { $exportParams.MaxAttachmentSize = $MaxAttachmentSize }
    if ($ConfigPath)        { $exportParams.ConfigPath        = $ConfigPath }

    Write-Host "`n### KDBX export" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Export-KeeperToKdbx.ps1') @exportParams
    $kdbxPassword = $null

    # --- 2. Sharing relationships ------------------------------------------
    if (-not $SkipSharing) {
        Write-Host "`n### Sharing export" -ForegroundColor Cyan
        $shareParams = @{
            OutDir    = (Join-Path $runDir 'sharing')
            KeeperExe = $KeeperExe
            CacheDir  = (Join-Path $BackupDir '.cache')
        }
        if ($IncludeCompliance)   { $shareParams.IncludeCompliance   = $true }
        if ($IncludeRecordAccess) { $shareParams.IncludeRecordAccess = $true }
        if ($ConfigPath)          { $shareParams.ConfigPath          = $ConfigPath }

        & (Join-Path $PSScriptRoot 'Export-KeeperSharing.ps1') @shareParams
        if ($LASTEXITCODE -ne 0) {
            $exitCode = 2
            Write-FailureEvent "Keeper backup: KDBX OK, but some sharing exports failed." 1002 'Warning'
        }
    }

    # --- 3. Retention -------------------------------------------------------
    Get-ChildItem -LiteralPath $BackupDir -Directory |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
        Sort-Object Name -Descending |
        Select-Object -Skip $KeepLast |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force; Write-Host "Removed old backup $($_.Name)" }
    Get-ChildItem -LiteralPath $LogDir -Filter 'backup-*.log' -File |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepLogsDays) } |
        Remove-Item -Force

    Write-Host "`nBackup finished: $runDir (exit $exitCode)" -ForegroundColor Green
}
catch {
    $exitCode = 1
    Write-Host "BACKUP FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-FailureEvent "Keeper backup failed: $($_.Exception.Message)." 1001 'Error'
}
finally {
    $kdbxPassword = $null
    Stop-Transcript | Out-Null
}
exit $exitCode
