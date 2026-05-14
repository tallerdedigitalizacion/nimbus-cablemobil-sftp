# Nimbus Cablemobil SFTP Mailer

This automation runs on Windows, connects to Cablemovil's SFTP with WinSCP, downloads invoice files, emails new files to the purchases mailbox, and emails execution errors to the IT mailbox.

It is intended for the Windows office machine that is allowed to reach Cablemovil's SFTP. Final production testing must happen from Patricia's whitelisted PC.

## Why WinSCP

Cablemovil's SFTP appears to require username/password authentication, probably uses port 22, and may support only older SSH/SFTP algorithms. FileZilla has not worked reliably with it, while WinSCP does.

For that reason this project deliberately uses `WinSCP.com` for SFTP automation. It does not use OpenSSH, Paramiko, FileZilla, Node SFTP libraries, or Python SFTP libraries.

## What It Does

1. Loads settings from `config.json`.
2. Creates `downloads/` and `logs/` if they do not exist.
3. Runs `WinSCP.com` with a temporary script file.
4. Downloads matching files from the configured remote SFTP directory.
5. Checks `sent-files.json` to avoid sending the same filename twice.
6. Emails each new file to the purchases mailbox.
7. Records successfully emailed files in `sent-files.json`.
8. Sends runtime errors to the IT mailbox.

Version 1 does not delete or move remote files.

## Windows Installation

1. Install WinSCP on the Windows machine.

   Default path:

   ```powershell
   C:\Program Files (x86)\WinSCP\WinSCP.com
   ```

2. Verify that `WinSCP.com` exists:

   ```powershell
   Test-Path "C:\Program Files (x86)\WinSCP\WinSCP.com"
   ```

3. Clone or copy this repository into:

   ```text
   C:\Nimbus\nimbus-cablemobil-sftp
   ```

4. Open PowerShell in that folder:

   ```powershell
   cd C:\Nimbus\nimbus-cablemobil-sftp
   ```

5. Copy the example configuration:

   ```powershell
   Copy-Item .\config.example.json .\config.json
   ```

6. Edit `config.json` with the real SFTP, SMTP, and mailbox values.

7. Test manually:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\run.ps1
   ```

8. Install the scheduled task:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\install.ps1 -DailyTime "09:00"
   ```

Administrator permissions may be needed to register a task that runs whether the user is logged on or not. Windows may also request the user's password because Task Scheduler must store credentials for logged-off execution.

Secrets are not embedded in the scheduled task. SFTP and SMTP credentials remain only in `config.json`.

## Manual Execution

From the project folder:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\run.ps1
```

Exit codes:

- `0`: success
- `1`: runtime error
- `2`: configuration error

## Install Scheduled Task

From the project folder:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install.ps1 -DailyTime "09:00"
```

Optional parameters:

- `-DailyTime "09:00"` sets the daily run time in 24-hour `HH:mm` format.
- `-ProjectPath "C:\Nimbus\nimbus-cablemobil-sftp"` points the task to a specific project folder.

The task name is:

```text
Nimbus Cablemobil SFTP Mailer
```

## Uninstall Scheduled Task

From the project folder:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## Configuration

Create `config.json` from `config.example.json` and edit the values:

```json
{
  "winscpPath": "C:\\Program Files (x86)\\WinSCP\\WinSCP.com",
  "sftpHost": "127.0.0.1",
  "sftpPort": 2222,
  "sftpUsername": "cablemobil",
  "sftpPassword": "CHANGE_ME",
  "sftpRemoteDirectory": "/upload/facturas",
  "filePattern": "*.*",
  "localDownloadDirectory": ".\\downloads",
  "stateFile": ".\\sent-files.json",
  "logFile": ".\\logs\\app.log",
  "smtpHost": "smtp.example.com",
  "smtpPort": 587,
  "smtpUseSsl": true,
  "smtpUsername": "CHANGE_ME",
  "smtpPassword": "CHANGE_ME",
  "mailFrom": "it@example.com",
  "mailToPurchases": "compras@example.com",
  "mailToIT": "it@example.com",
  "emailSubjectPrefix": "[Nimbus Cablemobil SFTP]"
}
```

## Local SFTP Testing

Development may happen on macOS, but execution must be tested on Windows because the automation depends on `WinSCP.com` and Windows Task Scheduler.

For non-production testing, a Docker SFTP server can be run on the Mac. The Windows VM or Windows office machine must connect to the Mac's IP address and the exposed Docker port. For example, if Docker exposes SFTP on port `2222`, set these fields in `config.json` on Windows:

```json
{
  "sftpHost": "MAC_IP_ADDRESS",
  "sftpPort": 2222
}
```

This local SFTP setup is optional. The final production test must happen from Patricia's whitelisted PC.

## Troubleshooting

### WinSCP path wrong

If the log says `WinSCP.com was not found`, check `winscpPath` in `config.json`.

Default install path:

```text
C:\Program Files (x86)\WinSCP\WinSCP.com
```

### SFTP connection fails

Confirm the host, port, username, and password. The real Cablemovil SFTP is IP-whitelisted, so tests from another computer may fail even with correct credentials.

Also confirm that the Windows machine can reach the server network. If legacy SSH/SFTP algorithms are involved, use WinSCP interactively on the same Windows machine to confirm it can connect.

### Wrong remote directory

If WinSCP connects but downloads nothing, check `sftpRemoteDirectory` and `filePattern`.

Example:

```json
"sftpRemoteDirectory": "/upload/facturas",
"filePattern": "*.*"
```

### SMTP authentication fails

Check `smtpHost`, `smtpPort`, `smtpUseSsl`, `smtpUsername`, `smtpPassword`, and `mailFrom`.

Some mail services require an app password or SMTP-specific credentials.

### File already sent and skipped

Version 1 uses `sent-files.json` to avoid duplicate emails. If the same filename already exists in `sent-files.json`, it will not be sent again.

If `sent-files.json` is deleted, old files still present in `downloads/` or on the remote SFTP may be sent again.

### Windows execution policy issue

Run scripts with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\run.ps1
```

The scheduled task installed by `install.ps1` also uses `-ExecutionPolicy Bypass`.

## Security Notes

`config.json` contains SFTP and SMTP credentials. Do not commit it.

Only commit `config.example.json`.

Restrict folder permissions on the Windows machine so only the operating user and appropriate administrators can read:

```text
C:\Nimbus\nimbus-cablemobil-sftp
```

## Operational Notes

Version 1 does not delete or move remote files after download.

Version 1 uses the local `sent-files.json` file to avoid duplicate sending. The duplicate rule is filename-based: if the same filename already appears in `sent-files.json`, it is skipped.

If `sent-files.json` is deleted, old files may be emailed again.

Logs are written to:

```text
logs\app.log
```

Downloaded files are stored in:

```text
downloads\
```

The final production test must happen from Patricia's whitelisted PC.
