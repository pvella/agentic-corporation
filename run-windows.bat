@echo off
REM Double-click on Windows: starts the event bridge and opens the Godot client.
REM Extra harness flags: run-windows.bat --mode live
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-windows.ps1" %*
exit /b %ERRORLEVEL%
