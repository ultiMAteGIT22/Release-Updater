@echo off
rem Double-click to start the updater (no console window left open).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Update-Releases.ps1"
