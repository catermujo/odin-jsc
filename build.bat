@echo off
setlocal

rem DUMBAI: keep a vendor-root Windows build entrypoint so JSC matches other vendor package conventions.
set SCRIPT_DIR=%~dp0

if defined PYTHON (
    set PYTHON_BIN=%PYTHON%
) else (
    set PYTHON_BIN=python
)

"%PYTHON_BIN%" "%SCRIPT_DIR%scripts\build_cjsc.py" %*
exit /b %ERRORLEVEL%
