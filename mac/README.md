# SprintTray for macOS

Shows the current Jira sprint number in the menu bar, with a progress line underneath
(green = time left in the sprint, red = elapsed).

> **Build the dmg first.** There is no prebuilt download for macOS. On a Mac with Xcode
> Command Line Tools (`xcode-select --install`), run this in the `mac` folder:
>
> ```
> bash build.sh
> ```
>
> It produces `build/SprintTray.dmg` (universal: Apple Silicon + Intel). Then follow
> [Install](#install) below.

## Requirements

- macOS 13 (Ventura) or newer
- **acli-pii** (Atlassian CLI with PII redaction) installed, e.g. in `~/.local/bin`
  (also found in `/opt/homebrew/bin`, `/usr/local/bin`)
- A logged-in acli-pii session:

  ```
  acli-pii jira auth login
  acli-pii jira sprint list --project APPOBS --state active
  ```

SprintTray has no Jira credentials of its own; it calls `acli-pii` with your login.

## Install

1. Open `SprintTray.dmg` and drag **SprintTray** into **Applications**.
2. The app is not notarized, so the first start is blocked by Gatekeeper. Either
   right-click SprintTray in Applications → **Open** → **Open**, or run:

   ```
   xattr -dr com.apple.quarantine /Applications/SprintTray.app
   ```

3. Enable **Start at Login** in the SprintTray menu.

## Usage

Click the sprint number in the menu bar: sprint info, Refresh, Copy Sprint Name,
Help / Status, Start at Login, Quit. Starting it a second time does nothing.

Settings (then Quit and restart SprintTray):

```
defaults write com.dynatrace.sprinttray project XYZ
defaults write com.dynatrace.sprinttray refreshMinutes 30
```

Defaults: project `APPOBS`, refresh every 60 minutes.

## Troubleshooting

A red **?** means the sprint could not be read; a dialog shows the reason and the setup steps.

| Message | Fix |
|---|---|
| `acli-pii not found` | Install acli-pii in one of the locations above, then Refresh |
| `Not logged in to Jira` | Run `acli-pii jira auth login`, then Refresh |
| `no open sprint found` | Check the project key (`defaults write ... project`) |
| `acli-pii failed. Error: unnown flag: --project`| Update acli-pii to the latest version, then Refresh | 
