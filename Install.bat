@echo off
setlocal

set "SCRIPT=%~dp0resources\install.ps1"

if not exist "%SCRIPT%" (
    echo Missing setup script:
    echo %SCRIPT%
    echo.
    echo Keep this installer in the same folder as the resources folder.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "EXITCODE=%ERRORLEVEL%"
echo.

if not "%EXITCODE%"=="0" (
    echo Setup failed. Exit code: %EXITCODE%
    echo.
    pause
    exit /b %EXITCODE%
)

echo Setup finished. You can now copy or select a GitHub repo URL and press Ctrl+Alt+G.
echo.
pause
exit /b 0
