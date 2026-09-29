@echo off
REM Project-local nvim (Windows side). Same isolation as bin/nvim-local: every XDG_*
REM variable points inside this nook. nvim on Windows honours XDG_* ("are used if
REM defined"), so this is the same design with different syntax.
REM
REM KEEP THIS FILE ASCII-ONLY. cmd.exe desyncs on LF line endings combined with
REM non-ASCII bytes, and then executes tails of real code lines as commands.
for %%I in ("%~dp0..") do set "NOOK=%%~fI\"
for %%K in (config data state cache run) do if not exist "%NOOK%.nvim\xdg\%%K" mkdir "%NOOK%.nvim\xdg\%%K"
set "XDG_CONFIG_HOME=%NOOK%.nvim\xdg\config"
set "XDG_DATA_HOME=%NOOK%.nvim\xdg\data"
set "XDG_STATE_HOME=%NOOK%.nvim\xdg\state"
set "XDG_CACHE_HOME=%NOOK%.nvim\xdg\cache"
set "XDG_RUNTIME_DIR=%NOOK%.nvim\xdg\run"
nvim -u "%NOOK%nvim\init.lua" %*
exit /b %ERRORLEVEL%
