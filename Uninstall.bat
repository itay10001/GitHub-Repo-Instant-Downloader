@echo off
setlocal

set "SCRIPT=%~dp0resources\uninstall.ps1"

if not exist "%SCRIPT%" (
    echo Missing uninstall script:
    echo %SCRIPT%
    echo.
    echo Keep this uninstaller in the same folder as the resources folder.
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
