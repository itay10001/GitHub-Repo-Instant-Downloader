param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "GitHubRepoDownloadFinder")
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host "==> $Message"
}

function Get-StartupShortcutPath {
    $startupDir = [Environment]::GetFolderPath("Startup")
    return (Join-Path $startupDir "GitHub Repo Download Finder Hotkey.lnk")
}

function Assert-SafeInstallDir([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA)

    if (-not $resolved.StartsWith($localAppData, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a folder outside LOCALAPPDATA: $resolved"
    }
    if ($resolved.Length -le ($localAppData.Length + 5)) {
        throw "Refusing to remove a broad folder: $resolved"
    }

    return $resolved
}

function Stop-HotkeyScript([string]$HotkeyScript) {
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        return
    }

    $processes = Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match "^AutoHotkey(64|32|UX)?\.exe$" -and
            $_.CommandLine -and
            $_.CommandLine.IndexOf($HotkeyScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }

    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

$resolvedInstallDir = Assert-SafeInstallDir $InstallDir
$hotkeyScript = Join-Path $resolvedInstallDir "hotkey\github_repo_download_finder_hotkey.ahk"
$shortcutPath = Get-StartupShortcutPath

Write-Step "Stopping hotkey script if it is running"
Stop-HotkeyScript $hotkeyScript

if (Test-Path -LiteralPath $shortcutPath) {
    Write-Step "Removing startup shortcut"
    Remove-Item -LiteralPath $shortcutPath -Force
}

if (Test-Path -LiteralPath $resolvedInstallDir) {
    Write-Step "Removing installed files"
    Remove-Item -LiteralPath $resolvedInstallDir -Recurse -Force
}

Write-Host ""
Write-Host "Uninstalled GitHub Repo Download Finder hotkey."
