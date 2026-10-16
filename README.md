# RestoreTools

Backup and restore scripts for the company USB backup drive, built on [restic](https://restic.net/)
(encrypted, keeps history, only copies what changed). Everything runs straight from the drive on any Windows PC.

## Files

| File | Purpose |
| --- | --- |
| `Run-Backup.cmd` | Double-click launcher for the backup (asks which folders and file types). |
| `Run-Restore.cmd` | Double-click launcher for the restore. |
| `backup-usb.ps1` | Backs up this PC to the plugged-in drive. Does nothing if the drive isn't present. |
| `restore-usb.ps1` | Restores files: PC -> snapshot -> user -> folder(s) -> destination. |
| `logo.png` | Branding asset. |

## Setup

1. Download `restic.exe` (Windows amd64) from the [restic releases](https://github.com/restic/restic/releases)
   and place it next to the scripts. It is not stored in this repo (see `.gitignore`).
   The scripts check its SHA-256 against a trusted list; to run a different version, pass `-TrustRestic`
   or add its hash to `$TrustedResticSha256`.
2. The drive must have the label `COMPANY` (set in `$DriveLabel` in `backup-usb.ps1`); backups go to the
   `CompanyBackup` folder on it.

## Usage

```powershell
# Backup
.\Run-Backup.cmd
.\backup-usb.ps1 -Folders documents,music -Extensions pdf,docx,jpg -MaxFileSize 2G
.\backup-usb.ps1 -DryRun        # show what would happen, write nothing
.\backup-usb.ps1 -Check         # force an integrity check

# Restore
.\Run-Restore.cmd
.\restore-usb.ps1 -Target D:\Restored -RepoRoot E:\CompanyBackup
```

Common switches: `-NoAnim` (no animation), `-Plain` (no colors, ASCII only), `-TrustRestic`.

Folder names accepted by `-Folders`: `documents`, `desktop`, `downloads`, `pictures`, `videos`, `music`,
`home`, `onedrive`, `repos`, `ssh`, `appdata`, or any full path.

## Security notes

- The backup password is prompted for. It can optionally be saved Windows-encrypted (DPAPI) per PC and user.
  Never commit `restic-pass.txt`.
- Restores into drive roots, Windows/Program Files folders, or the vault itself are refused, and existing files
  are never silently overwritten.
- `backup-log.txt` and `backup-settings-*.json` are local runtime files and are git-ignored.
