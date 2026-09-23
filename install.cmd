@echo off
rem Double-click launcher for install.ps1 (per-user install, see README.md).
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set LOCALAGENT_RC=%ERRORLEVEL%
echo %* | findstr /i /c:"-NonInteractive" >nul || pause
exit /b %LOCALAGENT_RC%
