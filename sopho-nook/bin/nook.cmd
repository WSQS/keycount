@echo off
REM Enter the nook (no arguments): opens the project-local nvim and shows the file picker.
REM From inside nvim everything else happens too: <leader>f files, <leader>t verify,
REM <leader>a pi, <leader>g lazygit, <leader>? keymaps.
REM
REM KEEP THIS FILE ASCII-ONLY (see nvim-local.cmd for why).
if not "%~1"=="" (
  echo Usage: nook.cmd          ^(no arguments: enter the picker^) 1>&2
  echo        To open one file directly use bin\nvim-local.cmd ^<file^> 1>&2
  exit /b 2
)
for %%I in ("%~dp0..") do set "NOOK=%%~fI\"
call "%NOOK%bin\nvim-local.cmd" -c "lua require('kc').pick()"
exit /b %ERRORLEVEL%
