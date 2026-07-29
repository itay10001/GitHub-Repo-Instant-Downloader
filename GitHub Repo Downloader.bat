@echo off
setlocal

set "APP_DIR=%~dp0resources\app"
set "SCRIPT=%APP_DIR%\github_repo_download_finder.ps1"
set "WINDOW_TITLE=GitHub Repo Downloader"

if not exist "%SCRIPT%" (
    echo Missing app file:
    echo %SCRIPT%
    echo.
    echo Keep this launcher in the same folder as the resources folder.
    echo.
    pause
    exit /b 1
)

start "%WINDOW_TITLE%" /D "%~dp0" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%SCRIPT%" %*
