@echo off
setlocal

set "APP_DIR=%~dp0app"
set "SCRIPT=%APP_DIR%\github_repo_download_finder.ps1"
set "WINDOW_TITLE=GitHub Repo Downloader"

if not exist "%SCRIPT%" (
    echo Missing app file:
    echo %SCRIPT%
    echo.
    echo Keep this launcher in the same folder as the app folder.
    echo.
    pause
    exit /b 1
)

where wt.exe >nul 2>nul
if %errorlevel%==0 (
    start "" wt.exe new-tab --title "%WINDOW_TITLE%" -d "%~dp0" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%SCRIPT%" %*
) else (
    start "%WINDOW_TITLE%" /D "%~dp0" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%SCRIPT%" %*
)
