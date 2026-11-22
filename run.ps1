# AuditorTI - execucao direta pelo GitHub (sem pendrive e sem instalar)
# Abra o PowerShell e cole:
#   irm https://raw.githubusercontent.com/Strikedio/Auditor-de-TI/main/run.ps1 | iex
& {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $url = 'https://raw.githubusercontent.com/Strikedio/Auditor-de-TI/main/src/AuditorTI.ps1'
    $dir = Join-Path $env:TEMP 'AuditorTI'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $arq = Join-Path $dir 'AuditorTI.ps1'
    Write-Host 'Baixando o AuditorTI do GitHub...' -ForegroundColor Cyan
    try { Invoke-WebRequest -Uri $url -OutFile $arq -UseBasicParsing -ErrorAction Stop }
    catch { Write-Host "Falha no download: $($_.Exception.Message)" -ForegroundColor Red; return }
    Unblock-File $arq -ErrorAction SilentlyContinue
    Write-Host 'Abrindo o AuditorTI (confirme a permissao de Administrador)...' -ForegroundColor Cyan
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$arq`"" -Verb RunAs
}
