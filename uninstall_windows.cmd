@echo off
setlocal
call "%~dp0install_windows.cmd" --uninstall %*
exit /b %errorlevel%
