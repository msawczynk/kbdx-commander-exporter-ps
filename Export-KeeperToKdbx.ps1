#Requires -Version 5.1
<#
.SYNOPSIS
    Exports a Keeper vault to a KeePass (.kdbx) file using Keeper Commander.

.DESCRIPTION
    Wraps:  keeper [--config <cfg>] export --format=keepass [options] <file.kdbx>
    The KDBX contains records, file attachments, folders and subfolders
    (not sharing permissions).

    By default the KDBX password is NOT passed on the command line: Commander
    prompts for it itself (masked). Pass -KdbxPassword only for unattended runs;
    it is then visible in the process list while Commander runs.

    Docs: https://docs.keeper.io/keeperpam/commander-cli/command-reference/import-and-export-commands

.EXAMPLE
    .\Export-KeeperToKdbx.ps1 -OutFile C:\export\vault.kdbx

.EXAMPLE
    .\Export-KeeperToKdbx.ps1 -OutFile C:\export\socials.kdbx -Folder "Socials" -OwnedOnly -MaxAttachmentSize 10M

.EXAMPLE
    $pw = Read-Host -AsSecureString
    .\Export-KeeperToKdbx.ps1 -OutFile .\vault.kdbx -KdbxPassword $pw -ConfigPath C:\keeper\config.json -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$OutFile,
    [SecureString]$KdbxPassword,           # omit = Commander prompts (safer)
    [string]$KeyFile,                      # optional KeePass key file
    [string]$Folder,                       # folder name or UID to export
    [switch]$OwnedOnly,                    # only records you own
    [ValidatePattern('^\d+[KkMmGg]?$')]
    [string]$MaxAttachmentSize,            # e.g. 100K, 10M, 2G
    [switch]$StoreInVault,                 # also attach the .kdbx to a Keeper record
    [string]$ConfigPath,                   # Commander config.json (default: ~/.keeper/config.json)
    [string]$KeeperExe = "keeper",
    [switch]$InstallPrereqs,               # pip install keepercommander + pykeepass
    [switch]$Force,                        # overwrite existing file
    [switch]$NoPrompt                      # unattended: pass --force to Commander and capture its output to the log
)

$ErrorActionPreference = 'Stop'

function ConvertTo-Plain([SecureString]$s) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try     { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# --- Prereqs ----------------------------------------------------------------
if ($InstallPrereqs) {
    $py = Get-Command py, python3, python -CommandType Application -ErrorAction SilentlyContinue |
          Select-Object -First 1
    if (-not $py) { throw "Python not found. Install Python 3 first (https://www.python.org)." }
    & $py.Source -m pip install --upgrade keepercommander pykeepass
    if ($LASTEXITCODE -ne 0) { throw "pip install failed (see README: lxml on Windows)." }
}
if (-not (Get-Command $KeeperExe -ErrorAction SilentlyContinue)) {
    throw "'$KeeperExe' not found on PATH. Run with -InstallPrereqs or: pip install keepercommander pykeepass"
}

# --- Inputs -----------------------------------------------------------------
$OutFile = [IO.Path]::GetFullPath($OutFile)
if (Test-Path -LiteralPath $OutFile) {
    if ($Force) { Remove-Item -LiteralPath $OutFile -Force }
    else { throw "$OutFile already exists. Use -Force to overwrite." }
}
$dir = Split-Path $OutFile -Parent
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

if ($ConfigPath) {
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file not found: $ConfigPath" }
}
if ($KeyFile) { $KeyFile = [IO.Path]::GetFullPath($KeyFile) }

# --- Build command ----------------------------------------------------------
$cmdArgs = [System.Collections.Generic.List[string]]::new()
if ($ConfigPath)        { $cmdArgs.AddRange([string[]]@('--config', $ConfigPath)) }
$cmdArgs.AddRange([string[]]@('export', '--format=keepass'))
if ($KdbxPassword)      { $cmdArgs.Add("--keepass-file-password=$(ConvertTo-Plain $KdbxPassword)") }
if ($KeyFile)           { $cmdArgs.AddRange([string[]]@('--keepass-key-file', $KeyFile)) }
if ($Folder)            { $cmdArgs.AddRange([string[]]@('--folder', $Folder)) }
if ($OwnedOnly)         { $cmdArgs.Add('--owned-only') }
if ($MaxAttachmentSize) { $cmdArgs.AddRange([string[]]@('--max-size', $MaxAttachmentSize.ToUpper())) }
if ($StoreInVault)      { $cmdArgs.Add('--save-in-vault') }   # docs say --store-in-vault; Commander source uses --save-in-vault
if ($NoPrompt)          { $cmdArgs.Add('--force') }          # suppress Commander confirmations
$cmdArgs.Add($OutFile)

$shown = ($cmdArgs | ForEach-Object { $_ -replace '^(--keepass-file-password=).*', '$1********' }) -join ' '
Write-Host "Running: $KeeperExe $shown" -ForegroundColor Cyan
if (-not $KdbxPassword) { Write-Host "Commander will prompt for the KDBX file password." -ForegroundColor Yellow }

# --- Run --------------------------------------------------------------------
$exit = $null
try {
    $argArray = $cmdArgs.ToArray()
    if ($NoPrompt) {
        # capture Commander output (incl. stderr) so it lands in the transcript/log
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & $KeeperExe @argArray 2>&1 | ForEach-Object { Write-Host "    $_" }
        $exit = $LASTEXITCODE
        $ErrorActionPreference = $eap
    } else {
        & $KeeperExe @argArray
        $exit = $LASTEXITCODE
    }
}
finally {
    $cmdArgs.Clear(); $argArray = $null
}

# Commander can return 0 on some failures, so also check the file exists
if ($exit -ne 0 -or -not (Test-Path -LiteralPath $OutFile)) {
    throw "Export failed (exit code $exit). Check login with '$KeeperExe login-status' or log in via '$KeeperExe shell'."
}

$size = (Get-Item -LiteralPath $OutFile).Length
Write-Host ("Exported to {0} ({1:N1} KB)." -f $OutFile, ($size / 1KB)) -ForegroundColor Green
