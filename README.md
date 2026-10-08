# Keeper Vault Backup: KDBX + sharing relationships

PowerShell scripts that back up a Keeper vault with Keeper Commander, on a schedule or by hand. Each run produces two things:

1. A **KeePass `.kdbx` file**: records, attachments, folders and subfolders, protected with a password.
2. **Sharing relationships**: shared folders, users and teams on each folder, team members, and records shared with individual users. One of the files can be used to restore folder memberships with `apply-membership`.

| Script | Purpose |
|---|---|
| `Register-KeeperKdbxBackupTask.ps1` | One-time setup. Saves the KDBX password and creates the Windows scheduled task. |
| `Invoke-KeeperKdbxBackup.ps1` | Runs one full backup. The scheduled task calls this. |
| `Export-KeeperToKdbx.ps1` | KDBX export only. Can also be run by hand. |
| `Export-KeeperSharing.ps1` | Sharing export only. Can also be run by hand. |

Keep all four files in the same folder.

---

## Output of each run

```
D:\KeeperBackups\
├─ 20261008-020000\
│  ├─ keeper-vault.kdbx
│  └─ sharing\
│     ├─ shared_folder_membership.json      ← restorable (apply-membership)
│     ├─ share-report-records.csv
│     ├─ share-report-folders.csv
│     ├─ shared-records-report.json
│     ├─ compliance-*.csv                   ← only with -IncludeCompliance
│     ├─ external-shares-report.csv         ← only with -IncludeCompliance
│     └─ manifest.json                      ← status + SHA-256 of each file
├─ logs\backup-20261008-020000.log
└─ .cache\                                  ← Commander compliance cache
```

### Sharing files

| File | Commander command | Contents | Requires |
|---|---|---|---|
| `shared_folder_membership.json` | `download-membership --source keeper` | Shared folders, their user and team permissions, and team members. Can be re-applied with `apply-membership`. | Any user |
| `share-report-records.csv` | `share-report --owner --verbose --show-team-users` | Each shared record: owner, who it is shared with, and permissions | Any user |
| `share-report-folders.csv` | `share-report --folders --show-team-users` | Each shared folder, with the users and teams that have access | Any user |
| `shared-records-report.json` | `shared-records-report --all-records --show-team-users` | Record shares, including team members | Any user |
| `compliance-report-shared.csv` | `compliance-report --shared --rebuild` | All shared records across **every vault in the enterprise** | Admin + Compliance Reporting add-on |
| `compliance-team-report.csv` | `compliance team-report -tu` | Team → shared folder access and permissions | Admin + Compliance |
| `compliance-shared-folder-report.csv` | `compliance shared-folder-report -tu` | All users and teams on all shared folders, enterprise-wide | Admin + Compliance |
| `external-shares-report.csv` | `external-shares-report` | Shares with people outside the company. Report only; nothing is removed. | Admin |
| `compliance-record-access.csv` | `compliance record-access-report --report-type vault --email @all` | Records currently accessible in each user's vault | Admin + Compliance + ARAM |

> **What "complete" covers.** The KDBX and the four "Any user" files cover only what **the Keeper account running the backup** can see. Because Keeper is zero-knowledge, an admin cannot export the contents of other users' vaults. For the **enterprise-wide** sharing picture, run the backup as a Keeper admin with `-IncludeCompliance` (and `-IncludeRecordAccess` if you have ARAM). Those reports show *who has access to what*, but not the passwords.

The sharing files contain no passwords. They do contain record titles, URLs, email addresses and team names, so treat them as sensitive.

---

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+, on Windows (Task Scheduler and DPAPI are Windows-only).
- Python 3.
- A **recent** Keeper Commander, plus pykeepass:

  ```powershell
  pip install --upgrade keepercommander pykeepass
  ```

  The backup passes `--force` to `export`, an option only recent Commander versions have, so upgrade if you see "unrecognized arguments".

> **Windows note:** if `pip install pykeepass` fails while building **lxml**, install a pre-built lxml wheel that matches your Python version, then retry. Keeper's KeePass README has the steps: <https://github.com/Keeper-Security/Commander/blob/master/keepercommander/importer/keepass/README.md>

---

## Setup (once)

### 1. Set up Commander to stay logged in

Do this as the Windows user that will run the task:

```powershell
keeper shell
My Vault> login admin@company.com
My Vault> this-device persistent-login on
My Vault> this-device register
My Vault> this-device timeout 20160            # inactivity timeout in minutes (14 days)
My Vault> this-device 2fa_expiration forever   # only needed if your account uses 2FA
My Vault> quit
```

- **Timeout:** set it longer than the gap between backups. Each run counts as activity and resets the timer.
- **Enterprise limit:** the enterprise logout timeout, set by your admin in a role policy, can cap this value. To check the current values, run `this-device`.

### 2. Register the task

```powershell
# Daily at 02:00, vault-level sharing, keep 14 runs, test right away
.\Register-KeeperKdbxBackupTask.ps1 -BackupDir D:\KeeperBackups -RunNow

# Admin account: add enterprise-wide sharing reports, run even when logged off
.\Register-KeeperKdbxBackupTask.ps1 -BackupDir D:\KeeperBackups -IncludeCompliance -RunWhenLoggedOff -TimeLimitHours 6 -RunNow

# Weekly on Sunday at 03:00, keep 8
.\Register-KeeperKdbxBackupTask.ps1 -BackupDir D:\KeeperBackups -Schedule Weekly -DaysOfWeek Sunday -At 03:00 -KeepLast 8
```

The setup script does the following:

1. Asks for the KDBX password and saves it encrypted with Windows DPAPI to `%LOCALAPPDATA%\KeeperKdbxBackup\kdbx-password.xml`. Only the same Windows user on the same PC can decrypt it. **Also save this password in Keeper**, because you need it to open the backups.
2. Restricts access to the backup folder to you, SYSTEM and Administrators.
3. Creates the scheduled task **Keeper Vault Backup**.
4. With `-RunNow`, runs the task once and reports the result.

| Parameter | Default | Description |
|---|---|---|
| `-BackupDir` | (required) | Backup root folder. |
| `-Schedule` / `-At` / `-DaysOfWeek` | `Daily` / `02:00` / `Sunday` | When to run. `-DaysOfWeek` applies only to `Weekly`. |
| `-KeepLast` | `14` | Number of run folders to keep. Older ones are deleted. |
| `-IncludeCompliance` | off | Adds the enterprise-wide sharing reports (admin + Compliance add-on). |
| `-IncludeRecordAccess` | off | Adds the record-access report for all users (also needs ARAM). |
| `-SkipSharing` | off | KDBX only. |
| `-TimeLimitHours` | `2` | Maximum run time. Raise it for large enterprises; the first compliance run can take a long time. |
| `-RunWhenLoggedOff` | off | Runs even when you are logged off. Asks for your Windows password, which Task Scheduler stores. |
| `-RunNow` | off | Runs the task once right after setup to test it. |
| `-SkipPassword` | off | Keeps the KDBX password that is already saved. |
| `-KeyFile`, `-Folder`, `-OwnedOnly`, `-MaxAttachmentSize`, `-ConfigPath` | | Passed on to the KDBX export. |

To change any option, run the setup again; it replaces the task. Add `-SkipPassword` to keep the saved password.

---

## Monitoring

| Result | Task "Last Run Result" | Event Log (Application, source `KeeperKdbxBackup`) |
|---|---|---|
| Everything OK | `0x0` | – |
| KDBX OK, some sharing exports failed | `0x2` | Warning, event ID **1002** |
| Backup failed | `0x1` | Error, event ID **1001** |

- **Which step failed:** `sharing\manifest.json` lists each sharing step with its status. The log in `logs\` has Commander's full output.
- **Event Log entries:** these are written only if setup was run as admin, which creates the event source. You can alert on event IDs 1001 and 1002 with your monitoring tool.
- **Log retention:** logs are kept for 30 days.

---

## Restoring

| What | How |
|---|---|
| Records, into Keeper | `keeper import --format keepass <path>\keeper-vault.kdbx` (asks for the KDBX password) |
| Records, read only | Open the `.kdbx` in KeePass or KeePassXC |
| Shared folder memberships | `keeper apply-membership <path>\sharing\shared_folder_membership.json`. The users and teams must already exist. Add `--full-sync` to also remove permissions that aren't in the file. |
| Everything else | The CSV and JSON reports are a record of the sharing setup, for audit or to rebuild it by hand. |

---

## Running by hand

```powershell
# KDBX only (Commander asks for the password)
.\Export-KeeperToKdbx.ps1 -OutFile C:\export\vault.kdbx

# Sharing only
.\Export-KeeperSharing.ps1 -OutDir C:\export\sharing -IncludeCompliance
```

If PowerShell blocks the scripts, allow them for the current session only: `Set-ExecutionPolicy -Scope Process Bypass`.

---

## Security notes

- **The `.kdbx` contains every password in the vault.** Keep the backup folder on encrypted storage, use a strong KDBX password (16+ characters), and limit who can reach the folder.
- **Password exposure during export:** in unattended runs, the KDBX password is passed to Commander on its command line for the length of the export. Only processes on the same machine can see it.
- **Persistent login:** Commander's login is stored in Windows Credential Manager for that Windows user. Protect that Windows account. Persistent login also turns on "stay logged in" for that Keeper account on all its devices.
- **Admin policy:** if a role enforcement blocks export, the KDBX step fails ("`export` command is disabled").
- **Passwords with `"` in Windows PowerShell 5.1:** 5.1 has a known problem passing double quotes to other programs. Avoid `"` in the KDBX password, or use PowerShell 7.3+.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Task result `0x1` with "not logged in" or a timeout in the log | Persistent login expired. Log in again in `keeper shell` and check `this-device`. |
| `unrecognized arguments: --force` | Commander is too old. Run `pip install --upgrade keepercommander`. |
| Error mentioning `pykeepass` or `lxml` | See the Windows note under Requirements. |
| Compliance steps fail | The account must be a Keeper admin, and the enterprise needs the Compliance Reporting add-on (plus ARAM for record-access). |
| Task stopped after 2 hours | Raise `-TimeLimitHours`. The first compliance cache build is slow. |
| "Device not approved" | Approve the device (Keeper Automator, Admin Console, or `device-approve` in Commander). |

## References

- Import/export commands: <https://docs.keeper.io/keeperpam/commander-cli/command-reference/import-and-export-commands>
- Reporting commands (share-report, shared-records-report, external-shares-report): <https://docs.keeper.io/keeperpam/commander-cli/command-reference/reporting-commands>
- Compliance commands: <https://docs.keeper.io/keeperpam/commander-cli/command-reference/enterprise-management-commands/compliance-commands>
- Persistent login: <https://docs.keeper.io/keeperpam/commander-cli/commander-installation-setup/logging-in>
- Commander source (export/download-membership options): <https://github.com/Keeper-Security/Commander/blob/master/keepercommander/importer/commands.py>
