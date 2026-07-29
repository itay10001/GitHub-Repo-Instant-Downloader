param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "GitHubRepoDownloadFinder"),
    [string]$Hotkey = "^!g",
    [switch]$SkipAutoHotkeyInstall,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host "==> $Message"
}

function Get-ProjectRoot {
    $root = $PSScriptRoot
    if (-not $root) {
        $root = (Get-Location).Path
    }
    return $root
}

function Find-AutoHotkey {
    $commandNames = @(
        "AutoHotkey64.exe",
        "AutoHotkey.exe",
        "AutoHotkeyUX.exe"
    )

    foreach ($name in $commandNames) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and (Test-Path -LiteralPath $command.Source)) {
            return $command.Source
        }
    }

    $candidates = @()
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $root) {
            continue
        }

        if ($root -eq $env:LOCALAPPDATA) {
            $candidates += Join-Path $root "Programs\AutoHotkey\v2\AutoHotkey64.exe"
            $candidates += Join-Path $root "Programs\AutoHotkey\AutoHotkey64.exe"
        }
        else {
            $candidates += Join-Path $root "AutoHotkey\v2\AutoHotkey64.exe"
            $candidates += Join-Path $root "AutoHotkey\AutoHotkey64.exe"
        }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Install-AutoHotkey {
    if ($SkipAutoHotkeyInstall) {
        throw "AutoHotkey was not found. Re-run setup without -SkipAutoHotkeyInstall, or install AutoHotkey v2 manually."
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "AutoHotkey was not found, and winget is not available. Install AutoHotkey v2, then run this setup again."
    }

    Write-Step "AutoHotkey not found. Installing AutoHotkey v2 with winget"
    $arguments = @(
        "install",
        "--id", "AutoHotkey.AutoHotkey",
        "--exact",
        "--source", "winget",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )

    $process = Start-Process -FilePath $winget.Source -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "winget could not install AutoHotkey. Exit code: $($process.ExitCode)"
    }
}

function Copy-AppFiles([string]$SourceRoot, [string]$TargetRoot) {
    New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null

    $items = @(
        "app",
        "hotkey",
        "Install.bat",
        "Uninstall.bat",
        "GitHub Repo Downloader.bat",
        "auth.ps1",
        "README.md",
        "LICENSE"
    )

    foreach ($item in $items) {
        $source = Join-Path $SourceRoot $item
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Missing required project file or folder: $source"
        }

        $target = Join-Path $TargetRoot $item
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
    }
}

function Write-HotkeyConfig([string]$TargetRoot, [string]$HotkeyValue) {
    $hotkeyDir = Join-Path $TargetRoot "hotkey"
    New-Item -ItemType Directory -Path $hotkeyDir -Force | Out-Null

    $configPath = Join-Path $hotkeyDir "github_repo_download_finder_hotkey.ini"
    $content = @(
        "[Settings]",
        "Hotkey=$HotkeyValue"
    )
    Set-Content -LiteralPath $configPath -Value $content -Encoding ASCII
    return $configPath
}

function New-StartupShortcut([string]$AhkPath, [string]$HotkeyScript) {
    $startupDir = [Environment]::GetFolderPath("Startup")
    $shortcutPath = Join-Path $startupDir "GitHub Repo Download Finder Hotkey.lnk"

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $AhkPath
    $shortcut.Arguments = "`"$HotkeyScript`""
    $shortcut.WorkingDirectory = Split-Path -Parent $HotkeyScript
    $shortcut.IconLocation = $AhkPath
    $shortcut.Description = "GitHub Repo Download Finder hotkey"
    $shortcut.Save()

    return $shortcutPath
}

function Start-HotkeyScript([string]$AhkPath, [string]$HotkeyScript) {
    Start-Process -FilePath $AhkPath -ArgumentList @("`"$HotkeyScript`"") | Out-Null
}

$projectRoot = Get-ProjectRoot
$mainScript = Join-Path $projectRoot "app\github_repo_download_finder.ps1"
$hotkeySource = Join-Path $projectRoot "hotkey\github_repo_download_finder_hotkey.ahk"

if (-not (Test-Path -LiteralPath $mainScript)) {
    throw "Run this setup from the GitHub Repo Download Finder project folder."
}
if (-not (Test-Path -LiteralPath $hotkeySource)) {
    throw "Hotkey script is missing: $hotkeySource"
}
if (-not $Hotkey.Trim()) {
    throw "-Hotkey cannot be empty."
}

$autoHotkeyPath = Find-AutoHotkey
if (-not $autoHotkeyPath) {
    Install-AutoHotkey
    $autoHotkeyPath = Find-AutoHotkey
}
if (-not $autoHotkeyPath) {
    throw "AutoHotkey still was not found after installation."
}

Write-Step "Installing app files to $InstallDir"
Copy-AppFiles $projectRoot $InstallDir

$hotkeyScript = Join-Path $InstallDir "hotkey\github_repo_download_finder_hotkey.ahk"
Write-HotkeyConfig $InstallDir $Hotkey | Out-Null

Write-Step "Registering startup hotkey: $Hotkey"
$shortcutPath = New-StartupShortcut $autoHotkeyPath $hotkeyScript

if (-not $NoStart) {
    Write-Step "Starting hotkey script"
    Start-HotkeyScript $autoHotkeyPath $hotkeyScript
}

Write-Host ""
Write-Host "Installed GitHub Repo Download Finder."
Write-Host "Hotkey:          $Hotkey"
Write-Host "Installed files: $InstallDir"
Write-Host "Startup link:    $shortcutPath"
Write-Host ""
Write-Host "Try it: copy or select a GitHub repo URL, then press the configured hotkey."
