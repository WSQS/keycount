@echo off
REM Project-local pi (Windows side): config/sessions/credentials/trust go into
REM <nook>\.agent\, and this project's skills are passed explicitly with --skill.
REM
REM PI_OFFLINE is deliberately NOT set here: Windows usually has no fd/fdfind and an
REM offline pi cannot download it, which makes its find tool fail outright. Without
REM the flag pi fetches fd into <nook>\.agent\bin\ (still inside the project).
REM
REM KEEP THIS FILE ASCII-ONLY (see nvim-local.cmd for why).
for %%I in ("%~dp0..") do set "NOOK=%%~fI\"
if not exist "%NOOK%.agent" mkdir "%NOOK%.agent"
set "PI_CODING_AGENT_DIR=%NOOK%.agent"
if "%PI_SKIP_VERSION_CHECK%"=="" set "PI_SKIP_VERSION_CHECK=1"
if not exist "%NOOK%agents\skills" echo pi-local: warning -- skills directory not found: %NOOK%agents\skills 1>&2

REM Role description (policy, tracked in git). pi's --append-system-prompt accepts
REM a path to an existing file and inlines its contents as text.
set "HAS_ROLE="
set "ROLE_ARG="
if exist "%NOOK%agents\ROLE.md" set "HAS_ROLE=1"
if exist "%NOOK%agents\ROLE.md" set "ROLE_ARG=--append-system-prompt "%NOOK%agents\ROLE.md""
if not defined HAS_ROLE echo pi-local: warning -- role description not found: %NOOK%agents\ROLE.md 1>&2

call pi --skill "%NOOK%agents\skills" %ROLE_ARG% %*
exit /b %ERRORLEVEL%
