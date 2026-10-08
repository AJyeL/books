@echo off
rem Lanceur de rapatrier-sauvegarde.ps1, pour un double-clic (decision 009).
rem -ExecutionPolicy Bypass leve le refus des scripts pour CE seul lancement, sans modifier les reglages du systeme.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0rapatrier-sauvegarde.ps1" %*
set CODE=%ERRORLEVEL%
echo.
pause
exit /b %CODE%
