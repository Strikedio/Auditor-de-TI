@echo off
REM Executa o AuditorTI pelo script PowerShell (sem precisar do .exe)
REM O programa pede permissao de Administrador automaticamente.
set "SCRIPT=%~dp0AuditorTI.ps1"
if exist "%~dp0src\AuditorTI.ps1" set "SCRIPT=%~dp0src\AuditorTI.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%"
