#Requires -Version 5.1
<#
.SYNOPSIS
    Exports Keeper sharing relationships (shared folders, teams, record shares) with Keeper Commander.

.DESCRIPTION
    Vault scope (always - what the running Keeper account can see):
      shared_folder_membership.json   download-membership --source keeper
                                      (restorable with: apply-membership <file>)
      share-report-records.csv        share-report --owner --verbose --show-team-users
      share-report-folders.csv        share-report --folders --show-team-users
      shared-records-report.json      shared-records-report --all-records --show-team-users

    Enterprise scope (-IncludeCompliance; Keeper admin + Compliance Reporting add-on):
      compliance-report-shared.csv    compliance-report --shared --rebuild
      compliance-team-report.csv      compliance team-report --show-team-users
      compliance-shared-folder-report.csv  compliance shared-folder-report --show-team-users
      external-shares-report.csv      external-shares-report   (report only, nothing removed)

    -IncludeRecordAccess (also needs the ARAM add-on):
      compliance-record-access.csv    compliance record-access-report --report-type vault --email @all

    Writes manifest.json with per-step status and SHA-256 of each file.
    None of these files contain passwords, but they do contain titles, URLs,
    user emails and team names - treat them as sensitive.

    Exit code: 0 = all steps OK, 2 = some steps failed (others still written).

.EXAMPLE
    .\Export-KeeperSharing.ps1 -OutDir D:\KeeperBackups\sharing

.EXAMPLE
    .\Export-KeeperSharing.ps1 -OutDir D:\KeeperBackups\sharing -IncludeCompliance -IncludeRecordAccess
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$OutDir,
    [switch]$IncludeCompliance,
    [switch]$IncludeRecordAccess,
    [string]$ConfigPath,
    [string]$KeeperExe = 'keeper',
    [string]$CacheDir                     # where compliance cache (sox_*.db) lives; default: <OutDir>\..\.cache
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command $KeeperExe -ErrorAction SilentlyContinue)) {
    throw "'$KeeperExe' not found on PATH. Install with: pip install keepercommander"
}
$OutDir = [IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
if (-not $CacheDir) { $CacheDir = Join-Path (Split-Path $OutDir -Parent) '.cache' }
if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }

$globalArgs = @()
if ($ConfigPath) { $globalArgs = @('--config', [IO.Path]::GetFullPath($ConfigPath)) }

function Out([string]$name) { Join-Path $OutDir $name }

# --- Steps ------------------------------------------------------------------
$steps = [System.Collections.Generic.List[object]]::new()
function Add-Step($name, $file, [string[]]$cmd) { $steps.Add([pscustomobject]@{ Name = $name; File = $file; Cmd = $cmd }) }

$f = Out 'shared_folder_membership.json'
Add-Step 'download-membership' $f @('download-membership', '--source', 'keeper', $f)
$f = Out 'share-report-records.csv'
Add-Step 'share-report (records)' $f @('share-report', '--owner', '--verbose', '--show-team-users', '--format', 'csv', '--output', $f)
$f = Out 'share-report-folders.csv'
Add-Step 'share-report (folders)' $f @('share-report', '--folders', '--show-team-users', '--format', 'csv', '--output', $f)
$f = Out 'shared-records-report.json'
Add-Step 'shared-records-report' $f @('shared-records-report', '--all-records', '--show-team-users', '--format', 'json', '--output', $f)

if ($IncludeCompliance -or $IncludeRecordAccess) {
    # First compliance call rebuilds the cache; later calls reuse it (same working dir, < 1 day old)
    $f = Out 'compliance-report-shared.csv'
    Add-Step 'compliance-report (shared)' $f @('compliance-report', '--shared', '--rebuild', '--format', 'csv', '--output', $f)
    $f = Out 'compliance-team-report.csv'
    Add-Step 'compliance team-report' $f @('compliance', 'team-report', '--show-team-users', '--format', 'csv', '--output', $f)
    $f = Out 'compliance-shared-folder-report.csv'
    Add-Step 'compliance shared-folder-report' $f @('compliance', 'shared-folder-report', '--show-team-users', '--format', 'csv', '--output', $f)
    $f = Out 'external-shares-report.csv'
    Add-Step 'external-shares-report' $f @('external-shares-report', '--format', 'csv', '--output', $f)
}
if ($IncludeRecordAccess) {
    $f = Out 'compliance-record-access.csv'
    Add-Step 'compliance record-access-report' $f @('compliance', 'record-access-report', '--report-type', 'vault', '--email', '@all', '--format', 'csv', '--output', $f)
}

# --- Run --------------------------------------------------------------------
$results = @()
Push-Location -LiteralPath $CacheDir
try {
    foreach ($s in $steps) {
        Write-Host "==> $($s.Name)" -ForegroundColor Cyan
        if (Test-Path -LiteralPath $s.File) { Remove-Item -LiteralPath $s.File -Force }   # download-membership merges into existing files
        $started = Get-Date
        $allArgs = @($globalArgs + $s.Cmd)
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & $KeeperExe @allArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
        $exit = $LASTEXITCODE
        $ErrorActionPreference = $eap

        $ok = ($exit -eq 0) -and (Test-Path -LiteralPath $s.File) -and ((Get-Item -LiteralPath $s.File).Length -gt 0)
        $hash = if ($ok) { (Get-FileHash -LiteralPath $s.File -Algorithm SHA256).Hash } else { $null }
        if ($ok) { Write-Host "    OK -> $(Split-Path $s.File -Leaf)" -ForegroundColor Green }
        else     { Write-Host "    FAILED (exit $exit, file missing or empty)" -ForegroundColor Red }

        $results += [pscustomobject]@{
            step     = $s.Name
            file     = Split-Path $s.File -Leaf
            ok       = $ok
            exitCode = $exit
            sha256   = $hash
            seconds  = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        }
    }
}
finally { Pop-Location }

[pscustomobject]@{
    created   = (Get-Date).ToString('o')
    machine   = $env:COMPUTERNAME
    winUser   = "$env:USERDOMAIN\$env:USERNAME"
    scope     = if ($IncludeRecordAccess) { 'vault+compliance+record-access' } elseif ($IncludeCompliance) { 'vault+compliance' } else { 'vault' }
    steps     = $results
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Out 'manifest.json') -Encoding UTF8

$failed = @($results | Where-Object { -not $_.ok })
if ($failed.Count) {
    Write-Warning "$($failed.Count) of $($results.Count) sharing exports failed: $(($failed.step) -join ', ')"
    exit 2
}
Write-Host "Sharing export complete: $OutDir" -ForegroundColor Green
exit 0
