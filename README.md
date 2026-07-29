# GitHub Repo Download Finder

GitHub Repo Download Finder is a small Windows-friendly tool that answers the annoying question:

> "Where do I actually download this GitHub project?"

Paste any public GitHub repo URL and it shows clear download links, available versions, and the latest release notes.

It can find:

- Latest release assets.
- Source-code ZIP/TAR links.
- Older releases and tags.
- What's new in the latest release, using GitHub release notes first and common changelog files as a fallback.
- One best download URL for shortcut/automation use.
- Plain-language download labels, such as Windows 64-bit installer, portable version, ARM64 build, or source code for developers.
- A recommended download when the release has confusing asset names.

The main version is a dependency-free PowerShell script for Windows. A Python version is included as a portable backup.

## Why

GitHub is great for developers, but normal download paths can be confusing. Sometimes you need a release asset. Sometimes there are only tags. Sometimes there are no releases at all and you just need the default branch ZIP.

This tool checks those paths for you and puts the useful choices in one terminal menu.

## Install The Ctrl+Alt+G Hotkey

For the normal Windows install, double-click:

```text
Install.bat
```

Do not double-click PowerShell scripts; Windows may open `.ps1` files in Notepad. If you prefer PowerShell, run this from the extracted folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\install.ps1
```

The installer:

- Checks whether AutoHotkey v2 is installed.
- Installs AutoHotkey with `winget` if it is missing.
- Copies the app to `%LOCALAPPDATA%\GitHubRepoDownloadFinder`.
- Registers a Startup shortcut so the hotkey is available after reboot.
- Starts the hotkey immediately.

After setup, copy or select a GitHub repo URL, then press:

```text
Ctrl+Alt+G
```

The hotkey checks the clipboard first. If the clipboard does not contain a GitHub repo URL, it checks the currently selected text.

To use a different AutoHotkey hotkey string:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\install.ps1 -Hotkey "^!d"
```

To uninstall the hotkey and installed app copy:

```text
Uninstall.bat
```

Or from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\uninstall.ps1
```

## Run It

On Windows, double-click the main app file. It opens a terminal window, then asks for the GitHub repo URL:

```bat
GitHub Repo Downloader.bat
```

Or run the PowerShell script directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\app\github_repo_download_finder.ps1
```

Then paste a repo URL such as:

```text
https://github.com/psf/requests
```

## Share It

For Windows users, send/download the whole folder. They only need to open:

```bat
GitHub Repo Downloader.bat
```

For the full hotkey experience, tell them to run:

```text
Install.bat
```

The files inside `resources` are the background machinery, so they should stay in the folder but your friends do not need to open them.

You can also pass the repo directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\app\github_repo_download_finder.ps1 https://github.com/psf/requests
```

## Useful Commands

Show summary and latest download links without the menu:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\app\github_repo_download_finder.ps1 owner/repo -NoMenu
```

Show downloadable versions:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\app\github_repo_download_finder.ps1 owner/repo -Versions
```

Show what's new in the latest release:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\app\github_repo_download_finder.ps1 owner/repo -Notes
```

Download the recommended latest file into `downloads`:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\app\github_repo_download_finder.ps1 owner/repo -DownloadLatest
```

Same instant download, with a clearer name:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\app\github_repo_download_finder.ps1 owner/repo -QuickDownload
```

Print only one URL for shortcuts/automation:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\app\github_repo_download_finder.ps1 owner/repo -BestUrl
```

Pick a different output folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\app\github_repo_download_finder.ps1 owner/repo -DownloadLatest -OutputDir "C:\Users\gilad\Downloads"
```

## Private Repos And Rate Limits

Public repos usually work without setup. Unauthenticated GitHub API requests are limited much more tightly than authenticated requests, so frequent testing can hit the limit.

For private repos or higher GitHub API rate limits, run the auth helper once:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\auth.ps1
```

It prompts for a GitHub token inside PowerShell and saves it encrypted for your Windows user at `%LOCALAPPDATA%\GitHubRepoDownloadFinder\github_token.securestring`. Use the least permissions possible: public repo/rate-limit use does not need write access, and private repos only need read-only access to the repos you want. Do not paste tokens into chat or commit them to GitHub.

If you are running from old Command Prompt and paste does not work, copy the token from GitHub and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\auth.ps1 -FromClipboard
```

To remove the saved token:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\auth.ps1 -Clear
```

Advanced users can also set `GITHUB_TOKEN` for the current terminal session, or sign in with the GitHub CLI. The app checks for auth in this order: `GITHUB_TOKEN`, saved token from `resources\auth.ps1`, then `gh auth token`.

To check authentication without printing your token:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\app\github_repo_download_finder.ps1 -AuthStatus
```

## Python Version

There is also a cross-platform Python version:

```powershell
python .\resources\app\github_repo_download_finder.py owner/repo --no-menu
python .\resources\app\github_repo_download_finder.py owner/repo --best-url
```

## Safety

- The tool reads public GitHub repository metadata through GitHub's API.
- The app itself does not install anything automatically.
- `resources\install.ps1` can install AutoHotkey v2 with `winget` if AutoHotkey is missing.
- The hotkey script reads the clipboard and selected text only when you press the configured hotkey.
- It downloads files only when you choose a download action.
- For private repos or higher API limits, you can provide your own `GITHUB_TOKEN` environment variable.

## Notes

Some repositories do not publish GitHub releases. In that case the script falls back to tags, then the default branch ZIP link.

If a release has no app binaries and only source code or support files, the picker warns you. Source code downloads are useful for developers, but they usually are not the app a normal Windows user wants.

The "what's new" view checks the latest GitHub release notes first. If those are empty or missing, it looks for common files such as `CHANGELOG.md`, `CHANGES.md`, and `RELEASES.md`.

## License

MIT
