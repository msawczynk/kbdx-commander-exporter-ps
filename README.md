# Export-KeeperToKdbx.ps1

A PowerShell script that exports a Keeper vault to a KeePass `.kdbx` file. It uses Keeper Commander to do the export.

It runs this Commander command:

```
keeper [--config <config.json>] export --format=keepass [options] <file.kdbx>
```

## What gets exported

| Included | Not included |
|---|---|
| Records (login, password, URL, notes, custom fields) | Shared folder permissions (users and teams) |
| File attachments (you can limit the size with `-MaxAttachmentSize`) | Record sharing settings |
| Folders and subfolders | Anything outside the selected `-Folder`, if you use that option |

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+. It should also work on macOS and Linux with `pwsh`.
- Python 3.
- Keeper Commander and pykeepass. Commander needs pykeepass for the KeePass format.

  ```powershell
  pip install keepercommander pykeepass
  ```

  You can also run the script with `-InstallPrereqs` to install both.

> **Windows note:** if `pip install pykeepass` fails while building **lxml**, install a pre-built lxml wheel that matches your Python version, then retry. Keeper's KeePass README has the steps: <https://github.com/Keeper-Security/Commander/blob/master/keepercommander/importer/keepass/README.md>

## One-time login

The script expects Commander to be logged in already. Set up persistent login once:

```powershell
keeper shell
My Vault> login you@company.com
My Vault> this-device persistent-login on
My Vault> quit
```

If you are not logged in, Commander will ask you to log in when the script runs. That works in an interactive session but not in unattended runs.

## Usage

```powershell
# Export the whole vault. Commander asks for the KDBX password (input is hidden).
.\Export-KeeperToKdbx.ps1 -OutFile C:\export\vault.kdbx

# Export one folder, only records you own, attachments up to 10 MB
.\Export-KeeperToKdbx.ps1 -OutFile C:\export\socials.kdbx -Folder "Socials" -OwnedOnly -MaxAttachmentSize 10M

# Unattended run: use a specific config and pass the password in, overwrite the file
$pw = Read-Host "KDBX password" -AsSecureString
.\Export-KeeperToKdbx.ps1 -OutFile .\vault.kdbx -KdbxPassword $pw -ConfigPath C:\keeper\config.json -Force

# Add a KeePass key file as a second factor
.\Export-KeeperToKdbx.ps1 -OutFile .\vault.kdbx -KeyFile .\vault.keyx
```

If PowerShell blocks the script, allow it for the current session only:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-OutFile` | Yes | Path to the `.kdbx` file to create. Missing folders are created. |
| `-KdbxPassword` | No | The KDBX password as a SecureString. If you leave it out, Commander asks for it, which is safer. |
| `-KeyFile` | No | KeePass key file (`--keepass-key-file`). |
| `-Folder` | No | Name or UID of the Keeper folder to export. |
| `-OwnedOnly` | No | Export only records you own. |
| `-MaxAttachmentSize` | No | Maximum size per attachment, e.g. `100K`, `10M`, `2G`. |
| `-StoreInVault` | No | Also save the `.kdbx` as an attachment on a record in your Keeper vault. |
| `-ConfigPath` | No | Commander `config.json` to use. The default is `~/.keeper/config.json`. |
| `-KeeperExe` | No | Path to the `keeper` command, if it's not on PATH. |
| `-InstallPrereqs` | No | Runs `pip install --upgrade keepercommander pykeepass` first. |
| `-Force` | No | Overwrite `-OutFile` if it already exists. |

## Security notes

- **The `.kdbx` contains your passwords.** Store it encrypted, choose a strong KDBX password, and delete the file when you no longer need it.
- **Command-line password:** with `-KdbxPassword`, the password is passed to Commander on its command line. Other processes on the machine can see it while the export runs. The script hides it in its own console output. For the most protection, leave `-KdbxPassword` out and let Commander prompt.
- **Passwords with `"` in Windows PowerShell 5.1:** 5.1 has a known problem passing double quotes to other programs. If your KDBX password contains `"`, use PowerShell 7.3+ or let Commander prompt.
- **Admin policy:** enterprise admins can turn off vault export with a role enforcement. If your role blocks it, the export fails.

## Troubleshooting

| Problem | Fix |
|---|---|
| `'keeper' not found on PATH` | Run `pip install keepercommander`, then reopen the terminal. Or pass `-KeeperExe` with the full path, e.g. `...\Python3x\Scripts\keeper.exe`. |
| Error mentioning `pykeepass` or `lxml` | Install pykeepass. See the Windows note above. |
| "Export failed" with exit code 0 | Commander sometimes returns 0 even when it fails. Run `keeper login-status`, then try the export by hand in `keeper shell` to see the error. |
| "Device not approved" | Approve the device, or ask your admin to (Keeper Automator, or `device-approve` in Commander). |
| `-Folder` finds no records | Use the folder UID instead of the name. You can find it with `ls -l` in `keeper shell`. |

## References

- Commander import/export commands: <https://docs.keeper.io/keeperpam/commander-cli/command-reference/import-and-export-commands>
- Commander KeePass support (pykeepass/lxml): <https://github.com/Keeper-Security/Commander/blob/master/keepercommander/importer/keepass/README.md>
