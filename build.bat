@echo off
setlocal

rem DUMBAI: keep a vendor-root Windows build entrypoint so JSC matches other vendor package conventions.
set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR:~0,-1%

rem DUMBAI: Ensure Scoop-managed toolchains are visible even when build.bat is launched
rem outside a user shell profile.
set SCOOP_ROOT=%USERPROFILE%\scoop
call :append_path "%SCOOP_ROOT%\shims"
call :append_path "%SCOOP_ROOT%\apps\ruby\current\bin"
call :append_path "%SCOOP_ROOT%\apps\llvm\current\bin"
call :append_path "%SCOOP_ROOT%\apps\perl\current\perl\bin"
call :append_path "%SCOOP_ROOT%\apps\git\current\cmd"
call :append_path "%SCOOP_ROOT%\apps\ninja\current"
call :append_path "%SCOOP_ROOT%\apps\cmake\current\bin"
rem DUMBAI: WebKit Win configure requires host gperf; expose the Scoop vcpkg
rem tool install so FindGperf succeeds without manual PATH setup.
call :append_path "%SCOOP_ROOT%\apps\vcpkg\current\installed\x64-windows\tools\gperf"

if not defined VCPKG_ROOT (
    rem DUMBAI: Keep vcpkg selection stable across shells by preferring the repo
    rem workstation's Scoop-managed installation.
    if exist "%SCOOP_ROOT%\apps\vcpkg\current\vcpkg.exe" (
        set VCPKG_ROOT=%SCOOP_ROOT%\apps\vcpkg\current
    )
)

if /i "%VSCMD_ARG_TGT_ARCH%" neq "x64" (
    call :init_vs
    if errorlevel 1 (
        echo [jsc build] Visual Studio developer environment initialization failed.
        exit /b 1
    )
)

where clang-cl >nul 2>nul
if not errorlevel 1 (
    rem DUMBAI: Current WebKit Win port expects clang-cl flags/runtime; force
    rem clang-cl so CMake can locate clang_rt.builtins and configure shared JSC.
    set CC=clang-cl
    set CXX=clang-cl
)

if defined PYTHON (
    set PYTHON_BIN=%PYTHON%
) else (
    set PYTHON_BIN=python
)

rem DUMBAI: Always execute from vendor/jsc so relative paths and cloned WebKit checkout
rem behavior remain consistent across callers.
pushd "%ROOT_DIR%"
"%PYTHON_BIN%" "%SCRIPT_DIR%scripts\build_cjsc.py" %*
set BUILD_RC=%ERRORLEVEL%
popd
exit /b %BUILD_RC%

:append_path
if not exist "%~1" exit /b 0
set "PATH=%~1;%PATH%"
exit /b 0

:init_vs
rem DUMBAI: Prefer the full Community installation, then fall back to BuildTools, so
rem vcpkg compiler detection works without requiring a pre-opened Developer Prompt.
set VCVARS64=
for %%I in (
    "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
) do (
    if not defined VCVARS64 if exist %%~I set VCVARS64=%%~I
)
if not defined VCVARS64 (
    exit /b 1
)
call "%VCVARS64%"
if errorlevel 1 (
    exit /b 1
)
exit /b 0
