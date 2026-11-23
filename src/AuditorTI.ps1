<#
    =====================================================================
     AuditorTI - Auditoria técnica de estações Windows
     Desempenho • Segurança • Relatório auditável em PDF com papel timbrado
    ---------------------------------------------------------------------
     Autor ......: Samuel David Diniz Reis
     Requisitos .: Windows 10/11, PowerShell 5.1, executar como Administrador
     Compilação .: veja Compilar-EXE.ps1 (gera AuditorTI.exe com ps2exe)
    =====================================================================
#>
param(
    [switch]$SemInterface,      # executa todos os testes sem janela e gera o relatório
    [switch]$TestarInterface,   # abre a janela, salva um print e fecha (verificação)
    [string]$Cliente = 'Teste automatizado',
    [string]$Tecnico = '',
    [string]$Timbrado = '',
    [string]$Saida = '',
    [string]$Otimizar = '',     # (sem interface) ids das otimizações ou 'todos'
    [string]$Corrigir = '',     # (sem interface) ids dos reparos, separados por vírgula
    [switch]$Capturar           # (sem interface) faz a captura de pacotes no teste de rede
)

$Global:VersaoApp = '1.5.0'
$ErrorActionPreference = 'Continue'
try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction Stop } catch {}

$Global:TemGUI = $true
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()
}
catch { $Global:TemGUI = $false }

# Qualquer erro grave é mostrado na tela e gravado em %TEMP%\AuditorTI_erro.log
trap {
    $msg = "Erro inesperado no AuditorTI:`r`n`r`n$($_.Exception.Message)`r`n`r`nLinha $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line)"
    try { Add-Content -Path (Join-Path $env:TEMP 'AuditorTI_erro.log') -Value ("[{0}] {1}" -f (Get-Date), $msg) } catch {}
    if (-not $SemInterface -and $Global:TemGUI) { [System.Windows.Forms.MessageBox]::Show($msg, 'AuditorTI', 'OK', 'Error') | Out-Null }
    else { [Console]::Error.WriteLine($msg); exit 2 }
    continue
}

# ---------------------------------------------------------------------
# Exige privilégio de Administrador
# ---------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($PSCommandPath -and $PSCommandPath -like '*.ps1') {
        $fwd = ''
        foreach ($kv in $PSBoundParameters.GetEnumerator()) {
            if ($kv.Value -is [switch]) { if ($kv.Value) { $fwd += " -$($kv.Key)" } }
            else { $fwd += " -$($kv.Key) `"$($kv.Value)`"" }
        }
        $jan = if ($SemInterface) { 'Hidden' } else { 'Normal' }
        try { Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle $jan -File `"$PSCommandPath`"$fwd" -Verb RunAs }
        catch { [Console]::Error.WriteLine('Execute o AuditorTI como Administrador.') }
    }
    elseif ($Global:TemGUI) { [System.Windows.Forms.MessageBox]::Show('Execute o AuditorTI como Administrador (clique com o botão direito > Executar como administrador).', 'AuditorTI', 'OK', 'Warning') | Out-Null }
    else { [Console]::Error.WriteLine('Execute o AuditorTI como Administrador.') }
    exit
}

# ---------------------------------------------------------------------
# Detecção do sistema (cliente / servidor / Server Core) e compatibilidade
# ---------------------------------------------------------------------
$Global:SO = @{ Caption = ''; Build = 0; Server = $false; DC = $false; Core = $false; PSVer = $PSVersionTable.PSVersion.Major }
try {
    $osx = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $Global:SO.Caption = [string]$osx.Caption; $Global:SO.Build = [int]$osx.BuildNumber
    $Global:SO.Server = ([int]$osx.ProductType -ne 1); $Global:SO.DC = ([int]$osx.ProductType -eq 2)
    $it = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallationType -ErrorAction SilentlyContinue).InstallationType
    $Global:SO.Core = ([string]$it -match 'Core')
} catch {}

# ---------------------------------------------------------------------
# Estado global
# ---------------------------------------------------------------------
$Global:Sync = [hashtable]::Synchronized(@{ Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'; Atual = $null })
$Sync = $Global:Sync
$Global:Cfg = [hashtable]::Synchronized(@{})
$Global:Resultados = [ordered]@{}
$Global:Prints = @{}
$Global:Acoes = New-Object System.Collections.ArrayList
$Global:LogGeral = New-Object System.Collections.ArrayList
$Global:Inicio = $null
$Global:Fim = $null
$Global:IdAud = $null
$Global:Timbrado = $null
$Global:Rodando = $false
$Global:Cancelar = $false
$Global:FecharApos = $false
$Global:UltimaPasta = $null

# ---------------------------------------------------------------------
# Modo portátil (pendrive): se o programa estiver num pendrive, ou houver um
# arquivo 'portable.txt' ao lado dele, configurações, papel timbrado e
# relatórios ficam na própria pasta do programa. Caso contrário, usa
# %APPDATA%\AuditorTI e Documentos\AuditoriasTI.
# ---------------------------------------------------------------------
$Global:BaseDir = $PSScriptRoot
if (-not $Global:BaseDir) { $Global:BaseDir = [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }
$Global:Portatil = $false
try {
    $tipoDrv = (New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($Global:BaseDir))).DriveType
    if ((Test-Path (Join-Path $Global:BaseDir 'portable.txt')) -or [string]$tipoDrv -eq 'Removable') {
        $teste = Join-Path $Global:BaseDir ('.gravacao_' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($teste, 'ok'); Remove-Item $teste -Force
        $Global:Portatil = $true
    }
} catch { $Global:Portatil = $false }
if ($Global:Portatil) {
    $Global:CfgDir = Join-Path $Global:BaseDir 'dados'
    $Global:PastaRelatorios = Join-Path $Global:BaseDir 'Relatorios'
}
else {
    $Global:CfgDir = Join-Path $env:APPDATA 'AuditorTI'
    $Global:PastaRelatorios = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AuditoriasTI'
}
$Global:CfgArq = Join-Path $Global:CfgDir 'config.json'

# ---------------------------------------------------------------------
# Funções auxiliares (injetadas em cada teste, que roda em segundo plano)
# ---------------------------------------------------------------------
$Global:Helpers = @'
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Log([string]$m) { $Sync.Log.Enqueue(("{0:HH:mm:ss}  {1}" -f (Get-Date), $m)) }

function New-R {
    $r = @{
        Itens    = New-Object System.Collections.ArrayList
        Tabelas  = New-Object System.Collections.ArrayList
        Achados  = New-Object System.Collections.ArrayList
        Metricas = @{}
        Extra    = @{}
    }
    $Sync.Atual = $r
    return $r
}

function Add-Item($R, [string]$Item, $Valor, [string]$Status = 'Info') {
    [void]$R.Itens.Add([pscustomobject]@{ Item = $Item; Valor = [string]$Valor; Status = $Status })
}

function Add-Tabela($R, [string]$Titulo, $Linhas) {
    $arr = @($Linhas | Where-Object { $null -ne $_ })
    if ($arr.Count -gt 0) { [void]$R.Tabelas.Add(@{ Titulo = $Titulo; Linhas = $arr }) }
}

# Categoria: 'Desempenho' ou 'Segurança'  |  Severidade: Crítico, Alto, Médio, Baixo, Info
# Penalidade = pontos descontados da nota (0 a 10). Se omitida, usa a tabela padrão.
function Add-Achado($R, [string]$Cat, [string]$Sev, [string]$Texto, [string]$Rec, $Pen = $null, [switch]$Upgrade) {
    if ($null -eq $Pen) {
        $tab = @{ 'Crítico' = 2.5; 'Alto' = 1.2; 'Médio' = 0.5; 'Baixo' = 0.15; 'Info' = 0 }
        $Pen = $tab[$Sev]; if ($null -eq $Pen) { $Pen = 0 }
    }
    [void]$R.Achados.Add([pscustomobject]@{
        Categoria = $Cat; Severidade = $Sev; Achado = $Texto; Recomendacao = $Rec
        Penalidade = [double]$Pen; Upgrade = [bool]$Upgrade
    })
}

function GB($b) { if ($b) { [math]::Round([double]$b / 1GB, 1) } else { 0 } }
function SimNao($b) { if ($b) { 'Sim' } else { 'Não' } }
function Fmt($d) {
    if (-not $d) { return '-' }
    try { $x = [datetime]$d; if ($x.Year -lt 2001) { return '-' }; return $x.ToString('dd/MM/yyyy HH:mm') } catch { return [string]$d }
}
function Get-RegVal([string]$Path, [string]$Name) {
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

# Executa um programa de linha de comando sem abrir janela e devolve a saída
function Invoke-Cmd([string]$Exe, [string]$Argumentos, [int]$TimeoutMs = 120000, [switch]$Utf8) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe; $psi.Arguments = $Argumentos
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        if ($Utf8) { $psi.StandardOutputEncoding = [Text.Encoding]::UTF8 }
        else { $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
        $p = [Diagnostics.Process]::Start($psi)
        $tOut = $p.StandardOutput.ReadToEndAsync()
        $tErr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {} }
        [void]$tOut.Wait(10000); [void]$tErr.Wait(2000)
        $o = if ($tOut.IsCompleted) { [string]$tOut.Result } else { '' }
        $e = if ($tErr.IsCompleted) { [string]$tErr.Result } else { '' }
        $global:UltimoCodigo = if ($p.HasExited) { $p.ExitCode } else { -1 }
        return (($o + $e) -replace "`0", '')
    } catch { $global:UltimoCodigo = -1; return '' }
}

# Extrai o caminho do executável de uma linha de comando
function Get-ExePath([string]$cmd) {
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($cmd.Trim())
    if ($c.StartsWith('"')) { $f = $c.IndexOf('"', 1); if ($f -gt 1) { return $c.Substring(1, $f - 1) } }
    $m = [regex]::Match($c, '^(.+?\.(exe|com|bat|cmd|ps1|vbs|vbe|js|jse|wsf|hta|scr|dll|msi|lnk))(\s|,|$)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return ($c -split '\s+')[0]
}

function Get-Assinatura([string]$path) {
    if (-not $path) { return 'Desconhecido' }
    if (-not (Test-Path -LiteralPath $path)) {
        $w = Get-Command $path -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($w -and $w.Source -and (Test-Path -LiteralPath $w.Source)) { $path = $w.Source } else { return 'Arquivo não encontrado' }
    }
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
        if ([string]$s.Status -eq 'Valid') {
            $cn = 'válida'
            if ($s.SignerCertificate.Subject -match 'CN="?([^,"]+)') { $cn = $Matches[1] }
            return "Assinado ($cn)"
        }
        elseif ([string]$s.Status -eq 'NotSigned') { return 'Não assinado' }
        else { return "Assinatura: $($s.Status)" }
    } catch { return 'Erro ao verificar' }
}

# Padrões típicos de malware / persistência maliciosa
function Test-Suspeito([string]$t) {
    if (-not $t) { return $false }
    $p = '\\AppData\\Local\\Temp\\|\\Windows\\Temp\\|\\Users\\Public\\|\\Downloads\\|\\\$Recycle|\s-enc(odedcommand)?\s|\s-e\s+[A-Za-z0-9+/=]{20,}|frombase64string|downloadstring|downloadfile|invoke-webrequest|\biwr\s|\biex[\s(]|invoke-expression|mshta|regsvr32.+/i:|rundll32.+(javascript|http)|certutil.+(-urlcache|-decode)|bitsadmin.+/transfer|\s-w(indowstyle)?\s+hidden|wscript.+\.(vbs|js)\b|cscript.+\.(vbs|js)\b'
    return [regex]::IsMatch($t, $p, 'IgnoreCase')
}

# ---------- Ações que alteram o sistema (sempre registram o estado anterior) ----------
function Add-Acao($R, [string]$Acao, [string]$Item, [string]$Anterior, [string]$Resultado, [string]$Desfazer = '') {
    if (-not $R.Extra.Acoes) { $R.Extra.Acoes = New-Object System.Collections.ArrayList }
    [void]$R.Extra.Acoes.Add([pscustomobject]@{ Data = Get-Date; 'Ação' = $Acao; Item = $Item; 'Estado anterior' = $Anterior; Resultado = $Resultado; Desfazer = $Desfazer })
}

function ConvertTo-LiteralPS($v) {
    if ($null -eq $v) { return '$null' }
    if ($v -is [string]) { return "'" + $v.Replace("'", "''") + "'" }
    if ($v -is [string[]]) { return '@(' + (($v | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ',') + ')' }
    if ($v -is [byte[]]) { return '([byte[]](' + ($v -join ',') + '))' }
    if ($v -is [ValueType]) { return [string]$v }
    return "'" + ([string]$v).Replace("'", "''") + "'"
}

# Altera um valor do registro guardando como desfazer
function Set-RegTweak($R, [string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    $existia = $false; $ant = $null; $tipoAnt = $Type
    try {
        $k = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($k.GetValueNames() -contains $Name) { $existia = $true; $ant = $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames'); $tipoAnt = [string]$k.GetValueKind($Name) }
    } catch {}
    if ($existia) { $undo = "New-ItemProperty -LiteralPath '$Path' -Name '$Name' -Value $(ConvertTo-LiteralPS $ant) -PropertyType $tipoAnt -Force | Out-Null" }
    else { $undo = "Remove-ItemProperty -LiteralPath '$Path' -Name '$Name' -ErrorAction SilentlyContinue" }
    try {
        if ([string]$Value -eq '<RemoveEntry>') { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
        else {
            if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        }
        $res = 'Sucesso'
    } catch { $res = "Falha: $($_.Exception.Message)" }
    Add-Acao $R 'Registro' "$Path\$Name = $Value" $(if ($existia) { [string]$ant } else { '(não existia)' }) $res $undo
}

# Altera o tipo de inicialização de um serviço guardando como desfazer
function Set-SvcTweak($R, [string]$Name, [string]$Tipo) {
    $s = Get-CimInstance Win32_Service -Filter "Name='$Name'"
    if (-not $s) { Add-Acao $R 'Serviço' "$Name -> $Tipo" '-' 'Ignorado (serviço não existe)'; return }
    $sc = switch ($s.StartMode) { 'Auto' { if ($s.DelayedAutoStart) { 'delayed-auto' } else { 'auto' } } 'Manual' { 'demand' } 'Disabled' { 'disabled' } default { 'demand' } }
    try { Set-Service -Name $s.Name -StartupType $Tipo -ErrorAction Stop; $res = 'Sucesso' } catch { $res = "Falha: $($_.Exception.Message)" }
    Add-Acao $R 'Serviço' "$($s.Name) ($($s.DisplayName)) -> $Tipo" ([string]$s.StartMode) $res "sc.exe config `"$($s.Name)`" start= $sc | Out-Null"
}

# Executa uma etapa, registra o resultado e o tempo
function Invoke-Etapa($R, [string]$Nome, [scriptblock]$Bloco) {
    Log ">> $Nome..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $st = 'OK'
    try { $msg = & $Bloco; if (-not $msg) { $msg = 'Concluído' } }
    catch { $msg = "Falha: $($_.Exception.Message)"; $st = 'Atenção' }
    $msg = [string](@($msg) | Select-Object -Last 1)
    if ($msg -like 'Falha*' -or $msg -like 'ATENÇÃO*') { $st = 'Atenção' }
    Add-Item $R $Nome ("{0} ({1:N0} s)" -f $msg, $sw.Elapsed.TotalSeconds) $st
    Log "   $Nome -> $msg"
}

# Últimas linhas úteis da saída de um comando
function Get-Resumo([string]$txt, [int]$n = 2) {
    ((($txt -split "`r?`n") | ForEach-Object { ($_ -split "`r")[-1].Trim() } | Where-Object { $_ -and $_ -notmatch '^[\s\.\d%=\[\]-]+$' }) | Select-Object -Last $n) -join ' | '
}

function New-PontoRestauracao($R, [string]$Descricao) {
    Set-RegTweak $R 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0 'DWord'
    if (-not (Get-ComputerRestorePoint -ErrorAction SilentlyContinue)) { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop }
    Checkpoint-Computer -Description $Descricao -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    Add-Acao $R 'Ponto de restauração' $Descricao '-' 'Sucesso'
    'Ponto de restauração criado'
}
'@

# As mesmas funções ficam disponíveis na interface principal
. ([scriptblock]::Create($Global:Helpers))
# Na versão .exe (sem console) erros não tratados viram janelas pop-up; os pontos críticos usam try/catch
$ErrorActionPreference = 'SilentlyContinue'

# =====================================================================
#  DEFINIÇÃO DOS TESTES
#  Cada teste roda em segundo plano e devolve um objeto $R com:
#  Itens (verificações), Tabelas (dados), Achados (problemas + recomendação)
# =====================================================================
$Global:Testes = @(

# ---------------------------------------------------------------------
@{ Id = 'sistema'; Nome = 'Sistema operacional e hardware'; Timeout = 180
   Desc = 'Versão e suporte do Windows, ativação, BIOS/UEFI, TPM, Secure Boot, BitLocker, pontos de restauração e dispositivos com erro de driver.'
   Codigo = {
    $R = New-R
    Log 'Coletando informações do sistema operacional e do hardware...'
    $os   = Get-CimInstance Win32_OperatingSystem
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $bb   = Get-CimInstance Win32_BaseBoard
    $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpu  = @(Get-CimInstance Win32_VideoController)
    $cv   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$os.BuildNumber
    $disp = [string]$cv.DisplayVersion; if (-not $disp) { $disp = [string]$cv.ReleaseId }

    Add-Item $R 'Nome do computador' $env:COMPUTERNAME
    Add-Item $R 'Fabricante / Modelo' ("{0} {1}" -f $cs.Manufacturer, $cs.Model)
    Add-Item $R 'Número de série' $bios.SerialNumber
    Add-Item $R 'Placa-mãe' ("{0} {1}" -f $bb.Manufacturer, $bb.Product)
    Add-Item $R 'BIOS / UEFI' ("{0} ({1})" -f $bios.SMBIOSBIOSVersion, (Fmt $bios.ReleaseDate))
    Add-Item $R 'Sistema operacional' ("{0} {1}" -f $os.Caption, $os.OSArchitecture)
    Add-Item $R 'Versão / Build' ("{0} - build {1}.{2}" -f $disp, $os.BuildNumber, $cv.UBR)
    Add-Item $R 'Instalado em' (Fmt $os.InstallDate)
    $up = (Get-Date) - $os.LastBootUpTime
    Add-Item $R 'Último boot' ("{0} (ligado há {1} dia(s) e {2} h)" -f (Fmt $os.LastBootUpTime), $up.Days, $up.Hours) $(if ($up.TotalDays -gt 14) { 'Atenção' } else { 'OK' })
    if ($cs.PartOfDomain) { Add-Item $R 'Domínio' $cs.Domain } else { Add-Item $R 'Grupo de trabalho' $cs.Workgroup }
    Add-Item $R 'Usuário conectado' $cs.UserName
    Add-Item $R 'Processador' ("$($cpu.Name)".Trim())
    Add-Item $R 'Núcleos / Threads' ("{0} núcleos / {1} threads - {2} MHz" -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $cpu.MaxClockSpeed)
    foreach ($g in $gpu) { Add-Item $R 'Placa de vídeo' ("{0} (driver {1})" -f $g.Name, $g.DriverVersion) }

    $R.Metricas.Build = $build
    $R.Metricas.UptimeDias = [math]::Round($up.TotalDays, 1)
    $R.Extra.Resumo = @{
        Computador = $env:COMPUTERNAME
        Modelo     = ("{0} {1}" -f $cs.Manufacturer, $cs.Model)
        Serie      = [string]$bios.SerialNumber
        SO         = ("{0} {1} (build {2})" -f $os.Caption, $disp, $os.BuildNumber)
        CPU        = ("$($cpu.Name)".Trim())
        RAM        = ("{0} GB" -f [math]::Round($cs.TotalPhysicalMemory / 1GB, 0))
    }

    if ($up.TotalDays -gt 14) {
        Add-Achado $R 'Desempenho' 'Baixo' ("Computador ligado há {0} dias sem reiniciar." -f $up.Days) 'Reiniciar o computador periodicamente (ao menos 1 vez por semana) para aplicar atualizações e liberar recursos.' 0.2
    }

    # --- Ciclo de suporte do Windows (datas para edições Home/Pro e Enterprise/Education) ---
    Log 'Verificando ciclo de suporte do Windows...'
    if ($os.ProductType -eq 1) {
        $edicao = [string]$cv.EditionID
        $fimHP  = @{ 19045 = '2025-10-14'; 22000 = '2023-10-10'; 22621 = '2024-10-08'; 22631 = '2025-11-11'; 26100 = '2026-10-13'; 26200 = '2027-10-12' }
        $fimEnt = @{ 19045 = '2025-10-14'; 22000 = '2024-10-08'; 22621 = '2025-10-14'; 22631 = '2026-11-10'; 26100 = '2027-10-12'; 26200 = '2028-10-10' }
        if ($edicao -match 'EnterpriseS|LTSC|IoT') {
            Add-Item $R 'Suporte Microsoft' 'Edição LTSC/IoT (ciclo de suporte longo)' 'OK'
        }
        else {
            $tab = if ($edicao -match 'Enterprise|Education') { $fimEnt } else { $fimHP }
            $data = $null
            if ($tab.ContainsKey($build)) { $data = [datetime]$tab[$build] }
            elseif ($build -lt 19045) { $data = [datetime]'2023-06-13' }
            if ($data) {
                $txtData = $data.ToString('dd/MM/yyyy')
                if ($data -lt (Get-Date)) {
                    Add-Item $R 'Suporte Microsoft' "ENCERRADO em $txtData" 'Crítico'
                    if ($build -lt 22000) {
                        Add-Achado $R 'Segurança' 'Crítico' "Windows 10 sem suporte desde ${txtData}: não recebe mais correções de segurança (salvo se inscrito no programa ESU)." 'Migrar para o Windows 11 (se o hardware for compatível) ou inscrever no ESU. Se o hardware não for compatível, planejar a substituição do equipamento.' -Upgrade
                    }
                    else {
                        Add-Achado $R 'Segurança' 'Alto' "A versão $disp do Windows 11 está sem suporte desde $txtData." 'Atualizar para a versão mais recente do Windows 11 pelo Windows Update.'
                    }
                }
                elseif (($data - (Get-Date)).TotalDays -lt 120) {
                    Add-Item $R 'Suporte Microsoft' "Termina em $txtData" 'Atenção'
                    Add-Achado $R 'Segurança' 'Baixo' "O suporte da versão $disp termina em $txtData." 'Planejar a atualização para a próxima versão do Windows.'
                }
                else { Add-Item $R 'Suporte Microsoft' "Suportado até $txtData" 'OK' }
            }
            else { Add-Item $R 'Suporte Microsoft' 'Versão recente (sem data de fim conhecida)' 'OK' }
        }
    }
    else { Add-Item $R 'Suporte Microsoft' 'Windows Server - consultar ciclo de vida específico' 'Info' }

    # --- Ativação ---
    Log 'Verificando ativação do Windows...'
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1
    $stMap = @{ 0 = 'Não licenciado'; 1 = 'Ativado'; 2 = 'Período de carência'; 3 = 'Carência adicional'; 4 = 'Não original'; 5 = 'Notificação'; 6 = 'Carência estendida' }
    if ($lic) {
        $st = $stMap[[int]$lic.LicenseStatus]
        Add-Item $R 'Ativação do Windows' $st $(if ($lic.LicenseStatus -eq 1) { 'OK' } else { 'Crítico' })
        if ($lic.LicenseStatus -ne 1) { Add-Achado $R 'Segurança' 'Médio' "Windows não ativado ($st)." 'Regularizar a licença do Windows (licença original garante atualizações e suporte).' }
    }

    # --- TPM / Secure Boot / BitLocker ---
    Log 'Verificando TPM, Secure Boot e BitLocker...'
    $tpm = $null
    try { $tpm = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop } catch {}
    if ($tpm) {
        $ver = ([string]$tpm.SpecVersion -split ',')[0].Trim()
        $R.Metricas.TPM = $ver
        Add-Item $R 'TPM' ("Versão {0} - {1}" -f $ver, $(if ($tpm.IsEnabled_InitialValue) { 'ativado' } else { 'desativado' })) $(if ($ver -like '2*') { 'OK' } else { 'Atenção' })
    }
    else {
        Add-Item $R 'TPM' 'Não encontrado ou desativado na BIOS' 'Atenção'
        Add-Achado $R 'Segurança' 'Baixo' 'Chip TPM não encontrado/ativado.' 'Ativar o TPM (fTPM/PTT) na BIOS. É requisito do Windows 11 e do BitLocker.'
    }
    $sb = $null
    try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop } catch { $sb = $null }
    if ($sb -eq $true) { Add-Item $R 'Secure Boot' 'Ativado' 'OK' }
    elseif ($sb -eq $false) {
        Add-Item $R 'Secure Boot' 'Desativado' 'Atenção'
        Add-Achado $R 'Segurança' 'Médio' 'Secure Boot (inicialização segura) desativado.' 'Ativar o Secure Boot na BIOS/UEFI para impedir a carga de bootkits/rootkits.'
    }
    else {
        Add-Item $R 'Secure Boot' 'Não suportado (BIOS legado / modo CSM)' 'Atenção'
        Add-Achado $R 'Segurança' 'Médio' 'Computador inicializando em modo BIOS legado (sem UEFI/Secure Boot).' 'Converter o disco para GPT (mbr2gpt) e ativar UEFI + Secure Boot.'
    }
    $bl = $null
    try { $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop } catch {}
    if ($bl) {
        $on = ([string]$bl.ProtectionStatus -eq 'On' -or [string]$bl.ProtectionStatus -eq '1')
        Add-Item $R "BitLocker ($env:SystemDrive)" ("{0} - {1}% criptografado" -f $(if ($on) { 'Protegido' } else { 'Desligado' }), $bl.EncryptionPercentage) $(if ($on) { 'OK' } else { 'Atenção' })
        if (-not $on) { Add-Achado $R 'Segurança' 'Médio' 'Disco do sistema sem criptografia (BitLocker desligado).' 'Ativar BitLocker/criptografia de dispositivo e guardar a chave de recuperação em local seguro. Essencial em notebooks.' }
    }
    else {
        Add-Item $R 'BitLocker' 'Indisponível nesta edição do Windows' 'Atenção'
        Add-Achado $R 'Segurança' 'Baixo' 'Criptografia de disco indisponível (edição Home sem criptografia de dispositivo).' 'Avaliar upgrade para Windows Pro para usar BitLocker, principalmente em notebooks.'
    }
    if ($R.Metricas.Build -lt 22000) {
        $okW11 = ($R.Metricas.TPM -like '2*') -and ($sb -eq $true) -and ($cs.TotalPhysicalMemory -ge 3.5GB)
        Add-Item $R 'Requisitos básicos do Windows 11' $(if ($okW11) { 'TPM 2.0, UEFI/Secure Boot e RAM atendidos (confirmar CPU no app Verificação de Integridade do PC)' } else { 'NÃO atendidos (TPM 2.0 / Secure Boot / RAM)' }) $(if ($okW11) { 'OK' } else { 'Atenção' })
    }

    # --- Pontos de restauração ---
    $rp = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
    if ($rp.Count -gt 0) {
        $ultRp = [Management.ManagementDateTimeConverter]::ToDateTime($rp[-1].CreationTime)
        Add-Item $R 'Pontos de restauração' ("{0} ponto(s) - último em {1}" -f $rp.Count, (Fmt $ultRp)) 'OK'
    }
    else {
        Add-Item $R 'Pontos de restauração' 'Nenhum (Proteção do Sistema desativada?)' 'Atenção'
        Add-Achado $R 'Segurança' 'Baixo' 'Nenhum ponto de restauração do sistema disponível.' 'Ativar a Proteção do Sistema no disco C: (reserva de 5% a 10%) para permitir reverter falhas.'
    }

    # --- Dispositivos com erro ---
    Log 'Procurando dispositivos com erro no Gerenciador de Dispositivos...'
    $pnp = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0 AND ConfigManagerErrorCode <> 22 AND ConfigManagerErrorCode <> 45')
    Add-Item $R 'Dispositivos com erro de driver' $pnp.Count $(if ($pnp.Count) { 'Atenção' } else { 'OK' })
    if ($pnp.Count) {
        Add-Tabela $R 'Dispositivos com problema no Gerenciador de Dispositivos' ($pnp | Select-Object @{n = 'Dispositivo'; e = { $_.Name } }, @{n = 'Classe'; e = { $_.PNPClass } }, @{n = 'Código de erro'; e = { $_.ConfigManagerErrorCode } }, @{n = 'ID'; e = { $_.PNPDeviceID } })
        Add-Achado $R 'Desempenho' 'Médio' ("{0} dispositivo(s) com erro de driver." -f $pnp.Count) 'Instalar/atualizar os drivers no site do fabricante do equipamento.' 0.5
    }
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'memoria'; Nome = 'Memória RAM'; Timeout = 700
   Desc = 'Quantidade instalada, uso atual, módulos e slots livres, tipo/velocidade, memória virtual, processos que mais consomem e teste de integridade da RAM (padrões de memória, estilo MemTest).'
   Codigo = {
    $R = New-R
    Log 'Lendo módulos de memória RAM...'
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $tot = [double]$cs.TotalPhysicalMemory
    $livre = [double]$os.FreePhysicalMemory * 1KB
    $uso = [math]::Round((1 - $livre / $tot) * 100, 0)
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $arr = Get-CimInstance Win32_PhysicalMemoryArray | Where-Object { $_.Use -eq 3 } | Select-Object -First 1
    $slots = if ($arr -and $arr.MemoryDevices) { [int]$arr.MemoryDevices } else { $mods.Count }
    $maxKB = if ($arr.MaxCapacityEx) { [double]$arr.MaxCapacityEx } else { [double]$arr.MaxCapacity }
    $instGB = [math]::Round((($mods | Measure-Object Capacity -Sum).Sum) / 1GB, 0)
    if (-not $instGB) { $instGB = [math]::Round($tot / 1GB, 0) }
    $tipoMap = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
    $tipo = $tipoMap[[int]($mods | Select-Object -First 1).SMBIOSMemoryType]; if (-not $tipo) { $tipo = '' }
    $vel = ($mods | Select-Object -First 1).ConfiguredClockSpeed; if (-not $vel) { $vel = ($mods | Select-Object -First 1).Speed }
    $livres = [math]::Max(0, $slots - $mods.Count)

    Add-Item $R 'Memória instalada' ("{0} GB {1} ({2} GB utilizáveis)" -f $instGB, $tipo, (GB $tot)) $(if ($instGB -ge 16) { 'OK' } elseif ($instGB -ge 8) { 'Atenção' } else { 'Crítico' })
    Add-Item $R 'Uso atual' ("{0}% ({1} GB em uso, {2} GB livres)" -f $uso, (GB ($tot - $livre)), (GB $livre)) $(if ($uso -ge 90) { 'Crítico' } elseif ($uso -ge 80) { 'Atenção' } else { 'OK' })
    Add-Item $R 'Slots de memória' ("{0} ocupado(s) de {1} - {2} livre(s)" -f $mods.Count, $slots, $livres)
    if ($maxKB) { Add-Item $R 'Capacidade máxima suportada (placa)' ("{0} GB" -f [math]::Round($maxKB / 1MB, 0)) }
    if ($vel) { Add-Item $R 'Velocidade' "$vel MHz" }

    Add-Tabela $R 'Módulos de memória instalados' ($mods | Select-Object @{n = 'Slot'; e = { $_.DeviceLocator } }, @{n = 'Capacidade (GB)'; e = { [math]::Round($_.Capacity / 1GB, 0) } }, @{n = 'Tipo'; e = { $tipoMap[[int]$_.SMBIOSMemoryType] } }, @{n = 'Velocidade (MHz)'; e = { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } }, @{n = 'Fabricante'; e = { $_.Manufacturer } }, @{n = 'Part number'; e = { ("$($_.PartNumber)").Trim() } })

    $pf = @(Get-CimInstance Win32_PageFileUsage)
    foreach ($p in $pf) { Add-Item $R 'Memória virtual (pagefile)' ("{0} - {1} MB alocados, pico de uso {2} MB" -f $p.Name, $p.AllocatedBaseSize, $p.PeakUsage) }

    Log 'Identificando processos que mais consomem memória...'
    Add-Tabela $R 'Processos que mais consomem memória' (Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 @{n = 'Processo'; e = { $_.ProcessName } }, @{n = 'RAM (MB)'; e = { [math]::Round($_.WorkingSet64 / 1MB, 0) } }, @{n = 'PID'; e = { $_.Id } })

    $R.Metricas.RamGB = $instGB; $R.Metricas.RamUso = $uso; $R.Metricas.SlotsLivres = $livres

    $txtSlot = if ($livres -gt 0) { "Há $livres slot(s) livre(s)." } else { 'Não há slots livres: substituir módulo(s) por de maior capacidade.' }
    if ($instGB -lt 4) { Add-Achado $R 'Desempenho' 'Crítico' "Apenas $instGB GB de RAM - insuficiente para o Windows atual." "Upgrade para no mínimo 8 GB (ideal 16 GB) de memória $tipo $vel MHz. $txtSlot" 3 -Upgrade }
    elseif ($instGB -lt 8) { Add-Achado $R 'Desempenho' 'Alto' "Apenas $instGB GB de RAM - abaixo do recomendado para uso profissional." "Upgrade para 16 GB de memória $tipo $vel MHz. $txtSlot" 2 -Upgrade }
    elseif ($instGB -lt 16) { Add-Achado $R 'Desempenho' 'Baixo' "$instGB GB de RAM - suficiente para uso básico." "Para multitarefa e maior vida útil, considerar 16 GB de memória $tipo. $txtSlot" 0.5 -Upgrade }
    if ($uso -ge 90) { Add-Achado $R 'Desempenho' 'Alto' "Memória RAM com $uso% de uso no momento da auditoria." 'Fechar/remover programas que consomem muita memória e avaliar upgrade de RAM.' 1 }
    elseif ($uso -ge 80) { Add-Achado $R 'Desempenho' 'Médio' "Memória RAM com $uso% de uso no momento da auditoria." 'Revisar programas em segundo plano e na inicialização.' 0.5 }
    if ($mods.Count -eq 1 -and $slots -ge 2) { Add-Achado $R 'Desempenho' 'Info' 'Apenas um módulo de memória instalado (single channel).' "Instalar um segundo módulo idêntico ($tipo, mesma capacidade e velocidade) para ativar o dual channel e ganhar desempenho, principalmente com vídeo integrado." 0 -Upgrade }
    if ($Cfg.TesteMemoria) {
        Log 'Teste de integridade da RAM (padrões de memória, estilo MemTest)...'
        $csmem = @"
public static class AuditorMem {
    static byte[][] _b;
    public static long Alocar(long total, int chunk) {
        int n = (int)(total / chunk); if (n < 1) n = 1;
        _b = new byte[n][]; long ok = 0;
        for (int i=0;i<n;i++){ try { _b[i]=new byte[chunk]; ok+=chunk; } catch { break; } }
        return ok;
    }
    public static long Padrao(byte v) {
        long e=0;
        for(int k=0;k<_b.Length;k++){ var a=_b[k]; if(a==null)continue; for(int i=0;i<a.Length;i++)a[i]=v; }
        for(int k=0;k<_b.Length;k++){ var a=_b[k]; if(a==null)continue; for(int i=0;i<a.Length;i++) if(a[i]!=v) e++; }
        return e;
    }
    public static long Endereco() {
        long e=0;
        for(int k=0;k<_b.Length;k++){ var a=_b[k]; if(a==null)continue; for(int i=0;i<a.Length;i++)a[i]=(byte)(i*31+k); }
        for(int k=0;k<_b.Length;k++){ var a=_b[k]; if(a==null)continue; for(int i=0;i<a.Length;i++) if(a[i]!=(byte)(i*31+k)) e++; }
        return e;
    }
    public static void Liberar(){ _b=null; }
}
"@
        if (-not ('AuditorMem' -as [type])) { Add-Type -TypeDefinition $csmem -ErrorAction SilentlyContinue }
        if ('AuditorMem' -as [type]) {
            $osm = Get-CimInstance Win32_OperatingSystem
            $livreB = [double]$osm.FreePhysicalMemory * 1KB
            $alvo = [long][math]::Min($livreB * 0.5, 4GB)
            if ($alvo -lt 256MB) { $alvo = [long][math]::Min([long]($livreB * 0.8), [long]256MB) }
            try {
                $aloc = [AuditorMem]::Alocar([long]$alvo, [int]64MB)
                $erros = [int64]0; $i = 0
                foreach ($pat in @([byte]0, [byte]255, [byte]85, [byte]170)) {
                    $i++; Log ("  padrão {0}/5 (0x{1:X2})..." -f $i, $pat)
                    $erros += [AuditorMem]::Padrao($pat)
                }
                Log '  padrão 5/5 (endereçamento)...'
                $erros += [AuditorMem]::Endereco()
                [AuditorMem]::Liberar(); [GC]::Collect()
                $gbTest = [math]::Round($aloc / 1GB, 2)
                Add-Item $R 'Teste de integridade da RAM' ("{0} erro(s) em {1} GB testados (5 padrões: 00, FF, 55, AA e endereçamento)" -f $erros, $gbTest) $(if ($erros -gt 0) { 'Crítico' } else { 'OK' })
                $R.Metricas.MemErros = [int64]$erros; $R.Metricas.MemTestGB = $gbTest
                if ($erros -gt 0) {
                    Add-Achado $R 'Desempenho' 'Crítico' "O teste encontrou $erros erro(s) de memória em $gbTest GB de RAM testados." 'Forte indício de módulo de memória defeituoso. Testar os módulos um a um, reassentar na placa e rodar o teste completo (Diagnóstico de Memória do Windows pelo reinício ou MemTest86 por pendrive). Substituir o módulo com defeito.' 3 -Upgrade
                }
                else { Add-Item $R 'Cobertura do teste de RAM' 'Testada apenas a memória livre no momento (a RAM em uso pelo Windows não entra). Para 100% da memória, agendar o Diagnóstico de Memória do Windows (mdsched) no reinício.' 'Info' }
            }
            catch { try { [AuditorMem]::Liberar() } catch {}; Add-Item $R 'Teste de integridade da RAM' "Não concluído: $($_.Exception.Message)" 'Atenção' }
        }
    }
    else { Add-Item $R 'Teste de integridade da RAM' 'Não executado (opção desmarcada)' }
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'disco'; Nome = 'Discos e armazenamento'; Timeout = 1800
   Desc = 'Todos os discos físicos: tipo (SSD/HDD), saúde e atributos S.M.A.R.T. detalhados, espaço livre por unidade, arquivos temporários e leitura real de cada disco (amostrada ou completa, setor por setor).'
   Codigo = {
    $R = New-R
    Log 'Inventariando discos físicos e saúde SMART...'
    $sysNum = $null
    try { $sysNum = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop | Select-Object -First 1).DiskNumber } catch {}
    $R.Metricas.NumSistema = $sysNum
    $fp = @(); try { $fp = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | Where-Object { $_.PredictFailure }) } catch {}
    if ($fp.Count) {
        Add-Item $R 'Alerta SMART de falha iminente' 'SIM - o disco prevê falha' 'Crítico'
        Add-Achado $R 'Desempenho' 'Crítico' 'O SMART do disco indica FALHA IMINENTE.' 'Fazer backup IMEDIATO dos dados e substituir o disco.' 3 -Upgrade
    }
    else { Add-Item $R 'Alerta SMART de falha iminente' 'Nenhum' 'OK' }

    $linhas = New-Object System.Collections.ArrayList
    foreach ($pd in @(Get-PhysicalDisk)) {
        $mt = [string]$pd.MediaType; if ($mt -eq '4') { $mt = 'SSD' } elseif ($mt -eq '3') { $mt = 'HDD' }
        $bt = [string]$pd.BusType; if ($bt -eq '17') { $bt = 'NVMe' } elseif ($bt -eq '11') { $bt = 'SATA' } elseif ($bt -eq '7') { $bt = 'USB' } elseif ($bt -eq '8') { $bt = 'RAID' }
        $hs = [string]$pd.HealthStatus; if ($hs -eq '0') { $hs = 'Healthy' } elseif ($hs -eq '1') { $hs = 'Warning' } elseif ($hs -eq '2') { $hs = 'Unhealthy' }
        $tipo = if ($mt -eq 'SSD' -or $bt -eq 'NVMe') { 'SSD' } elseif ($mt -eq 'HDD') { 'HDD' } else { 'Não identificado' }
        $saude = switch ($hs) { 'Healthy' { 'Saudável' } 'Warning' { 'ALERTA' } 'Unhealthy' { 'COM FALHA' } default { $hs } }
        $rc = $null; try { $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        $ehSis = ([string]$pd.DeviceId -eq [string]$sysNum)
        if ($ehSis) { $R.Metricas.TipoSistema = $tipo; $R.Metricas.BusSistema = $bt }
        [void]$linhas.Add([pscustomobject]@{
            'Disco'            = $pd.FriendlyName
            'Tipo'             = $tipo
            'Interface'        = $bt
            'Tamanho (GB)'     = GB $pd.Size
            'Saúde'            = $saude
            'Temperatura'      = $(if ($rc.Temperature) { "$($rc.Temperature) °C" } else { '-' })
            'Desgaste'         = $(if ($null -ne $rc.Wear) { "$($rc.Wear)%" } else { '-' })
            'Horas ligado'     = $(if ($rc.PowerOnHours) { $rc.PowerOnHours } else { '-' })
            'Erros de leitura' = $(if ($null -ne $rc.ReadErrorsUncorrected) { $rc.ReadErrorsUncorrected } else { '-' })
            'Disco do sistema' = SimNao $ehSis
        })
        Add-Item $R ("Disco: {0}" -f $pd.FriendlyName) ("{0} {1} - {2} GB - {3}" -f $tipo, $bt, (GB $pd.Size), $saude) $(if ($hs -eq 'Healthy') { 'OK' } else { 'Crítico' })
        if ($hs -ne 'Healthy' -and $hs) { Add-Achado $R 'Desempenho' 'Crítico' "Disco $($pd.FriendlyName) com estado de saúde: $saude." 'Fazer backup imediato e substituir o disco.' 3 -Upgrade }
        if ($rc.Wear -ge 80) { Add-Achado $R 'Desempenho' 'Alto' "SSD $($pd.FriendlyName) com $($rc.Wear)% de desgaste." 'Planejar a substituição do SSD e manter backup atualizado.' 1 -Upgrade }
        if ($rc.Temperature -ge 60) { Add-Achado $R 'Desempenho' 'Médio' "Disco $($pd.FriendlyName) operando a $($rc.Temperature) °C." 'Melhorar a ventilação/limpeza interna do equipamento.' 0.3 }
        if ($rc.ReadErrorsUncorrected -gt 0) { Add-Achado $R 'Desempenho' 'Alto' "Disco $($pd.FriendlyName) com $($rc.ReadErrorsUncorrected) erro(s) de leitura não corrigidos." 'Fazer backup e testar o disco com a ferramenta do fabricante; substituir se os erros aumentarem.' 1 }
        if ($ehSis -and $tipo -eq 'HDD') { Add-Achado $R 'Desempenho' 'Alto' 'O Windows está instalado em um HDD (disco mecânico) - principal causa de lentidão.' 'Substituir por SSD (SATA ou NVMe, conforme a placa-mãe). É o upgrade com maior ganho de velocidade.' 2.5 -Upgrade }
    }
    Add-Tabela $R 'Discos físicos' $linhas
    if (-not $R.Metricas.TipoSistema) { $R.Metricas.TipoSistema = 'Não identificado' }

    Log 'Lendo atributos S.M.A.R.T. detalhados (estilo CrystalDiskInfo)...'
    function Get-SmartDetalhado {
        $nomes = @{ 1 = 'Taxa de erro de leitura'; 3 = 'Tempo de spin-up'; 5 = 'Setores realocados'; 7 = 'Taxa de erro de busca'; 9 = 'Horas ligado'; 10 = 'Tentativas de rotação'; 12 = 'Ciclos de energia'; 173 = 'Desgaste (SSD)'; 177 = 'Desgaste (SSD)'; 184 = 'Erro fim-a-fim'; 187 = 'Erros não corrigíveis reportados'; 188 = 'Command Timeout'; 190 = 'Temperatura do ar'; 194 = 'Temperatura'; 196 = 'Eventos de realocação'; 197 = 'Setores pendentes'; 198 = 'Setores incorrigíveis (offline)'; 199 = 'Erros CRC UDMA (cabo)'; 231 = 'Vida útil restante (SSD)'; 233 = 'Média usada/horas (SSD)'; 241 = 'Total gravado (host)'; 242 = 'Total lido (host)' }
        $criticos = 5, 10, 184, 187, 196, 197, 198
        $data = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictData -ErrorAction SilentlyContinue)
        $thrs = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictThresholds -ErrorAction SilentlyContinue)
        $drives = @(Get-CimInstance Win32_DiskDrive)
        $saida = New-Object System.Collections.ArrayList
        foreach ($d in $data) {
            $vs = $d.VendorSpecific
            if (-not $vs -or $vs.Count -lt 362) { continue }
            $instU = ([string]$d.InstanceName -replace '_0$', '').ToUpper()
            $dd = $drives | Where-Object { $_.PNPDeviceID -and $instU -eq ([string]$_.PNPDeviceID).ToUpper() } | Select-Object -First 1
            if (-not $dd) { $dd = $drives | Where-Object { $_.PNPDeviceID -and ($instU -like ('*' + ((([string]$_.PNPDeviceID) -split '\\')[-1]).ToUpper() + '*')) } | Select-Object -First 1 }
            $modelo = if ($dd -and $dd.Model) { ([string]$dd.Model).Trim() } else { [string]$d.InstanceName }
            $tmap = @{}
            $t = $thrs | Where-Object { $_.InstanceName -eq $d.InstanceName } | Select-Object -First 1
            if ($t -and $t.VendorSpecific) { $tv = $t.VendorSpecific; for ($o = 2; $o + 1 -lt $tv.Count; $o += 12) { $tid = $tv[$o]; if ($tid) { $tmap[[int]$tid] = $tv[$o + 1] } } }
            $attrs = New-Object System.Collections.ArrayList
            $alertas = New-Object System.Collections.ArrayList
            $temp = $null
            for ($o = 2; $o + 11 -lt $vs.Count; $o += 12) {
                $id = [int]$vs[$o]
                if ($id -eq 0) { continue }
                $cur = [int]$vs[$o + 3]; $wst = [int]$vs[$o + 4]
                $raw = [int64]0; for ($b = 0; $b -lt 6; $b++) { $raw = $raw -bor ([int64]$vs[$o + 5 + $b] -shl (8 * $b)) }
                $nome = if ($nomes[$id]) { $nomes[$id] } else { "Atributo $id" }
                $rawShow = [string]$raw
                if ($id -eq 194 -or $id -eq 190) { $temp = [int]($raw -band 0xFF); $rawShow = "$temp" }
                [void]$attrs.Add([pscustomobject]@{ 'ID' = ('{0:X2}' -f $id); 'Atributo' = $nome; 'Atual' = $cur; 'Pior' = $wst; 'Limite' = $(if ($tmap.ContainsKey($id)) { $tmap[$id] } else { '-' }); 'Valor bruto' = $rawShow })
                if (($criticos -contains $id) -and $raw -gt 0) { [void]$alertas.Add("$nome = $raw") }
                if ($tmap.ContainsKey($id) -and [int]$tmap[$id] -gt 0 -and $cur -le [int]$tmap[$id]) { [void]$alertas.Add("$nome no limite (atual $cur <= limite $($tmap[$id]))") }
            }
            [void]$saida.Add(@{ Modelo = $modelo; Attrs = $attrs; Alertas = @($alertas | Select-Object -Unique); Temp = $temp })
        }
        return , $saida
    }
    $smart = @()
    try { $smart = @(Get-SmartDetalhado) } catch { }
    foreach ($s in $smart) {
        $estado = if ($s.Alertas.Count) { 'Cuidado' } else { 'Bom' }
        $txt = $estado
        if ($s.Temp) { $txt += " - $($s.Temp) °C" }
        if ($s.Alertas.Count) { $txt += ' - ' + ($s.Alertas -join '; ') }
        Add-Item $R ("S.M.A.R.T.: {0}" -f $s.Modelo) $txt $(if ($s.Alertas.Count) { 'Atenção' } else { 'OK' })
        Add-Tabela $R ("Atributos S.M.A.R.T. - {0}" -f $s.Modelo) $s.Attrs
        if ($s.Alertas.Count) { Add-Achado $R 'Desempenho' 'Alto' ("Disco {0} com atributos S.M.A.R.T. em alerta: {1}." -f $s.Modelo, ($s.Alertas -join '; ')) 'Fazer backup e monitorar de perto. Setores realocados/pendentes/incorrigíveis que aumentam indicam disco em degradação: planejar a substituição. Erros CRC UDMA costumam ser cabo/conector SATA.' 1 -Upgrade }
    }
    if (-not $smart.Count) { Add-Item $R 'Atributos S.M.A.R.T. detalhados' 'Não expostos por este disco/controladora (comum em NVMe, USB e RAID) - usar os contadores de confiabilidade e a saúde acima' 'Info' }

    Log 'Verificando espaço livre nas unidades...'
    $vols = @(Get-Volume | Where-Object { $_.DriveLetter -and ([string]$_.DriveType -in @('Fixed', '3')) -and $_.Size -gt 0 } | Sort-Object DriveLetter)
    $tv = foreach ($v in $vols) {
        $pct = [math]::Round($v.SizeRemaining / $v.Size * 100, 0)
        if ("$($v.DriveLetter):" -eq $env:SystemDrive) { $R.Metricas.LivreSistema = $pct }
        [pscustomobject]@{ 'Unidade' = "$($v.DriveLetter):"; 'Rótulo' = $v.FileSystemLabel; 'Sistema de arquivos' = $v.FileSystem; 'Tamanho (GB)' = GB $v.Size; 'Livre (GB)' = GB $v.SizeRemaining; 'Livre (%)' = $pct }
        Add-Item $R ("Unidade {0}: espaço livre" -f $v.DriveLetter) ("{0} GB de {1} GB ({2}%)" -f (GB $v.SizeRemaining), (GB $v.Size), $pct) $(if ($pct -lt 10) { 'Crítico' } elseif ($pct -lt 20) { 'Atenção' } else { 'OK' })
    }
    Add-Tabela $R 'Unidades (volumes)' $tv
    $ls = $R.Metricas.LivreSistema
    if ($null -ne $ls -and $ls -lt 10) { Add-Achado $R 'Desempenho' 'Alto' "Disco do sistema com apenas $ls% de espaço livre." 'Liberar espaço (Limpeza de Disco, remover arquivos/programas desnecessários) ou ampliar o armazenamento.' 1.5 -Upgrade }
    elseif ($null -ne $ls -and $ls -lt 20) { Add-Achado $R 'Desempenho' 'Médio' "Disco do sistema com $ls% de espaço livre." 'Fazer limpeza de arquivos temporários e manter pelo menos 20% livre.' 0.5 }

    Log 'Calculando arquivos temporários...'
    $tmpTot = 0
    $pastas = @("$env:windir\Temp") + @(Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' })
    foreach ($p in $pastas) { if (Test-Path $p) { $tmpTot += [double](Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } }
    Add-Item $R 'Arquivos temporários' ("{0} GB" -f (GB $tmpTot)) $(if ($tmpTot -gt 5GB) { 'Atenção' } else { 'OK' })
    if ($tmpTot -gt 5GB) { Add-Achado $R 'Desempenho' 'Baixo' ("{0} GB em arquivos temporários." -f (GB $tmpTot)) 'Executar a Limpeza de Disco / Sensor de Armazenamento.' 0.2 }

    if ($Cfg.TesteDisco) {
        # Leitura real de CADA disco físico pelo dispositivo bruto (\\.\PhysicalDriveN).
        # 'amostrado' percorre o disco inteiro em ~200 pontos; 'completo' lê todos os setores.
        $completo = [bool]$Cfg.LeituraCompleta
        function Read-DiscoBruto([int]$numero, [int64]$tamanho, [bool]$full) {
            $r = @{ Lido = [int64]0; Erros = (New-Object System.Collections.ArrayList); Velos = (New-Object System.Collections.ArrayList); MinMB = $null; MaxMB = 0.0; MedMB = $null; Cancelado = $false; Falha = $null }
            if (-not $tamanho -or $tamanho -lt 1MB) { $r.Falha = 'tamanho do disco desconhecido'; return $r }
            $bloco = [int]8MB
            try { $fs = New-Object IO.FileStream("\\.\PhysicalDrive$numero", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite) }
            catch { $r.Falha = $_.Exception.Message; return $r }
            $buf = New-Object byte[] $bloco
            try {
                if ($full) {
                    $pos = [int64]0; $prox = 0
                    while ($pos -lt $tamanho) {
                        if ($Sync.Cancelar) { $r.Cancelado = $true; break }
                        $ler = [int][math]::Min([int64]$bloco, $tamanho - $pos); $ler = $ler - ($ler % 4096)
                        if ($ler -le 0) { break }
                        try {
                            $fs.Position = $pos
                            $sw = [Diagnostics.Stopwatch]::StartNew(); $n = $fs.Read($buf, 0, $ler); $sw.Stop()
                            if ($n -le 0) { break }
                            $mb = ($n / 1MB) / [math]::Max(0.0001, $sw.Elapsed.TotalSeconds)
                            [void]$r.Velos.Add($mb); if ($mb -gt $r.MaxMB) { $r.MaxMB = $mb }; if ($null -eq $r.MinMB -or $mb -lt $r.MinMB) { $r.MinMB = $mb }
                            $r.Lido += $n; $pos += $n
                        } catch { [void]$r.Erros.Add($pos); $pos += $bloco }
                        $pct = [int]($pos * 100 / $tamanho)
                        if ($pct -ge $prox) { Log ("    disco {0}: {1}% ({2:N0} GB de {3:N0} GB) - {4} erro(s) de leitura" -f $numero, $pct, ($pos / 1GB), ($tamanho / 1GB), $r.Erros.Count); $prox += 2 }
                    }
                }
                else {
                    $amostras = 200
                    for ($i = 0; $i -lt $amostras; $i++) {
                        if ($Sync.Cancelar) { $r.Cancelado = $true; break }
                        $pos = [int64]([double]$i * $tamanho / $amostras); $pos = $pos - ($pos % 4096)
                        if ($pos + $bloco -gt $tamanho) { $pos = $tamanho - $bloco - (($tamanho - $bloco) % 4096) }
                        if ($pos -lt 0) { $pos = 0 }
                        try {
                            $fs.Position = $pos
                            $sw = [Diagnostics.Stopwatch]::StartNew(); $n = $fs.Read($buf, 0, $bloco); $sw.Stop()
                            if ($n -le 0) { continue }
                            $mb = ($n / 1MB) / [math]::Max(0.0001, $sw.Elapsed.TotalSeconds)
                            [void]$r.Velos.Add($mb); if ($mb -gt $r.MaxMB) { $r.MaxMB = $mb }; if ($null -eq $r.MinMB -or $mb -lt $r.MinMB) { $r.MinMB = $mb }
                            $r.Lido += $n
                        } catch { [void]$r.Erros.Add($pos) }
                        if ($i % 40 -eq 0) { Log ("    disco {0}: amostra {1}/{2}" -f $numero, $i, $amostras) }
                    }
                }
            } finally { $fs.Close() }
            if ($r.Velos.Count) { $r.MedMB = ($r.Velos | Measure-Object -Average).Average }
            return $r
        }

        $modoTxt = if ($completo) { 'completa (todos os setores)' } else { 'amostrada (200 pontos ao longo do disco)' }
        Log ("Leitura {0} dos discos físicos..." -f $modoTxt)
        $tLeit = New-Object System.Collections.ArrayList
        $fis = @(Get-PhysicalDisk | Where-Object { [string]$_.BusType -notin @('7', 'USB') -or $completo })
        foreach ($pd in @(Get-PhysicalDisk | Sort-Object DeviceId)) {
            $num = [int]$pd.DeviceId
            $bt = [string]$pd.BusType; if ($bt -eq '17') { $bt = 'NVMe' } elseif ($bt -eq '11') { $bt = 'SATA' } elseif ($bt -eq '7') { $bt = 'USB' } elseif ($bt -eq '8') { $bt = 'RAID' }
            Log ("  Lendo disco {0}: {1} ({2} GB)..." -f $num, $pd.FriendlyName, (GB $pd.Size))
            $rd = Read-DiscoBruto $num ([int64]$pd.Size) $completo
            if ($rd.Falha) { Add-Item $R ("Leitura do disco {0} ({1})" -f $num, $pd.FriendlyName) ("Não foi possível ler: {0}" -f $rd.Falha) 'Atenção'; continue }
            $med = if ($null -ne $rd.MedMB) { [math]::Round($rd.MedMB, 0) } else { 0 }
            $mn = if ($null -ne $rd.MinMB) { [math]::Round($rd.MinMB, 0) } else { 0 }
            $mx = [math]::Round($rd.MaxMB, 0)
            $nErr = $rd.Erros.Count
            $gb = [math]::Round($rd.Lido / 1GB, 2)
            $cobertura = if ($completo) { "$gb GB (100% - setor por setor)" } else { "$gb GB (amostragem ao longo de $(GB $pd.Size) GB)" }
            $stat = if ($nErr -gt 0) { 'Crítico' } elseif ($med -gt 0 -and $med -lt 80 -and $bt -ne 'USB') { 'Atenção' } elseif ($rd.Cancelado) { 'Atenção' } else { 'OK' }
            $txt = ("Média {0} MB/s (mín {1} / máx {2}) | lido {3}{4} | {5} erro(s) de leitura{6}" -f $med, $mn, $mx, $cobertura, '', $nErr, $(if ($rd.Cancelado) { ' | CANCELADO' } else { '' }))
            Add-Item $R ("Leitura do disco {0}: {1} [{2}]" -f $num, $pd.FriendlyName, $bt) $txt $stat
            [void]$tLeit.Add([pscustomobject]@{
                'Disco' = "$num - $($pd.FriendlyName)"; 'Interface' = $bt; 'Tamanho (GB)' = GB $pd.Size
                'Modo' = $(if ($completo) { 'Completo' } else { 'Amostrado' }); 'Lido (GB)' = $gb
                'Vel. média (MB/s)' = $med; 'Mínima' = $mn; 'Máxima' = $mx; 'Erros de leitura' = $nErr
            })
            if ($num -eq 0 -or ([string]$pd.DeviceId -eq [string]$R.Metricas.NumSistema)) { $R.Metricas.LeituraSistema = $med }
            if ($nErr -gt 0) {
                $locais = (($rd.Erros | Select-Object -First 5 | ForEach-Object { "{0:N1} GB" -f ($_ / 1GB) }) -join ', ')
                Add-Achado $R 'Desempenho' 'Crítico' ("Disco {0} ({1}) com {2} erro(s) de leitura (setores defeituosos) - ex.: {3}." -f $num, $pd.FriendlyName, $nErr, $locais) 'Fazer backup IMEDIATO. Setores ilegíveis indicam disco em falha física. Rodar chkdsk /r e substituir o disco.' 3 -Upgrade
            }
            if ($nErr -eq 0 -and $med -gt 0 -and $med -lt 80 -and $bt -in @('SATA', 'RAID')) {
                Add-Achado $R 'Desempenho' 'Médio' ("Disco {0} ({1}) com leitura média baixa ({2} MB/s)." -f $num, $pd.FriendlyName, $med) 'Verificar cabo/porta SATA, fragmentação (HDD), saúde do disco e modo AHCI. Se for o disco do sistema, considerar SSD.' 0.5
            }
        }
        Add-Tabela $R ("Leitura dos discos ({0})" -f $modoTxt) $tLeit

        # Latência aleatória 4K no disco do sistema (importante para SSD)
        $letra = $env:SystemDrive.TrimEnd(':')
        $ran = $null
        $o = Invoke-Cmd "$env:windir\System32\winsat.exe" "disk -ran -read -drive $letra" 180000
        $m = [regex]::Matches($o, '([\d]+[\.,]?[\d]*)\s*MB/s')
        if ($m.Count) { $ran = [math]::Round([double]($m[$m.Count - 1].Groups[1].Value -replace ',', '.'), 1) }
        if ($ran) { Add-Item $R 'Leitura aleatória 4K (disco do sistema)' "$ran MB/s" $(if ($ran -lt 10) { 'Atenção' } else { 'OK' }) }
        Add-Item $R 'Modo do teste de leitura' $modoTxt 'Info'
    }
    else { Add-Item $R 'Teste de leitura dos discos' 'Não executado (opção desmarcada)' }
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'desempenho'; Nome = 'Processador e desempenho geral'; Timeout = 150
   Desc = 'Carga da CPU em repouso, benchmark de CPU (mono e multi-thread), processos que mais usam CPU, programas na inicialização, plano de energia e saúde da bateria.'
   Codigo = {
    $R = New-R
    Log 'Medindo a carga do processador (5 amostras)...'
    $am = @()
    for ($i = 0; $i -lt 5; $i++) {
        $v = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
        $am += [double]$v; Start-Sleep -Milliseconds 900
    }
    $media = [math]::Round(($am | Measure-Object -Average).Average, 0)
    Add-Item $R 'Carga média da CPU em repouso' "$media%" $(if ($media -ge 80) { 'Crítico' } elseif ($media -ge 50) { 'Atenção' } else { 'OK' })

    Log 'Executando benchmark de CPU (cálculo de números primos)...'
    $cs = @'
public static class AuditorBench {
    static bool P(int i) { for (int j = 2; (long)j * j <= i; j++) { if (i % j == 0) return false; } return true; }
    public static int Primos(int n) { int c = 0; for (int i = 2; i < n; i++) { if (P(i)) c++; } return c; }
    public static int PrimosMT(int n) {
        int total = 0; int k = System.Environment.ProcessorCount;
        System.Threading.Tasks.Parallel.For(0, k, t => {
            int c = 0; for (int i = 2 + t; i < n; i += k) { if (P(i)) c++; }
            System.Threading.Interlocked.Add(ref total, c);
        });
        return total;
    }
}
'@
    if (-not ('AuditorBench' -as [type])) { Add-Type -TypeDefinition $cs -ErrorAction SilentlyContinue }
    if ('AuditorBench' -as [type]) {
        [void][AuditorBench]::Primos(200000)
        $sw = [Diagnostics.Stopwatch]::StartNew(); [void][AuditorBench]::Primos(2000000); $sw.Stop(); $mono = [int]$sw.ElapsedMilliseconds
        $sw = [Diagnostics.Stopwatch]::StartNew(); [void][AuditorBench]::PrimosMT(8000000); $sw.Stop(); $multi = [int]$sw.ElapsedMilliseconds
        $ptsMono = [math]::Round(500000 / [math]::Max(1, $mono), 0)
        $ptsMulti = [math]::Round(4000000 / [math]::Max(1, $multi), 0)
        Add-Item $R 'Benchmark CPU mono-thread' "$ptsMono pontos ($mono ms)" $(if ($mono -gt 1300) { 'Atenção' } else { 'OK' })
        Add-Item $R 'Benchmark CPU multi-thread' "$ptsMulti pontos ($multi ms)" 'Info'
        $R.Metricas.BenchMono = $mono; $R.Metricas.BenchMulti = $multi
        if ($mono -gt 2500) { Add-Achado $R 'Desempenho' 'Alto' "Processador com desempenho muito baixo no benchmark ($ptsMono pontos)." 'O processador limita o uso atual. Avaliar a substituição do equipamento.' 2 -Upgrade }
        elseif ($mono -gt 1300) { Add-Achado $R 'Desempenho' 'Médio' "Processador com desempenho abaixo da média ($ptsMono pontos)." 'Adequado para tarefas leves. Para uso intenso, considerar equipamento mais novo.' 1 }
        elseif ($mono -gt 800) { Add-Achado $R 'Desempenho' 'Baixo' "Processador com desempenho intermediário ($ptsMono pontos)." 'Desempenho adequado para escritório.' 0.4 }
    }
    $nuc = (Get-CimInstance Win32_Processor | Measure-Object NumberOfCores -Sum).Sum
    if ($nuc -lt 4) { Add-Achado $R 'Desempenho' 'Médio' "Processador com apenas $nuc núcleo(s)." 'Para multitarefa, o ideal são 4 núcleos ou mais.' 0.7 -Upgrade }
    if ($media -ge 80) { Add-Achado $R 'Desempenho' 'Alto' "CPU com $media% de uso mesmo em repouso." 'Verificar os processos da tabela abaixo; pode indicar malware (minerador) ou programa travado.' 1 }
    elseif ($media -ge 50) { Add-Achado $R 'Desempenho' 'Médio' "CPU com $media% de uso em repouso." 'Revisar os processos em segundo plano.' 0.5 }

    Log 'Medindo uso de CPU por processo...'
    $p1 = @{}; Get-Process | ForEach-Object { $p1[$_.Id] = $_.TotalProcessorTime.TotalMilliseconds }
    Start-Sleep -Seconds 2
    $np = [int]$env:NUMBER_OF_PROCESSORS; if (-not $np) { $np = 1 }
    $top = Get-Process | ForEach-Object {
        if ($p1.ContainsKey($_.Id)) {
            [pscustomobject]@{ 'Processo' = $_.ProcessName; 'CPU (%)' = [math]::Round(([double]$_.TotalProcessorTime.TotalMilliseconds - [double]$p1[$_.Id]) / 2000 / $np * 100, 1); 'RAM (MB)' = [math]::Round($_.WorkingSet64 / 1MB, 0); 'PID' = $_.Id }
        }
    } | Sort-Object 'CPU (%)' -Descending | Select-Object -First 10
    Add-Tabela $R 'Processos que mais usam CPU (amostra de 2 s)' $top

    Log 'Listando programas da inicialização...'
    $st = @(Get-CimInstance Win32_StartupCommand)
    Add-Item $R 'Programas na inicialização' $st.Count $(if ($st.Count -gt 12) { 'Atenção' } else { 'OK' })
    Add-Tabela $R 'Programas que iniciam com o Windows' ($st | Select-Object @{n = 'Nome'; e = { $_.Name } }, @{n = 'Comando'; e = { $_.Command } }, @{n = 'Local'; e = { $_.Location } }, @{n = 'Usuário'; e = { $_.User } })
    if ($st.Count -gt 12) { Add-Achado $R 'Desempenho' 'Médio' "$($st.Count) programas iniciam junto com o Windows." 'Desativar os desnecessários (Gerenciador de Tarefas > Aplicativos de inicialização).' 0.5 }

    $pc = Invoke-Cmd "$env:windir\System32\powercfg.exe" '/getactivescheme' 15000
    if ($pc -match '\(([^)]+)\)') { Add-Item $R 'Plano de energia' $Matches[1] }

    $bat = Get-CimInstance Win32_Battery | Select-Object -First 1
    if ($bat) {
        Log 'Gerando relatório da bateria...'
        Add-Item $R 'Carga atual da bateria' "$($bat.EstimatedChargeRemaining)%"
        $x = Join-Path $env:TEMP 'auditorti_bateria.xml'
        Remove-Item $x -Force -ErrorAction SilentlyContinue
        [void](Invoke-Cmd "$env:windir\System32\powercfg.exe" "/batteryreport /xml /output `"$x`"" 60000)
        if (Test-Path $x) {
            try {
                [xml]$bx = Get-Content $x -Raw
                $b1 = @($bx.BatteryReport.Batteries.Battery)[0]
                $des = [double]$b1.DesignCapacity; $full = [double]$b1.FullChargeCapacity
                if ($des -gt 0) {
                    $sd = [math]::Round($full / $des * 100, 0)
                    Add-Item $R 'Saúde da bateria' ("{0}% da capacidade original ({1:N0} de {2:N0} mWh) - {3} ciclos" -f $sd, $full, $des, $b1.CycleCount) $(if ($sd -lt 60) { 'Crítico' } elseif ($sd -lt 80) { 'Atenção' } else { 'OK' })
                    $R.Metricas.Bateria = $sd
                    if ($sd -lt 60) { Add-Achado $R 'Desempenho' 'Médio' "Bateria com apenas $sd% da capacidade original." 'Substituir a bateria do notebook.' 0.5 -Upgrade }
                }
            } catch {}
            Remove-Item $x -Force -ErrorAction SilentlyContinue
        }
    }
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'rede'; Nome = 'Rede e portas'; Timeout = 150
   Desc = 'Adaptadores, IP/gateway/DNS, conectividade e latência, perfil de rede, portas TCP em escuta e processos, SMBv1, compartilhamentos e Wi-Fi.'
   Codigo = {
    $R = New-R
    Log 'Lendo adaptadores de rede...'
    $ads = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { [string]$_.Status -eq 'Up' })
    Add-Tabela $R 'Adaptadores de rede ativos' ($ads | Select-Object @{n = 'Adaptador'; e = { $_.Name } }, @{n = 'Descrição'; e = { $_.InterfaceDescription } }, @{n = 'Velocidade'; e = { $_.LinkSpeed } }, @{n = 'MAC'; e = { $_.MacAddress } })
    $cfgs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.NetAdapter -and [string]$_.NetAdapter.Status -eq 'Up' })
    foreach ($c in $cfgs) {
        $dns = @($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ', '
        Add-Item $R ("Rede: {0}" -f $c.InterfaceAlias) ("IP {0} | Gateway {1} | DNS {2}" -f (($c.IPv4Address.IPAddress) -join ', '), (($c.IPv4DefaultGateway.NextHop) -join ', '), $dns)
    }
    Add-Tabela $R 'Perfis de conexão' (Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object @{n = 'Rede'; e = { $_.Name } }, @{n = 'Interface'; e = { $_.InterfaceAlias } }, @{n = 'Categoria'; e = { switch ([string]$_.NetworkCategory) { 'Public' { 'Pública' } 'Private' { 'Privada' } 'DomainAuthenticated' { 'Domínio' } default { [string]$_.NetworkCategory } } } }, @{n = 'Internet IPv4'; e = { [string]$_.IPv4Connectivity } })

    Log 'Testando conectividade com a internet...'
    $ping = @(Test-Connection 8.8.8.8 -Count 3 -ErrorAction SilentlyContinue)
    if ($ping.Count) {
        $lat = [math]::Round(($ping | Measure-Object ResponseTime -Average).Average, 0)
        Add-Item $R 'Internet (ping 8.8.8.8)' "OK - latência média $lat ms" $(if ($lat -gt 150) { 'Atenção' } else { 'OK' })
        $R.Metricas.Internet = $true
    }
    else { Add-Item $R 'Internet (ping 8.8.8.8)' 'Sem resposta' 'Atenção'; $R.Metricas.Internet = $false }
    $dnsOk = Resolve-DnsName 'www.microsoft.com' -Type A -QuickTimeout -ErrorAction SilentlyContinue
    Add-Item $R 'Resolução de nomes (DNS)' $(if ($dnsOk) { 'OK' } else { 'Falhou' }) $(if ($dnsOk) { 'OK' } else { 'Atenção' })

    Log 'Mapeando portas TCP em escuta e processos responsáveis...'
    $procs = @{}; Get-Process | ForEach-Object { $procs[$_.Id] = $_.ProcessName }
    $svcPid = @{}
    Get-CimInstance Win32_Service -Filter 'ProcessId > 0' | ForEach-Object { $k = [int]$_.ProcessId; if ($svcPid[$k]) { $svcPid[$k] += ', ' + $_.Name } else { $svcPid[$k] = $_.Name } }
    $risco = @{ 21 = 'FTP (sem criptografia)'; 23 = 'Telnet (sem criptografia)'; 69 = 'TFTP'; 135 = 'RPC do Windows'; 139 = 'NetBIOS'; 445 = 'SMB (compartilhamento de arquivos)'; 1433 = 'SQL Server'; 3306 = 'MySQL'; 3389 = 'Área de Trabalho Remota (RDP)'; 5432 = 'PostgreSQL'; 5800 = 'VNC (web)'; 5900 = 'VNC'; 5985 = 'WinRM HTTP'; 5986 = 'WinRM HTTPS'; 8080 = 'HTTP alternativo' }
    $tcp = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Sort-Object LocalPort)
    $vistos = @{}; $expostas = New-Object System.Collections.ArrayList; $locais = 0
    foreach ($c in $tcp) {
        $k = "$($c.LocalAddress):$($c.LocalPort)"; if ($vistos[$k]) { continue }; $vistos[$k] = 1
        if ($c.LocalAddress -in @('127.0.0.1', '::1')) { $locais++; continue }
        $porta = [int]$c.LocalPort
        [void]$expostas.Add([pscustomobject]@{
            'Porta' = $porta; 'Endereço' = $c.LocalAddress; 'Processo' = $procs[[int]$c.OwningProcess]; 'PID' = $c.OwningProcess
            'Serviço' = $svcPid[[int]$c.OwningProcess]; 'Observação' = $(if ($risco.ContainsKey($porta)) { $risco[$porta] } else { '' })
        })
    }
    $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue)
    Add-Item $R 'Portas TCP abertas para a rede' $expostas.Count
    Add-Item $R 'Portas TCP apenas locais (127.0.0.1)' $locais
    Add-Item $R 'Portas UDP em uso' $udp.Count
    Add-Tabela $R 'Portas TCP em escuta acessíveis pela rede' $expostas
    $portasExp = @($expostas | ForEach-Object { $_.Porta } | Sort-Object -Unique)
    foreach ($pt in @(21, 23, 69, 5800, 5900)) { if ($portasExp -contains $pt) { Add-Achado $R 'Segurança' 'Alto' "Serviço inseguro na porta $pt ($($risco[$pt])) aberto para a rede." 'Desativar o serviço ou bloquear a porta no firewall. Usar alternativas criptografadas (SFTP/SSH, RDP com NLA, VPN).' } }
    foreach ($pt in @(1433, 3306, 5432)) { if ($portasExp -contains $pt) { Add-Achado $R 'Segurança' 'Médio' "Banco de dados ($($risco[$pt])) escutando na rede na porta $pt." 'Restringir no firewall aos IPs que realmente precisam acessar o banco.' } }
    if ($portasExp -contains 3389) { Add-Achado $R 'Segurança' 'Médio' 'Área de Trabalho Remota (porta 3389) aberta para a rede.' 'Se não for usada, desativar. Se for, restringir no firewall, exigir NLA e senhas fortes; nunca expor à internet sem VPN.' }
    if ($portasExp -contains 5985 -or $portasExp -contains 5986) { Add-Achado $R 'Segurança' 'Baixo' 'WinRM (gerenciamento remoto) escutando na rede.' 'Desativar se não for usado para administração remota.' }

    Log 'Verificando protocolo SMB e compartilhamentos...'
    $smb = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
    if ($smb) {
        if ($smb.EnableSMB1Protocol) {
            Add-Item $R 'SMBv1 (protocolo antigo)' 'ATIVADO' 'Crítico'
            Add-Achado $R 'Segurança' 'Alto' 'Protocolo SMBv1 ativado (vulnerável - explorado pelo ransomware WannaCry).' 'Desativar: Set-SmbServerConfiguration -EnableSMB1Protocol $false e remover o recurso "Suporte para SMB 1.0/CIFS".'
        }
        else { Add-Item $R 'SMBv1 (protocolo antigo)' 'Desativado' 'OK' }
        Add-Item $R 'Assinatura SMB obrigatória' (SimNao $smb.RequireSecuritySignature) $(if ($smb.RequireSecuritySignature) { 'OK' } else { 'Info' })
    }
    $sh = @(Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^(ADMIN\$|IPC\$|[A-Za-z]\$|print\$)$' })
    $tsh = foreach ($s in $sh) {
        $ac = @(Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue)
        foreach ($a in $ac) {
            if ($a.AccountName -match 'Everyone|Todos' -and [string]$a.AccessRight -match 'Full|0' -and [string]$a.AccessControlType -match 'Allow|0') {
                Add-Achado $R 'Segurança' 'Alto' "Compartilhamento '$($s.Name)' com CONTROLE TOTAL para Todos." 'Restringir as permissões apenas aos usuários/grupos necessários.'
            }
        }
        [pscustomobject]@{ 'Compartilhamento' = $s.Name; 'Caminho' = $s.Path; 'Permissões' = (($ac | ForEach-Object { "$($_.AccountName): $($_.AccessRight)" }) -join '; ') }
    }
    Add-Item $R 'Pastas compartilhadas' @($tsh).Count
    Add-Tabela $R 'Pastas compartilhadas na rede' $tsh

    $w = Invoke-Cmd "$env:windir\System32\netsh.exe" 'wlan show interfaces' 15000
    $mS = [regex]::Match($w, '(?m)^\s*SSID\s*:\s*(.+)$')
    if ($mS.Success) {
        $sinal = [regex]::Match($w, '(\d+)\s*%').Groups[1].Value
        $aut = [regex]::Match($w, '(?m)^\s*(Autentica\S*|Authentication)\s*:\s*(.+)$').Groups[2].Value.Trim()
        Add-Item $R 'Wi-Fi conectado' ("{0} - sinal {1}% - {2}" -f $mS.Groups[1].Value.Trim(), $sinal, $aut) $(if ([int]$sinal -lt 50) { 'Atenção' } else { 'OK' })
        if ($aut -match 'Abert|Open|WEP') { Add-Achado $R 'Segurança' 'Alto' "Rede Wi-Fi sem criptografia adequada ($aut)." 'Configurar o roteador com WPA2-AES ou WPA3 e senha forte.' }
    }
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'audio'; Nome = 'Áudio'; Timeout = 60
   Desc = 'Dispositivos de som, serviços de áudio, dispositivos de reprodução/gravação e teste audível (confirmado pelo técnico).'
   Codigo = {
    $R = New-R
    Log 'Verificando dispositivos de som...'
    $snd = @(Get-CimInstance Win32_SoundDevice)
    Add-Item $R 'Placas/controladoras de som' $snd.Count $(if ($snd.Count) { 'OK' } else { 'Crítico' })
    Add-Tabela $R 'Dispositivos de som' ($snd | Select-Object @{n = 'Dispositivo'; e = { $_.Name } }, @{n = 'Fabricante'; e = { $_.Manufacturer } }, @{n = 'Status'; e = { $_.Status } })
    foreach ($s in $snd) { if ($s.Status -and $s.Status -ne 'OK') { Add-Achado $R 'Desempenho' 'Médio' "Dispositivo de som '$($s.Name)' com status $($s.Status)." 'Reinstalar o driver de áudio do fabricante.' 0.3 } }
    if (-not $snd.Count) { Add-Achado $R 'Desempenho' 'Médio' 'Nenhum dispositivo de som encontrado.' 'Verificar se o áudio está ativado na BIOS e instalar o driver.' 0.3 }
    foreach ($n in @('Audiosrv', 'AudioEndpointBuilder')) {
        $s = Get-Service $n -ErrorAction SilentlyContinue
        if ($s) {
            Add-Item $R "Serviço: $($s.DisplayName)" $(if ([string]$s.Status -eq 'Running') { 'Em execução' } else { [string]$s.Status }) $(if ([string]$s.Status -eq 'Running') { 'OK' } else { 'Crítico' })
            if ([string]$s.Status -ne 'Running') { Add-Achado $R 'Desempenho' 'Médio' "Serviço de áudio $($s.DisplayName) parado." 'Iniciar o serviço e configurá-lo como Automático.' 0.5 }
        }
    }
    $ends = @(Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue)
    Add-Tabela $R 'Dispositivos de reprodução e gravação' ($ends | Select-Object @{n = 'Dispositivo'; e = { $_.FriendlyName } }, @{n = 'Status'; e = { [string]$_.Status } })
    Add-Item $R 'Dispositivos de reprodução/gravação' $ends.Count
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'servicos'; Nome = 'Serviços do Windows'; Timeout = 300
   Desc = 'Serviços em execução, serviços não essenciais (com opção de desativar após confirmação), serviços de terceiros, assinatura digital, caminhos sem aspas e caminhos suspeitos.'
   Codigo = {
    $R = New-R
    Log 'Listando serviços do Windows...'
    $svcs = @(Get-CimInstance Win32_Service)
    $rod = @($svcs | Where-Object { $_.State -eq 'Running' })
    Add-Item $R 'Serviços instalados' $svcs.Count
    Add-Item $R 'Serviços em execução' $rod.Count

    $cand = [ordered]@{
        'DiagTrack'        = @('Recomendado', 'Telemetria da Microsoft (envia dados de uso). Não afeta o funcionamento.')
        'dmwappushservice' = @('Recomendado', 'Roteamento de mensagens de telemetria.')
        'RemoteRegistry'   = @('Recomendado', 'Permite editar o registro pela rede - risco de segurança.')
        'Fax'              = @('Recomendado', 'Serviço de fax.')
        'RetailDemo'       = @('Recomendado', 'Modo de demonstração de loja.')
        'MapsBroker'       = @('Recomendado', 'Download de mapas offline.')
        'WMPNetworkSvc'    = @('Recomendado', 'Compartilhamento de mídia do Windows Media Player.')
        'XblAuthManager'   = @('Recomendado', 'Xbox Live (jogos).')
        'XblGameSave'      = @('Recomendado', 'Xbox Live - salvamento de jogos.')
        'XboxNetApiSvc'    = @('Recomendado', 'Xbox Live - rede.')
        'TlntSvr'          = @('Recomendado', 'Servidor Telnet - protocolo sem criptografia.')
        'ftpsvc'           = @('Recomendado', 'Servidor FTP (IIS) - protocolo sem criptografia.')
        'Spooler'          = @('Recomendado', 'Spooler de impressão: nenhuma impressora física instalada (reduz risco PrintNightmare).')
        'XboxGipSvc'       = @('Avaliar', 'Acessórios Xbox (controles).')
        'SNMP'             = @('Avaliar', 'Agente SNMP - desativar se não houver monitoramento.')
        'SharedAccess'     = @('Avaliar', 'Compartilhamento de conexão com a Internet (ICS/hotspot).')
        'SSDPSrv'          = @('Avaliar', 'Descoberta UPnP - necessária para descoberta de rede/dispositivos.')
        'upnphost'         = @('Avaliar', 'Host de dispositivos UPnP.')
        'lfsvc'            = @('Avaliar', 'Geolocalização - desativar se não usa localização.')
        'WerSvc'           = @('Avaliar', 'Relatório de erros do Windows.')
        'TermService'      = @('Avaliar', 'Área de Trabalho Remota - desativar SOMENTE se não for usada para suporte.')
        'WinRM'            = @('Avaliar', 'Gerenciamento remoto do Windows - desativar se não for usado.')
    }
    $imp = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'PDF|XPS|OneNote|Fax|Send To|Enviar' })
    $estado = @{ 'Running' = 'Em execução'; 'Stopped' = 'Parado' }
    $lista = foreach ($n in $cand.Keys) {
        $s = $svcs | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        if (-not $s -or $s.StartMode -eq 'Disabled') { continue }
        if ($n -eq 'Spooler' -and $imp.Count -gt 0) { continue }
        [pscustomobject]@{ 'Serviço' = $s.Name; 'Nome' = $s.DisplayName; 'Estado' = $(if ($estado[$s.State]) { $estado[$s.State] } else { $s.State }); 'Inicialização' = $s.StartMode; 'Classificação' = $cand[$n][0]; 'Motivo' = $cand[$n][1] }
    }
    $lista = @($lista)
    $R.Extra.Candidatos = $lista
    Add-Item $R 'Serviços não essenciais ativos' $lista.Count $(if ($lista.Count) { 'Atenção' } else { 'OK' })
    Add-Tabela $R 'Serviços não essenciais identificados' $lista
    $recom = @($lista | Where-Object { $_.'Classificação' -eq 'Recomendado' })
    if ($recom.Count) { Add-Achado $R 'Desempenho' 'Baixo' ("{0} serviço(s) não essencial(is) habilitado(s): {1}." -f $recom.Count, (($recom | ForEach-Object { $_.'Serviço' }) -join ', ')) 'Desativar os serviços não utilizados (o AuditorTI oferece esta opção com confirmação e script de restauração).' ([math]::Min(0.8, $recom.Count * 0.1)) }
    foreach ($x in $lista) {
        if ($x.'Serviço' -eq 'RemoteRegistry' -and $x.Estado -eq 'Em execução') { Add-Achado $R 'Segurança' 'Médio' 'Serviço Registro Remoto em execução.' 'Desativar o serviço RemoteRegistry.' }
        if ($x.'Serviço' -in @('TlntSvr', 'ftpsvc')) { Add-Achado $R 'Segurança' 'Alto' "Serviço inseguro instalado: $($x.Nome)." 'Desativar e remover o recurso; usar alternativas criptografadas.' }
    }

    Log 'Analisando serviços de terceiros e assinaturas digitais...'
    $terc = New-Object System.Collections.ArrayList; $semAss = @(); $semAspas = @(); $susp = @()
    foreach ($s in $svcs) {
        $exe = Get-ExePath $s.PathName
        if (-not $exe -or $exe -match '^(?i)[a-z]:\\windows\\') { continue }
        $ass = Get-Assinatura $exe
        [void]$terc.Add([pscustomobject]@{ 'Serviço' = $s.Name; 'Nome' = $s.DisplayName; 'Estado' = $s.State; 'Início' = $s.StartMode; 'Conta' = $s.StartName; 'Executável' = $exe; 'Assinatura' = $ass })
        if ($ass -eq 'Não assinado' -and $s.State -eq 'Running') { $semAss += $s.DisplayName }
        if ($s.PathName -and $s.PathName -notmatch '^\s*"' -and $exe -match ' ') { $semAspas += $s.Name }
        if (Test-Suspeito $s.PathName) { $susp += "$($s.Name) ($exe)" }
    }
    Add-Item $R 'Serviços de terceiros' $terc.Count
    Add-Tabela $R 'Serviços de terceiros (fora da pasta do Windows)' $terc
    if ($semAss.Count) { Add-Achado $R 'Segurança' 'Médio' ("Serviço(s) em execução sem assinatura digital: {0}." -f ($semAss -join ', ')) 'Confirmar a origem desses programas; remover os desconhecidos.' }
    if ($semAspas.Count) { Add-Achado $R 'Segurança' 'Médio' ("Serviço(s) com caminho sem aspas (permite elevação de privilégio): {0}." -f ($semAspas -join ', ')) 'Corrigir o ImagePath no registro (HKLM\SYSTEM\CurrentControlSet\Services\<serviço>) colocando o caminho entre aspas.' }
    if ($susp.Count) { Add-Achado $R 'Segurança' 'Alto' ("Serviço(s) executando de local suspeito: {0}." -f ($susp -join '; ')) 'Investigar imediatamente com antivírus/antimalware; remover se for malicioso.' }

    $parados = @($svcs | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and -not $_.DelayedAutoStart } | Select-Object @{n = 'Serviço'; e = { $_.Name } }, @{n = 'Nome'; e = { $_.DisplayName } }, @{n = 'Estado'; e = { $_.State } })
    Add-Tabela $R 'Serviços automáticos que não estão em execução (informativo)' $parados
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'atualizacoes'; Nome = 'Atualizações e programas instalados'; Timeout = 900
   Desc = 'Histórico e pendências do Windows Update, reinicialização pendente, inventário de programas, atualizações de programas (winget), ferramentas de acesso remoto, softwares obsoletos e indesejados.'
   Codigo = {
    $R = New-R
    Log 'Lendo histórico do Windows Update...'
    $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
    if ($wu -and [string]$wu.StartType -eq 'Disabled') {
        Add-Item $R 'Serviço Windows Update' 'DESATIVADO' 'Crítico'
        Add-Achado $R 'Segurança' 'Alto' 'O serviço Windows Update está desativado.' 'Reativar o serviço (Manual) para receber correções de segurança.'
    }
    try {
        $sess = New-Object -ComObject Microsoft.Update.Session
        $srch = $sess.CreateUpdateSearcher()
        $n = $srch.GetTotalHistoryCount()
        $hist = @()
        if ($n -gt 0) { $hist = @($srch.QueryHistory(0, [math]::Min($n, 100))) }
        $ok = @($hist | Where-Object { $_.Operation -eq 1 -and $_.ResultCode -in 2, 3 })
        $fal = @($hist | Where-Object { $_.Operation -eq 1 -and $_.ResultCode -in 4, 5 })
        $ult = ($ok | Sort-Object Date -Descending | Select-Object -First 1).Date
        if ($ult) {
            $ult = $ult.ToLocalTime(); $dias = [int]((Get-Date) - $ult).TotalDays
            Add-Item $R 'Última atualização instalada' ("{0} (há {1} dias)" -f (Fmt $ult), $dias) $(if ($dias -gt 45) { 'Crítico' } elseif ($dias -gt 30) { 'Atenção' } else { 'OK' })
            $R.Metricas.DiasUpdate = $dias
            if ($dias -gt 45) { Add-Achado $R 'Segurança' 'Alto' "Nenhuma atualização do Windows instalada há $dias dias." 'Executar o Windows Update e investigar por que as atualizações não estão sendo instaladas.' }
            elseif ($dias -gt 30) { Add-Achado $R 'Segurança' 'Médio' "Última atualização do Windows há $dias dias." 'Executar o Windows Update.' }
        }
        Add-Item $R 'Falhas de instalação no histórico recente' $fal.Count $(if ($fal.Count -gt 3) { 'Atenção' } else { 'OK' })
        if ($fal.Count -gt 3) { Add-Achado $R 'Segurança' 'Baixo' "$($fal.Count) falhas de instalação de atualizações no histórico recente." 'Executar a solução de problemas do Windows Update / DISM /RestoreHealth e SFC /scannow.' }
        Add-Tabela $R 'Últimas atualizações instaladas' ($ok | Sort-Object Date -Descending | Select-Object -First 15 @{n = 'Data'; e = { Fmt ($_.Date.ToLocalTime()) } }, @{n = 'Atualização'; e = { $_.Title } })

        if ($Cfg.BuscarWU) {
            Log 'Buscando atualizações pendentes no Windows Update (pode levar alguns minutos)...'
            $res = $srch.Search("IsInstalled=0 and IsHidden=0")
            $pend = @(for ($i = 0; $i -lt $res.Updates.Count; $i++) {
                $u = $res.Updates.Item($i)
                [pscustomobject]@{ 'Atualização' = $u.Title; 'Severidade' = $(if ($u.MsrcSeverity) { $u.MsrcSeverity } else { '-' }); 'Tamanho (MB)' = [math]::Round([double]$u.MaxDownloadSize / 1MB, 1) }
            })
            Add-Item $R 'Atualizações do Windows pendentes' $pend.Count $(if ($pend.Count) { 'Atenção' } else { 'OK' })
            Add-Tabela $R 'Atualizações do Windows pendentes' $pend
            $R.Metricas.PendentesWU = $pend.Count
            $crit = @($pend | Where-Object { $_.Severidade -match 'Critical|Important' })
            if ($crit.Count) { Add-Achado $R 'Segurança' 'Alto' "$($crit.Count) atualização(ões) de segurança crítica/importante pendente(s)." 'Instalar as atualizações pendentes pelo Windows Update e reiniciar.' }
            elseif ($pend.Count) { Add-Achado $R 'Segurança' 'Médio' "$($pend.Count) atualização(ões) do Windows pendente(s)." 'Instalar as atualizações pendentes pelo Windows Update.' }
        }
        else { Add-Item $R 'Busca online de atualizações pendentes' 'Não executada (opção desmarcada)' }
    } catch { Add-Item $R 'Windows Update' "Não foi possível consultar: $($_.Exception.Message)" 'Atenção' }

    $rb = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    Add-Item $R 'Reinicialização pendente' (SimNao $rb) $(if ($rb) { 'Atenção' } else { 'OK' })
    if ($rb) { Add-Achado $R 'Segurança' 'Baixo' 'Há atualizações aguardando reinicialização para serem concluídas.' 'Reiniciar o computador.' }

    Log 'Inventariando programas instalados...'
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $progs = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } | Sort-Object DisplayName -Unique | Select-Object @{n = 'Programa'; e = { $_.DisplayName } }, @{n = 'Versão'; e = { $_.DisplayVersion } }, @{n = 'Fabricante'; e = { $_.Publisher } }, @{n = 'Instalado em'; e = { if ("$($_.InstallDate)" -match '^(\d{4})(\d{2})(\d{2})$') { "$($Matches[3])/$($Matches[2])/$($Matches[1])" } else { '-' } } })
    Add-Item $R 'Programas instalados' $progs.Count
    Add-Tabela $R 'Programas instalados' $progs

    $remoto = @($progs | Where-Object { $_.Programa -match 'AnyDesk|TeamViewer|RustDesk|UltraVNC|TightVNC|RealVNC|Chrome Remote|Splashtop|LogMeIn|Ammyy|Supremo|ScreenConnect|ConnectWise|NetSupport|Radmin|AeroAdmin|DWService|Remote Utilities|HopToDesk' })
    if ($remoto.Count) {
        Add-Item $R 'Ferramentas de acesso remoto' (($remoto | ForEach-Object { $_.Programa }) -join ', ') 'Atenção'
        Add-Achado $R 'Segurança' 'Médio' ("Ferramenta(s) de acesso remoto instalada(s): {0}." -f (($remoto | ForEach-Object { $_.Programa }) -join ', ')) 'Confirmar com o cliente se são autorizadas. Remover as não utilizadas e proteger as demais com senha forte e 2FA.'
    }
    $obs = @($progs | Where-Object { $_.Programa -match 'Flash Player|Shockwave|Silverlight|QuickTime|Java\(TM\) [67]|Java [67] Update|Internet Explorer' })
    if ($obs.Count) { Add-Achado $R 'Segurança' 'Alto' ("Software obsoleto/sem suporte: {0}." -f (($obs | ForEach-Object { $_.Programa }) -join ', ')) 'Desinstalar: esses programas não recebem mais correções de segurança.' }
    $pup = @($progs | Where-Object { $_.Programa -match 'Baidu|Driver Booster|Driver Easy|Reimage|PC Optimizer|Segurazo|ByteFence|Web Companion|Wave Browser|OneLaunch|Advanced SystemCare|MyPC Backup|Search Protect|Conduit|Ask Toolbar|PC Cleaner|Opera GX Browser Assistant' })
    if ($pup.Count) { Add-Achado $R 'Segurança' 'Médio' ("Possível software indesejado (PUP): {0}." -f (($pup | ForEach-Object { $_.Programa }) -join ', ')) 'Desinstalar e executar uma verificação antimalware.' }

    if ($Cfg.Winget) {
        Log 'Consultando atualizações de programas (winget)...'
        $wg = (Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $wg) { $wg = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName }
        if ($wg) {
            $txt = Invoke-Cmd $wg 'upgrade --include-unknown --accept-source-agreements --disable-interactivity' 180000 -Utf8
            $lns = @($txt -split "`n" | ForEach-Object { ($_ -split "`r")[-1] })
            $idx = -1; for ($i = 0; $i -lt $lns.Count; $i++) { if ($lns[$i] -match '^-{10,}') { $idx = $i; break } }
            $upd = New-Object System.Collections.ArrayList
            if ($idx -gt 0) {
                $hdr = $lns[$idx - 1]
                $st = @([regex]::Matches($hdr, '\S+') | ForEach-Object { $_.Index })
                if ($st.Count -ge 4) {
                    for ($j = $idx + 1; $j -lt $lns.Count; $j++) {
                        $l = $lns[$j]
                        if ($l.Length -lt $st[3] -or $l -match '^\d+\s') { break }
                        $fimDisp = if ($st.Count -ge 5 -and $l.Length -gt $st[4]) { $st[4] } else { $l.Length }
                        [void]$upd.Add([pscustomobject]@{
                            'Programa'   = $l.Substring(0, $st[1]).Trim()
                            'ID'         = $l.Substring($st[1], $st[2] - $st[1]).Trim()
                            'Versão atual' = $l.Substring($st[2], $st[3] - $st[2]).Trim()
                            'Disponível' = $l.Substring($st[3], $fimDisp - $st[3]).Trim()
                        })
                    }
                }
            }
            Add-Item $R 'Programas com atualização disponível (winget)' $upd.Count $(if ($upd.Count -gt 10) { 'Crítico' } elseif ($upd.Count) { 'Atenção' } else { 'OK' })
            Add-Tabela $R 'Programas com atualização disponível' $upd
            $R.Metricas.PendentesProg = $upd.Count
            if ($upd.Count -gt 10) { Add-Achado $R 'Segurança' 'Alto' "$($upd.Count) programas desatualizados." 'Atualizar os programas (comando: winget upgrade --all) e ativar a atualização automática deles.' }
            elseif ($upd.Count) { Add-Achado $R 'Segurança' 'Médio' "$($upd.Count) programa(s) desatualizado(s)." 'Atualizar os programas (comando: winget upgrade --all).' }
        }
        else { Add-Item $R 'Atualização de programas (winget)' 'winget não disponível neste computador' 'Info' }
    }
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'antivirus'; Nome = 'Antivírus e proteção contra ameaças'; Timeout = 120
   Desc = 'Antivírus registrados, proteção em tempo real, idade das definições, última verificação, proteção contra adulteração, exclusões configuradas e ameaças detectadas.'
   Codigo = {
    $R = New-R
    Log 'Consultando a Central de Segurança do Windows...'
    $ativo = $false; $atual = $false
    $avs = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
    $lin = foreach ($a in $avs) {
        $h = '{0:X6}' -f [int]$a.productState
        $en = $h.Substring(2, 2) -in @('10', '11'); $up = $h.Substring(4, 2) -eq '00'
        if ($en) { $ativo = $true; if ($up) { $atual = $true } }
        [pscustomobject]@{ 'Antivírus' = $a.displayName; 'Estado' = $(if ($en) { 'Ativo' } else { 'Desativado' }); 'Definições' = $(if ($up) { 'Atualizadas' } else { 'DESATUALIZADAS' }); 'Executável' = $a.pathToSignedProductExe }
    }
    Add-Tabela $R 'Antivírus registrados no Windows' $lin
    Add-Item $R 'Antivírus ativo' $(if ($ativo) { (($lin | Where-Object { $_.Estado -eq 'Ativo' } | ForEach-Object { $_.'Antivírus' }) -join ', ') } else { 'NENHUM' }) $(if ($ativo) { 'OK' } else { 'Crítico' })
    $R.Metricas.AVAtivo = $ativo

    $mp = $null; try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch {}
    $defNormal = $false
    if ($mp) {
        $defNormal = ([string]$mp.AMRunningMode -eq 'Normal')
        Add-Item $R 'Microsoft Defender - modo' $(switch ([string]$mp.AMRunningMode) { 'Normal' { 'Ativo (antivírus principal)' } 'Passive Mode' { 'Passivo (outro antivírus é o principal)' } 'EDR Block Mode' { 'Modo de bloqueio EDR' } default { [string]$mp.AMRunningMode } })
        Add-Item $R 'Proteção em tempo real (Defender)' (SimNao $mp.RealTimeProtectionEnabled) $(if ($mp.RealTimeProtectionEnabled -or -not $defNormal) { 'OK' } else { 'Crítico' })
        Add-Item $R 'Definições do Defender' ("{0} ({1} dia(s))" -f (Fmt $mp.AntivirusSignatureLastUpdated), $mp.AntivirusSignatureAge) $(if ($mp.AntivirusSignatureAge -gt 3 -and $defNormal) { 'Atenção' } else { 'OK' })
        Add-Item $R 'Última verificação rápida' $(if ($mp.QuickScanAge -lt 1000) { "há $($mp.QuickScanAge) dia(s)" } else { 'Nunca' }) $(if ($mp.QuickScanAge -gt 14 -and $defNormal) { 'Atenção' } else { 'OK' })
        Add-Item $R 'Proteção contra adulteração' (SimNao $mp.IsTamperProtected) $(if ($mp.IsTamperProtected -or -not $defNormal) { 'OK' } else { 'Atenção' })
        if ($defNormal) {
            if (-not $mp.RealTimeProtectionEnabled) { Add-Achado $R 'Segurança' 'Crítico' 'Proteção em tempo real do Microsoft Defender DESATIVADA.' 'Ativar em Segurança do Windows > Proteção contra vírus e ameaças. Se foi desativada sem motivo, investigar malware.' }
            if ($mp.AntivirusSignatureAge -gt 3) { Add-Achado $R 'Segurança' 'Alto' "Definições de vírus com $($mp.AntivirusSignatureAge) dias." 'Atualizar as definições do antivírus e verificar a conexão com o Windows Update.' }
            if ($mp.QuickScanAge -gt 14) { Add-Achado $R 'Segurança' 'Baixo' 'Nenhuma verificação rápida nos últimos 14 dias.' 'Agendar verificações periódicas.' }
            if (-not $mp.IsTamperProtected) { Add-Achado $R 'Segurança' 'Médio' 'Proteção contra adulteração do Defender desativada.' 'Ativar a Proteção contra Adulteração (impede que malware desligue o antivírus).' }
        }
    }
    if (-not $ativo) { Add-Achado $R 'Segurança' 'Crítico' 'Nenhum antivírus ativo no computador.' 'Ativar o Microsoft Defender ou instalar/ativar um antivírus corporativo imediatamente.' }
    elseif (-not $atual -and -not $defNormal) { Add-Achado $R 'Segurança' 'Alto' 'O antivírus ativo está com definições desatualizadas.' 'Atualizar o antivírus e verificar a licença.' }

    Log 'Verificando exclusões e ameaças detectadas...'
    $pref = Get-MpPreference -ErrorAction SilentlyContinue
    if ($pref) {
        $exc = New-Object System.Collections.ArrayList
        foreach ($v in @($pref.ExclusionPath)) { if ($v -and $v -notmatch '^N/A') { [void]$exc.Add([pscustomobject]@{ 'Tipo' = 'Pasta/arquivo'; 'Valor' = $v }) } }
        foreach ($v in @($pref.ExclusionProcess)) { if ($v -and $v -notmatch '^N/A') { [void]$exc.Add([pscustomobject]@{ 'Tipo' = 'Processo'; 'Valor' = $v }) } }
        foreach ($v in @($pref.ExclusionExtension)) { if ($v -and $v -notmatch '^N/A') { [void]$exc.Add([pscustomobject]@{ 'Tipo' = 'Extensão'; 'Valor' = $v }) } }
        Add-Item $R 'Exclusões no antivírus' $exc.Count $(if ($exc.Count) { 'Atenção' } else { 'OK' })
        Add-Tabela $R 'Exclusões configuradas no Defender' $exc
        if ($exc.Count) {
            $grave = @($exc | Where-Object { $_.Valor -match '^[A-Za-z]:\\?$|\\AppData|\\Temp|\\Users\\?$|^\.?(exe|dll|ps1|bat|vbs|js)$' })
            if ($grave.Count) { Add-Achado $R 'Segurança' 'Alto' ("Exclusões perigosas no antivírus: {0}." -f (($grave | ForEach-Object { $_.Valor }) -join ', ')) 'Remover imediatamente essas exclusões; malware costuma criá-las para não ser detectado.' }
            else { Add-Achado $R 'Segurança' 'Médio' "$($exc.Count) exclusão(ões) configurada(s) no antivírus." 'Revisar e manter apenas as exclusões justificadas.' }
        }
        if ($defNormal -and $pref.PUAProtection -eq 0) { Add-Achado $R 'Segurança' 'Baixo' 'Bloqueio de aplicativos potencialmente indesejados (PUA) desativado.' 'Ativar com: Set-MpPreference -PUAProtection Enabled' }
    }
    $nomes = @{}; Get-MpThreat -ErrorAction SilentlyContinue | ForEach-Object { $nomes[[string]$_.ThreatID] = $_.ThreatName; if ($_.IsActive) { Add-Achado $R 'Segurança' 'Crítico' "Ameaça ATIVA detectada: $($_.ThreatName)." 'Executar verificação completa / offline do Defender e remover a ameaça.' } }
    $det = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Sort-Object InitialDetectionTime -Descending | Select-Object -First 20)
    Add-Item $R 'Ameaças detectadas (histórico)' $det.Count $(if ($det.Count) { 'Atenção' } else { 'OK' })
    Add-Tabela $R 'Histórico de ameaças detectadas' ($det | Select-Object @{n = 'Data'; e = { Fmt $_.InitialDetectionTime } }, @{n = 'Ameaça'; e = { $nomes[[string]$_.ThreatID] } }, @{n = 'Arquivo/recurso'; e = { ($_.Resources -join '; ') } }, @{n = 'Ação concluída'; e = { SimNao $_.ActionSuccess } })
    $rec = @($det | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddDays(-30) })
    if ($rec.Count) { Add-Achado $R 'Segurança' 'Médio' "$($rec.Count) ameaça(s) detectada(s) nos últimos 30 dias." 'Executar verificação completa e orientar o usuário sobre a origem (downloads, pendrives, e-mails).' }
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'firewall'; Nome = 'Firewall'; Timeout = 300
   Desc = 'Estado dos perfis Domínio/Privado/Público, ação padrão de entrada, firewalls de terceiros e análise das regras de entrada (regras abertas, programas em pastas suspeitas, portas sensíveis e regras órfãs).'
   Codigo = {
    $R = New-R
    Log 'Verificando perfis do Firewall do Windows...'
    $fw3 = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName FirewallProduct -ErrorAction SilentlyContinue | Where-Object { ('{0:X6}' -f [int]$_.productState).Substring(2, 2) -in @('10', '11') })
    if ($fw3.Count) { Add-Item $R 'Firewall de terceiros ativo' (($fw3 | ForEach-Object { $_.displayName }) -join ', ') 'OK' }
    $nomes = @{ 'Domain' = 'Domínio'; 'Private' = 'Privado'; 'Public' = 'Público' }
    $desl = @()
    foreach ($p in @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue)) {
        $en = ([string]$p.Enabled -in @('True', '1'))
        $inb = [string]$p.DefaultInboundAction; if ($inb -in @('NotConfigured', '0', '')) { $inb = 'Block' }
        $np = if ($nomes[[string]$p.Name]) { $nomes[[string]$p.Name] } else { [string]$p.Name }
        Add-Item $R "Perfil $np" ("{0} - entrada padrão: {1}" -f $(if ($en) { 'Ativado' } else { 'DESATIVADO' }), $(if ($inb -match 'Allow|2') { 'PERMITIR' } else { 'Bloquear' })) $(if ($en -and $inb -notmatch 'Allow|2') { 'OK' } else { 'Crítico' })
        if (-not $en) { $desl += $np }
        if ($inb -match 'Allow|2') { Add-Achado $R 'Segurança' 'Alto' "Perfil $np do firewall permite todas as conexões de entrada por padrão." 'Alterar a ação padrão de entrada para Bloquear.' }
    }
    if ($desl.Count) {
        if ($fw3.Count) { Add-Achado $R 'Segurança' 'Médio' ("Firewall do Windows desativado no(s) perfil(is): {0} (há firewall de terceiros ativo)." -f ($desl -join ', ')) 'Confirmar que o firewall de terceiros está protegendo todos os perfis.' }
        else { Add-Achado $R 'Segurança' 'Crítico' ("Firewall DESATIVADO no(s) perfil(is): {0}." -f ($desl -join ', ')) 'Ativar o Firewall do Windows em todos os perfis.' }
    }

    Log 'Analisando regras de entrada do firewall (pode levar 1 minuto)...'
    $regras = @(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue)
    $app = @{}; $port = @{}; $addr = @{}
    try { Get-NetFirewallApplicationFilter -All -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object { $app[$_.InstanceID] = $_.Program } } catch { Get-NetFirewallApplicationFilter -All -ErrorAction SilentlyContinue | ForEach-Object { $app[$_.InstanceID] = $_.Program } }
    try { Get-NetFirewallPortFilter -All -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object { $port[$_.InstanceID] = $_ } } catch { Get-NetFirewallPortFilter -All -ErrorAction SilentlyContinue | ForEach-Object { $port[$_.InstanceID] = $_ } }
    try { Get-NetFirewallAddressFilter -All -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object { $addr[$_.InstanceID] = $_ } } catch { Get-NetFirewallAddressFilter -All -ErrorAction SilentlyContinue | ForEach-Object { $addr[$_.InstanceID] = $_ } }
    Add-Item $R 'Regras de entrada ativas (permitir)' $regras.Count

    $sens = @('21', '23', '139', '445', '3389', '5900', '1433', '3306')
    $susp = New-Object System.Collections.ArrayList; $pers = New-Object System.Collections.ArrayList
    $nAlto = 0; $nMed = 0; $nOrf = 0
    foreach ($r in $regras) {
        $id = [string]$r.InstanceID; if (-not $id) { $id = [string]$r.Name }
        if (-not $port.ContainsKey($id)) {
            # consulta individual (mais lenta) quando a consulta em lote não trouxe os filtros desta regra
            $port[$id] = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $addr[$id] = $r | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
            $app[$id] = ($r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
        }
        $prog = [string]$app[$id]; if (-not $prog) { $prog = 'Any' }
        $pf = $port[$id]; $af = $addr[$id]
        $proto = [string]$pf.Protocol; if (-not $proto) { $proto = 'Any' }
        $lport = (@($pf.LocalPort) -join ','); if (-not $lport) { $lport = 'Any' }
        $raddr = (@($af.RemoteAddress) -join ','); if (-not $raddr) { $raddr = 'Any' }
        $perfil = [string]$r.Profile
        $publico = ($perfil -match 'Any|Public|^0$|4')
        $motivo = @(); $sev = ''
        if ($prog -ne 'Any' -and (Test-Suspeito $prog)) { $motivo += 'Programa em pasta temporária/pública'; $sev = 'Alto' }
        if ($prog -eq 'Any' -and $lport -eq 'Any' -and $raddr -eq 'Any' -and $proto -eq 'Any') { $motivo += 'Regra totalmente aberta (qualquer programa, porta e origem)'; $sev = 'Alto' }
        if ($publico -and $raddr -eq 'Any' -and @($lport -split ',' | Where-Object { $_ -in $sens }).Count) { $motivo += 'Porta sensível aberta a qualquer origem na rede pública'; if (-not $sev) { $sev = 'Médio' } }
        if ($prog -notin @('Any', 'System') -and -not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($prog)))) { $motivo += 'Programa da regra não existe mais (regra órfã)'; if (-not $sev) { $sev = 'Baixo' } }
        $linha = [pscustomobject]@{ 'Regra' = $r.DisplayName; 'Perfil' = $perfil; 'Programa' = $prog; 'Protocolo' = $proto; 'Porta local' = $lport; 'Origem' = $raddr }
        if ($motivo.Count) {
            $linha | Add-Member -NotePropertyName 'Motivo' -NotePropertyValue ($motivo -join '; ')
            [void]$susp.Add($linha)
            switch ($sev) { 'Alto' { $nAlto++ } 'Médio' { $nMed++ } 'Baixo' { $nOrf++ } }
        }
        elseif (-not $r.DisplayGroup) { [void]$pers.Add($linha) }
    }
    Add-Item $R 'Regras de entrada suspeitas' $susp.Count $(if ($nAlto) { 'Crítico' } elseif ($susp.Count) { 'Atenção' } else { 'OK' })
    Add-Item $R 'Regras personalizadas (criadas por programas/usuário)' $pers.Count
    Add-Tabela $R 'Regras de entrada que merecem revisão' $susp
    Add-Tabela $R 'Regras de entrada personalizadas (fora do padrão do Windows)' $pers
    if ($nAlto) { Add-Achado $R 'Segurança' 'Alto' "$nAlto regra(s) de entrada com permissão perigosa (totalmente aberta ou programa em pasta suspeita)." 'Revisar as regras listadas e remover as que não forem necessárias.' ([math]::Min(2.5, 1.2 * $nAlto)) }
    if ($nMed) { Add-Achado $R 'Segurança' 'Médio' "$nMed regra(s) liberando portas sensíveis para qualquer origem na rede pública." 'Restringir a origem (IP/sub-rede local) ou limitar ao perfil Privado/Domínio.' }
    if ($nOrf) { Add-Achado $R 'Segurança' 'Baixo' "$nOrf regra(s) órfã(s) apontando para programas que não existem mais." 'Remover as regras órfãs para manter o firewall limpo.' }
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'usuarios'; Nome = 'Usuários e contas'; Timeout = 120
   Desc = 'Contas locais, administradores, conta Convidado e Administrador interno, contas sem senha ou inativas, política de senha/bloqueio e perfis de usuário.'
   Codigo = {
    $R = New-R
    Log 'Listando contas de usuários locais...'
    $users = @(Get-LocalUser -ErrorAction SilentlyContinue)
    $admSid = 'S-1-5-32-544'
    $admNome = 'Administradores'
    try { $admNome = (New-Object Security.Principal.SecurityIdentifier $admSid).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1] } catch {}
    $admins = @()
    try { $admins = @(Get-LocalGroupMember -SID $admSid -ErrorAction Stop | ForEach-Object { [string]$_.Name }) }
    catch {
        try {
            $g = [ADSI]"WinNT://$env:COMPUTERNAME/$admNome,group"
            $admins = @($g.psbase.Invoke('Members') | ForEach-Object { $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null) })
        } catch {}
    }
    $ehAdm = { param($n) [bool](@($admins | Where-Object { ($_ -split '\\')[-1] -eq $n }).Count) }
    $lin = foreach ($u in $users) {
        [pscustomobject]@{
            'Usuário' = $u.Name; 'Ativo' = SimNao $u.Enabled; 'Administrador' = SimNao (& $ehAdm $u.Name)
            'Último logon' = Fmt $u.LastLogon; 'Senha alterada' = Fmt $u.PasswordLastSet
            'Senha expira' = $(if ($u.PasswordExpires) { Fmt $u.PasswordExpires } else { 'Nunca' })
            'Exige senha' = SimNao $u.PasswordRequired; 'Descrição' = $u.Description
        }
    }
    Add-Tabela $R 'Contas de usuários locais' $lin
    Add-Tabela $R "Membros do grupo $admNome" ($admins | ForEach-Object { [pscustomobject]@{ 'Membro' = $_ } })
    $ativos = @($users | Where-Object { $_.Enabled })
    Add-Item $R 'Contas locais' ("{0} ({1} ativas)" -f $users.Count, $ativos.Count)
    Add-Item $R 'Membros do grupo Administradores' $admins.Count $(if ($admins.Count -gt 3) { 'Atenção' } else { 'OK' })

    foreach ($u in $users) {
        $sid = [string]$u.SID
        if ($sid -match '-501$' -and $u.Enabled) { Add-Achado $R 'Segurança' 'Alto' 'Conta Convidado (Guest) ATIVADA.' 'Desativar a conta Convidado.' }
        if ($sid -match '-500$' -and $u.Enabled) { Add-Achado $R 'Segurança' 'Médio' "Conta Administrador interna ($($u.Name)) ativada." 'Desativar a conta interna e usar uma conta administrativa nominal com senha forte.' }
        if ($u.Enabled -and -not $u.PasswordRequired -and $sid -notmatch '-50[0-3]$') { Add-Achado $R 'Segurança' 'Médio' "Conta '$($u.Name)' configurada como 'senha não obrigatória'." 'Verificar se a conta possui senha e exigir senha: net user <conta> /passwordreq:yes' }
        if ($u.Enabled -and $sid -notmatch '-50[0-3]$' -and (-not $u.LastLogon -or $u.LastLogon -lt (Get-Date).AddDays(-90))) { Add-Achado $R 'Segurança' 'Baixo' "Conta '$($u.Name)' ativa sem uso há mais de 90 dias." 'Desativar contas que não são mais utilizadas.' }
    }
    $admLocAtivos = @($ativos | Where-Object { & $ehAdm $_.Name })
    if ($admins.Count -gt 3) { Add-Achado $R 'Segurança' 'Médio' "$($admins.Count) membros no grupo Administradores." 'Manter apenas as contas que realmente precisam de privilégio administrativo.' }
    $comuns = @($ativos | Where-Object { [string]$_.SID -notmatch '-50[0-3]$' })
    if ($comuns.Count -ge 1 -and $comuns.Count -eq $admLocAtivos.Count) { Add-Achado $R 'Segurança' 'Baixo' 'Todas as contas de uso diário são administradoras.' 'Criar uma conta padrão (sem privilégio) para o uso diário e manter uma conta administrativa separada.' }

    Log 'Lendo política de senhas e bloqueio de conta...'
    $tmp = Join-Path $env:TEMP 'auditorti_sec.inf'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    [void](Invoke-Cmd "$env:windir\System32\secedit.exe" "/export /cfg `"$tmp`" /areas SECURITYPOLICY /quiet" 60000)
    $pol = @{}
    if (Test-Path $tmp) { Get-Content $tmp | ForEach-Object { if ($_ -match '^\s*(\w+)\s*=\s*(.+)$') { $pol[$Matches[1]] = $Matches[2].Trim() } }; Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    if ($pol.Count) {
        $min = [int]$pol['MinimumPasswordLength']; $blq = [int]$pol['LockoutBadCount']; $cpx = [int]$pol['PasswordComplexity']; $hst = [int]$pol['PasswordHistorySize']
        Add-Item $R 'Tamanho mínimo de senha' "$min caracteres" $(if ($min -ge 8) { 'OK' } else { 'Atenção' })
        Add-Item $R 'Complexidade de senha exigida' (SimNao ($cpx -eq 1)) $(if ($cpx -eq 1) { 'OK' } else { 'Atenção' })
        Add-Item $R 'Bloqueio após tentativas inválidas' $(if ($blq -gt 0) { "$blq tentativas" } else { 'Desativado' }) $(if ($blq -gt 0) { 'OK' } else { 'Atenção' })
        Add-Item $R 'Histórico de senhas' "$hst senha(s) lembrada(s)"
        if ($min -lt 8) { Add-Achado $R 'Segurança' 'Médio' "Política aceita senhas com $min caracteres." 'Definir mínimo de 8 (ideal 12) caracteres: net accounts /minpwlen:12' }
        if ($blq -eq 0) { Add-Achado $R 'Segurança' 'Médio' 'Sem bloqueio de conta após tentativas de senha incorretas (permite força bruta).' 'Configurar bloqueio após 5-10 tentativas: net accounts /lockoutthreshold:10' }
        if ($cpx -ne 1) { Add-Achado $R 'Segurança' 'Baixo' 'Complexidade de senha não exigida.' 'Ativar "A senha deve satisfazer a requisitos de complexidade" (secpol.msc).' }
    }
    Add-Tabela $R 'Perfis de usuário no disco' (Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | Select-Object @{n = 'Pasta'; e = { $_.LocalPath } }, @{n = 'Último uso'; e = { Fmt $_.LastUseTime } }, @{n = 'Carregado'; e = { SimNao $_.Loaded } })
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'registro'; Nome = 'Registro do Windows e configurações de segurança'; Timeout = 300
   Desc = 'Chaves Run/RunOnce (todos os usuários), Winlogon (Shell/Userinit/Autologon), IFEO, AppInit_DLLs, UAC, RDP/NLA, WDigest, LSA, NTLM, AutoRun, SmartScreen, políticas que desativam Defender/Windows Update, arquivo hosts e proxy.'
   Codigo = {
    $R = New-R
    Log 'Verificando chaves de inicialização automática (Run/RunOnce)...'
    $runKeys = New-Object System.Collections.ArrayList
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce')) { [void]$runKeys.Add(@($k, ($k -replace '^HKLM:', 'HKLM'))) }
    foreach ($h in @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' })) {
        $sid = $h.PSChildName; $nome = $sid
        try { $nome = (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch {}
        foreach ($s in @('Run', 'RunOnce')) { [void]$runKeys.Add(@("Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\$s", "HKU\$nome\...\$s")) }
    }
    $auto = New-Object System.Collections.ArrayList; $nSus = @(); $nSemAss = 0; $nOrf = 0
    foreach ($par in $runKeys) {
        $k = $par[0]
        if (-not (Test-Path $k)) { continue }
        $it = Get-Item $k
        foreach ($vn in $it.GetValueNames()) {
            if (-not $vn) { continue }
            $cmd = [string]$it.GetValue($vn); $exe = Get-ExePath $cmd; $ass = Get-Assinatura $exe; $sus = Test-Suspeito $cmd
            if ($sus) { $nSus += $vn } elseif ($ass -eq 'Não assinado') { $nSemAss++ } elseif ($ass -eq 'Arquivo não encontrado') { $nOrf++ }
            [void]$auto.Add([pscustomobject]@{ 'Chave' = $par[1]; 'Nome' = $vn; 'Comando' = $cmd; 'Assinatura' = $ass; 'Suspeito' = SimNao $sus })
        }
    }
    Add-Item $R 'Entradas de inicialização no registro' $auto.Count
    Add-Tabela $R 'Inicialização automática pelo registro (Run/RunOnce)' $auto
    if ($nSus.Count) { Add-Achado $R 'Segurança' 'Alto' ("Entrada(s) de inicialização com padrão suspeito: {0}." -f ($nSus -join ', ')) 'Investigar com antimalware e remover se for maliciosa.' }
    if ($nSemAss) { Add-Achado $R 'Segurança' 'Baixo' "$nSemAss programa(s) de inicialização sem assinatura digital." 'Confirmar a origem desses programas.' }
    if ($nOrf) { Add-Achado $R 'Desempenho' 'Baixo' "$nOrf entrada(s) de inicialização apontando para arquivos inexistentes." 'Remover as entradas órfãs (Autoruns da Sysinternals ajuda).' 0.1 }

    Log 'Verificando Winlogon, IFEO e AppInit_DLLs (técnicas de persistência)...'
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $shell = [string](Get-RegVal $wl 'Shell')
    $okShell = (-not $shell) -or ($shell.Trim() -match '^(?i)explorer\.exe$')
    Add-Item $R 'Winlogon - Shell' $shell $(if ($okShell) { 'OK' } else { 'Crítico' })
    if (-not $okShell) { Add-Achado $R 'Segurança' 'Crítico' "Valor Shell do Winlogon alterado: '$shell' (técnica de persistência de malware)." "Restaurar para 'explorer.exe' e investigar o computador." }
    $ui = [string](Get-RegVal $wl 'Userinit')
    $okUi = (-not $ui) -or ($ui.Trim() -match '^(?i)C:\\Windows\\system32\\userinit\.exe,?$')
    Add-Item $R 'Winlogon - Userinit' $ui $(if ($okUi) { 'OK' } else { 'Crítico' })
    if (-not $okUi) { Add-Achado $R 'Segurança' 'Crítico' "Valor Userinit do Winlogon alterado: '$ui'." "Restaurar para 'C:\Windows\system32\userinit.exe,' e investigar o computador." }
    if ([string](Get-RegVal $wl 'AutoAdminLogon') -eq '1') {
        Add-Item $R 'Logon automático' 'ATIVADO' 'Atenção'
        Add-Achado $R 'Segurança' 'Alto' 'Logon automático ativado (qualquer pessoa que ligar o computador acessa a conta).' 'Desativar o AutoAdminLogon (netplwiz).'
        if (Get-RegVal $wl 'DefaultPassword') { Add-Achado $R 'Segurança' 'Alto' 'Senha de logon gravada em texto puro no registro (DefaultPassword).' 'Remover o valor DefaultPassword da chave Winlogon e trocar a senha da conta.' }
    }
    else { Add-Item $R 'Logon automático' 'Desativado' 'OK' }

    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    $dbg = @(Get-ChildItem $ifeo -ErrorAction SilentlyContinue | ForEach-Object { $d = $_.GetValue('Debugger'); if ($d) { [pscustomobject]@{ 'Programa' = $_.PSChildName; 'Debugger' = $d } } })
    Add-Item $R 'Redirecionamentos IFEO (Debugger)' $dbg.Count $(if ($dbg.Count) { 'Atenção' } else { 'OK' })
    Add-Tabela $R 'Programas redirecionados via IFEO (Debugger)' $dbg
    foreach ($d in $dbg) {
        if ($d.Programa -match '^(?i)(sethc|utilman|osk|narrator|magnify|displayswitch|atbroker)\.exe$') { Add-Achado $R 'Segurança' 'Crítico' "Backdoor de acessibilidade: $($d.Programa) redirecionado para '$($d.Debugger)'." 'Remover o valor Debugger imediatamente e investigar invasão (permite abrir um prompt na tela de logon).' }
        else { Add-Achado $R 'Segurança' 'Médio' "$($d.Programa) é redirecionado para '$($d.Debugger)' (IFEO)." 'Confirmar se é legítimo (ex.: Process Explorer substituindo o Gerenciador de Tarefas).' }
    }
    $ai = [string](Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' 'AppInit_DLLs')
    if ($ai.Trim() -and (Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' 'LoadAppInit_DLLs') -eq 1) { Add-Achado $R 'Segurança' 'Alto' "AppInit_DLLs ativo: $ai (DLL injetada em todos os programas)." 'Investigar a DLL; remover se não for de um software legítimo.' }

    Log 'Verificando UAC, Área de Trabalho Remota e proteção de credenciais...'
    $pol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lua = Get-RegVal $pol 'EnableLUA'; $cpa = Get-RegVal $pol 'ConsentPromptBehaviorAdmin'
    if ($lua -eq 0) { Add-Item $R 'Controle de Conta de Usuário (UAC)' 'DESATIVADO' 'Crítico'; Add-Achado $R 'Segurança' 'Crítico' 'UAC (Controle de Conta de Usuário) desativado.' 'Reativar o UAC (EnableLUA=1) e reiniciar.' }
    elseif ($cpa -eq 0) { Add-Item $R 'Controle de Conta de Usuário (UAC)' 'Ativo, mas eleva sem perguntar' 'Atenção'; Add-Achado $R 'Segurança' 'Alto' 'UAC configurado para elevar privilégios sem perguntar.' 'Ajustar o UAC para o nível padrão (notificar).' }
    else { Add-Item $R 'Controle de Conta de Usuário (UAC)' 'Ativado' 'OK' }

    $ts = Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
    $nla = Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication'
    $rdpP = Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'PortNumber'
    if ($ts -eq 0) {
        Add-Item $R 'Área de Trabalho Remota (RDP)' ("Ativada - porta {0} - NLA: {1}" -f $rdpP, (SimNao ($nla -ne 0))) 'Atenção'
        if ($nla -eq 0) { Add-Achado $R 'Segurança' 'Alto' 'RDP ativado SEM autenticação em nível de rede (NLA).' 'Ativar o NLA nas configurações de Área de Trabalho Remota.' }
    }
    else { Add-Item $R 'Área de Trabalho Remota (RDP)' 'Desativada' 'OK' }
    $wd = Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential'
    Add-Item $R 'WDigest (senhas em texto na memória)' $(if ($wd -eq 1) { 'ATIVADO' } else { 'Desativado' }) $(if ($wd -eq 1) { 'Crítico' } else { 'OK' })
    if ($wd -eq 1) { Add-Achado $R 'Segurança' 'Alto' 'WDigest ativado: senhas ficam em texto puro na memória (roubo com Mimikatz).' 'Definir UseLogonCredential=0 em HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest.' }
    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $ppl = Get-RegVal $lsa 'RunAsPPL'
    Add-Item $R 'Proteção LSA (RunAsPPL)' (SimNao ($ppl -in 1, 2)) $(if ($ppl -in 1, 2) { 'OK' } else { 'Info' })
    if ($ppl -notin 1, 2) { Add-Achado $R 'Segurança' 'Baixo' 'Proteção adicional da LSA (RunAsPPL) desativada.' 'Ativar a "Proteção da Autoridade de Segurança Local" em Segurança do Windows > Segurança do dispositivo > Isolamento de núcleo.' }
    $lm = Get-RegVal $lsa 'LmCompatibilityLevel'
    if ($null -ne $lm -and $lm -lt 3) { Add-Item $R 'Autenticação NTLM' "Nível $lm (permite LM/NTLMv1)" 'Atenção'; Add-Achado $R 'Segurança' 'Médio' "Autenticação LM/NTLMv1 permitida (LmCompatibilityLevel=$lm)." 'Definir LmCompatibilityLevel=5 (somente NTLMv2).' }
    if ((Get-RegVal $lsa 'NoLMHash') -eq 0) { Add-Achado $R 'Segurança' 'Médio' 'O Windows armazena hash LM das senhas (fraco).' 'Definir NoLMHash=1.' }

    Log 'Verificando AutoRun, SmartScreen e políticas...'
    $ar = Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun'
    Add-Item $R 'AutoRun de mídias removíveis' $(if ($ar -eq 255) { 'Desativado em todas as unidades' } else { 'Parcial/ativado' }) $(if ($ar -eq 255) { 'OK' } else { 'Info' })
    if ($ar -ne 255) { Add-Achado $R 'Segurança' 'Baixo' 'Reprodução automática (AutoRun) não totalmente desativada.' 'Definir NoDriveTypeAutoRun=255 (0xFF) para evitar execução automática a partir de pendrives.' }
    $ss = [string](Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled')
    $ssp = Get-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
    if ($ss -eq 'Off' -or $ssp -eq 0) { Add-Item $R 'SmartScreen' 'Desativado' 'Atenção'; Add-Achado $R 'Segurança' 'Médio' 'SmartScreen desativado (proteção contra downloads e sites maliciosos).' 'Reativar o SmartScreen em Segurança do Windows > Controle de aplicativos e do navegador.' }
    else { Add-Item $R 'SmartScreen' 'Ativado' 'OK' }
    if ((Get-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware') -eq 1) { Add-Achado $R 'Segurança' 'Alto' 'Política de registro desativando o Microsoft Defender (DisableAntiSpyware=1).' 'Remover a política, a menos que outro antivírus corporativo esteja ativo.' }
    if ((Get-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableRealtimeMonitoring') -eq 1) { Add-Achado $R 'Segurança' 'Alto' 'Política de registro desativando a proteção em tempo real do Defender.' 'Remover a política DisableRealtimeMonitoring.' }
    if ((Get-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate') -eq 1) { Add-Item $R 'Atualização automática (política)' 'DESATIVADA' 'Crítico'; Add-Achado $R 'Segurança' 'Alto' 'Atualizações automáticas desativadas por política (NoAutoUpdate=1).' 'Remover a política e permitir a instalação automática de atualizações.' }
    $sbl = Get-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' 'EnableScriptBlockLogging'
    Add-Item $R 'Log de scripts do PowerShell' $(if ($sbl -eq 1) { 'Ativado' } else { 'Desativado (recomendado ativar em ambiente corporativo)' }) 'Info'

    Log 'Verificando arquivo hosts e proxy...'
    $hostsF = "$env:windir\System32\drivers\etc\hosts"
    $hl = @(Get-Content $hostsF -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*[^#\s]' } | ForEach-Object { $p = ($_.Trim() -split '\s+'); [pscustomobject]@{ 'IP' = $p[0]; 'Domínio' = ($p[1..($p.Count - 1)] -join ' ') } })
    Add-Item $R 'Entradas no arquivo hosts' $hl.Count $(if ($hl.Count) { 'Atenção' } else { 'OK' })
    Add-Tabela $R 'Entradas do arquivo hosts' $hl
    $hlGrave = @($hl | Where-Object { $_.'Domínio' -match 'google|microsoft|windowsupdate|live\.com|office|bb\.com|caixa|itau|bradesco|santander|sicredi|sicoob|nubank|inter\.co|gov\.br|facebook|whatsapp|avast|kaspersky|eset|mcafee|norton|avg|malwarebytes' -and $_.IP -notin @('127.0.0.1', '::1', '0.0.0.0') })
    if ($hlGrave.Count) { Add-Achado $R 'Segurança' 'Alto' ("Arquivo hosts redireciona domínios importantes: {0}." -f (($hlGrave | ForEach-Object { "$($_.'Domínio') -> $($_.IP)" }) -join '; ')) 'Possível malware/phishing: limpar o arquivo hosts e executar verificação completa.' }
    elseif ($hl.Count) { Add-Achado $R 'Segurança' 'Info' "Arquivo hosts com $($hl.Count) entrada(s) personalizada(s)." 'Confirmar se as entradas são legítimas.' 0 }
    $ie = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ((Get-RegVal $ie 'ProxyEnable') -eq 1) {
        $px = Get-RegVal $ie 'ProxyServer'
        Add-Item $R 'Proxy configurado' $px 'Atenção'
        Add-Achado $R 'Segurança' 'Baixo' "Proxy de internet configurado: $px." 'Confirmar com o cliente se o proxy é legítimo (malware pode redirecionar a navegação).'
    }
    else { Add-Item $R 'Proxy configurado' 'Não' 'OK' }
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'tarefas'; Nome = 'Tarefas agendadas'; Timeout = 300
   Desc = 'Todas as tarefas agendadas: tarefas de terceiros, ações com padrões maliciosos (PowerShell codificado, downloads, scripts em pastas temporárias), assinatura digital, privilégios e arquivos inexistentes.'
   Codigo = {
    $R = New-R
    Log 'Lendo tarefas agendadas...'
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
    Add-Item $R 'Total de tarefas agendadas' $tasks.Count
    $gmap = @{ 'Logon' = 'Ao fazer logon'; 'Boot' = 'Na inicialização'; 'Daily' = 'Diária'; 'Weekly' = 'Semanal'; 'Monthly' = 'Mensal'; 'Time' = 'Data/hora'; 'Idle' = 'Ociosidade'; 'Registration' = 'Ao registrar'; 'SessionStateChange' = 'Mudança de sessão'; 'Event' = 'Evento' }
    $terc = New-Object System.Collections.ArrayList; $sus = New-Object System.Collections.ArrayList
    $nSemAss = @(); $nOrf = @()
    foreach ($t in $tasks) {
        $acoes = @($t.Actions | ForEach-Object { if ($_.Execute) { ("{0} {1}" -f $_.Execute, $_.Arguments).Trim() } elseif ($_.ClassId) { "COM: $($_.ClassId)" } })
        $acaoTxt = $acoes -join ' | '
        $ms = $t.TaskPath -like '\Microsoft\*'
        $suspeita = Test-Suspeito $acaoTxt
        if ($ms -and -not $suspeita) { continue }
        $exe = $null; $prim = @($t.Actions)[0]; if ($prim.Execute) { $exe = Get-ExePath $prim.Execute }
        $ass = if ($exe) { Get-Assinatura $exe } else { '-' }
        $info = Get-ScheduledTaskInfo -InputObject $t -ErrorAction SilentlyContinue
        $gat = (@($t.Triggers | ForEach-Object { $c = ($_.CimClass.CimClassName -replace '^MSFT_Task', '' -replace 'Trigger$', ''); if ($gmap[$c]) { $gmap[$c] } else { $c } }) -join ', ')
        $conta = [string]$t.Principal.UserId; if (-not $conta) { $conta = [string]$t.Principal.GroupId }
        $row = [pscustomobject]@{ 'Tarefa' = ($t.TaskPath + $t.TaskName); 'Estado' = [string]$t.State; 'Gatilho' = $gat; 'Ação' = $acaoTxt; 'Conta' = $conta; 'Privilégio' = $(if ([string]$t.Principal.RunLevel -eq 'Highest') { 'Elevado' } else { 'Normal' }); 'Última execução' = (Fmt $info.LastRunTime); 'Assinatura' = $ass; 'Suspeita' = SimNao $suspeita }
        [void]$terc.Add($row)
        if ($suspeita) { [void]$sus.Add($row) }
        elseif ($ass -eq 'Não assinado' -and [string]$t.State -ne 'Disabled') { $nSemAss += $t.TaskName }
        elseif ($ass -eq 'Arquivo não encontrado') { $nOrf += $t.TaskName }
    }
    Add-Item $R 'Tarefas de terceiros (fora da Microsoft)' $terc.Count
    Add-Item $R 'Tarefas com padrão suspeito' $sus.Count $(if ($sus.Count) { 'Crítico' } else { 'OK' })
    Add-Tabela $R 'Tarefas com padrão suspeito' $sus
    Add-Tabela $R 'Tarefas agendadas de terceiros' $terc
    if ($sus.Count) { Add-Achado $R 'Segurança' 'Alto' ("Tarefa(s) agendada(s) com comportamento suspeito: {0}." -f (($sus | ForEach-Object { $_.Tarefa }) -join ', ')) 'Analisar a ação da tarefa. Se não for reconhecida, desativá-la, remover o arquivo e executar verificação antimalware completa.' ([math]::Min(3, 1.2 * $sus.Count)) }
    if ($nSemAss.Count) { Add-Achado $R 'Segurança' 'Baixo' ("Tarefa(s) ativa(s) executando programa sem assinatura digital: {0}." -f ($nSemAss -join ', ')) 'Confirmar a origem dos programas executados por essas tarefas.' }
    if ($nOrf.Count) { Add-Achado $R 'Desempenho' 'Baixo' ("Tarefa(s) apontando para arquivo inexistente: {0}." -f ($nOrf -join ', ')) 'Excluir as tarefas órfãs (Agendador de Tarefas).' 0.1 }
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'eventos'; Nome = 'Logs de eventos e estabilidade'; Timeout = 300
   Desc = 'Erros críticos do sistema (7 dias), telas azuis, desligamentos inesperados, erros de disco e de hardware (30 dias), programas que travaram, logons com falha, limpeza de log de auditoria, contas criadas e inclusões em grupos.'
   Codigo = {
    $R = New-R
    $d7 = (Get-Date).AddDays(-7); $d30 = (Get-Date).AddDays(-30)
    Log 'Lendo log do Sistema (últimos 7 dias)...'
    $sys = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $d7 } -MaxEvents 3000 -ErrorAction SilentlyContinue)
    Add-Item $R 'Erros/críticos no log do Sistema (7 dias)' $sys.Count $(if ($sys.Count -gt 100) { 'Atenção' } else { 'OK' })
    Add-Tabela $R 'Principais origens de erro no log do Sistema (7 dias)' ($sys | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 10 @{n = 'Origem'; e = { $_.Name } }, @{n = 'Ocorrências'; e = { $_.Count } }, @{n = 'Exemplo de mensagem'; e = { $m = ("$($_.Group[0].Message)" -split "`n")[0].Trim(); if ($m.Length -gt 140) { $m.Substring(0, 140) + '...' } else { $m } } })

    Log 'Procurando telas azuis, desligamentos inesperados e erros de hardware (30 dias)...'
    $kp = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $d30 } -ErrorAction SilentlyContinue)
    $bsod = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $d30 } -ErrorAction SilentlyContinue)
    $whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = 1, 2, 3; StartTime = $d30 } -ErrorAction SilentlyContinue)
    $disk = @()
    foreach ($pv in @('disk', 'Ntfs', 'stornvme', 'storahci', 'iaStorA', 'iaStorAC')) { $disk += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $pv; Level = 1, 2, 3; StartTime = $d30 } -ErrorAction SilentlyContinue | Where-Object { $_.Id -in 7, 11, 51, 55, 98, 129, 153, 157 }) }
    Add-Item $R 'Telas azuis (BSOD) - 30 dias' $bsod.Count $(if ($bsod.Count) { 'Crítico' } else { 'OK' })
    Add-Item $R 'Desligamentos inesperados - 30 dias' $kp.Count $(if ($kp.Count -gt 2) { 'Atenção' } else { 'OK' })
    Add-Item $R 'Erros de disco/controladora - 30 dias' $disk.Count $(if ($disk.Count) { 'Crítico' } else { 'OK' })
    Add-Item $R 'Erros de hardware (WHEA) - 30 dias' $whea.Count $(if ($whea.Count) { 'Crítico' } else { 'OK' })
    $R.Metricas.BSOD = $bsod.Count
    if ($bsod.Count) { Add-Achado $R 'Desempenho' 'Alto' "$($bsod.Count) tela(s) azul(is) (BSOD) nos últimos 30 dias." 'Atualizar drivers/BIOS, testar a memória RAM (mdsched) e analisar os arquivos de despejo em C:\Windows\Minidump.' 1.5 }
    if ($kp.Count -gt 2) { Add-Achado $R 'Desempenho' 'Médio' "$($kp.Count) desligamentos inesperados nos últimos 30 dias." 'Verificar fonte/nobreak, superaquecimento e estabilidade elétrica.' 0.5 }
    if ($disk.Count) { Add-Achado $R 'Desempenho' 'Alto' "$($disk.Count) erro(s) de disco/controladora registrados nos últimos 30 dias." 'Fazer backup, executar chkdsk e testar o disco; substituir se os erros persistirem.' 1.5 -Upgrade }
    if ($whea.Count) { Add-Achado $R 'Desempenho' 'Alto' "$($whea.Count) erro(s) de hardware (WHEA) registrados." 'Verificar CPU/memória/temperaturas e atualizar a BIOS.' 1 }

    Log 'Identificando programas que travaram (7 dias)...'
    $app = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; StartTime = $d7 } -ErrorAction SilentlyContinue)
    Add-Item $R 'Travamentos de programas (7 dias)' $app.Count $(if ($app.Count -gt 20) { 'Atenção' } else { 'OK' })
    Add-Tabela $R 'Programas que mais travaram (7 dias)' ($app | Group-Object { "$($_.Properties[0].Value)" } | Sort-Object Count -Descending | Select-Object -First 10 @{n = 'Programa'; e = { $_.Name } }, @{n = 'Ocorrências'; e = { $_.Count } })
    if ($app.Count -gt 20) { Add-Achado $R 'Desempenho' 'Baixo' "$($app.Count) travamentos de programas em 7 dias." 'Atualizar/reinstalar os programas que mais travam (ver tabela).' 0.3 }

    Log 'Lendo log de Segurança (logons com falha e alterações de contas)...'
    $f = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = $d7 } -MaxEvents 5000 -ErrorAction SilentlyContinue)
    Add-Item $R 'Logons com falha (7 dias)' $f.Count $(if ($f.Count -gt 30) { 'Atenção' } else { 'OK' })
    if ($f.Count) {
        Add-Tabela $R 'Logons com falha por conta/origem (7 dias)' ($f | Group-Object { "$($_.Properties[5].Value)|$($_.Properties[19].Value)" } | Sort-Object Count -Descending | Select-Object -First 10 @{n = 'Conta'; e = { ($_.Name -split '\|')[0] } }, @{n = 'IP de origem'; e = { ($_.Name -split '\|')[1] } }, @{n = 'Tentativas'; e = { $_.Count } })
    }
    if ($f.Count -gt 30) { Add-Achado $R 'Segurança' 'Médio' "$($f.Count) tentativas de logon com falha em 7 dias (possível ataque de senha)." 'Verificar a origem das tentativas, ativar bloqueio de conta e restringir acesso remoto.' }
    $clr = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 1102; StartTime = $d30 } -ErrorAction SilentlyContinue)
    $clr += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 104; ProviderName = 'Microsoft-Windows-Eventlog'; StartTime = $d30 } -ErrorAction SilentlyContinue)
    Add-Item $R 'Logs de eventos apagados (30 dias)' $clr.Count $(if ($clr.Count) { 'Crítico' } else { 'OK' })
    if ($clr.Count) { Add-Achado $R 'Segurança' 'Alto' "Log de eventos foi apagado $($clr.Count) vez(es) nos últimos 30 dias." 'Confirmar quem apagou e por quê; apagar logs é comum após invasões.' }
    $nov = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4720; StartTime = $d30 } -ErrorAction SilentlyContinue)
    Add-Tabela $R 'Contas criadas nos últimos 30 dias' ($nov | Select-Object @{n = 'Data'; e = { Fmt $_.TimeCreated } }, @{n = 'Conta criada'; e = { $_.Properties[0].Value } }, @{n = 'Criada por'; e = { $_.Properties[4].Value } })
    $grp = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4732; StartTime = $d30 } -ErrorAction SilentlyContinue)
    Add-Tabela $R 'Inclusões em grupos locais nos últimos 30 dias' ($grp | Select-Object @{n = 'Data'; e = { Fmt $_.TimeCreated } }, @{n = 'Membro'; e = { $m = [string]$_.Properties[0].Value; if (-not $m -or $m -eq '-') { try { (New-Object Security.Principal.SecurityIdentifier ([string]$_.Properties[1].Value)).Translate([Security.Principal.NTAccount]).Value } catch { [string]$_.Properties[1].Value } } else { $m } } }, @{n = 'Grupo'; e = { $_.Properties[2].Value } }, @{n = 'Alterado por'; e = { $_.Properties[6].Value } })
    if ($nov.Count) { Add-Achado $R 'Segurança' 'Info' "$($nov.Count) conta(s) criada(s) nos últimos 30 dias." 'Confirmar com o cliente se as contas foram criadas por pessoas autorizadas.' 0 }
    $R
}}

# ---------------------------------------------------------------------
@{ Id = 'redeseg'; Nome = 'Segurança de rede (avançado)'; Timeout = 900
   Desc = 'Auditoria de segurança da rede: LLMNR/NBT-NS/mDNS (envenenamento/Responder), assinatura SMB, WPAD, túneis IPv6 (Teredo/ISATAP/6to4), roteamento, tabela ARP (spoofing), servidores DNS, descoberta de hosts na rede e captura opcional de pacotes (pktmon/Wireshark).'
   Codigo = {
    $R = New-R
    $srv = $Cfg.SO -and $Cfg.SO.Server
    Log 'Auditando a configuração de segurança da rede...'

    # --- Perfil e adaptadores ---
    $cfgs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.NetAdapter -and [string]$_.NetAdapter.Status -eq 'Up' })
    Add-Item $R 'Interfaces de rede ativas' $cfgs.Count
    $gws = @($cfgs | ForEach-Object { $_.IPv4DefaultGateway.NextHop } | Where-Object { $_ } | Sort-Object -Unique)
    Add-Item $R 'Gateway(s) padrão' (($gws -join ', '))

    # --- LLMNR ---
    Log 'Verificando LLMNR, NetBIOS e mDNS (vetores de envenenamento)...'
    $llmnr = Get-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast'
    if ($llmnr -eq 0) { Add-Item $R 'LLMNR' 'Desativado' 'OK' }
    else {
        Add-Item $R 'LLMNR (multicast DNS)' 'ATIVADO' 'Atenção'
        Add-Achado $R 'Segurança' 'Alto' 'LLMNR ativado: permite ataques de envenenamento de nome (Responder) para roubo de credenciais na rede.' 'Desativar por GPO ou registro: HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient\EnableMulticast = 0.'
    }

    # --- NetBIOS over TCP/IP ---
    $nbt = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=true' -ErrorAction SilentlyContinue)
    $nbtOn = @($nbt | Where-Object { [int]$_.TcpipNetbiosOptions -ne 2 })
    if ($nbtOn.Count) {
        Add-Item $R 'NetBIOS over TCP/IP (NBT-NS)' ("Ativado em {0} adaptador(es)" -f $nbtOn.Count) 'Atenção'
        Add-Achado $R 'Segurança' 'Alto' 'NetBIOS over TCP/IP (NBT-NS) ativado: outro vetor de envenenamento de nome (Responder) e vazamento de informação.' 'Desativar o NetBIOS over TCP/IP nas propriedades TCP/IPv4 de cada adaptador (ou via DHCP), deixando o DNS resolver os nomes.'
    }
    else { Add-Item $R 'NetBIOS over TCP/IP (NBT-NS)' 'Desativado' 'OK' }

    # --- mDNS ---
    $mdns = Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' 'EnableMDNS'
    if ($null -ne $mdns -and $mdns -eq 0) { Add-Item $R 'mDNS' 'Desativado' 'OK' }
    else {
        Add-Item $R 'mDNS (multicast DNS)' 'Ativado (padrão)' 'Info'
        Add-Achado $R 'Segurança' 'Baixo' 'mDNS ativado: pode ser usado para descoberta/envenenamento em redes não confiáveis.' 'Em ambiente corporativo, avaliar desativar: HKLM\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\EnableMDNS = 0.' 0.15
    }

    # --- Assinatura SMB ---
    Log 'Verificando assinatura SMB (proteção contra NTLM relay)...'
    $smbS = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
    $smbC = Get-SmbClientConfiguration -ErrorAction SilentlyContinue
    if ($smbS) {
        Add-Item $R 'Assinatura SMB obrigatória (servidor)' (SimNao $smbS.RequireSecuritySignature) $(if ($smbS.RequireSecuritySignature) { 'OK' } else { 'Atenção' })
        if (-not $smbS.RequireSecuritySignature) { Add-Achado $R 'Segurança' 'Médio' 'Servidor SMB não exige assinatura: facilita ataques de NTLM relay na rede.' 'Exigir assinatura SMB: Set-SmbServerConfiguration -RequireSecuritySignature $true (via GPO em domínio).' }
    }
    if ($smbC) { Add-Item $R 'Assinatura SMB obrigatória (cliente)' (SimNao $smbC.RequireSecuritySignature) $(if ($smbC.RequireSecuritySignature) { 'OK' } else { 'Info' }) }

    # --- WPAD ---
    $autoDet = Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'AutoDetect'
    $wpadSvc = Get-Service 'WinHttpAutoProxySvc' -ErrorAction SilentlyContinue
    if ($autoDet -eq 1) {
        Add-Item $R 'Detecção automática de proxy (WPAD)' 'ATIVADA' 'Atenção'
        Add-Achado $R 'Segurança' 'Médio' 'Detecção automática de proxy (WPAD) ativada: permite sequestro de proxy e interceptação do tráfego web na rede.' 'Desmarcar "Detectar configurações automaticamente" nas opções de Internet e criar um registro WPAD interno, ou desativar o serviço WinHttpAutoProxySvc.'
    }
    else { Add-Item $R 'Detecção automática de proxy (WPAD)' 'Desativada' 'OK' }

    # --- Roteamento IP ---
    $ipr = Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'IPEnableRouter'
    if ($ipr -eq 1) {
        Add-Item $R 'Roteamento de IP (IP forwarding)' 'ATIVADO' $(if ($srv) { 'Atenção' } else { 'Crítico' })
        Add-Achado $R 'Segurança' $(if ($srv) { 'Médio' } else { 'Alto' }) 'Encaminhamento de IP ativado: o computador roteia tráfego entre redes (pode indicar pivô de ataque ou configuração indevida).' 'Se não houver função de roteamento/RRAS prevista, definir IPEnableRouter = 0.'
    }
    else { Add-Item $R 'Roteamento de IP (IP forwarding)' 'Desativado' 'OK' }

    # --- Túneis IPv6 ---
    Log 'Verificando túneis IPv6 (Teredo, ISATAP, 6to4)...'
    $ter = Invoke-Cmd "$env:windir\System32\netsh.exe" 'interface teredo show state' 15000
    $isa = Invoke-Cmd "$env:windir\System32\netsh.exe" 'interface isatap show state' 15000
    $s6 = Invoke-Cmd "$env:windir\System32\netsh.exe" 'interface 6to4 show state' 15000
    $tun = @()
    if ($ter -match '(?im)(type|tipo)\s*:\s*(enterpriseclient|client|default|automatic)' -and $ter -notmatch '(?im):\s*(disabled|desativad)') { $tun += 'Teredo' }
    if ($isa -match '(?im):\s*(enabled|automatic|habilitad|automát)' -and $isa -notmatch '(?im):\s*(disabled|desativad)') { $tun += 'ISATAP' }
    if ($s6 -match '(?im):\s*(enabled|automatic|habilitad|automát)' -and $s6 -notmatch '(?im):\s*(disabled|desativad)') { $tun += '6to4' }
    if ($tun.Count) {
        Add-Item $R 'Túneis IPv6 ativos' ($tun -join ', ') 'Atenção'
        Add-Achado $R 'Segurança' 'Médio' ("Túnel(is) IPv6 ativo(s): {0}. Podem contornar controles de rede IPv4 e permitir mitm via RA falso." -f ($tun -join ', ')) 'Desativar os túneis não utilizados: netsh interface teredo set state disabled; netsh interface isatap set state disabled; netsh interface 6to4 set state disabled.'
    }
    else { Add-Item $R 'Túneis IPv6 (Teredo/ISATAP/6to4)' 'Nenhum ativo' 'OK' }

    # --- Servidores DNS ---
    Log 'Analisando servidores DNS...'
    $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses.Count } | Select-Object -ExpandProperty ServerAddresses | Sort-Object -Unique)
    Add-Item $R 'Servidores DNS configurados' (($dns -join ', '))
    $dnsPub = @('8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9', '208.67.222.222', '208.67.220.220', '4.2.2.2', '4.2.2.1')
    $ext = @($dns | Where-Object { $_ -in $dnsPub })
    if ($srv -and $Cfg.SO.DC -and $ext.Count) { Add-Achado $R 'Segurança' 'Médio' ("Controlador de domínio usando DNS público ({0})." -f ($ext -join ', ')) 'Um DC deve apontar para si mesmo/DNS interno; DNS público quebra a resolução do AD e expõe consultas.' }
    try {
        $doh = @(Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue)
        if ($doh.Count) { Add-Item $R 'DNS over HTTPS (DoH) configurado' ($doh.Count) 'Info' }
    } catch {}

    # --- Tabela ARP / vizinhança (spoofing e descoberta de hosts) ---
    Log 'Lendo tabela ARP e descobrindo hosts na rede local...'
    $neigh = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { [string]$_.State -in @('Reachable', 'Stale', 'Permanent', 'Delay', 'Probe') -and $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch '^(00-00-00-00-00-00|FF-FF-FF-FF-FF-FF)$' -and $_.IPAddress -notmatch '^(224\.|239\.|255\.)' })
    $hosts = @($neigh | Where-Object { $_.IPAddress -notmatch '\.255$' } | Select-Object @{n = 'IP'; e = { $_.IPAddress } }, @{n = 'MAC'; e = { $_.LinkLayerAddress } }, @{n = 'Estado'; e = { [string]$_.State } }, @{n = 'Interface'; e = { (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Name } } | Sort-Object { [version](($_.IP -replace '[^\d.]', '')) } -ErrorAction SilentlyContinue)
    if (-not $hosts.Count) {
        $arp = Invoke-Cmd "$env:windir\System32\arp.exe" '-a' 20000
        $hosts = @([regex]::Matches($arp, '(?m)^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F-]{11,17})\s+(\w+)') | ForEach-Object { [pscustomobject]@{ IP = $_.Groups[1].Value; MAC = ($_.Groups[2].Value -replace ':', '-').ToUpper(); Estado = $_.Groups[3].Value; Interface = '' } } | Where-Object { $_.MAC -notmatch '^FF-FF' -and $_.IP -notmatch '\.255$|^22[4-9]\.|^23\d\.' })
    }
    Add-Item $R 'Hosts vistos na rede local (ARP)' $hosts.Count
    Add-Tabela $R 'Hosts na rede local (tabela ARP/vizinhança)' $hosts
    # MAC duplicado em vários IPs = possível ARP spoofing (ou gateway redundante)
    $dupMac = @($hosts | Group-Object MAC | Where-Object { $_.Count -gt 1 -and $_.Name -notmatch '^(00-00|FF-FF)' })
    foreach ($d in $dupMac) {
        $ips = @($d.Group | ForEach-Object { $_.IP })
        $gwDup = @($ips | Where-Object { $_ -in $gws }).Count -gt 0
        Add-Achado $R 'Segurança' $(if ($gwDup) { 'Alto' } else { 'Médio' }) ("MAC {0} responde por {1} IPs: {2}." -f $d.Name, $d.Count, ($ips -join ', ')) 'Possível ARP spoofing (envenenamento) na rede - um atacante pode estar interceptando o tráfego. Verificar o dispositivo com esse MAC. Se for gateway redundante/NIC teaming, é normal.'
    }
    if (-not $dupMac.Count) { Add-Item $R 'Indício de ARP spoofing' 'Nenhum (sem MAC duplicado)' 'OK' }

    # --- Ferramentas de análise presentes ---
    $tshark = (Get-Command tshark.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $tshark) { foreach ($c in @("$env:ProgramFiles\Wireshark\tshark.exe", "${env:ProgramFiles(x86)}\Wireshark\tshark.exe")) { if (Test-Path $c) { $tshark = $c; break } } }
    $pktmon = (Get-Command pktmon.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source; if (-not $pktmon) { if (Test-Path "$env:windir\System32\pktmon.exe") { $pktmon = "$env:windir\System32\pktmon.exe" } }
    Add-Item $R 'Wireshark/tshark instalado' $(if ($tshark) { 'Sim' } else { 'Não' }) 'Info'
    Add-Item $R 'pktmon (captura nativa do Windows)' $(if ($pktmon) { 'Disponível' } else { 'Indisponível (Windows antigo)' }) 'Info'

    # --- Captura de pacotes (opcional) ---
    if ($Cfg.CapturaRede) {
        $seg = [int]$Cfg.CapSeg; if ($seg -lt 10) { $seg = 45 }
        if ($pktmon) {
            Log ("Iniciando captura de pacotes com pktmon por {0} s..." -f $seg)
            $dir = Join-Path $env:TEMP ('AuditorTI_cap_' + (Get-Date -Format 'yyyyMMddHHmmss'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $etl = Join-Path $dir 'captura.etl'; $pcap = Join-Path $dir 'captura_rede.pcapng'
            [void](Invoke-Cmd $pktmon 'stop' 20000)
            [void](Invoke-Cmd $pktmon ('start --capture --pkt-size 256 --file-name "{0}"' -f $etl) 30000)
            if ($UltimoCodigo -ne 0 -or -not (Test-Path $etl)) { [void](Invoke-Cmd $pktmon ('start --etw --pkt-size 256 --file-name "{0}"' -f $etl) 30000) }
            Start-Sleep -Seconds $seg
            [void](Invoke-Cmd $pktmon 'stop' 60000)
            Log 'Convertendo a captura para o formato do Wireshark (pcapng)...'
            [void](Invoke-Cmd $pktmon ('pcapng "{0}" -o "{1}"' -f $etl, $pcap) 180000)
            if (-not (Test-Path $pcap)) { $alt = ($pcap -replace '\.pcapng$', '.pcap'); [void](Invoke-Cmd $pktmon ('etl2pcap "{0}" -o "{1}"' -f $etl, $alt) 180000); if (Test-Path $alt) { $pcap = $alt } }
            if (Test-Path $pcap) {
                $tam = [math]::Round((Get-Item $pcap).Length / 1MB, 2)
                Add-Item $R 'Captura de pacotes' ("Concluída - {0} MB ({1} s) - arquivo para abrir no Wireshark" -f $tam, $seg) 'OK'
                $R.Extra.Captura = $pcap
                Add-Item $R 'Arquivo da captura' ('captura_rede' + [IO.Path]::GetExtension($pcap) + ' (salvo na pasta do relatório)') 'Info'
            }
            else { Add-Item $R 'Captura de pacotes' 'Capturado, mas não foi possível converter para pcapng (arquivo .etl na pasta temporária)' 'Atenção'; if (Test-Path $etl) { $R.Extra.Captura = $etl } }

            # Análise com tshark, se disponível
            if ($tshark -and $R.Extra.Captura -and $R.Extra.Captura -like '*.pcap*') {
                Log 'Analisando a captura com tshark...'
                $phs = Invoke-Cmd $tshark ('-r "{0}" -q -z io,phs' -f $R.Extra.Captura) 120000 -Utf8
                $claros = @()
                foreach ($prot in @(@('telnet', 'Telnet'), @('ftp', 'FTP'), @('http', 'HTTP'), @('tftp', 'TFTP'), @('smb\b', 'SMBv1'), @('llmnr', 'LLMNR'), @('nbns', 'NetBIOS-NS'), @('nbdgm', 'NetBIOS'))) { if ($phs -match ('(?im)\b' + $prot[0])) { $claros += $prot[1] } }
                if ($claros.Count) { Add-Achado $R 'Segurança' 'Médio' ("Protocolos sem criptografia/legados vistos na rede: {0}." -f (($claros | Select-Object -Unique) -join ', ')) 'Tráfego em texto puro pode ser interceptado. Migrar para alternativas seguras (HTTPS, SFTP/SSH, SMBv3) e desativar LLMNR/NBT-NS.' }
                $linhas = @($phs -split "`n" | Where-Object { $_ -match '\S' -and $_ -notmatch '====|Protocol Hierarchy|frames:' } | Select-Object -First 40 | ForEach-Object { [pscustomobject]@{ 'Hierarquia de protocolos (tshark)' = ($_.TrimEnd()) } })
                Add-Tabela $R 'Protocolos observados na captura (tshark -z io,phs)' $linhas
            }
            elseif ($R.Extra.Captura) { Add-Item $R 'Análise da captura' 'Arquivo salvo para abrir manualmente no Wireshark (tshark não instalado para análise automática)' 'Info' }
        }
        else { Add-Item $R 'Captura de pacotes' 'Não executada: pktmon indisponível (Windows anterior ao 10 1809/Server 2019) e Wireshark/tshark não instalado' 'Atenção' }
    }
    else { Add-Item $R 'Captura de pacotes' 'Não executada (opção desmarcada)' }
    $R
}}
)

# =====================================================================
#  NOTAS, PAPEL TIMBRADO E RELATÓRIO
# =====================================================================

function Get-TodosAchados {
    $l = New-Object System.Collections.ArrayList
    foreach ($k in $Global:Resultados.Keys) {
        foreach ($a in $Global:Resultados[$k].Achados) {
            [void]$l.Add([pscustomobject]@{ Area = $Global:Resultados[$k].Nome; AreaId = $k; Categoria = $a.Categoria; Severidade = $a.Severidade; Achado = $a.Achado; Recomendacao = $a.Recomendacao; Penalidade = $a.Penalidade; Upgrade = $a.Upgrade })
        }
    }
    return , $l
}

function Get-RankSev([string]$s) { switch ($s) { 'Crítico' { 0 } 'Alto' { 1 } 'Médio' { 2 } 'Baixo' { 3 } default { 4 } } }

function Get-Notas {
    $all = Get-TodosAchados
    $penD = [double](($all | Where-Object { $_.Categoria -eq 'Desempenho' } | Measure-Object Penalidade -Sum).Sum)
    $penS = [double](($all | Where-Object { $_.Categoria -eq 'Segurança' } | Measure-Object Penalidade -Sum).Sum)
    $notaD = [math]::Max(0, 10 - $penD)
    $notaS = [math]::Max(0, 10 - $penS)
    $critS = @($all | Where-Object { $_.Categoria -eq 'Segurança' -and $_.Severidade -eq 'Crítico' }).Count
    $critD = @($all | Where-Object { $_.Categoria -eq 'Desempenho' -and $_.Severidade -eq 'Crítico' }).Count
    if ($critS -gt 0) { $notaS = [math]::Min($notaS, 5) }
    if ($critD -gt 0) { $notaD = [math]::Min($notaD, 5) }
    return @{
        Desempenho = [math]::Round($notaD, 1); Seguranca = [math]::Round($notaS, 1)
        PenD = [math]::Round($penD, 2); PenS = [math]::Round($penS, 2)
        Contagem = @{
            'Crítico' = @($all | Where-Object { $_.Severidade -eq 'Crítico' }).Count
            'Alto'    = @($all | Where-Object { $_.Severidade -eq 'Alto' }).Count
            'Médio'   = @($all | Where-Object { $_.Severidade -eq 'Médio' }).Count
            'Baixo'   = @($all | Where-Object { $_.Severidade -eq 'Baixo' }).Count
        }
    }
}

function Get-Conceito([double]$n) {
    if ($n -ge 9) { return @('Excelente', '#1e8e3e') }
    elseif ($n -ge 7) { return @('Bom', '#43a047') }
    elseif ($n -ge 5) { return @('Regular', '#f9a825') }
    elseif ($n -ge 3) { return @('Ruim', '#ef6c00') }
    else { return @('Crítico', '#c62828') }
}

function Format-Nota([double]$n) { $n.ToString('0.0', [Globalization.CultureInfo]'pt-BR') }

# ---------------------------------------------------------------------
# Converte a 1ª página de um PDF em PNG (API nativa do Windows 10/11)
# ---------------------------------------------------------------------
function Convert-PdfParaPng([string]$pdf, [string]$png) {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
        $null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
        $null = [Windows.Data.Pdf.PdfPageRenderOptions, Windows.Data.Pdf, ContentType = WindowsRuntime]
        $null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
        $metodos = [System.WindowsRuntimeSystemExtensions].GetMethods()
        $asTaskOp = $metodos | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
        $asTaskAc = $metodos | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
        $esperar = {
            param($op, [Type]$tipo)
            $t = $asTaskOp.MakeGenericMethod($tipo).Invoke($null, @($op))
            [void]$t.Wait(-1); $t.Result
        }
        $arq = & $esperar ([Windows.Storage.StorageFile]::GetFileFromPathAsync($pdf)) ([Windows.Storage.StorageFile])
        $doc = & $esperar ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($arq)) ([Windows.Data.Pdf.PdfDocument])
        $pag = $doc.GetPage(0)
        $opt = New-Object Windows.Data.Pdf.PdfPageRenderOptions
        $opt.DestinationWidth = [uint32]2480
        $st = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
        $t = $asTaskAc.Invoke($null, @($pag.RenderToStreamAsync($st, $opt))); [void]$t.Wait(-1)
        $net = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($st.GetInputStreamAt(0))
        $img = [System.Drawing.Image]::FromStream($net)
        $img.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        $img.Dispose(); $net.Dispose()
        return (Test-Path $png)
    } catch { return $false }
}

# ---------------------------------------------------------------------
# Gera PDF a partir do HTML usando o Microsoft Edge (ou Chrome) sem janela
# ---------------------------------------------------------------------
function Export-Pdf([string]$html, [string]$pdf) {
    $nav = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $nav) { return $false }
    $uri = ([Uri]$html).AbsoluteUri
    foreach ($modo in @('--headless=new', '--headless')) {
        Remove-Item $pdf -Force -ErrorAction SilentlyContinue
        $perfil = Join-Path $env:TEMP ('auditorti_nav_' + [guid]::NewGuid().ToString('N'))
        $arg = "$modo --disable-gpu --no-first-run --no-default-browser-check --disable-extensions --no-pdf-header-footer --run-all-compositor-stages-before-draw --virtual-time-budget=8000 --user-data-dir=`"$perfil`" --print-to-pdf=`"$pdf`" `"$uri`""
        try {
            $p = Start-Process -FilePath $nav -ArgumentList $arg -PassThru -WindowStyle Hidden
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt 120) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
            if (-not $p.HasExited) { try { $p.Kill() } catch {} }
        } catch {}
        for ($i = 0; $i -lt 25 -and -not (Test-Path $pdf); $i++) { Start-Sleep -Milliseconds 200 }
        Remove-Item $perfil -Recurse -Force -ErrorAction SilentlyContinue
        if ((Test-Path $pdf) -and (Get-Item $pdf).Length -gt 1000) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------
function Esc([object]$s) { if ($null -eq $s) { return '' }; [System.Net.WebUtility]::HtmlEncode([string]$s) }

function Get-Classe([string]$s) {
    switch ($s) {
        'Crítico' { 'critico' } 'Alto' { 'alto' } 'Médio' { 'medio' } 'Baixo' { 'baixo' }
        'OK' { 'ok' } 'Atenção' { 'atencao' } 'Erro' { 'critico' } default { 'info' }
    }
}

function ConvertTo-TabelaHtml($linhas, [int]$max = 30) {
    $arr = @($linhas | Where-Object { $null -ne $_ })
    if (-not $arr.Count) { return '' }
    $cols = @($arr[0].PSObject.Properties | ForEach-Object { $_.Name })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table class="dados"><thead><tr>')
    foreach ($c in $cols) { [void]$sb.Append("<th>$(Esc $c)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($l in ($arr | Select-Object -First $max)) {
        [void]$sb.Append('<tr>')
        foreach ($c in $cols) {
            $v = [string]$l.$c
            if ($v.Length -gt 200) { $v = $v.Substring(0, 197) + '...' }
            [void]$sb.Append("<td>$(Esc $v)</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    if ($arr.Count -gt $max) { [void]$sb.Append("<p class='obs'>Exibindo $max de $($arr.Count) registros. A lista completa está no arquivo de evidências (evidencias.json).</p>") }
    return $sb.ToString()
}

function New-RelatorioHtml($Info, $Notas, [string]$HashEvid, $HashesPrints) {
    $sb = New-Object System.Text.StringBuilder
    $Wr = { param($t) [void]$sb.Append($t) }
    $topo = [int]$Info.MargemTopo; $base = [int]$Info.MargemBase; $lado = [int]$Info.MargemLado
    if (-not $Info.Timbrado) { $topo = [math]::Max(12, [math]::Min($topo, 15)); $base = [math]::Max(12, [math]::Min($base, 15)) }
    $todos = Get-TodosAchados
    $cD = Get-Conceito $Notas.Desempenho; $cS = Get-Conceito $Notas.Seguranca
    $res = $null; if ($Global:Resultados.Contains('sistema')) { $res = $Global:Resultados['sistema'].Extra.Resumo }
    if (-not $res) { $res = @{ Computador = $env:COMPUTERNAME; Modelo = '-'; Serie = '-'; SO = '-'; CPU = '-'; RAM = '-' } }
    $dur = $Global:Fim - $Global:Inicio

    & $Wr @"
<!DOCTYPE html>
<html lang="pt-BR"><head><meta charset="utf-8">
<title>Relatório de Auditoria - $(Esc $Info.Cliente) - $(Esc $res.Computador)</title>
<style>
@page { size: A4; margin: 0; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body { font-family: 'Segoe UI', Arial, sans-serif; font-size: 9.5pt; color: #1f2933; line-height: 1.35; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
.timbrado { position: fixed; top: 0; left: 0; width: 210mm; height: 297mm; z-index: -1; }
.timbrado img { width: 210mm; height: 297mm; display: block; }
@media screen { body { width: 210mm; margin: 0 auto; background: #fff; position: relative; box-shadow: 0 0 12px #999; } .timbrado { position: absolute; } }
table.pagina { width: 210mm; border-collapse: collapse; }
table.pagina > thead > tr > td, table.pagina > tfoot > tr > td { padding: 0; }
.esp-topo { height: ${topo}mm; } .esp-base { height: ${base}mm; }
td.conteudo { padding: 0 ${lado}mm; vertical-align: top; }
h1 { font-size: 17pt; color: #123456; margin: 0 0 1mm; letter-spacing: .3px; }
.sub { color: #486581; font-size: 10pt; margin-bottom: 4mm; }
h2 { font-size: 12.5pt; color: #123456; border-bottom: 2px solid #123456; padding-bottom: 1mm; margin: 6mm 0 3mm; page-break-after: avoid; }
h3 { font-size: 10.5pt; margin: 4mm 0 1.5mm; color: #334e68; page-break-after: avoid; }
p { margin: 1mm 0 2mm; }
.obs { font-size: 7.5pt; color: #627d98; font-style: italic; }
table.dados { width: 100%; border-collapse: collapse; margin: 1mm 0 3mm; font-size: 8pt; background: rgba(255,255,255,.88); }
table.dados th { background: #123456; color: #fff; text-align: left; padding: 1.2mm 1.5mm; font-weight: 600; }
table.dados td { border-bottom: 1px solid #d9e2ec; padding: .9mm 1.5mm; vertical-align: top; word-break: break-word; }
table.dados tr { page-break-inside: avoid; }
table.dados tbody tr:nth-child(even) td { background: rgba(240,244,248,.9); }
.ident { display: grid; grid-template-columns: 1fr 1fr; gap: 1.2mm 6mm; background: rgba(240,244,248,.92); padding: 3mm 4mm; border-radius: 2mm; font-size: 9pt; }
.ident b { color: #486581; font-weight: 600; display: inline-block; min-width: 30mm; }
.notas { display: flex; gap: 5mm; margin: 4mm 0; page-break-inside: avoid; }
.nota { flex: 1; border: 1px solid #d9e2ec; border-radius: 3mm; padding: 4mm; display: flex; align-items: center; gap: 5mm; background: rgba(255,255,255,.94); }
.dial { width: 30mm; height: 30mm; border-radius: 50%; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.dial span { width: 23mm; height: 23mm; border-radius: 50%; background: #fff; display: flex; align-items: center; justify-content: center; font-size: 19pt; font-weight: 700; }
.nota .tit { font-size: 11pt; font-weight: 700; color: #123456; }
.nota .conc { font-size: 13pt; font-weight: 700; }
.chips { display: flex; gap: 3mm; margin: 2mm 0 4mm; }
.chip { flex: 1; text-align: center; border-radius: 2mm; padding: 2mm; color: #fff; font-weight: 600; }
.chip b { display: block; font-size: 15pt; }
.badge { display: inline-block; padding: .2mm 2mm; border-radius: 3mm; font-size: 7.5pt; font-weight: 600; color: #fff; white-space: nowrap; }
.critico { background: #c62828; } .alto { background: #e65100; } .medio { background: #f9a825; color: #222; } .baixo { background: #78909c; }
.ok { background: #2e7d32; } .atencao { background: #f9a825; color: #222; } .info { } span.info { background: #90a4ae; }
.achado { border-left: 2.5mm solid #90a4ae; padding: 1.5mm 3mm; margin: 1.5mm 0; background: rgba(255,255,255,.92); page-break-inside: avoid; }
.achado.critico, .achado.alto, .achado.medio, .achado.baixo { background: rgba(255,255,255,.92); color: #1f2933; }
.achado.critico { border-color: #c62828; } .achado.alto { border-color: #e65100; } .achado.medio { border-color: #f9a825; } .achado.baixo { border-color: #78909c; }
.achado .rec { color: #334e68; font-size: 8.5pt; margin-top: .6mm; }
.fig { page-break-inside: avoid; text-align: center; margin: 3mm 0 4mm; }
.fig img { max-width: 100%; max-height: 180mm; border: 1px solid #bcccdc; }
.fig .leg { font-size: 7.5pt; color: #627d98; margin-top: 1mm; }
.cab-teste { display: flex; justify-content: space-between; align-items: baseline; }
.cab-teste .meta { font-size: 8pt; color: #627d98; }
.quebra { page-break-before: always; }
.assin { display: flex; gap: 12mm; margin-top: 18mm; page-break-inside: avoid; }
.assin div { flex: 1; border-top: 1px solid #333; text-align: center; padding-top: 1.5mm; font-size: 8.5pt; }
.mono { font-family: Consolas, monospace; font-size: 7.5pt; word-break: break-all; }
.log { font-family: Consolas, monospace; font-size: 6.8pt; white-space: pre-wrap; background: rgba(240,244,248,.92); padding: 2mm; border-radius: 1mm; }
ul { margin: 1mm 0 2mm 5mm; padding-left: 3mm; } li { margin-bottom: 1mm; }
</style></head><body>
"@
    if ($Info.Timbrado -and (Test-Path $Info.Timbrado)) {
        $ext = [IO.Path]::GetExtension($Info.Timbrado).ToLower()
        $mime = if ($ext -eq '.png') { 'image/png' } else { 'image/jpeg' }
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Info.Timbrado))
        & $Wr "<div class='timbrado'><img src='data:$mime;base64,$b64' alt=''></div>"
    }
    & $Wr "<table class='pagina'><thead><tr><td><div class='esp-topo'></div></td></tr></thead><tfoot><tr><td><div class='esp-base'></div></td></tr></tfoot><tbody><tr><td class='conteudo'>"

    # ---------- Capa / identificação ----------
    & $Wr "<h1>RELATÓRIO DE AUDITORIA TÉCNICA</h1><div class='sub'>Estação de trabalho Windows — diagnóstico de desempenho e segurança</div>"
    & $Wr "<div class='ident'>"
    & $Wr "<div><b>Cliente:</b> $(Esc $Info.Cliente)</div><div><b>Nº OS / chamado:</b> $(Esc $Info.OS)</div>"
    & $Wr "<div><b>Técnico responsável:</b> $(Esc $Info.Tecnico)</div><div><b>ID do relatório:</b> $(Esc $Global:IdAud)</div>"
    & $Wr "<div><b>Início:</b> $($Global:Inicio.ToString('dd/MM/yyyy HH:mm:ss'))</div><div><b>Término:</b> $($Global:Fim.ToString('dd/MM/yyyy HH:mm:ss')) ($([int]$dur.TotalMinutes) min $($dur.Seconds) s)</div>"
    & $Wr "<div><b>Computador:</b> $(Esc $res.Computador)</div><div><b>Equipamento:</b> $(Esc $res.Modelo)</div>"
    & $Wr "<div><b>Nº de série:</b> $(Esc $res.Serie)</div><div><b>Sistema:</b> $(Esc $res.SO)</div>"
    & $Wr "<div><b>Processador:</b> $(Esc $res.CPU)</div><div><b>Memória:</b> $(Esc $res.RAM)</div>"
    & $Wr "</div>"

    # ---------- Notas ----------
    $degD = [int]($Notas.Desempenho * 36); $degS = [int]($Notas.Seguranca * 36)
    & $Wr "<h2>Avaliação geral</h2><div class='notas'>"
    & $Wr "<div class='nota'><div class='dial' style='background: conic-gradient($($cD[1]) ${degD}deg, #e4e7eb 0)'><span>$(Format-Nota $Notas.Desempenho)</span></div><div><div class='tit'>Nota de desempenho</div><div class='conc' style='color:$($cD[1])'>$($cD[0])</div><div class='obs'>Escala de 0 a 10 — hardware, disco, memória, CPU e estabilidade</div></div></div>"
    & $Wr "<div class='nota'><div class='dial' style='background: conic-gradient($($cS[1]) ${degS}deg, #e4e7eb 0)'><span>$(Format-Nota $Notas.Seguranca)</span></div><div><div class='tit'>Nota de segurança</div><div class='conc' style='color:$($cS[1])'>$($cS[0])</div><div class='obs'>Escala de 0 a 10 — atualizações, antivírus, firewall, contas e configurações</div></div></div>"
    & $Wr "</div>"
    $cnt = $Notas.Contagem
    & $Wr "<div class='chips'><div class='chip critico'><b>$($cnt['Crítico'])</b>Crítico</div><div class='chip alto'><b>$($cnt['Alto'])</b>Alto</div><div class='chip medio'><b>$($cnt['Médio'])</b>Médio</div><div class='chip baixo'><b>$($cnt['Baixo'])</b>Baixo</div></div>"

    # ---------- Resumo executivo ----------
    $nAreas = $Global:Resultados.Count
    $nVerif = 0; foreach ($k in $Global:Resultados.Keys) { $nVerif += $Global:Resultados[$k].Itens.Count }
    & $Wr "<h2>Resumo executivo</h2>"
    & $Wr "<p>Foram analisadas <b>$nAreas áreas</b> do equipamento, totalizando <b>$nVerif verificações</b> automatizadas. Foram identificados <b>$($cnt['Crítico']) ponto(s) crítico(s)</b>, $($cnt['Alto']) de severidade alta, $($cnt['Médio']) média e $($cnt['Baixo']) baixa. O equipamento obteve nota <b>$(Format-Nota $Notas.Desempenho)</b> em desempenho (<b>$($cD[0])</b>) e <b>$(Format-Nota $Notas.Seguranca)</b> em segurança (<b>$($cS[0])</b>).</p>"
    $prio = @($todos | Where-Object { $_.Severidade -in @('Crítico', 'Alto') } | Sort-Object @{e = { Get-RankSev $_.Severidade } }, Categoria)
    if ($prio.Count) {
        & $Wr "<h3>Pontos que exigem atenção imediata</h3>"
        foreach ($a in ($prio | Select-Object -First 10)) { & $Wr "<div class='achado $(Get-Classe $a.Severidade)'><span class='badge $(Get-Classe $a.Severidade)'>$(Esc $a.Severidade)</span> <b>$(Esc $a.Area):</b> $(Esc $a.Achado)<div class='rec'>&#10140; $(Esc $a.Recomendacao)</div></div>" }
    }
    else { & $Wr "<p>Nenhum problema crítico ou de severidade alta foi encontrado.</p>" }

    # ---------- Melhorias e upgrades ----------
    & $Wr "<h2>Melhorias e upgrades recomendados</h2>"
    $upg = @($todos | Where-Object { $_.Upgrade } | Sort-Object @{e = { Get-RankSev $_.Severidade } })
    if ($upg.Count) {
        & $Wr "<h3>Upgrades de hardware / equipamento</h3><ul>"
        foreach ($u in $upg) { & $Wr "<li><span class='badge $(Get-Classe $u.Severidade)'>$(Esc $u.Severidade)</span> <b>$(Esc $u.Achado)</b><br>$(Esc $u.Recomendacao)</li>" }
        & $Wr "</ul>"
    }
    else { & $Wr "<p>O hardware atende ao uso atual; nenhum upgrade é necessário no momento.</p>" }
    $vistos = @{}
    $plano = foreach ($a in ($todos | Where-Object { $_.Severidade -ne 'Info' -and -not $_.Upgrade } | Sort-Object @{e = { Get-RankSev $_.Severidade } })) {
        if ($vistos[$a.Recomendacao]) { continue }; $vistos[$a.Recomendacao] = 1
        $pz = switch ($a.Severidade) { 'Crítico' { 'Imediata' } 'Alto' { 'Alta (até 7 dias)' } 'Médio' { 'Média (até 30 dias)' } default { 'Baixa' } }
        [pscustomobject]@{ 'Prioridade' = $pz; 'Área' = $a.Area; 'Categoria' = $a.Categoria; 'Ação recomendada' = $a.Recomendacao }
    }
    if (@($plano).Count) { & $Wr "<h3>Plano de ação priorizado</h3>"; & $Wr (ConvertTo-TabelaHtml $plano 60) }
    $dicas = @($todos | Where-Object { $_.Severidade -eq 'Info' -and $_.Recomendacao -and -not $_.Upgrade })
    if ($dicas.Count) { & $Wr "<h3>Sugestões adicionais</h3><ul>"; foreach ($d in $dicas) { & $Wr "<li>$(Esc $d.Achado) — $(Esc $d.Recomendacao)</li>" }; & $Wr "</ul>" }

    # ---------- Ações executadas ----------
    if ($Global:Lotes.Count -or $Global:Acoes.Count) {
        & $Wr "<h2>Manutenção e alterações realizadas</h2>"
        & $Wr "<p>As ações abaixo foram autorizadas pelo técnico. Os achados e as notas deste relatório refletem a situação <b>encontrada</b> na auditoria; para comprovar o resultado das correções, execute uma nova auditoria após reiniciar o computador.</p>"
        foreach ($lt in $Global:Lotes) {
            & $Wr "<h3>$(Esc $lt.Titulo) <span class='obs'>($($lt.Inicio.ToString('dd/MM/yyyy HH:mm')) a $($lt.Fim.ToString('HH:mm')))</span></h3>"
            & $Wr "<table class='dados'><thead><tr><th style='width:40%'>Etapa</th><th>Resultado</th><th style='width:16mm'>Situação</th></tr></thead><tbody>"
            foreach ($i in $lt.Itens) { & $Wr "<tr><td>$(Esc $i.Item)</td><td>$(Esc $i.Valor)</td><td><span class='badge $(Get-Classe $i.Status)'>$(Esc $i.Status)</span></td></tr>" }
            & $Wr "</tbody></table>"
        }
        if ($Global:Acoes.Count) {
            & $Wr "<h3>Registro detalhado das alterações</h3><p class='obs'>O valor anterior de cada configuração foi guardado. O script <b>desfazer_alteracoes.ps1</b> (na pasta do relatório) restaura as configurações alteradas.</p>"
            & $Wr (ConvertTo-TabelaHtml ($Global:Acoes | Select-Object @{n = 'Data/hora'; e = { $_.Data.ToString('dd/MM HH:mm:ss') } }, 'Ação', 'Item', 'Estado anterior', 'Resultado', @{n = 'Reversível'; e = { SimNao ([bool]$_.Desfazer) } }) 300)
        }
    }

    # ---------- Detalhamento ----------
    & $Wr "<h2 class='quebra'>Detalhamento por área</h2>"
    $nSec = 0; $nFig = 0
    foreach ($k in $Global:Resultados.Keys) {
        $r = $Global:Resultados[$k]; $nSec++
        $st = $r.Situacao
        & $Wr "<div class='cab-teste'><h3>$nSec. $(Esc $r.Nome) <span class='badge $(Get-Classe $st)'>$(Esc $st)</span></h3><span class='meta'>duração: $([math]::Round($r.Duracao,0)) s</span></div>"
        if ($r.Desc) { & $Wr "<p class='obs'>Escopo: $(Esc $r.Desc)</p>" }
        if ($r.Itens.Count) {
            & $Wr "<table class='dados'><thead><tr><th style='width:34%'>Verificação</th><th>Resultado</th><th style='width:16mm'>Situação</th></tr></thead><tbody>"
            foreach ($i in $r.Itens) { & $Wr "<tr><td>$(Esc $i.Item)</td><td>$(Esc $i.Valor)</td><td><span class='badge $(Get-Classe $i.Status)'>$(Esc $i.Status)</span></td></tr>" }
            & $Wr "</tbody></table>"
        }
        foreach ($a in ($r.Achados | Sort-Object @{e = { Get-RankSev $_.Severidade } })) {
            & $Wr "<div class='achado $(Get-Classe $a.Severidade)'><span class='badge $(Get-Classe $a.Severidade)'>$(Esc $a.Severidade)</span> <span class='obs'>[$(Esc $a.Categoria)$(if ($a.Penalidade -gt 0) { ' | -' + (Format-Nota $a.Penalidade) + ' pt' })]</span> $(Esc $a.Achado)<div class='rec'>&#10140; $(Esc $a.Recomendacao)</div></div>"
        }
        foreach ($t in $r.Tabelas) { & $Wr "<h3 style='font-size:9.5pt'>$(Esc $t.Titulo)</h3>"; & $Wr (ConvertTo-TabelaHtml $t.Linhas 30) }
        if ($Global:Prints.ContainsKey($k)) {
            $nFig++
            $b64 = [Convert]::ToBase64String($Global:Prints[$k])
            & $Wr "<div class='fig'><img src='data:image/jpeg;base64,$b64' alt=''><div class='leg'>Figura $nFig — Tela do AuditorTI ao concluir o teste &ldquo;$(Esc $r.Nome)&rdquo; ($($r.Fim.ToString('dd/MM/yyyy HH:mm:ss')))</div></div>"
        }
    }
    $naoExec = @($Global:Testes | Where-Object { -not $Global:Resultados.Contains($_.Id) })
    if ($naoExec.Count) { & $Wr "<p class='obs'>Testes não executados nesta auditoria: $(Esc (($naoExec | ForEach-Object { $_.Nome }) -join ', ')). As notas consideram apenas as áreas analisadas.</p>" }

    # ---------- Lista completa de achados ----------
    & $Wr "<h2 class='quebra'>Anexo A — Lista completa de achados</h2>"
    $n = 0
    $lista = foreach ($a in ($todos | Sort-Object @{e = { Get-RankSev $_.Severidade } }, Categoria)) { $n++; [pscustomobject]@{ '#' = $n; 'Severidade' = $a.Severidade; 'Categoria' = $a.Categoria; 'Área' = $a.Area; 'Achado' = $a.Achado; 'Desconto' = $(if ($a.Penalidade -gt 0) { '-' + (Format-Nota $a.Penalidade) } else { '0' }) } }
    if ($n) { & $Wr (ConvertTo-TabelaHtml $lista 500) } else { & $Wr "<p>Nenhum achado.</p>" }

    # ---------- Metodologia ----------
    & $Wr "<h2>Anexo B — Metodologia e critérios de pontuação</h2>"
    & $Wr "<p>A auditoria foi realizada pelo software AuditorTI $Global:VersaoApp, executado localmente com privilégios de administrador, consultando diretamente as interfaces do Windows (WMI/CIM, Registro, Windows Update Agent, Microsoft Defender, Firewall do Windows, Agendador de Tarefas e Logs de Eventos). Nenhum dado foi enviado para a internet.</p>"
    & $Wr "<p>Cada área começa com nota 10. Cada achado desconta pontos conforme a severidade (Segurança: Crítico −2,5 | Alto −1,2 | Médio −0,5 | Baixo −0,15; Desempenho: desconto específico indicado em cada achado). Havendo qualquer achado Crítico, a nota da categoria é limitada a 5,0. Descontos totais: desempenho −$(Format-Nota $Notas.PenD) / segurança −$(Format-Nota $Notas.PenS).</p>"
    & $Wr "<p><b>Conceitos:</b> 9,0–10 Excelente · 7,0–8,9 Bom · 5,0–6,9 Regular · 3,0–4,9 Ruim · abaixo de 3,0 Crítico.</p>"
    $met = foreach ($t in $Global:Testes) { [pscustomobject]@{ 'Área' = $t.Nome; 'O que é verificado' = $t.Desc; 'Executado' = SimNao ($Global:Resultados.Contains($t.Id)) } }
    & $Wr (ConvertTo-TabelaHtml $met 50)

    # ---------- Integridade ----------
    & $Wr "<h2>Anexo C — Integridade e rastreabilidade</h2>"
    & $Wr "<p>Os dados brutos coletados foram gravados no arquivo <b>evidencias.json</b>, entregue junto com este relatório. Qualquer alteração nesse arquivo muda o código de verificação (hash SHA-256) abaixo, permitindo comprovar a autenticidade das informações.</p>"
    & $Wr "<div class='ident'><div><b>ID do relatório:</b> $(Esc $Global:IdAud)</div><div><b>Versão do software:</b> AuditorTI $Global:VersaoApp</div><div><b>Executado por:</b> $(Esc ([Security.Principal.WindowsIdentity]::GetCurrent().Name))</div><div><b>Computador:</b> $(Esc $env:COMPUTERNAME)</div></div>"
    & $Wr "<p><b>SHA-256 de evidencias.json:</b><br><span class='mono'>$HashEvid</span></p>"
    if ($HashesPrints -and @($HashesPrints).Count) { & $Wr "<h3>Hash das capturas de tela</h3>"; & $Wr (ConvertTo-TabelaHtml $HashesPrints 50) }
    $ult = @($Global:LogGeral | Select-Object -Last 120)
    & $Wr "<h3>Registro de execução (últimas $($ult.Count) linhas)</h3><div class='log'>$(Esc ($ult -join "`n"))</div>"

    # ---------- Assinaturas ----------
    & $Wr "<div class='assin'><div>$(Esc $Info.Tecnico)<br>Técnico responsável</div><div>$(Esc $Info.Cliente)<br>Cliente / responsável pelo equipamento</div></div>"
    & $Wr "<p class='obs' style='text-align:center;margin-top:4mm'>Relatório gerado automaticamente em $((Get-Date).ToString('dd/MM/yyyy HH:mm')) — $(Esc $Global:IdAud)</p>"
    & $Wr "</td></tr></tbody></table></body></html>"
    return $sb.ToString()
}

# ---------------------------------------------------------------------
# Gera a pasta do relatório: HTML, PDF, evidências, prints e script de restauração
# ---------------------------------------------------------------------
function New-Relatorio($Info) {
    $notas = Get-Notas
    $limpa = ($Info.Cliente -replace '[\\/:*?"<>|]', '' -replace '\s+', '_').Trim('_')
    if (-not $limpa) { $limpa = 'cliente' }
    $raiz = $Global:PastaRelatorios
    $dir = Join-Path $raiz ("{0}_{1}_{2}" -f $Global:Inicio.ToString('yyyy-MM-dd_HHmm'), $limpa, $env:COMPUTERNAME)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $dPr = Join-Path $dir 'prints'; New-Item -ItemType Directory -Path $dPr -Force | Out-Null
    foreach ($kk in $Global:Resultados.Keys) { $cap = $Global:Resultados[$kk].Extra.Captura; if ($cap -and (Test-Path $cap)) { try { Copy-Item $cap (Join-Path $dir ('captura_rede' + [IO.Path]::GetExtension($cap))) -Force } catch {} } }
    $utf8 = New-Object System.Text.UTF8Encoding $false

    # capturas de tela
    $hp = New-Object System.Collections.ArrayList; $i = 0
    foreach ($k in $Global:Resultados.Keys) {
        if (-not $Global:Prints.ContainsKey($k)) { continue }
        $i++; $arq = Join-Path $dPr ("{0:00}_{1}.jpg" -f $i, $k)
        [IO.File]::WriteAllBytes($arq, $Global:Prints[$k])
        [void]$hp.Add([pscustomobject]@{ 'Arquivo' = "prints\" + (Split-Path $arq -Leaf); 'SHA-256' = (Get-FileHash $arq -Algorithm SHA256).Hash })
    }

    # evidências
    $evid = [ordered]@{
        IdRelatorio = $Global:IdAud; Software = "AuditorTI $Global:VersaoApp"
        Cliente = $Info.Cliente; Tecnico = $Info.Tecnico; OS = $Info.OS
        Computador = $env:COMPUTERNAME; ExecutadoPor = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Inicio = $Global:Inicio.ToString('o'); Fim = $Global:Fim.ToString('o')
        NotaDesempenho = $notas.Desempenho; NotaSeguranca = $notas.Seguranca
        Resultados = @(foreach ($k in $Global:Resultados.Keys) {
            $r = $Global:Resultados[$k]
            [ordered]@{ Id = $k; Nome = $r.Nome; Situacao = $r.Situacao; DuracaoSeg = [math]::Round($r.Duracao, 1); Itens = @($r.Itens); Achados = @($r.Achados); Tabelas = @($r.Tabelas | ForEach-Object { [ordered]@{ Titulo = $_.Titulo; Linhas = @($_.Linhas) } }); Metricas = $r.Metricas }
        })
        Manutencao = @($Global:Lotes | ForEach-Object { [ordered]@{ Titulo = $_.Titulo; Inicio = $_.Inicio.ToString('o'); Fim = $_.Fim.ToString('o'); Etapas = @($_.Itens) } })
        AcoesExecutadas = @($Global:Acoes | Select-Object @{n = 'Data'; e = { $_.Data.ToString('o') } }, 'Ação', 'Item', 'Estado anterior', 'Resultado', 'Desfazer')
        Capturas = @($hp)
        Log = @($Global:LogGeral)
    }
    $jsonArq = Join-Path $dir 'evidencias.json'
    [IO.File]::WriteAllText($jsonArq, ($evid | ConvertTo-Json -Depth 8), $utf8)
    $hash = (Get-FileHash $jsonArq -Algorithm SHA256).Hash

    # script para desfazer as alterações (ordem inversa)
    $desf = @($Global:Acoes | Where-Object { $_.Desfazer -and $_.Resultado -like 'Sucesso*' })
    if ($desf.Count) {
        $sr = New-Object System.Text.StringBuilder
        [void]$sr.AppendLine("# Desfaz as alterações feitas pelo AuditorTI - $Global:IdAud")
        [void]$sr.AppendLine("# Execute como Administrador: clique com o botão direito > Executar com o PowerShell")
        [void]$sr.AppendLine('$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())')
        [void]$sr.AppendLine('if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs; exit }')
        [void]$sr.AppendLine('$ErrorActionPreference = ''Continue''')
        for ($j = $desf.Count - 1; $j -ge 0; $j--) {
            [void]$sr.AppendLine("# $($desf[$j].'Ação'): $($desf[$j].Item)")
            [void]$sr.AppendLine($desf[$j].Desfazer)
        }
        [void]$sr.AppendLine("Write-Host 'Alterações desfeitas. Reinicie o computador.' -ForegroundColor Green")
        [void]$sr.AppendLine("if (-not `$env:CI) { Read-Host 'Pressione ENTER para fechar' }")
        [IO.File]::WriteAllText((Join-Path $dir 'desfazer_alteracoes.ps1'), $sr.ToString(), (New-Object System.Text.UTF8Encoding $true))
    }

    $html = New-RelatorioHtml $Info $notas $hash $hp
    $htmlArq = Join-Path $dir 'relatorio.html'
    [IO.File]::WriteAllText($htmlArq, $html, (New-Object System.Text.UTF8Encoding $true))
    $pdfArq = Join-Path $dir ("Relatorio_Auditoria_{0}_{1}.pdf" -f $limpa, $Global:Inicio.ToString('yyyyMMdd_HHmm'))
    $okPdf = Export-Pdf $htmlArq $pdfArq
    return @{ Pasta = $dir; Html = $htmlArq; Pdf = $(if ($okPdf) { $pdfArq } else { $null }); Hash = $hash }
}

# =====================================================================
#  INTERFACE GRÁFICA
# =====================================================================

function Get-Situacao($res) {
    $sevs = @($res.Achados | ForEach-Object { $_.Severidade })
    if ($res.Erro) { return 'Erro' }
    if ($sevs -contains 'Crítico') { return 'Crítico' }
    if ($sevs -contains 'Alto' -or $sevs -contains 'Médio') { return 'Atenção' }
    return 'OK'
}

function Get-CorSituacao([string]$s) {
    switch ($s) {
        'OK' { [Drawing.Color]::FromArgb(222, 244, 228) }
        'Atenção' { [Drawing.Color]::FromArgb(255, 243, 205) }
        'Médio' { [Drawing.Color]::FromArgb(255, 236, 210) }
        'Baixo' { [Drawing.Color]::FromArgb(246, 246, 236) }
        'Crítico' { [Drawing.Color]::FromArgb(253, 222, 222) }
        'Alto' { [Drawing.Color]::FromArgb(253, 228, 214) }
        'Erro' { [Drawing.Color]::FromArgb(253, 222, 222) }
        'Executando' { [Drawing.Color]::FromArgb(220, 235, 252) }
        default { [Drawing.Color]::White }
    }
}

function Update-Log {
    $m = $null
    while ($Global:Sync.Log.TryDequeue([ref]$m)) {
        if ($txtLog) { $txtLog.AppendText($m + [Environment]::NewLine) } else { [Console]::WriteLine($m) }
        [void]$Global:LogGeral.Add($m)
    }
}
function Write-LogUI([string]$m) { $Global:Sync.Log.Enqueue(("{0:HH:mm:ss}  {1}" -f (Get-Date), $m)); Update-Log }

# Executa um teste em segundo plano mantendo a interface responsiva
function Invoke-Teste($t, $item) {
    $Global:Sync.Atual = $null
    $iss = [initialsessionstate]::CreateDefault()
    try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch {}
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $Global:Sync)
    $rs.SessionStateProxy.SetVariable('Cfg', $Global:Cfg)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($Global:Helpers + "`n" + $t.Codigo.ToString())
    $h = $ps.BeginInvoke()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $estourou = $false
    while (-not $h.IsCompleted) {
        Update-Log
        if ($item) { $item.SubItems[2].Text = ('{0:N0} s' -f $sw.Elapsed.TotalSeconds) }
        elseif ($Global:StatusBase -and $lblStatus) { $lblStatus.Text = ('{0}  ({1:mm\:ss})' -f $Global:StatusBase, $sw.Elapsed) }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 60
        if ($Global:Cancelar) { break }
        if ($sw.Elapsed.TotalSeconds -gt $t.Timeout) { $estourou = $true; break }
    }
    $res = $null; $erro = $null
    if ($h.IsCompleted) {
        try { $out = $ps.EndInvoke($h); $res = @($out | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('Itens') }) | Select-Object -Last 1 }
        catch { $erro = $_.Exception.Message }
    }
    else { try { $ps.BeginStop($null, $null) | Out-Null } catch {} }
    if (-not $res) { $res = $Global:Sync.Atual }
    if ($res) { $res = $res.PSObject.BaseObject }
    if (-not $res) { $res = @{ Itens = New-Object System.Collections.ArrayList; Tabelas = New-Object System.Collections.ArrayList; Achados = New-Object System.Collections.ArrayList; Metricas = @{}; Extra = @{} } }
    if ($estourou) { Add-Item $res 'Execução' "Tempo limite de $($t.Timeout) s excedido - resultados parciais" 'Atenção' }
    if ($Global:Cancelar) { Add-Item $res 'Execução' 'Cancelada pelo usuário - resultados parciais' 'Atenção' }
    if ($erro) { Add-Item $res 'Erro na execução' $erro 'Erro'; if (-not $res.Itens.Count -or $res.Itens.Count -le 1) { $res.Erro = $true } }
    Update-Log
    if ($h.IsCompleted) { try { $ps.Dispose(); $rs.Close(); $rs.Dispose() } catch {} }
    return $res
}

function Get-CorBadge([string]$s) {
    switch ($s) { 'Crítico' { [Drawing.Color]::FromArgb(198, 40, 40) } 'Alto' { [Drawing.Color]::FromArgb(230, 81, 0) } 'Médio' { [Drawing.Color]::FromArgb(249, 168, 37) } 'Baixo' { [Drawing.Color]::FromArgb(120, 144, 156) } 'OK' { [Drawing.Color]::FromArgb(46, 125, 50) } 'Atenção' { [Drawing.Color]::FromArgb(249, 168, 37) } default { [Drawing.Color]::FromArgb(144, 164, 174) } }
}
function Add-GridDados($parent, [int]$x, [int]$y, [int]$w, $rows, $corFn) {
    $g = New-GridBase; $g.Location = New-Object Drawing.Point($x, $y); $g.Width = $w
    $cols = @($rows[0].PSObject.Properties.Name)
    foreach ($c in $cols) { [void]$g.Columns.Add(('c' + [guid]::NewGuid().ToString('N')), [string]$c) }
    foreach ($row in @($rows)) {
        $vals = foreach ($c in $cols) { $z = [string]$row.$c; if ($z.Length -gt 300) { $z = $z.Substring(0, 297) + '...' }; $z }
        $idx = $g.Rows.Add([object[]]$vals)
        if ($corFn) { $cor = & $corFn $row; if ($cor) { $g.Rows[$idx].DefaultCellStyle.BackColor = $cor } }
    }
    $parent.Controls.Add($g)
    return $g
}
function New-GridBase {
    $g = New-Object Windows.Forms.DataGridView
    $g.ReadOnly = $true; $g.AllowUserToAddRows = $false; $g.AllowUserToResizeRows = $false; $g.RowHeadersVisible = $false
    $g.BackgroundColor = [Drawing.Color]::White; $g.BorderStyle = 'FixedSingle'; $g.ScrollBars = 'None'
    $g.AutoSizeRowsMode = 'AllCells'; $g.AutoSizeColumnsMode = 'Fill'; $g.SelectionMode = 'FullRowSelect'
    $g.ColumnHeadersHeightSizeMode = 'DisableResizing'; $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI', 8.5, [Drawing.FontStyle]::Bold)
    $g.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(18, 52, 86); $g.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::White
    $g.DefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI', 8.5); $g.DefaultCellStyle.WrapMode = 'True'
    $g.AlternatingRowsDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(240, 244, 248)
    return $g
}
function Set-GridHeight($g, [int]$maxH = 560) {
    try { $g.PerformLayout() } catch {}
    $h = $g.ColumnHeadersHeight + 3
    foreach ($row in $g.Rows) { $h += $row.Height }
    if ($h -gt $maxH) { $g.ScrollBars = 'Vertical'; $h = $maxH }
    $g.Height = [math]::Max(40, $h)
}
function Add-Titulo($parent, [int]$x, [int]$y, [int]$w, [string]$t) {
    $l = New-Object Windows.Forms.Label; $l.AutoSize = $false; $l.Width = $w - $x; $l.Height = 20; $l.Location = New-Object Drawing.Point($x, $y)
    $l.Text = $t; $l.Font = New-Object Drawing.Font('Segoe UI', 9.5, [Drawing.FontStyle]::Bold); $l.ForeColor = [Drawing.Color]::FromArgb(18, 52, 86)
    $parent.Controls.Add($l); return ($y + 23)
}
function Add-WrapLabel($parent, [int]$x, [int]$y, [int]$w, [string]$t, [single]$sz, $color) {
    $f = New-Object Drawing.Font('Segoe UI', $sz)
    $m = [System.Windows.Forms.TextRenderer]::MeasureText($t, $f, (New-Object Drawing.Size($w, 1)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
    $l = New-Object Windows.Forms.Label; $l.AutoSize = $false; $l.Width = $w; $l.Height = [math]::Max(15, $m.Height + 2); $l.Location = New-Object Drawing.Point($x, $y)
    $l.Text = $t; $l.Font = $f; if ($color) { $l.ForeColor = $color }
    $parent.Controls.Add($l); return ($y + $l.Height)
}
function Add-AchadoUI($parent, [int]$x, [int]$y, [int]$w, $a) {
    $txt = ("[{0} - {1}] {2}`r`n→ {3}" -f $a.Severidade, $a.Categoria, $a.Achado, $a.Recomendacao)
    $f = New-Object Drawing.Font('Segoe UI', 8.5); $innerW = $w - $x - 16
    $m = [System.Windows.Forms.TextRenderer]::MeasureText($txt, $f, (New-Object Drawing.Size($innerW, 1)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
    $pnl = New-Object Windows.Forms.Panel; $pnl.Location = New-Object Drawing.Point($x, $y); $pnl.Width = $w - $x; $pnl.Height = [math]::Max(28, $m.Height + 10); $pnl.BackColor = Get-CorSituacao $a.Severidade
    $bar = New-Object Windows.Forms.Panel; $bar.Location = New-Object Drawing.Point(0, 0); $bar.Width = 5; $bar.Height = $pnl.Height; $bar.BackColor = Get-CorBadge $a.Severidade; $bar.Dock = 'Left'
    $l = New-Object Windows.Forms.Label; $l.AutoSize = $false; $l.Location = New-Object Drawing.Point(11, 4); $l.Width = $innerW; $l.Height = $m.Height + 2; $l.Text = $txt; $l.Font = $f
    $pnl.Controls.Add($l); $pnl.Controls.Add($bar); $parent.Controls.Add($pnl)
    return ($y + $pnl.Height)
}
function Get-TabTeste([string]$id, [string]$nome) {
    if ($Global:TabMap.ContainsKey($id)) { return $Global:TabMap[$id] }
    $tp = New-Object Windows.Forms.TabPage; $tp.Text = $nome; $tp.BackColor = [Drawing.Color]::White; $tp.Tag = $id
    $hostp = New-Object Windows.Forms.Panel; $hostp.Dock = 'Fill'; $hostp.AutoScroll = $true; $hostp.BackColor = [Drawing.Color]::White
    $content = New-Object Windows.Forms.Panel; $content.Location = New-Object Drawing.Point(0, 0); $content.BackColor = [Drawing.Color]::White; $content.Width = 10; $content.Height = 10
    $hostp.Controls.Add($content); $tp.Controls.Add($hostp); [void]$tabs.TabPages.Add($tp)
    $o = @{ Page = $tp; Host = $hostp; Content = $content }; $Global:TabMap[$id] = $o; return $o
}
function Fill-TabTeste([string]$id) {
    if (-not $Global:Resultados.Contains($id)) { return }
    $r = $Global:Resultados[$id]; $o = Get-TabTeste $id $r.Nome
    $content = $o.Content; $content.SuspendLayout(); $content.Controls.Clear()
  try {
    $W = [math]::Max(700, $o.Host.ClientSize.Width - 26); $y = 8
    $hd = New-Object Windows.Forms.Label; $hd.AutoSize = $false; $hd.Width = $W; $hd.Height = 30; $hd.Location = New-Object Drawing.Point(8, $y)
    $hd.Font = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold); $hd.Text = ("{0}    [ {1} ]" -f $r.Nome, $r.Situacao); $hd.BackColor = Get-CorSituacao $r.Situacao; $hd.TextAlign = 'MiddleLeft'
    $content.Controls.Add($hd); $y += 36
    if ($r.Desc) { $y = (Add-WrapLabel $content 8 $y ($W) ("Escopo: " + $r.Desc) 8 ([Drawing.Color]::DimGray)) + 6 }
    if ($r.Itens.Count) {
        $y = Add-Titulo $content 8 $y $W 'Verificações'
        $linhasItens = @($r.Itens | ForEach-Object { [pscustomobject]@{ 'Verificação' = $_.Item; 'Resultado' = $_.Valor; 'Situação' = $_.Status } })
        $g = Add-GridDados $content 8 $y $W $linhasItens { param($row) Get-CorSituacao ([string]$row.'Situação') }
        if ($g.Columns.Count -ge 3) { $g.Columns[0].FillWeight = 32; $g.Columns[1].FillWeight = 54; $g.Columns[2].FillWeight = 14 }
        Set-GridHeight $g; $y += $g.Height + 12
    }
    $achs = @($r.Achados | Sort-Object @{e = { Get-RankSev $_.Severidade } })
    if ($achs.Count) {
        $y = Add-Titulo $content 8 $y $W 'Pontos encontrados'
        foreach ($a in $achs) { $y = (Add-AchadoUI $content 8 $y $W $a) + 6 }
        $y += 4
    }
    foreach ($tb in $r.Tabelas) {
        $rows = @($tb.Linhas); if (-not $rows.Count) { continue }
        $y = Add-Titulo $content 8 $y $W ("{0}  ({1} registro(s))" -f $tb.Titulo, $rows.Count)
        $g = Add-GridDados $content 8 $y $W (@($rows | Select-Object -First 100)) $null
        Set-GridHeight $g; $y += $g.Height + 6
        if ($rows.Count -gt 100) { $y = (Add-WrapLabel $content 8 $y $W ("... e mais {0} registro(s) no relatório PDF." -f ($rows.Count - 100)) 8 ([Drawing.Color]::DimGray)) + 6 }
        $y += 6
    }
    $content.Width = $W + 16; $content.Height = $y + 8
  }
  catch {
    $le = New-Object Windows.Forms.Label; $le.AutoSize = $true; $le.Location = New-Object Drawing.Point(8, 8); $le.ForeColor = [Drawing.Color]::Firebrick
    $le.Text = "Falha ao montar a aba: $($_.Exception.Message)"; $content.Controls.Add($le); $content.Width = 700; $content.Height = 60
    try { Add-Content -Path (Join-Path $env:TEMP 'AuditorTI_erro.log') -Value ("[{0}] aba {1}: {2}" -f (Get-Date), $id, $_.Exception.Message) } catch {}
  }
  finally { $content.ResumeLayout() }
}
function Show-Resultado([string]$id) {
    if (-not $Global:Resultados.Contains($id)) { return }
    $r = $Global:Resultados[$id]; $o = Get-TabTeste $id $r.Nome
    $tabs.SelectedTab = $o.Page; [System.Windows.Forms.Application]::DoEvents()
    Fill-TabTeste $id
}

function Get-Print([object]$ctl = $null, [int]$maxH = 1500) {
    if (-not $ctl) { $ctl = $form }
    $form.Refresh(); [System.Windows.Forms.Application]::DoEvents()
    $w = [math]::Max(50, [int]$ctl.Width); $h = [math]::Max(50, [math]::Min([int]$ctl.Height, $maxH))
    $bmp = New-Object Drawing.Bitmap $w, $h
    $ctl.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0, 0, $w, $h))
    $ms = New-Object IO.MemoryStream
    $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    $ep = New-Object Drawing.Imaging.EncoderParameters 1
    $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), ([long]80)
    $bmp.Save($ms, $enc, $ep); $bmp.Dispose()
    return , $ms.ToArray()
}

function Invoke-TesteSom($res) {
    try {
        $sr = 44100; $n = [int]($sr * 1.6)
        $ms = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter $ms
        $bw.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $bw.Write([int](36 + $n * 2)); $bw.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
        $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1); $bw.Write([int]$sr); $bw.Write([int]($sr * 2)); $bw.Write([int16]2); $bw.Write([int16]16)
        $bw.Write([Text.Encoding]::ASCII.GetBytes('data')); $bw.Write([int]($n * 2))
        $dois = 2 * [math]::PI
        for ($i = 0; $i -lt $n; $i++) { $f = if ($i -lt $n / 2) { 660 } else { 880 }; $bw.Write([int16](11000 * [math]::Sin($dois * $f * $i / $sr))) }
        $bw.Flush(); $ms.Position = 0
        Write-LogUI 'Reproduzindo tom de teste nos alto-falantes...'
        $pl = New-Object Media.SoundPlayer $ms; $pl.PlaySync()
        $r = [System.Windows.Forms.MessageBox]::Show($form, 'Um tom de teste (dois bipes) foi reproduzido nos alto-falantes/fones.' + [Environment]::NewLine + [Environment]::NewLine + 'O som foi ouvido corretamente?', 'Teste de áudio', 'YesNo', 'Question')
        if ($r -eq 'Yes') { Add-Item $res 'Teste de reprodução de som' 'Tom ouvido e confirmado pelo técnico' 'OK' }
        else {
            Add-Item $res 'Teste de reprodução de som' 'Tom NÃO foi ouvido pelo técnico' 'Crítico'
            Add-Achado $res 'Desempenho' 'Médio' 'O tom de teste não foi ouvido na saída de áudio padrão.' 'Verificar volume/mudo, dispositivo de saída padrão, cabos/alto-falantes e driver de áudio.' 0.5
        }
    } catch { Add-Item $res 'Teste de reprodução de som' "Falha ao reproduzir: $($_.Exception.Message)" 'Atenção' }
}

function Invoke-RevisaoServicos($res) {
    $cands = @($res.Extra.Candidatos)
    if (-not $cands.Count) { return }
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Serviços não essenciais encontrados'; $dlg.Size = New-Object Drawing.Size(980, 560)
    $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = New-Object Drawing.Font('Segoe UI', 9)
    $lb = New-Object Windows.Forms.Label
    $lb.Text = "Os serviços abaixo NÃO são essenciais para o funcionamento do Windows. Marque os que deseja DESATIVAR.`r`n'Recomendado' = pode ser desativado com segurança.  'Avaliar' = desative somente se o cliente não usa o recurso.`r`nNada será alterado sem a sua confirmação. O estado original será salvo e um script para desfazer será gerado."
    $lb.Location = New-Object Drawing.Point(12, 10); $lb.Size = New-Object Drawing.Size(940, 52)
    $lvS = New-Object Windows.Forms.ListView
    $lvS.View = 'Details'; $lvS.CheckBoxes = $true; $lvS.FullRowSelect = $true; $lvS.GridLines = $true
    $lvS.Location = New-Object Drawing.Point(12, 66); $lvS.Size = New-Object Drawing.Size(940, 400)
    foreach ($c in @(@('Serviço', 130), @('Nome', 230), @('Estado', 85), @('Início', 75), @('Classificação', 95), @('Motivo', 300))) { [void]$lvS.Columns.Add($c[0], $c[1]) }
    foreach ($c in $cands) {
        $it = New-Object Windows.Forms.ListViewItem([string]$c.'Serviço')
        foreach ($v in @($c.Nome, $c.Estado, $c.'Inicialização', $c.'Classificação', $c.Motivo)) { [void]$it.SubItems.Add([string]$v) }
        $it.Checked = ($c.'Classificação' -eq 'Recomendado')
        if ($c.'Classificação' -eq 'Avaliar') { $it.BackColor = [Drawing.Color]::FromArgb(255, 248, 225) }
        [void]$lvS.Items.Add($it)
    }
    $bOk = New-Object Windows.Forms.Button; $bOk.Text = 'Desativar selecionados'; $bOk.Size = New-Object Drawing.Size(180, 32); $bOk.Location = New-Object Drawing.Point(592, 478); $bOk.DialogResult = 'OK'
    $bNo = New-Object Windows.Forms.Button; $bNo.Text = 'Não alterar nada'; $bNo.Size = New-Object Drawing.Size(170, 32); $bNo.Location = New-Object Drawing.Point(782, 478); $bNo.DialogResult = 'Cancel'
    $dlg.Controls.AddRange(@($lb, $lvS, $bOk, $bNo)); $dlg.AcceptButton = $bOk; $dlg.CancelButton = $bNo
    if ($dlg.ShowDialog($form) -ne 'OK') { Write-LogUI 'Revisão de serviços: nenhuma alteração realizada.'; Add-Item $res 'Desativação de serviços' 'Nenhuma alteração (decisão do técnico)' 'Info'; return }
    $sel = @($lvS.CheckedItems | ForEach-Object { $_.Text })
    if (-not $sel.Count) { Add-Item $res 'Desativação de serviços' 'Nenhum serviço selecionado' 'Info'; return }
    $msg = "Confirma a DESATIVAÇÃO de {0} serviço(s)?`r`n`r`n{1}`r`n`r`nO estado original será registrado no relatório e em desfazer_alteracoes.ps1." -f $sel.Count, ($sel -join ', ')
    if ([System.Windows.Forms.MessageBox]::Show($form, $msg, 'Confirmar alteração', 'YesNo', 'Warning') -ne 'Yes') { Add-Item $res 'Desativação de serviços' 'Cancelada pelo técnico' 'Info'; return }
    $ok = 0
    foreach ($n in $sel) {
        $o = Get-CimInstance Win32_Service -Filter "Name='$n'"
        $resultado = 'Sucesso'
        Write-LogUI "Desativando serviço $n..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            if ($o.State -eq 'Running') { Stop-Service -Name $n -Force -ErrorAction Stop }
        } catch { $resultado = "Sucesso (não parou agora: $($_.Exception.Message))" }
        try { Set-Service -Name $n -StartupType Disabled -ErrorAction Stop; $ok++ }
        catch { $resultado = "Falha: $($_.Exception.Message)" }
        $modo = switch ($o.StartMode) { 'Auto' { if ($o.DelayedAutoStart) { 'delayed-auto' } else { 'auto' } } 'Manual' { 'demand' } 'Disabled' { 'disabled' } default { 'demand' } }
        $undo = "sc.exe config `"$n`" start= $modo | Out-Null" + $(if ($o.State -eq 'Running') { "; Start-Service -Name '$n' -ErrorAction SilentlyContinue" } else { '' })
        [void]$Global:Acoes.Add([pscustomobject]@{
            'Data' = Get-Date; 'Ação' = 'Serviço desativado'; 'Item' = "$n ($($o.DisplayName))"
            'Estado anterior' = ("{0} / {1}{2}" -f $o.State, $o.StartMode, $(if ($o.DelayedAutoStart) { ' (atrasado)' } else { '' }))
            'Resultado' = $resultado; 'Desfazer' = $(if ($resultado -like 'Sucesso*') { $undo } else { '' })
        })
        Write-LogUI "  -> $resultado"
    }
    Add-Item $res 'Serviços desativados nesta auditoria' ("{0} de {1}: {2}" -f $ok, $sel.Count, ($sel -join ', ')) 'OK'
}

# ---------------------------------------------------------------------
# Configuração persistente (técnico, margens e papel timbrado)
# ---------------------------------------------------------------------
function Save-Config {
    try {
        New-Item -ItemType Directory -Path $Global:CfgDir -Force | Out-Null
        @{ Tecnico = $txtTecnico.Text; Timbrado = $Global:Timbrado; Topo = [int]$nudTopo.Value; Base = [int]$nudBase.Value; Lado = [int]$nudLado.Value
           Disco = $chkDisco.Checked; Leitura = $chkLeitura.Checked; Memoria = $chkMemoria.Checked; Captura = $chkCaptura.Checked; WU = $chkWU.Checked; Winget = $chkWinget.Checked; Som = $chkSom.Checked } | ConvertTo-Json | Set-Content -Path $Global:CfgArq -Encoding UTF8
    } catch {}
}

function Set-Timbrado([string]$origem) {
    New-Item -ItemType Directory -Path $Global:CfgDir -Force | Out-Null
    $ext = [IO.Path]::GetExtension($origem).ToLower()
    Get-ChildItem $Global:CfgDir -Filter 'timbrado.*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    if ($ext -eq '.pdf') {
        $dest = Join-Path $Global:CfgDir 'timbrado.png'
        if (-not (Convert-PdfParaPng $origem $dest)) {
            [System.Windows.Forms.MessageBox]::Show($form, 'Não foi possível converter o PDF. Exporte o papel timbrado como imagem PNG ou JPG (tamanho A4) e selecione novamente.', 'Papel timbrado', 'OK', 'Warning') | Out-Null
            return
        }
    }
    else { $dest = Join-Path $Global:CfgDir ("timbrado" + $ext); Copy-Item $origem $dest -Force }
    $Global:Timbrado = $dest
    $lblTimbrado.Text = [IO.Path]::GetFileName($origem)
    Save-Config
}


# =====================================================================
#  AÇÕES: OTIMIZAÇÃO (WinUtil Standard), SOLUCIONAR PROBLEMAS E ATIVAÇÃO
# =====================================================================

# ---------------------------------------------------------------------
# Otimização - mesmos ajustes do preset "Standard" da aba Tweaks do
# Chris Titus Tech WinUtil (https://github.com/ChrisTitusTech/winutil,
# licença MIT, arquivo config/tweaks.json). Cada alteração guarda o valor
# anterior e entra no script desfazer_alteracoes.ps1.
# ---------------------------------------------------------------------
$Global:TweaksPadrao = @(
    @{ Id = 'restauracao'; Nome = 'Ponto de restauração - criar'; Desc = 'Cria um ponto de restauração antes das alterações.' }
    @{ Id = 'atividade'; Nome = 'Histórico de atividades - desativar'; Desc = 'Políticas EnableActivityFeed / PublishUserActivities / UploadUserActivities.' }
    @{ Id = 'consumidor'; Nome = 'ConsumerFeatures - desativar'; Desc = 'Impede a instalação automática de apps sugeridos (Candy Crush etc.).' }
    @{ Id = 'descoberta'; Nome = 'Descoberta automática de pastas do Explorer - desativar'; Desc = 'Limpa o cache de visualização de pastas e usa visualização genérica (não reversível; só aparência).' }
    @{ Id = 'wpbt'; Nome = 'Windows Platform Binary Table (WPBT) - desativar'; Desc = 'Impede que o firmware instale programas no Windows.' }
    @{ Id = 'localizacao'; Nome = 'Rastreamento de localização - desativar'; Desc = 'Desativa o serviço lfsvc, o acesso à localização e a atualização automática de mapas.' }
    @{ Id = 'servicos'; Nome = 'Serviços - definir como manual'; Desc = 'CscService e DiagTrack desativados; MapsBroker e StorSvc manuais; SharedAccess (ICS/hotspot) desativado.' }
    @{ Id = 'telemetria'; Nome = 'Telemetria - desativar'; Desc = 'Telemetria, publicidade, coleta de digitação/escrita, relatório de erros e envio de amostras do Defender.' }
    @{ Id = 'entrega'; Nome = 'Otimização de Entrega - desativar'; Desc = 'Impede o compartilhamento de atualizações com outros PCs (DODownloadMode=0).' }
    @{ Id = 'limpeza'; Nome = 'Limpeza de disco - executar'; Desc = 'cleanmgr /VERYLOWDISK e DISM /StartComponentCleanup /ResetBase (demorado; remove a opção de desinstalar atualizações antigas).' }
    @{ Id = 'temp'; Nome = 'Arquivos temporários - remover'; Desc = 'Apaga o conteúdo de %TEMP% e C:\Windows\Temp.' }
    @{ Id = 'fimtarefa'; Nome = 'Finalizar tarefa com botão direito - ativar'; Desc = 'Adiciona "Finalizar tarefa" ao clicar com o botão direito na barra de tarefas.' }
)

$Global:CodigoOtimizar = {
    $R = New-R
    $sel = @($Cfg.Selecao)
    Log 'Otimização do Windows - preset Standard (WinUtil)'
    if ($sel -contains 'restauracao') { Invoke-Etapa $R 'Ponto de restauração - criar' { New-PontoRestauracao $R 'AuditorTI - antes da otimizacao' } }
    if ($sel -contains 'atividade') {
        Invoke-Etapa $R 'Histórico de atividades - desativar' {
            $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
            Set-RegTweak $R $p 'EnableActivityFeed' 1
            Set-RegTweak $R $p 'PublishUserActivities' 0
            Set-RegTweak $R $p 'UploadUserActivities' 0
        }
    }
    if ($sel -contains 'consumidor') { Invoke-Etapa $R 'ConsumerFeatures - desativar' { Set-RegTweak $R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 } }
    if ($sel -contains 'descoberta') {
        Invoke-Etapa $R 'Descoberta automática de pastas - desativar' {
            $base = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell'
            foreach ($k in @("$base\Bags", "$base\BagMRU")) { if (Test-Path $k) { Remove-Item -Path $k -Recurse -Force -ErrorAction Stop } }
            $all = "$base\Bags\AllFolders\Shell"
            if (-not (Test-Path $all)) { New-Item -Path $all -Force | Out-Null }
            New-ItemProperty -Path $all -Name 'FolderType' -Value 'NotSpecified' -PropertyType String -Force | Out-Null
            Add-Acao $R 'Registro' "$all\FolderType = NotSpecified (cache de pastas limpo)" '-' 'Sucesso' "Remove-ItemProperty -LiteralPath '$all' -Name 'FolderType' -ErrorAction SilentlyContinue"
            'Concluído (vale após sair e entrar novamente na conta)'
        }
    }
    if ($sel -contains 'wpbt') { Invoke-Etapa $R 'WPBT - desativar' { Set-RegTweak $R 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1 } }
    if ($sel -contains 'localizacao') {
        Invoke-Etapa $R 'Rastreamento de localização - desativar' {
            Set-SvcTweak $R 'lfsvc' 'Disabled'
            Set-RegTweak $R 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'
            Set-RegTweak $R 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' 'SensorPermissionState' 0
            Set-RegTweak $R 'HKLM:\SYSTEM\Maps' 'AutoUpdateEnabled' 0
        }
    }
    if ($sel -contains 'servicos') {
        Invoke-Etapa $R 'Serviços - definir como manual' {
            Set-SvcTweak $R 'CscService' 'Disabled'
            Set-SvcTweak $R 'DiagTrack' 'Disabled'
            Set-SvcTweak $R 'MapsBroker' 'Manual'
            Set-SvcTweak $R 'StorSvc' 'Manual'
            Set-SvcTweak $R 'SharedAccess' 'Disabled'
        }
    }
    if ($sel -contains 'telemetria') {
        Invoke-Etapa $R 'Telemetria - desativar' {
            Set-SvcTweak $R 'DiagTrack' 'Disabled'
            Set-SvcTweak $R 'WerSvc' 'Disabled'
            Set-RegTweak $R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
            Set-RegTweak $R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
            Set-RegTweak $R 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0
            Set-RegTweak $R 'HKCU:\Software\Microsoft\Input\TIPC' 'Enabled' 0
            Set-RegTweak $R 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
            Set-RegTweak $R 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
            Set-RegTweak $R 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0
            Set-RegTweak $R 'HKCU:\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0
            Set-RegTweak $R 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
            Set-RegTweak $R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0
            Set-RegTweak $R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
            Set-RegTweak $R 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
            Set-RegTweak $R 'HKCU:\Software\Microsoft\Siuf\Rules' 'PeriodInNanoSeconds' '<RemoveEntry>' 'QWord'
            try {
                $antSS = (Get-MpPreference -ErrorAction Stop).SubmitSamplesConsent
                Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction Stop
                Add-Acao $R 'Defender' 'Envio automático de amostras = 2 (nunca enviar)' ([string]$antSS) 'Sucesso' "Set-MpPreference -SubmitSamplesConsent $([int]$antSS)"
            } catch { Add-Acao $R 'Defender' 'Envio automático de amostras = 2' '-' "Ignorado: $($_.Exception.Message)" }
            $antPs = [Environment]::GetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', 'Machine')
            [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')
            Add-Acao $R 'Variável de ambiente' 'POWERSHELL_TELEMETRY_OPTOUT = 1' $(if ($antPs) { $antPs } else { '(não existia)' }) 'Sucesso' $(if ($antPs) { "[Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '$antPs', 'Machine')" } else { "[Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', `$null, 'Machine')" })
        }
    }
    if ($sel -contains 'entrega') { Invoke-Etapa $R 'Otimização de Entrega - desativar' { Set-RegTweak $R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0 } }
    if ($sel -contains 'limpeza') {
        Invoke-Etapa $R 'Limpeza de disco (cleanmgr)' {
            $livre0 = (Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free
            [void](Invoke-Cmd "$env:windir\System32\cleanmgr.exe" "/d $($env:SystemDrive.TrimEnd(':')) /VERYLOWDISK" 900000)
            $ganho = ((Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free - $livre0) / 1GB
            Add-Acao $R 'Limpeza' 'cleanmgr /VERYLOWDISK' '-' 'Sucesso'
            'Concluído ({0:N2} GB liberados)' -f [math]::Max(0, $ganho)
        }
        Invoke-Etapa $R 'Limpeza de componentes do Windows (DISM /ResetBase)' {
            $o = Invoke-Cmd "$env:windir\System32\dism.exe" '/Online /Cleanup-Image /StartComponentCleanup /ResetBase' 3600000
            $cod = $global:UltimoCodigo
            Add-Acao $R 'Limpeza' 'DISM /StartComponentCleanup /ResetBase (não reversível)' '-' $(if ($cod -eq 0) { 'Sucesso' } else { "Código $cod" })
            if ($cod -eq 0) { 'Concluído' } else { "ATENÇÃO: código $cod - $(Get-Resumo $o 1)" }
        }
    }
    if ($sel -contains 'temp') {
        Invoke-Etapa $R 'Arquivos temporários - remover' {
            $tot = 0
            foreach ($p in @($env:TEMP, "$env:windir\Temp")) {
                $antes = [double](Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                Remove-Item -Path (Join-Path $p '*') -Recurse -Force -ErrorAction SilentlyContinue
                $dep = [double](Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                $tot += [math]::Max(0, $antes - $dep)
            }
            Add-Acao $R 'Limpeza' 'Arquivos temporários removidos' '-' ('Sucesso ({0:N2} GB)' -f ($tot / 1GB))
            'Concluído ({0:N2} GB liberados)' -f ($tot / 1GB)
        }
    }
    if ($sel -contains 'fimtarefa') { Invoke-Etapa $R 'Finalizar tarefa com botão direito - ativar' { Set-RegTweak $R 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 1 } }
    $R
}

# ---------------------------------------------------------------------
# Solucionar problemas: reparos gerais + correções dos achados da auditoria
# ---------------------------------------------------------------------
function Get-ListaCorrecoes {
    $ach = @(Get-TodosAchados)
    $tem = { param($rx) [bool](@($ach | Where-Object { $_.Achado -match $rx }).Count) }
    $semNet = $Global:Resultados.Contains('rede') -and ($Global:Resultados['rede'].Metricas.Internet -eq $false)
    $l = New-Object System.Collections.ArrayList
    $add = { param($id, $nome, $desc, $marc, $grupo) [void]$l.Add(@{ Id = $id; Nome = $nome; Desc = $desc; Marcado = [bool]$marc; Grupo = $grupo }) }
    & $add 'restauracao' 'Criar ponto de restauração' 'Permite voltar o sistema ao estado anterior aos reparos.' $true 'Segurança'
    # correções dos problemas encontrados (só aparecem se o problema existir)
    if (& $tem 'Firewall DESATIVADO') { & $add 'firewall' 'Ativar o Firewall do Windows' 'Ativa o firewall em todos os perfis desativados.' $true 'Problema encontrado' }
    if (& $tem 'tempo real do Microsoft Defender DESATIVADA') { & $add 'temporeal' 'Ativar proteção em tempo real do Defender' 'Set-MpPreference -DisableRealtimeMonitoring $false' $true 'Problema encontrado' }
    if (& $tem 'por política') { & $add 'politicas' 'Remover políticas que desativam Defender/Windows Update' 'Remove DisableAntiSpyware, DisableRealtimeMonitoring e NoAutoUpdate.' $true 'Problema encontrado' }
    if (& $tem 'serviço Windows Update está desativado') { & $add 'wuservico' 'Reativar o serviço Windows Update' 'Define o serviço wuauserv como Manual.' $true 'Problema encontrado' }
    if (& $tem 'SMBv1') { & $add 'smb1' 'Desativar o protocolo SMBv1' 'Protocolo antigo e vulnerável (WannaCry).' $true 'Problema encontrado' }
    if (& $tem 'Convidado') { & $add 'convidado' 'Desativar a conta Convidado' 'Disable-LocalUser na conta Guest.' $true 'Problema encontrado' }
    if (& $tem 'UAC') { & $add 'uac' 'Reativar o UAC' 'EnableLUA=1 e ConsentPromptBehaviorAdmin=5 (requer reinício).' $true 'Problema encontrado' }
    if (& $tem 'WDigest') { & $add 'wdigest' 'Desativar WDigest' 'Impede senhas em texto puro na memória.' $true 'Problema encontrado' }
    if (& $tem 'sem autenticação em nível de rede') { & $add 'rdpnla' 'Exigir NLA na Área de Trabalho Remota' 'UserAuthentication=1.' $true 'Problema encontrado' }
    if (& $tem 'AutoRun') { & $add 'autorun' 'Desativar AutoRun de mídias removíveis' 'NoDriveTypeAutoRun=255.' $true 'Problema encontrado' }
    if (& $tem 'SmartScreen desativado') { & $add 'smartscreen' 'Reativar o SmartScreen' 'SmartScreenEnabled=Warn.' $true 'Problema encontrado' }
    if (& $tem 'PUA') { & $add 'pua' 'Bloquear aplicativos potencialmente indesejados (PUA)' 'Set-MpPreference -PUAProtection Enabled' $true 'Problema encontrado' }
    if (& $tem 'Sem bloqueio de conta') { & $add 'bloqueio' 'Bloquear conta após 10 senhas erradas' 'net accounts /lockoutthreshold:10 /lockoutduration:15 /lockoutwindow:15' $true 'Problema encontrado' }
    if (& $tem 'Serviço de áudio') { & $add 'audio' 'Iniciar serviços de áudio' 'Audiosrv e AudioEndpointBuilder em Automático e iniciados.' $true 'Problema encontrado' }
    # reparos gerais do Windows
    & $add 'dism' 'DISM - reparar imagem do Windows (RestoreHealth)' 'DISM /Online /Cleanup-Image /RestoreHealth (10 a 30 min, usa internet).' $true 'Reparo do sistema'
    & $add 'sfc' 'SFC - verificar e reparar arquivos do sistema' 'sfc /scannow (5 a 20 min). Executado depois do DISM.' $true 'Reparo do sistema'
    & $add 'chkdsk' 'CHKDSK - verificar o disco (online)' "chkdsk $env:SystemDrive /scan - verifica sem reiniciar." $true 'Reparo do sistema'
    & $add 'chkdskboot' 'CHKDSK completo no próximo reinício' "Marca o disco $env:SystemDrive para reparo (chkdsk /f) ao reiniciar." (& $tem 'erro\(s\) de disco|erros? de leitura|SMART|COM FALHA|ALERTA') 'Reparo do sistema'
    & $add 'assinaturas' 'Atualizar definições do antivírus' 'Update-MpSignature.' $true 'Reparo do sistema'
    & $add 'wureset' 'Redefinir componentes do Windows Update' 'Para serviços, renomeia SoftwareDistribution e catroot2 e reinicia.' (& $tem 'falhas de instalação|Nenhuma atualização do Windows instalada') 'Atualizações'
    & $add 'wuinstalar' 'Instalar atualizações pendentes do Windows' 'Baixa e instala pelo Windows Update (pode demorar e pedir reinício).' (& $tem 'pendente') 'Atualizações'
    & $add 'winget' 'Atualizar todos os programas (winget)' 'winget upgrade --all. Programas abertos podem ser fechados.' $false 'Atualizações'
    & $add 'temp' 'Limpar arquivos temporários' '%TEMP% e C:\Windows\Temp.' $true 'Limpeza'
    & $add 'dns' 'Limpar cache de DNS' 'ipconfig /flushdns.' $true 'Rede'
    & $add 'rede' 'Redefinir pilha de rede (Winsock/TCP-IP)' 'netsh winsock reset e netsh int ip reset (requer reinício).' $semNet 'Rede'
    return , $l
}

$Global:CodigoCorrigir = {
    $R = New-R
    $sel = @($Cfg.Selecao)
    $drv = $env:SystemDrive
    Log 'Solucionar problemas - início'
    if ($sel -contains 'restauracao') { Invoke-Etapa $R 'Ponto de restauração' { New-PontoRestauracao $R 'AuditorTI - antes dos reparos' } }
    if ($sel -contains 'firewall') {
        Invoke-Etapa $R 'Ativar o Firewall do Windows' {
            foreach ($p in @(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { [string]$_.Enabled -notin @('True', '1') })) {
                Set-NetFirewallProfile -Name $p.Name -Enabled True -ErrorAction Stop
                Add-Acao $R 'Firewall' "Perfil $($p.Name) ativado" 'Desativado' 'Sucesso' "Set-NetFirewallProfile -Name '$($p.Name)' -Enabled False"
            }
        }
    }
    if ($sel -contains 'temporeal') {
        Invoke-Etapa $R 'Ativar proteção em tempo real' {
            Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
            Add-Acao $R 'Defender' 'Proteção em tempo real ativada' 'Desativada' 'Sucesso' 'Set-MpPreference -DisableRealtimeMonitoring $true'
        }
    }
    if ($sel -contains 'politicas') {
        Invoke-Etapa $R 'Remover políticas que desativam proteções' {
            Set-RegTweak $R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware' '<RemoveEntry>'
            Set-RegTweak $R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableRealtimeMonitoring' '<RemoveEntry>'
            Set-RegTweak $R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' '<RemoveEntry>'
        }
    }
    if ($sel -contains 'wuservico') { Invoke-Etapa $R 'Reativar o serviço Windows Update' { Set-SvcTweak $R 'wuauserv' 'Manual' } }
    if ($sel -contains 'smb1') {
        Invoke-Etapa $R 'Desativar SMBv1' {
            Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
            Add-Acao $R 'Rede' 'SMBv1 desativado' 'Ativado' 'Sucesso' 'Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force'
        }
    }
    if ($sel -contains 'convidado') {
        Invoke-Etapa $R 'Desativar conta Convidado' {
            foreach ($u in @(Get-LocalUser | Where-Object { [string]$_.SID -match '-501$' -and $_.Enabled })) {
                Disable-LocalUser -SID $u.SID -ErrorAction Stop
                Add-Acao $R 'Conta' "$($u.Name) desativada" 'Ativa' 'Sucesso' "Enable-LocalUser -SID '$($u.SID)'"
            }
        }
    }
    if ($sel -contains 'uac') {
        Invoke-Etapa $R 'Reativar o UAC' {
            $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            Set-RegTweak $R $p 'EnableLUA' 1
            if ((Get-RegVal $p 'ConsentPromptBehaviorAdmin') -eq 0) { Set-RegTweak $R $p 'ConsentPromptBehaviorAdmin' 5 }
            'Concluído (vale após reiniciar)'
        }
    }
    if ($sel -contains 'wdigest') { Invoke-Etapa $R 'Desativar WDigest' { Set-RegTweak $R 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential' 0 } }
    if ($sel -contains 'rdpnla') { Invoke-Etapa $R 'Exigir NLA no RDP' { Set-RegTweak $R 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 1 } }
    if ($sel -contains 'autorun') { Invoke-Etapa $R 'Desativar AutoRun' { Set-RegTweak $R 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255 } }
    if ($sel -contains 'smartscreen') {
        Invoke-Etapa $R 'Reativar SmartScreen' {
            Set-RegTweak $R 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'Warn' 'String'
            if ((Get-RegVal 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen') -eq 0) { Set-RegTweak $R 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' '<RemoveEntry>' }
        }
    }
    if ($sel -contains 'pua') {
        Invoke-Etapa $R 'Bloquear PUA no Defender' {
            Set-MpPreference -PUAProtection Enabled -ErrorAction Stop
            Add-Acao $R 'Defender' 'Proteção contra PUA ativada' 'Desativada' 'Sucesso' 'Set-MpPreference -PUAProtection Disabled'
        }
    }
    if ($sel -contains 'bloqueio') {
        Invoke-Etapa $R 'Bloqueio de conta após senhas erradas' {
            $o = Invoke-Cmd "$env:windir\System32\net.exe" 'accounts /lockoutthreshold:10 /lockoutduration:15 /lockoutwindow:15' 30000
            Add-Acao $R 'Política de senha' 'Bloqueio após 10 tentativas por 15 min' 'Sem bloqueio' $(if ($global:UltimoCodigo -eq 0) { 'Sucesso' } else { "Falha: $(Get-Resumo $o 1)" }) "& `"$env:windir\System32\net.exe`" accounts /lockoutthreshold:0"
            if ($global:UltimoCodigo -eq 0) { 'Concluído' } else { "Falha: $(Get-Resumo $o 1)" }
        }
    }
    if ($sel -contains 'audio') {
        Invoke-Etapa $R 'Iniciar serviços de áudio' {
            foreach ($n in @('AudioEndpointBuilder', 'Audiosrv')) { Set-SvcTweak $R $n 'Automatic'; Start-Service -Name $n -ErrorAction Stop }
        }
    }
    if ($sel -contains 'dism') {
        Invoke-Etapa $R 'DISM /RestoreHealth' {
            Log '   (pode levar de 10 a 30 minutos - aguarde)'
            $o = Invoke-Cmd "$env:windir\System32\dism.exe" '/Online /Cleanup-Image /RestoreHealth' 5400000
            $cod = $global:UltimoCodigo
            Add-Acao $R 'Reparo' 'DISM /Online /Cleanup-Image /RestoreHealth' '-' $(if ($cod -eq 0) { 'Sucesso' } else { "Código $cod" })
            if ($cod -eq 0) { "Concluído - $(Get-Resumo $o 1)" } else { "ATENÇÃO: código $cod - $(Get-Resumo $o 2)" }
        }
    }
    if ($sel -contains 'sfc') {
        Invoke-Etapa $R 'SFC /scannow' {
            Log '   (pode levar de 5 a 20 minutos - aguarde)'
            $o = Invoke-Cmd "$env:windir\System32\sfc.exe" '/scannow' 5400000
            $cod = $global:UltimoCodigo
            $cbs = ''
            if ($o -match '(?i)n(ã|a)o encontrou nenhuma viola|did not find any integrity') { $cbs = 'Nenhum problema encontrado' }
            elseif ($o -match '(?i)reparou|successfully repaired') { $cbs = 'Arquivos corrompidos foram REPARADOS' }
            elseif ($o -match '(?i)n(ã|a)o p(ô|o)de reparar|unable to fix') { $cbs = 'ATENÇÃO: arquivos corrompidos que NÃO puderam ser reparados (ver C:\Windows\Logs\CBS\CBS.log)' }
            else { $cbs = Get-Resumo $o 1 }
            Add-Acao $R 'Reparo' 'sfc /scannow' '-' $cbs
            $cbs
        }
    }
    if ($sel -contains 'chkdsk') {
        Invoke-Etapa $R "CHKDSK $drv /scan" {
            $o = Invoke-Cmd "$env:windir\System32\chkdsk.exe" "$drv /scan" 3600000
            $cod = $global:UltimoCodigo
            $txt = switch ($cod) { 0 { 'Nenhum erro encontrado' } 1 { 'Erros encontrados e corrigidos' } 2 { 'Limpeza realizada' } 3 { 'ATENÇÃO: erros encontrados que exigem chkdsk /f no reinício' } default { "Código $cod - $(Get-Resumo $o 1)" } }
            Add-Acao $R 'Reparo' "chkdsk $drv /scan" '-' $txt
            $txt
        }
    }
    if ($sel -contains 'chkdskboot') {
        Invoke-Etapa $R 'Agendar CHKDSK completo no reinício' {
            $o = Invoke-Cmd "$env:windir\System32\fsutil.exe" "dirty set $drv" 30000
            Add-Acao $R 'Reparo' "Disco $drv marcado para chkdsk /f no próximo reinício" '-' $(if ($global:UltimoCodigo -eq 0) { 'Sucesso' } else { "Falha: $(Get-Resumo $o 1)" })
            if ($global:UltimoCodigo -eq 0) { 'Agendado - reinicie o computador (a verificação pode demorar)' } else { "Falha: $(Get-Resumo $o 1)" }
        }
    }
    if ($sel -contains 'assinaturas') {
        Invoke-Etapa $R 'Atualizar definições do antivírus' {
            Update-MpSignature -ErrorAction Stop
            $mp = Get-MpComputerStatus
            Add-Acao $R 'Defender' 'Definições atualizadas' '-' ("Sucesso ({0})" -f $mp.AntivirusSignatureVersion)
            "Concluído - versão $($mp.AntivirusSignatureVersion)"
        }
    }
    if ($sel -contains 'wureset') {
        Invoke-Etapa $R 'Redefinir componentes do Windows Update' {
            $svcs = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
            foreach ($s in $svcs) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
            $ts = Get-Date -Format 'yyyyMMddHHmmss'
            foreach ($p in @("$env:windir\SoftwareDistribution", "$env:windir\System32\catroot2")) {
                if (Test-Path $p) { Rename-Item -Path $p -NewName ((Split-Path $p -Leaf) + ".bak_$ts") -ErrorAction Stop }
            }
            foreach ($s in $svcs) { Start-Service -Name $s -ErrorAction SilentlyContinue }
            Add-Acao $R 'Windows Update' "Componentes redefinidos (pastas antigas: *.bak_$ts)" '-' 'Sucesso'
        }
    }
    if ($sel -contains 'wuinstalar') {
        Invoke-Etapa $R 'Instalar atualizações pendentes do Windows' {
            $sess = New-Object -ComObject Microsoft.Update.Session
            Log '   procurando atualizações...'
            $busca = $sess.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
            if ($busca.Updates.Count -eq 0) { return 'Nenhuma atualização pendente' }
            $col = New-Object -ComObject Microsoft.Update.UpdateColl
            for ($i = 0; $i -lt $busca.Updates.Count; $i++) { $u = $busca.Updates.Item($i); if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$col.Add($u); Log "   - $($u.Title)" }
            Log "   baixando $($col.Count) atualização(ões)..."
            $d = $sess.CreateUpdateDownloader(); $d.Updates = $col; [void]$d.Download()
            Log '   instalando...'
            $ins = $sess.CreateUpdateInstaller(); $ins.Updates = $col; $r2 = $ins.Install()
            $ok = 0; for ($i = 0; $i -lt $col.Count; $i++) { if ($r2.GetUpdateResult($i).ResultCode -in 2, 3) { $ok++ } }
            Add-Acao $R 'Windows Update' "$ok de $($col.Count) atualização(ões) instaladas" '-' $(if ($r2.RebootRequired) { 'Sucesso - REINÍCIO NECESSÁRIO' } else { 'Sucesso' })
            "$ok de $($col.Count) instaladas$(if ($r2.RebootRequired) { ' - reinício necessário' })"
        }
    }
    if ($sel -contains 'winget') {
        Invoke-Etapa $R 'Atualizar programas (winget)' {
            $wg = (Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if (-not $wg) { $wg = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName }
            if (-not $wg) { return 'winget não disponível' }
            Log '   (pode demorar - cada programa é baixado e instalado)'
            $o = Invoke-Cmd $wg 'upgrade --all --silent --include-unknown --accept-package-agreements --accept-source-agreements --disable-interactivity' 3600000 -Utf8
            Add-Acao $R 'Programas' 'winget upgrade --all' '-' "Código $($global:UltimoCodigo)"
            "Concluído - $(Get-Resumo $o 1)"
        }
    }
    if ($sel -contains 'temp') {
        Invoke-Etapa $R 'Limpar arquivos temporários' {
            $tot = 0
            $pastas = @("$env:windir\Temp") + @(Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' })
            foreach ($p in $pastas) {
                if (-not (Test-Path $p)) { continue }
                $antes = [double](Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                Remove-Item -Path (Join-Path $p '*') -Recurse -Force -ErrorAction SilentlyContinue
                $dep = [double](Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                $tot += [math]::Max(0, $antes - $dep)
            }
            Add-Acao $R 'Limpeza' 'Arquivos temporários de todos os usuários' '-' ('Sucesso ({0:N2} GB)' -f ($tot / 1GB))
            'Concluído ({0:N2} GB liberados)' -f ($tot / 1GB)
        }
    }
    if ($sel -contains 'dns') {
        Invoke-Etapa $R 'Limpar cache de DNS' {
            Clear-DnsClientCache -ErrorAction Stop
            Add-Acao $R 'Rede' 'Cache de DNS limpo' '-' 'Sucesso'
        }
    }
    if ($sel -contains 'rede') {
        Invoke-Etapa $R 'Redefinir pilha de rede' {
            $o1 = Invoke-Cmd "$env:windir\System32\netsh.exe" 'winsock reset' 60000
            $o2 = Invoke-Cmd "$env:windir\System32\netsh.exe" 'int ip reset' 60000
            Add-Acao $R 'Rede' 'netsh winsock reset / int ip reset' '-' 'Sucesso - REINÍCIO NECESSÁRIO'
            'Concluído - reinicie o computador'
        }
    }
    Log 'Solucionar problemas - fim'
    $R
}

# ---------------------------------------------------------------------
# Ativação LEGÍTIMA do Windows (chave OEM gravada na placa-mãe ou chave
# de produto informada). Não contorna o licenciamento da Microsoft.
# ---------------------------------------------------------------------
$Global:CodigoAtivar = {
    $R = New-R
    $cs = "$env:windir\System32\cscript.exe"; $slmgr = "$env:windir\System32\slmgr.vbs"
    $stMap = @{ 0 = 'Não licenciado'; 1 = 'Ativado'; 2 = 'Período de carência'; 3 = 'Carência adicional'; 4 = 'Não original'; 5 = 'Notificação'; 6 = 'Carência estendida' }
    $ler = { Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1 }
    $antes = & $ler
    $stAntes = $stMap[[int]$antes.LicenseStatus]
    $chave = [string]$Cfg.Chave; $Cfg.Chave = $null
    $masc = ''
    if ($chave) {
        $masc = 'XXXXX-XXXXX-XXXXX-XXXXX-' + $chave.Substring($chave.Length - 5)
        Invoke-Etapa $R "Instalar chave de produto ($masc)" {
            $o = Invoke-Cmd $cs "//nologo `"$slmgr`" /ipk $chave" 120000
            $o = $o.Replace($chave, $masc)
            if ($global:UltimoCodigo -ne 0 -or $o -match '(?i)erro|error|0x8') { "Falha: $(Get-Resumo $o 1)" } else { 'Chave instalada' }
        }
    }
    Invoke-Etapa $R 'Ativar junto à Microsoft (slmgr /ato)' {
        $o = Invoke-Cmd $cs "//nologo `"$slmgr`" /ato" 180000
        if ($chave) { $o = $o.Replace($chave, $masc) }
        Get-Resumo $o 1
    }
    $dep = & $ler
    $stDep = $stMap[[int]$dep.LicenseStatus]
    Add-Item $R 'Situação da licença' "$stDep (antes: $stAntes) - $($dep.Name) - chave final $($dep.PartialProductKey)" $(if ($dep.LicenseStatus -eq 1) { 'OK' } else { 'Atenção' })
    Add-Acao $R 'Ativação do Windows' $(if ($masc) { "Chave $masc" } else { 'Nova tentativa de ativação' }) "$stAntes (chave final $($antes.PartialProductKey))" $stDep $(if ($masc -and $antes.PartialProductKey) { "# Para voltar à chave anterior, reinstale a chave terminada em $($antes.PartialProductKey) com: slmgr /ipk <chave>" } else { '' })
    $R
}

# ---------------------------------------------------------------------
# Execução de um lote de ações (sem interface)
# ---------------------------------------------------------------------
$Global:Lotes = New-Object System.Collections.ArrayList
function Invoke-LoteCore([string]$Titulo, $Codigo, [int]$Timeout, $Selecao) {
    $Global:Cfg.Selecao = @($Selecao)
    Write-LogUI "=== $Titulo ==="
    $ini = Get-Date
    $res = Invoke-Teste @{ Codigo = $Codigo; Timeout = $Timeout } $null
    foreach ($a in @($res.Extra.Acoes)) { if ($a) { [void]$Global:Acoes.Add($a) } }
    [void]$Global:Lotes.Add(@{ Titulo = $Titulo; Inicio = $ini; Fim = (Get-Date); Itens = @($res.Itens) })
    Write-LogUI "=== $Titulo concluído ==="
    return $res
}

# ---------------------------------------------------------------------
# Janelas das ações (otimizar, solucionar problemas, ativação)
# ---------------------------------------------------------------------
function Show-Itens($itens, [string]$titulo) {
    $dgv.Rows.Clear(); $lblGrid.Text = $titulo
    if ($Global:TabAcoes) { $tabs.SelectedTab = $Global:TabAcoes }
    foreach ($i in $itens) { $n = $dgv.Rows.Add($i.Item, $i.Valor, $i.Status); $dgv.Rows[$n].DefaultCellStyle.BackColor = Get-CorSituacao $i.Status }
}

# Lista com caixas de seleção. Devolve os Ids marcados ou $null se cancelar.
function Show-DialogoLista([string]$Titulo, [string]$Texto, $Itens, [string]$TextoOk) {
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = $Titulo; $dlg.Size = New-Object Drawing.Size(1000, 600)
    $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = New-Object Drawing.Font('Segoe UI', 9)
    $lb = New-Object Windows.Forms.Label; $lb.Text = $Texto; $lb.Location = New-Object Drawing.Point(12, 10); $lb.Size = New-Object Drawing.Size(960, 56)
    $lvL = New-Object Windows.Forms.ListView
    $lvL.View = 'Details'; $lvL.CheckBoxes = $true; $lvL.FullRowSelect = $true; $lvL.GridLines = $true
    $lvL.Location = New-Object Drawing.Point(12, 70); $lvL.Size = New-Object Drawing.Size(960, 432)
    [void]$lvL.Columns.Add('Ação', 340); [void]$lvL.Columns.Add('Grupo', 130); [void]$lvL.Columns.Add('Detalhe', 470)
    foreach ($i in $Itens) {
        $it = New-Object Windows.Forms.ListViewItem([string]$i.Nome)
        [void]$it.SubItems.Add([string]$i.Grupo); [void]$it.SubItems.Add([string]$i.Desc)
        $it.Checked = [bool]$i.Marcado; $it.Tag = $i.Id
        if ($i.Grupo -eq 'Problema encontrado') { $it.BackColor = [Drawing.Color]::FromArgb(253, 232, 222) }
        [void]$lvL.Items.Add($it)
    }
    $bT = New-Object Windows.Forms.Button; $bT.Text = 'Marcar todos'; $bT.Size = New-Object Drawing.Size(120, 32); $bT.Location = New-Object Drawing.Point(12, 514)
    $bT.Add_Click({ foreach ($x in $lvL.Items) { $x.Checked = $true } })
    $bN = New-Object Windows.Forms.Button; $bN.Text = 'Desmarcar todos'; $bN.Size = New-Object Drawing.Size(120, 32); $bN.Location = New-Object Drawing.Point(138, 514)
    $bN.Add_Click({ foreach ($x in $lvL.Items) { $x.Checked = $false } })
    $bOk = New-Object Windows.Forms.Button; $bOk.Text = $TextoOk; $bOk.Size = New-Object Drawing.Size(200, 32); $bOk.Location = New-Object Drawing.Point(632, 514); $bOk.DialogResult = 'OK'
    $bNo = New-Object Windows.Forms.Button; $bNo.Text = 'Cancelar'; $bNo.Size = New-Object Drawing.Size(130, 32); $bNo.Location = New-Object Drawing.Point(842, 514); $bNo.DialogResult = 'Cancel'
    $dlg.Controls.AddRange(@($lb, $lvL, $bT, $bN, $bOk, $bNo)); $dlg.CancelButton = $bNo
    if ($dlg.ShowDialog($form) -ne 'OK') { return $null }
    return , @($lvL.CheckedItems | ForEach-Object { [string]$_.Tag })
}

function Set-BotoesAcao([bool]$ativo) {
    foreach ($c in @($btnIniciar, $btnOtimizar, $btnAtivar, $clb, $grp, $txtCliente, $txtOS, $txtTecnico, $btnTimbrado)) { $c.Enabled = $ativo }
    $btnCorrigir.Enabled = $ativo -and ($Global:Resultados.Count -gt 0)
    $btnRel.Enabled = $ativo -and ($Global:Resultados.Count -gt 0)
}

# Executa um lote mostrando o andamento na janela
function Invoke-Lote([string]$Titulo, $Codigo, [int]$Timeout, $Selecao) {
    $Global:Rodando = $true; $Global:Cancelar = $false; $Global:Sync['Cancelar'] = $false
    Set-BotoesAcao $false
    $prog.Style = 'Marquee'
    $Global:StatusBase = "Executando: $Titulo"
    $lblStatus.Text = $Global:StatusBase
    try { $res = Invoke-LoteCore $Titulo $Codigo $Timeout $Selecao }
    finally {
        $Global:StatusBase = $null; $prog.Style = 'Blocks'
        $Global:Rodando = $false
        Set-BotoesAcao $true
    }
    Show-Itens $res.Itens "Resultado: $Titulo"
    $lblStatus.Text = "$Titulo - concluído."
    if ($Global:FecharApos) { $form.Close() }
    return $res
}

function Invoke-Otimizar {
    $itens = foreach ($t in $Global:TweaksPadrao) { @{ Id = $t.Id; Nome = $t.Nome; Desc = $t.Desc; Marcado = $true; Grupo = 'Standard' } }
    $txt = "Mesmos ajustes do modo STANDARD da aba Tweaks do WinUtil (Chris Titus Tech).`r`nO valor anterior de cada alteração é registrado no relatório e no script desfazer_alteracoes.ps1 (exceto limpezas, que não têm volta).`r`nAtenção: 'Serviços - definir como manual' desativa o Compartilhamento de Internet (hotspot do Windows)."
    $sel = Show-DialogoLista 'Otimizar Windows - preset Standard' $txt $itens 'Aplicar otimizações'
    if ($null -eq $sel -or -not @($sel).Count) { return }
    if ([System.Windows.Forms.MessageBox]::Show($form, "Aplicar $(@($sel).Count) otimização(ões) neste computador?", 'Confirmar', 'YesNo', 'Question') -ne 'Yes') { return }
    $res = Invoke-Lote 'Otimização do Windows (Standard)' $Global:CodigoOtimizar 7200 $sel
    $f = @($res.Itens | Where-Object { $_.Status -ne 'OK' }).Count
    [System.Windows.Forms.MessageBox]::Show($form, "Otimização concluída$(if ($f) { " com $f aviso(s) - veja a lista" }).`r`n`r`nReinicie o computador para aplicar todos os ajustes.`r`nAs alterações entram no relatório (gere o PDF novamente se já tinha gerado).", 'AuditorTI', 'OK', 'Information') | Out-Null
}

function Invoke-Corrigir {
    $itens = Get-ListaCorrecoes
    $nProb = @($itens | Where-Object { $_.Grupo -eq 'Problema encontrado' }).Count
    $txt = "Itens em vermelho corrigem problemas encontrados na auditoria ($nProb). Os demais são reparos gerais do Windows.`r`nDISM e SFC podem levar mais de 30 minutos no total. Não desligue o computador durante o processo.`r`nTudo é registrado no relatório; configurações alteradas entram no script desfazer_alteracoes.ps1."
    $sel = Show-DialogoLista 'Solucionar problemas encontrados' $txt $itens 'Iniciar reparos'
    if ($null -eq $sel -or -not @($sel).Count) { return }
    if ([System.Windows.Forms.MessageBox]::Show($form, "Executar $(@($sel).Count) ação(ões) de reparo agora?", 'Confirmar', 'YesNo', 'Question') -ne 'Yes') { return }
    $res = Invoke-Lote 'Solucionar problemas' $Global:CodigoCorrigir 10800 $sel
    $f = @($res.Itens | Where-Object { $_.Status -ne 'OK' }).Count
    $r = [System.Windows.Forms.MessageBox]::Show($form, "Reparos concluídos$(if ($f) { " ($f item(ns) com aviso - veja a lista)" }).`r`n`r`nRecomendado: reiniciar o computador e executar a auditoria novamente para comparar as notas.`r`n`r`nDeseja executar a auditoria novamente agora (sem reiniciar)?", 'AuditorTI', 'YesNo', 'Information')
    if ($r -eq 'Yes') { $Global:ManterAcoes = $true; $btnIniciar.PerformClick() }
}

function Show-Ativacao {
    $stMap = @{ 0 = 'Não licenciado'; 1 = 'Ativado'; 2 = 'Período de carência'; 3 = 'Carência adicional'; 4 = 'Não original'; 5 = 'Notificação'; 6 = 'Carência estendida' }
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1
    $svc = Get-CimInstance SoftwareLicensingService
    $oem = [string]$svc.OA3xOriginalProductKey
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Ativação do Windows (licença legítima)'; $dlg.Size = New-Object Drawing.Size(620, 360)
    $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.Font = New-Object Drawing.Font('Segoe UI', 9)
    $st = if ($lic) { $stMap[[int]$lic.LicenseStatus] } else { 'Desconhecido' }
    $info = "Edição: $($lic.Name)`r`nSituação: $st`r`nChave instalada (final): $($lic.PartialProductKey)`r`n`r`n" +
        $(if ($oem) { "Chave OEM gravada na placa-mãe: XXXXX-XXXXX-XXXXX-XXXXX-$($oem.Substring($oem.Length - 5))`r`n($($svc.OA3xOriginalProductKeyDescription))" } else { 'Nenhuma chave OEM gravada na placa-mãe.' }) +
        "`r`n`r`nO AuditorTI só ativa com licença válida: a chave original do equipamento ou uma chave comprada. Não é feita nenhuma ativação ilegal."
    $lb = New-Object Windows.Forms.Label; $lb.Text = $info; $lb.Location = New-Object Drawing.Point(14, 12); $lb.Size = New-Object Drawing.Size(580, 200)
    $b1 = New-Object Windows.Forms.Button; $b1.Text = 'Ativar com a chave da placa'; $b1.Size = New-Object Drawing.Size(190, 34); $b1.Location = New-Object Drawing.Point(14, 222); $b1.Enabled = [bool]$oem
    $b2 = New-Object Windows.Forms.Button; $b2.Text = 'Informar chave de produto...'; $b2.Size = New-Object Drawing.Size(190, 34); $b2.Location = New-Object Drawing.Point(210, 222)
    $b3 = New-Object Windows.Forms.Button; $b3.Text = 'Tentar ativar novamente'; $b3.Size = New-Object Drawing.Size(180, 34); $b3.Location = New-Object Drawing.Point(406, 222)
    $b4 = New-Object Windows.Forms.Button; $b4.Text = 'Fechar'; $b4.Size = New-Object Drawing.Size(110, 32); $b4.Location = New-Object Drawing.Point(476, 272); $b4.DialogResult = 'Cancel'
    $b1.Add_Click({ $dlg.Tag = 'oem'; $dlg.DialogResult = 'OK' })
    $b2.Add_Click({ $dlg.Tag = 'chave'; $dlg.DialogResult = 'OK' })
    $b3.Add_Click({ $dlg.Tag = 'ato'; $dlg.DialogResult = 'OK' })
    $dlg.Controls.AddRange(@($lb, $b1, $b2, $b3, $b4)); $dlg.CancelButton = $b4
    if ($dlg.ShowDialog($form) -ne 'OK') { return }
    $chave = ''
    switch ($dlg.Tag) {
        'oem' { $chave = $oem }
        'chave' {
            Add-Type -AssemblyName Microsoft.VisualBasic
            $chave = ([Microsoft.VisualBasic.Interaction]::InputBox('Digite a chave de produto do Windows (25 caracteres):', 'Chave de produto', '')).Trim().ToUpper()
            if (-not $chave) { return }
            if ($chave -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') { [System.Windows.Forms.MessageBox]::Show($form, 'Chave inválida. Use o formato XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.', 'Ativação', 'OK', 'Warning') | Out-Null; return }
        }
    }
    $Global:Cfg.Chave = $chave
    $res = Invoke-Lote 'Ativação do Windows' $Global:CodigoAtivar 600 @()
    $Global:Cfg.Chave = $null
    $sit = ($res.Itens | Where-Object { $_.Item -eq 'Situação da licença' } | Select-Object -First 1).Valor
    [System.Windows.Forms.MessageBox]::Show($form, "Resultado: $sit`r`n`r`nSe falhar, verifique a internet e se a chave corresponde à edição instalada (Home/Pro).", 'Ativação do Windows', 'OK', 'Information') | Out-Null
}

# ---------------------------------------------------------------------
# Modo sem interface (linha de comando / verificação automática)
#   AuditorTI.ps1 -SemInterface -Cliente "Nome" [-Timbrado arquivo.png] [-Saida pasta]
# ---------------------------------------------------------------------
if ($SemInterface) {
    $Global:Cfg.TesteDisco = $true; $Global:Cfg.LeituraCompleta = $false; $Global:Cfg.TesteMemoria = $true; $Global:Cfg.BuscarWU = $false; $Global:Cfg.Winget = $true; $Global:Cfg.TesteSom = $false
    $Global:Cfg.SO = $Global:SO; $Global:Cfg.CapturaRede = [bool]$Capturar; $Global:Cfg.CapSeg = 12
    if ($Saida) { $Global:PastaRelatorios = $Saida }
    $Global:Inicio = Get-Date
    $Global:IdAud = 'AUD-{0}-{1}' -f $Global:Inicio.ToString('yyyyMMdd-HHmm'), ([guid]::NewGuid().ToString('N').Substring(0, 4).ToUpper())
    $falhas = 0
    foreach ($t in $Global:Testes) {
        Write-LogUI "=== $($t.Nome) ==="
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $res = Invoke-Teste $t $null
        $sw.Stop()
        $res.Nome = $t.Nome; $res.Id = $t.Id; $res.Desc = $t.Desc; $res.Duracao = $sw.Elapsed.TotalSeconds; $res.Fim = Get-Date
        $res.Situacao = Get-Situacao $res
        if ($res.Situacao -eq 'Erro' -or @($res.Itens | Where-Object { $_.Status -eq 'Erro' }).Count) { $falhas++ }
        $Global:Resultados[$t.Id] = $res
        Write-LogUI ("Concluído: {0} -> {1} | {2} verificações, {3} achados, {4:N0} s" -f $t.Nome, $res.Situacao, $res.Itens.Count, $res.Achados.Count, $res.Duracao)
    }
    $Global:Fim = Get-Date
    $nt = Get-Notas
    Write-LogUI ("NOTAS -> Desempenho: {0} | Segurança: {1}" -f (Format-Nota $nt.Desempenho), (Format-Nota $nt.Seguranca))
    if ($Otimizar) {
        $ids = if ($Otimizar -eq 'todos') { @($Global:TweaksPadrao | ForEach-Object { $_.Id }) } else { @($Otimizar -split '[,; ]+' | Where-Object { $_ }) }
        $r1 = Invoke-LoteCore 'Otimização do Windows (Standard)' $Global:CodigoOtimizar 7200 $ids
        foreach ($i in $r1.Itens) { Write-LogUI ("  [{0}] {1}: {2}" -f $i.Status, $i.Item, $i.Valor) }
    }
    if ($Corrigir) {
        $ids = @($Corrigir -split '[,; ]+' | Where-Object { $_ })
        $r2 = Invoke-LoteCore 'Solucionar problemas' $Global:CodigoCorrigir 10800 $ids
        foreach ($i in $r2.Itens) { Write-LogUI ("  [{0}] {1}: {2}" -f $i.Status, $i.Item, $i.Valor) }
    }
    $tb = $null; if ($Timbrado -and (Test-Path $Timbrado)) { $tb = (Resolve-Path $Timbrado).Path }
    $rel = New-Relatorio @{ Cliente = $Cliente; Tecnico = $Tecnico; OS = ''; Timbrado = $tb; MargemTopo = 40; MargemBase = 28; MargemLado = 18 }
    Write-LogUI "Relatório: $($rel.Pasta)"
    Write-LogUI ("PDF gerado: {0}" -f $(if ($rel.Pdf) { $rel.Pdf } else { 'NÃO' }))
    if ($falhas -or -not $rel.Pdf) { exit 1 } else { exit 0 }
}

# ---------------------------------------------------------------------
# Janela principal
# ---------------------------------------------------------------------
$azul = [Drawing.Color]::FromArgb(18, 52, 86)
$fonte = New-Object Drawing.Font('Segoe UI', 9)
$form = New-Object Windows.Forms.Form
$form.Text = "AuditorTI $Global:VersaoApp - Auditoria técnica de estações Windows"
$form.Size = New-Object Drawing.Size(1200, 780); $form.MinimumSize = New-Object Drawing.Size(1050, 680)
$form.StartPosition = 'CenterScreen'; $form.Font = $fonte; $form.BackColor = [Drawing.Color]::White

function New-Ctl($tipo, $x, $y, $w, $h, $txt = '') { $c = New-Object "Windows.Forms.$tipo"; $c.Location = New-Object Drawing.Point($x, $y); $c.Size = New-Object Drawing.Size($w, $h); if ($txt) { $c.Text = $txt }; return $c }

# Cabeçalho
$pTopo = New-Object Windows.Forms.Panel; $pTopo.Dock = 'Top'; $pTopo.Height = 58; $pTopo.BackColor = $azul
$lT = New-Ctl Label 16 6 600 30 'AuditorTI'; $lT.ForeColor = 'White'; $lT.Font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
$modoTxt = if ($Global:Portatil) { 'Modo portátil (pendrive)' } else { 'Modo instalado' }
$lS = New-Ctl Label 18 35 1000 18 "Diagnóstico de desempenho e segurança  •  $env:COMPUTERNAME  •  $((Get-CimInstance Win32_OperatingSystem).Caption)  •  $modoTxt"; $lS.ForeColor = [Drawing.Color]::FromArgb(200, 220, 240)
$pTopo.Controls.AddRange(@($lT, $lS))

# Painel esquerdo
$pEsq = New-Object Windows.Forms.Panel; $pEsq.Dock = 'Left'; $pEsq.Width = 318; $pEsq.BackColor = [Drawing.Color]::FromArgb(244, 247, 250); $pEsq.AutoScroll = $true
$y = 10
$l1 = New-Ctl Label 12 $y 290 18 'Cliente / empresa *'; $txtCliente = New-Ctl TextBox 12 ($y + 18) 288 24; $y += 50
$l2 = New-Ctl Label 12 $y 290 18 'Técnico responsável'; $txtTecnico = New-Ctl TextBox 12 ($y + 18) 288 24; $y += 50
$l3 = New-Ctl Label 12 $y 290 18 'Nº da OS / chamado'; $txtOS = New-Ctl TextBox 12 ($y + 18) 288 24; $y += 52
$l4 = New-Ctl Label 12 $y 290 18 'Papel timbrado (PNG, JPG ou PDF - tamanho A4)'
$btnTimbrado = New-Ctl Button 12 ($y + 19) 100 26 'Selecionar...'
$lblTimbrado = New-Ctl Label 118 ($y + 24) 185 18 '(nenhum)'; $lblTimbrado.ForeColor = [Drawing.Color]::DimGray
$btnSemTimb = New-Ctl LinkLabel 12 ($y + 48) 200 18 'remover papel timbrado'; $y += 72
$l5 = New-Ctl Label 12 $y 300 18 'Margens do texto sobre o timbrado (mm):'
$lt1 = New-Ctl Label 12 ($y + 22) 40 18 'Topo'; $nudTopo = New-Ctl NumericUpDown 50 ($y + 19) 48 24
$lt2 = New-Ctl Label 104 ($y + 22) 50 18 'Rodapé'; $nudBase = New-Ctl NumericUpDown 154 ($y + 19) 48 24
$lt3 = New-Ctl Label 208 ($y + 22) 46 18 'Lados'; $nudLado = New-Ctl NumericUpDown 252 ($y + 19) 48 24
foreach ($nu in @($nudTopo, $nudBase, $nudLado)) { $nu.Minimum = 5; $nu.Maximum = 120 }
$nudTopo.Value = 40; $nudBase.Value = 28; $nudLado.Value = 18; $y += 54
$grp = New-Ctl GroupBox 12 $y 290 188 'Opções'
$chkDisco = New-Ctl CheckBox 10 20 275 20 'Teste de leitura dos discos (todos)'; $chkDisco.Checked = $true
$chkLeitura = New-Ctl CheckBox 24 42 262 18 'Leitura completa, setor por setor (lento!)'; $chkLeitura.Checked = $false; $chkLeitura.Font = New-Object Drawing.Font('Segoe UI', 8)
$chkMemoria = New-Ctl CheckBox 10 64 275 20 'Teste de integridade da RAM (~1 min)'; $chkMemoria.Checked = $true
$chkCaptura = New-Ctl CheckBox 10 87 275 20 'Captura de pacotes de rede (~1 min)'; $chkCaptura.Checked = $false
$chkWU = New-Ctl CheckBox 10 110 275 20 'Buscar atualizações pendentes do Windows'; $chkWU.Checked = $true
$chkWinget = New-Ctl CheckBox 10 133 275 20 'Atualizações de programas (winget)'; $chkWinget.Checked = $true
$chkSom = New-Ctl CheckBox 10 156 275 20 'Teste audível de som (tocar tom)'; $chkSom.Checked = $true
$chkDisco.Add_CheckedChanged({ $chkLeitura.Enabled = $chkDisco.Checked })
$grp.Controls.AddRange(@($chkDisco, $chkLeitura, $chkMemoria, $chkCaptura, $chkWU, $chkWinget, $chkSom)); $y += 196
$l6 = New-Ctl Label 12 $y 290 18 'Testes a executar'
$clb = New-Ctl CheckedListBox 12 ($y + 18) 288 150; $clb.CheckOnClick = $true; $clb.IntegralHeight = $false
foreach ($t in $Global:Testes) { $i = $clb.Items.Add($t.Nome); $clb.SetItemChecked($i, $true) }
$y += 176
$btnIniciar = New-Ctl Button 12 $y 288 40 'INICIAR AUDITORIA'
$btnIniciar.BackColor = [Drawing.Color]::FromArgb(30, 142, 62); $btnIniciar.ForeColor = 'White'; $btnIniciar.FlatStyle = 'Flat'; $btnIniciar.Font = New-Object Drawing.Font('Segoe UI', 10.5, [Drawing.FontStyle]::Bold)
$y += 46
$btnRel = New-Ctl Button 12 $y 141 32 'Gerar relatório PDF'; $btnRel.Enabled = $false
$btnPasta = New-Ctl Button 159 $y 141 32 'Abrir pasta'; $btnPasta.Enabled = $false
$pEsq.Controls.AddRange(@($l1, $txtCliente, $l2, $txtTecnico, $l3, $txtOS, $l4, $btnTimbrado, $lblTimbrado, $btnSemTimb, $l5, $lt1, $nudTopo, $lt2, $nudBase, $lt3, $nudLado, $grp, $l6, $clb, $btnIniciar, $btnRel, $btnPasta))

# Painel direito
$pDir = New-Object Windows.Forms.Panel; $pDir.Dock = 'Fill'; $pDir.Padding = New-Object Windows.Forms.Padding(10, 8, 10, 8)
$lblStatus = New-Object Windows.Forms.Label; $lblStatus.Dock = 'Top'; $lblStatus.Height = 26; $lblStatus.Font = New-Object Drawing.Font('Segoe UI', 10.5, [Drawing.FontStyle]::Bold); $lblStatus.ForeColor = $azul
$lblStatus.Text = 'Preencha os dados do cliente e clique em INICIAR AUDITORIA.'
$prog = New-Object Windows.Forms.ProgressBar; $prog.Dock = 'Top'; $prog.Height = 16
$esp1 = New-Object Windows.Forms.Panel; $esp1.Dock = 'Top'; $esp1.Height = 6
$lv = New-Object Windows.Forms.ListView; $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false
foreach ($c in @(@('Teste', 290), @('Situação', 110), @('Tempo', 60), @('Resumo', 380))) { [void]$lv.Columns.Add($c[0], $c[1]) }
$Global:LvMap = @{}
foreach ($t in $Global:Testes) {
    $it = New-Object Windows.Forms.ListViewItem($t.Nome); [void]$it.SubItems.Add('Aguardando'); [void]$it.SubItems.Add(''); [void]$it.SubItems.Add(''); $it.Tag = $t.Id
    [void]$lv.Items.Add($it); $Global:LvMap[$t.Id] = $it
}
$tabs = New-Object Windows.Forms.TabControl; $tabs.Dock = 'Fill'; $tabs.Font = New-Object Drawing.Font('Segoe UI', 9)
$Global:TabMap = @{}
$tabResumo = New-Object Windows.Forms.TabPage; $tabResumo.Text = 'Resumo'; $tabResumo.BackColor = [Drawing.Color]::White; $tabResumo.Padding = New-Object Windows.Forms.Padding(3)
$tabResumo.Controls.Add($lv)
[void]$tabs.TabPages.Add($tabResumo)
# Aba de manutenção (resultados de Otimizar / Solucionar problemas / Ativação)
$lblGrid = New-Object Windows.Forms.Label; $lblGrid.Dock = 'Top'; $lblGrid.Height = 22; $lblGrid.Text = 'Resultados das ações'; $lblGrid.TextAlign = 'BottomLeft'; $lblGrid.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$dgv = New-Object Windows.Forms.DataGridView; $dgv.Dock = 'Fill'; $dgv.ReadOnly = $true; $dgv.AllowUserToAddRows = $false; $dgv.AllowUserToDeleteRows = $false; $dgv.RowHeadersVisible = $false
$dgv.SelectionMode = 'FullRowSelect'; $dgv.BackgroundColor = [Drawing.Color]::White; $dgv.BorderStyle = 'FixedSingle'
$dgv.DefaultCellStyle.WrapMode = 'True'; $dgv.AutoSizeRowsMode = 'AllCells'; $dgv.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
[void]$dgv.Columns.Add('c1', 'Etapa'); [void]$dgv.Columns.Add('c2', 'Resultado'); [void]$dgv.Columns.Add('c3', 'Situação')
$dgv.Columns[0].Width = 280; $dgv.Columns[1].AutoSizeMode = 'Fill'; $dgv.Columns[2].Width = 90
$tabAcoes = New-Object Windows.Forms.TabPage; $tabAcoes.Text = 'Manutenção'; $tabAcoes.BackColor = [Drawing.Color]::White; $tabAcoes.Padding = New-Object Windows.Forms.Padding(3)
$tabAcoes.Controls.Add($dgv); $tabAcoes.Controls.Add($lblGrid)
[void]$tabs.TabPages.Add($tabAcoes)
$Global:TabAcoes = $tabAcoes
$txtLog = New-Object Windows.Forms.TextBox; $txtLog.Dock = 'Bottom'; $txtLog.Height = 120; $txtLog.Multiline = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.ReadOnly = $true
$txtLog.Font = New-Object Drawing.Font('Consolas', 8.5); $txtLog.BackColor = [Drawing.Color]::FromArgb(250, 250, 250)
$pAcoes = New-Object Windows.Forms.FlowLayoutPanel; $pAcoes.Dock = 'Top'; $pAcoes.Height = 44; $pAcoes.WrapContents = $false
$btnCorrigir = New-Object Windows.Forms.Button; $btnCorrigir.Text = 'Solucionar problemas'; $btnCorrigir.Size = New-Object Drawing.Size(190, 36); $btnCorrigir.Enabled = $false
$btnCorrigir.BackColor = [Drawing.Color]::FromArgb(230, 81, 0); $btnCorrigir.ForeColor = 'White'; $btnCorrigir.FlatStyle = 'Flat'; $btnCorrigir.Font = New-Object Drawing.Font('Segoe UI', 9.5, [Drawing.FontStyle]::Bold)
$btnOtimizar = New-Object Windows.Forms.Button; $btnOtimizar.Text = 'Otimizar Windows (Standard)'; $btnOtimizar.Size = New-Object Drawing.Size(210, 36)
$btnOtimizar.BackColor = [Drawing.Color]::FromArgb(18, 52, 86); $btnOtimizar.ForeColor = 'White'; $btnOtimizar.FlatStyle = 'Flat'; $btnOtimizar.Font = New-Object Drawing.Font('Segoe UI', 9.5, [Drawing.FontStyle]::Bold)
$btnAtivar = New-Object Windows.Forms.Button; $btnAtivar.Text = 'Ativação do Windows'; $btnAtivar.Size = New-Object Drawing.Size(170, 36); $btnAtivar.FlatStyle = 'Flat'
$pAcoes.Controls.AddRange(@($btnCorrigir, $btnOtimizar, $btnAtivar))
$pDir.Controls.Add($tabs); $pDir.Controls.Add($esp1); $pDir.Controls.Add($prog); $pDir.Controls.Add($lblStatus); $pDir.Controls.Add($pAcoes); $pDir.Controls.Add($txtLog)
$tabs.BringToFront()

$form.Controls.Add($pDir); $form.Controls.Add($pEsq); $form.Controls.Add($pTopo)

# Carrega configuração salva
if (Test-Path $Global:CfgArq) {
    try {
        $c = Get-Content $Global:CfgArq -Raw | ConvertFrom-Json
        if ($c.Tecnico) { $txtTecnico.Text = $c.Tecnico }
        if ($c.Timbrado -and (Test-Path $c.Timbrado)) { $Global:Timbrado = $c.Timbrado; $lblTimbrado.Text = 'salvo: ' + [IO.Path]::GetFileName($c.Timbrado) }
        if ($c.Topo) { $nudTopo.Value = [math]::Min(120, [math]::Max(5, [int]$c.Topo)) }
        if ($c.Base) { $nudBase.Value = [math]::Min(120, [math]::Max(5, [int]$c.Base)) }
        if ($c.Lado) { $nudLado.Value = [math]::Min(120, [math]::Max(5, [int]$c.Lado)) }
        if ($null -ne $c.Disco) { $chkDisco.Checked = [bool]$c.Disco; $chkWU.Checked = [bool]$c.WU; $chkWinget.Checked = [bool]$c.Winget; $chkSom.Checked = [bool]$c.Som }
        if ($null -ne $c.Memoria) { $chkMemoria.Checked = [bool]$c.Memoria }
        if ($null -ne $c.Leitura) { $chkLeitura.Checked = [bool]$c.Leitura }
        if ($null -ne $c.Captura) { $chkCaptura.Checked = [bool]$c.Captura }
        $chkLeitura.Enabled = $chkDisco.Checked
    } catch {}
}

# ---------------------------------------------------------------------
# Eventos
# ---------------------------------------------------------------------
$btnTimbrado.Add_Click({
    $ofd = New-Object Windows.Forms.OpenFileDialog
    $ofd.Title = 'Selecione o papel timbrado (A4)'
    $ofd.Filter = 'Papel timbrado (*.png;*.jpg;*.jpeg;*.pdf)|*.png;*.jpg;*.jpeg;*.pdf|Todos os arquivos|*.*'
    if ($ofd.ShowDialog($form) -eq 'OK') { Set-Timbrado $ofd.FileName }
})
$btnSemTimb.Add_LinkClicked({ $Global:Timbrado = $null; $lblTimbrado.Text = '(nenhum)'; Save-Config })

$lv.Add_SelectedIndexChanged({ if ($lv.SelectedItems.Count -and -not $Global:Rodando) { Show-Resultado ([string]$lv.SelectedItems[0].Tag) } })

$btnCorrigir.Add_Click({ Invoke-Corrigir })
$btnOtimizar.Add_Click({ Invoke-Otimizar })
$btnAtivar.Add_Click({ Show-Ativacao })

$btnPasta.Add_Click({ if ($Global:UltimaPasta -and (Test-Path $Global:UltimaPasta)) { Start-Process explorer.exe $Global:UltimaPasta } })

$btnRel.Add_Click({
    if (-not $Global:Resultados.Count) { return }
    $btnRel.Enabled = $false; $form.Cursor = 'WaitCursor'
    $lblStatus.Text = 'Gerando relatório e PDF...'; [System.Windows.Forms.Application]::DoEvents()
    try {
        $info = @{ Cliente = $txtCliente.Text.Trim(); Tecnico = $txtTecnico.Text.Trim(); OS = $txtOS.Text.Trim(); Timbrado = $Global:Timbrado; MargemTopo = $nudTopo.Value; MargemBase = $nudBase.Value; MargemLado = $nudLado.Value }
        $rel = New-Relatorio $info
        $Global:UltimaPasta = $rel.Pasta; $btnPasta.Enabled = $true
        Write-LogUI "Relatório gerado em: $($rel.Pasta)"
        if ($rel.Pdf) {
            $lblStatus.Text = 'Relatório PDF gerado com sucesso.'
            Start-Process $rel.Pdf
        }
        else {
            $lblStatus.Text = 'Relatório HTML gerado (PDF automático indisponível).'
            [System.Windows.Forms.MessageBox]::Show($form, "Não foi possível gerar o PDF automaticamente (Microsoft Edge/Chrome não encontrado).`r`n`r`nO relatório será aberto no navegador: use Ctrl+P > 'Salvar como PDF', com Margens = Nenhuma e 'Gráficos de plano de fundo' ativado.", 'Relatório', 'OK', 'Information') | Out-Null
            Start-Process $rel.Html
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, "Erro ao gerar o relatório: $($_.Exception.Message)", 'Relatório', 'OK', 'Error') | Out-Null
    } finally { $btnRel.Enabled = $true; $form.Cursor = 'Default' }
})

$btnIniciar.Add_Click({
    if (-not $txtCliente.Text.Trim()) { [System.Windows.Forms.MessageBox]::Show($form, 'Informe o nome do cliente/empresa.', 'AuditorTI', 'OK', 'Information') | Out-Null; $txtCliente.Focus(); return }
    $sel = @(); for ($i = 0; $i -lt $Global:Testes.Count; $i++) { if ($clb.GetItemChecked($i)) { $sel += $Global:Testes[$i] } }
    if (-not $sel.Count) { [System.Windows.Forms.MessageBox]::Show($form, 'Selecione ao menos um teste.', 'AuditorTI', 'OK', 'Information') | Out-Null; return }
    Save-Config
    if ($chkDisco.Checked -and $chkLeitura.Checked -and ($sel.Id -contains 'disco')) {
        $totGB = [math]::Round((@(Get-PhysicalDisk | Where-Object { [string]$_.BusType -ne '7' } | Measure-Object Size -Sum).Sum) / 1GB, 0)
        $horas = [math]::Round($totGB / 110 / 60, 1)
        $tDisco = $Global:Testes | Where-Object { $_.Id -eq 'disco' } | Select-Object -First 1
        if ($tDisco) { $tDisco.Timeout = [int][math]::Max(1800, $totGB / 110 * 60 * 3) }
        if ([System.Windows.Forms.MessageBox]::Show($form, "A leitura COMPLETA (setor por setor) de ~$totGB GB pode levar cerca de $horas hora(s). O computador pode ser usado durante o teste, mas ficará mais lento." + [Environment]::NewLine + [Environment]::NewLine + 'Deseja continuar com a leitura completa? (Não = leitura amostrada, rápida)', 'Leitura completa dos discos', 'YesNoCancel', 'Warning') -eq 'No') { $chkLeitura.Checked = $false }
    }
    $manter = [bool]$Global:ManterAcoes; $Global:ManterAcoes = $false
    if (-not $manter -and ($Global:Acoes.Count -or $Global:Lotes.Count)) {
        $manter = ([System.Windows.Forms.MessageBox]::Show($form, 'Há manutenções/alterações registradas nesta sessão.' + [Environment]::NewLine + 'Manter esse registro no relatório da nova auditoria? (Sim = mesmo cliente / Não = novo cliente)', 'AuditorTI', 'YesNo', 'Question') -eq 'Yes')
    }
    $Global:Rodando = $true; $Global:Cancelar = $false; $Global:Sync['Cancelar'] = $false
    Set-BotoesAcao $false; $btnPasta.Enabled = $false
    $Global:Cfg.TesteDisco = $chkDisco.Checked; $Global:Cfg.LeituraCompleta = ($chkDisco.Checked -and $chkLeitura.Checked); $Global:Cfg.TesteMemoria = $chkMemoria.Checked; $Global:Cfg.BuscarWU = $chkWU.Checked; $Global:Cfg.Winget = $chkWinget.Checked; $Global:Cfg.TesteSom = $chkSom.Checked
    $Global:Cfg.SO = $Global:SO; $Global:Cfg.CapturaRede = $chkCaptura.Checked; $Global:Cfg.CapSeg = 45
    $Global:Resultados.Clear(); $Global:Prints.Clear(); $txtLog.Clear(); $dgv.Rows.Clear()
    foreach ($tbId in @($Global:TabMap.Keys)) { try { [void]$tabs.TabPages.Remove($Global:TabMap[$tbId].Page) } catch {} }
    $Global:TabMap.Clear()
    if (-not $manter) { $Global:Acoes.Clear(); $Global:Lotes.Clear(); $Global:LogGeral.Clear() }
    foreach ($it in $lv.Items) { $it.SubItems[1].Text = $(if ($sel.Id -contains $it.Tag) { 'Aguardando' } else { 'Não executado' }); $it.SubItems[2].Text = ''; $it.SubItems[3].Text = ''; $it.BackColor = [Drawing.Color]::White }
    $Global:Inicio = Get-Date
    $Global:IdAud = 'AUD-{0}-{1}' -f $Global:Inicio.ToString('yyyyMMdd-HHmm'), ([guid]::NewGuid().ToString('N').Substring(0, 4).ToUpper())
    Write-LogUI "Auditoria $Global:IdAud iniciada - cliente: $($txtCliente.Text.Trim()) - técnico: $($txtTecnico.Text.Trim())"
    $prog.Minimum = 0; $prog.Maximum = $sel.Count; $prog.Value = 0
    $n = 0
    foreach ($t in $sel) {
        if ($Global:Cancelar) { break }
        $n++
        $it = $Global:LvMap[$t.Id]
        $it.SubItems[1].Text = 'Executando...'; $it.BackColor = Get-CorSituacao 'Executando'; $it.EnsureVisible()
        $lblStatus.Text = "[$n/$($sel.Count)] Executando: $($t.Nome)"
        Write-LogUI "=== $($t.Nome) ==="
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $res = Invoke-Teste $t $it
        if ($t.Id -eq 'audio' -and $Global:Cfg.TesteSom -and -not $Global:Cancelar) { Invoke-TesteSom $res }
        if ($t.Id -eq 'servicos' -and -not $Global:Cancelar) { Invoke-RevisaoServicos $res }
        $sw.Stop()
        $res.Nome = $t.Nome; $res.Id = $t.Id; $res.Desc = $t.Desc; $res.Duracao = $sw.Elapsed.TotalSeconds; $res.Fim = Get-Date
        $res.Situacao = Get-Situacao $res
        $Global:Resultados[$t.Id] = $res
        $nA = @($res.Achados | Where-Object { $_.Severidade -ne 'Info' }).Count
        $it.SubItems[1].Text = $res.Situacao; $it.SubItems[2].Text = ('{0:N0} s' -f $res.Duracao)
        $it.SubItems[3].Text = $(if ($nA) { "$nA ponto(s) de atenção - $($res.Itens.Count) verificações" } else { "Sem problemas - $($res.Itens.Count) verificações" })
        $it.BackColor = Get-CorSituacao $res.Situacao
        Show-Resultado $t.Id
        $it.Selected = $true
        Write-LogUI "Concluído: $($t.Nome) -> $($res.Situacao) ($nA achado(s))"
        $Global:Prints[$t.Id] = $(if ($Global:TabMap.ContainsKey($t.Id)) { Get-Print $Global:TabMap[$t.Id].Content } else { Get-Print })
        $prog.Value = $n
    }
    $Global:Fim = Get-Date
    $Global:Rodando = $false
    Set-BotoesAcao $true
    if ($Global:FecharApos) { $form.Close(); return }
    if ($Global:Resultados.Count) {
        $nt = Get-Notas
        $lblStatus.Text = "Concluído!  Desempenho: $(Format-Nota $nt.Desempenho)/10 ($((Get-Conceito $nt.Desempenho)[0]))   |   Segurança: $(Format-Nota $nt.Seguranca)/10 ($((Get-Conceito $nt.Seguranca)[0]))"
        Write-LogUI $lblStatus.Text
        $r = [System.Windows.Forms.MessageBox]::Show($form, "Auditoria concluída.`r`n`r`nNota de desempenho: $(Format-Nota $nt.Desempenho) / 10`r`nNota de segurança: $(Format-Nota $nt.Seguranca) / 10`r`n`r`nPara corrigir o que foi encontrado, use o botão 'Solucionar problemas'.`r`n`r`nDeseja gerar o relatório em PDF agora?", 'AuditorTI', 'YesNo', 'Information')
        if ($r -eq 'Yes') { $btnRel.PerformClick() }
    }
})

$form.Add_FormClosing({
    param($s, $e)
    if ($Global:Rodando) {
        $r = [System.Windows.Forms.MessageBox]::Show($form, 'Há uma tarefa em andamento. Deseja interromper e sair?' + [Environment]::NewLine + '(Reparos como DISM/SFC já iniciados continuam rodando em segundo plano até terminar.)', 'AuditorTI', 'YesNo', 'Warning')
        $e.Cancel = $true
        if ($r -eq 'Yes') { $Global:Cancelar = $true; $Global:Sync['Cancelar'] = $true; $Global:FecharApos = $true }
    }
})

if ($TestarInterface) {
    # verificação automática: mostra a janela, salva um print e fecha
    $form.Add_Shown({
        $Global:Resultados['sistema'] = @{
            Nome = 'Sistema (teste)'; Situacao = 'Atenção'; Desc = 'Verificação automática da interface em abas.'
            Itens = @([pscustomobject]@{ Item = 'Interface'; Valor = 'Janela e abas criadas com sucesso'; Status = 'OK' }, [pscustomobject]@{ Item = 'Exemplo de alerta'; Valor = 'Valor de exemplo'; Status = 'Atenção' })
            Achados = @([pscustomobject]@{ Categoria = 'Segurança'; Severidade = 'Alto'; Achado = 'Achado de exemplo para testar o layout.'; Recomendacao = 'Recomendação de exemplo.'; Penalidade = 1.0; Upgrade = $false })
            Tabelas = @(@{ Titulo = 'Tabela de exemplo'; Linhas = @([pscustomobject]@{ Coluna1 = 'A'; Coluna2 = 'B'; Coluna3 = 'C' }, [pscustomobject]@{ Coluna1 = '1'; Coluna2 = '2'; Coluna3 = '3' }) })
        }
        $pasta = if ($Saida) { $Saida } else { $env:TEMP }
        New-Item -ItemType Directory -Path $pasta -Force | Out-Null
        try {
            Show-Resultado 'sistema'
            [System.Windows.Forms.Application]::DoEvents()
            $cap = if ($Global:TabMap.ContainsKey('sistema')) { Get-Print $Global:TabMap['sistema'].Content } else { Get-Print }
            [IO.File]::WriteAllBytes((Join-Path $pasta 'interface.jpg'), $cap)
            $alt = if ($Global:TabMap.ContainsKey('sistema')) { $Global:TabMap['sistema'].Content.Height } else { 0 }
            [IO.File]::WriteAllText((Join-Path $pasta 'altura.txt'), [string]$alt)
        }
        catch { try { [IO.File]::WriteAllText((Join-Path $pasta 'erro_interface.txt'), ($_ | Out-String)) } catch {} }
        finally { $form.Close() }
    })
}
[void]$form.ShowDialog()
$form.Dispose()
