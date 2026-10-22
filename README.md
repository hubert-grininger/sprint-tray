# SprintTray

Shows the current Jira sprint number in the Windows system tray, with a progress line
underneath (green = time left in the sprint, red = elapsed).

## Requirements

- Windows 10/11 (uses the built-in Windows PowerShell 5.1)
- **acli-pii** (Atlassian CLI with PII redaction) installed and on your `PATH`
  (default location: `%USERPROFILE%\.local\bin\acli-pii.exe`)
- A logged-in acli-pii session:

  ```
  acli-pii jira auth login
  ```

  Check that it works:

  ```
  acli-pii jira sprint list --project APPOBS --state active
  ```

SprintTray has no Jira credentials of its own; it calls `acli-pii` with your login.

## Usage

Start `SprintTray.exe`. If it is already running, a second start does nothing.

New tray icons are hidden behind the **^** arrow by default — drag the icon onto the taskbar
to keep it visible.

- **Hover:** sprint name, end date, days left and % elapsed
- **Double-click:** refresh
- **Right-click:** Refresh, Copy sprint name, Help / status, Exit

Options:

```
SprintTray.exe -Project APPOBS -RefreshMinutes 1440
```

Defaults: project `APPOBS`, refresh once a day (1440 minutes). Right-click → Refresh any time.

## Autostart

Put a shortcut to `SprintTray.exe` into your Startup folder (Win+R → `shell:startup`).

## Troubleshooting

If a refresh fails, the icon keeps showing the last sprint that loaded, in grey, with
"(cached)" in the tooltip. A notification pops up with the reason; clicking it (or right-click →
**Help / status**) shows the details and setup steps. A red **?** icon only appears when no sprint
has ever loaded on this PC.

| Message | Fix |
|---|---|
| `acli-pii not found` | Install acli-pii and make sure it is on your `PATH`, then Refresh |
| `Not logged in to Jira` | Run `acli-pii jira auth login`, then Refresh |
| `no open sprint found` | Check the project key (`-Project`) |
| acli-pii failed. Error: unnown flag: --project | Update acli-pii to the latest version, then Refresh |

## Building the exe

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-ps2exe -inputFile SprintTray.ps1 -outputFile SprintTray.exe -noConsole -STA -title SprintTray
```

The script can also be run directly without building: `SprintTray.vbs`.
