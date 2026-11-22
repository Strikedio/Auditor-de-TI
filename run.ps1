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
    try { Invoke-WebRequest -Uri ($url + '?t=' + [guid]::NewGuid().ToString('N')) -OutFile $arq -UseBasicParsing -ErrorAction Stop }
    catch { Write-Host "Falha no download: $($_.Exception.Message)" -ForegroundColor Red; return }
    Unblock-File $arq -ErrorAction SilentlyContinue
    $erros = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($arq, [ref]$null, [ref]$erros)
    if ($erros) {
        Write-Host 'O arquivo baixado tem erros e nao pode ser aberto:' -ForegroundColor Red
        $erros | ForEach-Object { Write-Host ("  linha {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red }
        return
    }
    Write-Host 'Abrindo o AuditorTI (confirme a permissao de Administrador)...' -ForegroundColor Cyan
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$arq`"" -Verb RunAs
}
