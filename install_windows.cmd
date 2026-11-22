@echo off
setlocal
where py >nul 2>nul
if errorlevel 1 goto python
py -3.12 -c "import sys" >nul 2>nul
if errorlevel 1 goto python
py -3.12 "%~dp0install.py" %*
exit /b %errorlevel%

:python
python "%~dp0install.py" %*
exit /b %errorlevel%
