@echo off
rem Lanceur de recevoir-guide.ps1, pour un double-clic (decision 017).
rem -ExecutionPolicy Bypass leve le refus des scripts pour CE seul lancement, sans modifier les reglages du systeme.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0recevoir-guide.ps1" %*
set CODE=%ERRORLEVEL%
echo.
pause
exit /b %CODE%
