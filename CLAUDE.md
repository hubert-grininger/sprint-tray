# SprintTray

Windows tray app (PowerShell 5.1 + WinForms) that shows the current Jira sprint number as
the tray icon, with a progress line underneath: green = time left, red = time elapsed.
Hover shows sprint name, end date, days left and % elapsed.

There is also a macOS menu bar version in `mac/` (Swift, see `mac/README.md`, `mac/build.sh`).

## Files

- `SprintTray.ps1` — the whole Windows app. Single source of truth.
- `SprintTray.vbs` — runs the `.ps1` hidden without building (`powershell -STA -File ...`).
- `SprintTray.exe` — built from the `.ps1` with ps2exe. Git-ignored, rebuild after changes.
- `README.md` — user-facing docs: requirements, usage, autostart, troubleshooting, build.
- `mac/` — macOS port: `Sources/main.swift`, `Info.plist`, `build.sh` (universal app + dmg).

## How it works

- Reads sprints by running `acli-pii jira sprint list --project <P> --state active --json`.
  The app holds no Jira credentials; auth is the user's `acli-pii jira auth login` session.
- Picks the sprint whose name matches `Sprint \d+`, falling back to any active sprint, and
  takes the most recent by start date (skips long-running planning buckets).
- `Update-Tray` computes progress from start/end dates, builds the icon, and sets the tooltip
  (max 63 chars). It runs on a timer every `-RefreshMinutes` and on Refresh.
- Errors: a red `?` icon is shown, plus a balloon tip once per distinct error. The "Help /
  status" menu item shows the message and setup steps (`$setupHelp`).
- Single instance via the named mutex `Local\SprintTray`; a second start exits immediately.
- Parameters: `-Project` (default `APPOBS`), `-RefreshMinutes` (default `60`).

## Key functions in `SprintTray.ps1`

- `Get-ActiveSprint` — calls acli-pii, parses JSON, chooses the sprint. Throws user-readable
  messages (`acli-pii not found`, `Not logged in to Jira`, no sprint found).
- `New-TextIcon` — draws the sprint number as a 32x32 glyph (scaled outline via
  `GraphicsPath`) plus the progress bar, returns an `Icon`.
- `Get-TextColor` — picks the glyph color from the Windows taskbar theme
  (`HKCU:\...\Themes\Personalize\SystemUsesLightTheme`): white on dark taskbar, dark blue on
  light. Read on every refresh, so theme changes apply at the next refresh.
- `Update-Tray` — the refresh path; builds the icon, sets tooltip, disposes the old icon.
- `Show-Help` — status / setup message box.

## Conventions

- Keep it a single PowerShell script with no external modules; it must run on Windows
  PowerShell 5.1 (hence the `ForEach-Object` unrolling and no `??`/ternary syntax).
- Match the existing style: short comments that explain *why*, `$script:` for shared state,
  `try/catch` in `Update-Tray` mapping errors to the `?` icon.
- Colors: progress track green `(30,160,60)`, elapsed red `(200,30,30)`, error glyph red
  `(190,40,40)`. Keep the progress bar readable on both light and dark taskbars.

## Build and test

```powershell
Import-Module ps2exe   # Install-Module ps2exe -Scope CurrentUser  (once)
Invoke-ps2exe -inputFile SprintTray.ps1 -outputFile SprintTray.exe -noConsole -STA -title SprintTray
```

- Quit the running tray app first (right-click → Exit, or stop the process), otherwise the
  build fails with "Access to the path ... is denied".
- Syntax check without running:
  `[System.Management.Automation.Language.Parser]::ParseFile(...)`.
- Run from source for quick testing: `SprintTray.vbs` (no build needed).
- There are no automated tests; verify by running the app and checking the icon, tooltip,
  error path (e.g. rename `acli-pii` off PATH → red `?`), and the Help message.

## Gotchas

- New tray icons are hidden behind the taskbar "^" overflow by default; mention this when
  users say the icon is missing.
- Single-instance mutex: if a stale process is running, new builds won't take effect until it
  is stopped.
- Error messages are built from acli-pii's stderr with non-ASCII stripped; keep the
  `auth|login|401|...` matching in `Get-ActiveSprint` in sync with what acli-pii prints.
- Git: `main` is the default branch; the exe and `mac/build/` are ignored.
