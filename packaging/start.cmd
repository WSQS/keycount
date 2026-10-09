@echo off
rem keycount pet launcher - record the window that owns the keyboard, then start the pet.
rem ASCII-only on purpose: cmd.exe misparses a file that mixes LF endings with non-ASCII.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
if errorlevel 1 pause
