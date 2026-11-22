# =====================================================================
#  Gera os pacotes do AuditorTI na pasta dist\
#    - AuditorTI.exe                       (executável)
#    - AuditorTI-Portatil-<versão>.zip     (para o pendrive)
#    - AuditorTI-Setup-<versão>.exe        (instalador - requer Inno Setup 6)
#  Uso local: botão direito > "Executar com o PowerShell"
#  Também é usado automaticamente pelo GitHub Actions.
# =====================================================================
param([string]$Versao = '')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$raiz = Split-Path $PSScriptRoot -Parent
$src = Join-Path $raiz 'src\AuditorTI.ps1'
$dist = Join-Path $raiz 'dist'

try {
    if (-not $Versao) { $Versao = [regex]::Match((Get-Content $src -Raw -Encoding UTF8), "VersaoApp = '([\d\.]+)'").Groups[1].Value }
    $Versao = $Versao.TrimStart('v')
    Write-Host "AuditorTI versão $Versao" -ForegroundColor Cyan
    if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
    New-Item -ItemType Directory -Path $dist -Force | Out-Null

    # --- 1. Executável (ps2exe) ---
    if (-not (Get-Module -ListAvailable -Name ps2exe)) {
        Write-Host 'Instalando o módulo ps2exe...' -ForegroundColor Cyan
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module ps2exe
    $exe = Join-Path $dist 'AuditorTI.exe'
    $p = @{
        inputFile = $src; outputFile = $exe
        noConsole = $true; requireAdmin = $true; STA = $true
        title = 'AuditorTI'; description = 'Auditoria técnica de estações Windows'; product = 'AuditorTI'
        company = 'Samuel David Diniz Reis'; copyright = 'Samuel David Diniz Reis'; version = "$Versao.0"
    }
    $icone = Join-Path $raiz 'assets\icone.ico'
    if (Test-Path $icone) { $p.iconFile = $icone }
    Write-Host 'Compilando AuditorTI.exe...' -ForegroundColor Cyan
    Invoke-ps2exe @p
    if (-not (Test-Path $exe)) { throw 'O ps2exe não gerou o AuditorTI.exe.' }

    # --- 2. Pacote portátil (pendrive) ---
    Write-Host 'Montando pacote portátil...' -ForegroundColor Cyan
    $port = Join-Path $dist 'AuditorTI-Portatil'
    New-Item -ItemType Directory -Path $port -Force | Out-Null
    Copy-Item $exe $port
    Copy-Item $src $port
    Copy-Item (Join-Path $raiz 'LEIA-ME.txt') $port
    Copy-Item (Join-Path $raiz 'Executar.bat') $port
    Set-Content -Path (Join-Path $port 'portable.txt') -Value 'Este arquivo ativa o modo portátil: configurações e relatórios ficam nesta pasta.' -Encoding UTF8
    Compress-Archive -Path (Join-Path $port '*') -DestinationPath (Join-Path $dist "AuditorTI-Portatil-$Versao.zip") -Force

    # --- 3. Instalador (Inno Setup) ---
    $iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($iscc) {
        Write-Host 'Gerando instalador...' -ForegroundColor Cyan
        & $iscc "/DMyAppVersion=$Versao" (Join-Path $PSScriptRoot 'instalador.iss')
        if ($LASTEXITCODE -ne 0) { throw "Inno Setup terminou com erro ($LASTEXITCODE)." }
    }
    else { Write-Host 'Inno Setup 6 não encontrado: instalador não gerado (baixe em https://jrsoftware.org/isdl.php).' -ForegroundColor Yellow }

    Write-Host ''
    Write-Host "Pronto! Arquivos em: $dist" -ForegroundColor Green
    Get-ChildItem $dist -File | ForEach-Object { Write-Host "  $($_.Name)" }
}
catch {
    Write-Host "Erro: $($_.Exception.Message)" -ForegroundColor Red
    if ($env:CI) { exit 1 }
}
if (-not $env:CI) { Write-Host ''; Read-Host 'Pressione ENTER para fechar' }
