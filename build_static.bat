@echo off
setlocal

rem DUMBAI: JSC currently ships shared artifacts only; keep build_static as a naming-compatible alias.
call "%~dp0build.bat" %*
exit /b %ERRORLEVEL%
