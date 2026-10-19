@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SpotifyUpdateLock.ps1" %*
exit /b %errorlevel%
