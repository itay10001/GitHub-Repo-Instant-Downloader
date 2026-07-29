@echo off
setlocal

set "SCRIPT=%~dp0uninstall.ps1"

if not exist "%SCRIPT%" (
    echo Missing uninstall script:
    echo %SCRIPT%
    echo.
    echo Keep this uninstaller in the same folder as uninstall.ps1.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "EXITCODE=%ERRORLEVEL%"
echo.

if not "%EXITCODE%"=="0" (
    echo Uninstall failed. Exit code: %EXITCODE%
    echo.
    pause
    exit /b %EXITCODE%
)

echo Uninstall finished.
echo.
pause
exit /b 0
