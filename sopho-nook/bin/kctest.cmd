@echo off
REM keycount verification entry (Windows side). The nook's scripts are bash, so this
REM just locates Git Bash and delegates the whole run to bin/kctest.
REM
REM KEEP THIS FILE ASCII-ONLY. cmd.exe desyncs on LF line endings combined with
REM non-ASCII bytes, and then executes tails of real code lines as commands.
set "BASH=C:\Program Files\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=C:\Program Files (x86)\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=C:\Program Files\Git\usr\bin\bash.exe"
if not exist "%BASH%" (
  echo kctest: Git Bash not found. Install Git for Windows, or run bin/kctest in any bash. 1>&2
  exit /b 2
)
for %%I in ("%~dp0..") do set "NOOK=%%~fI\"
"%BASH%" "%NOOK%bin/kctest" %*
exit /b %ERRORLEVEL%
