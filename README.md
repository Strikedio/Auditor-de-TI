# AuditorTI — Auditor de TI

Ferramenta para auditoria técnica de computadores Windows 10/11: analisa desempenho e segurança, dá uma nota de 0 a 10 para cada um e gera um **relatório em PDF no seu papel timbrado**, com prints, plano de ação e sugestões de upgrade.

## Três formas de usar

### 1. Instalador (computador da empresa / notebook de campo)
Baixe o **`AuditorTI-Setup-x.x.x.exe`** em [Releases](https://github.com/Strikedio/Auditor-de-TI/releases/latest) e instale. Ele cria atalho no Menu Iniciar e na Área de Trabalho e tem desinstalador.
Configurações em `%APPDATA%\AuditorTI` e relatórios em `Documentos\AuditoriasTI`.

### 2. Pendrive (modo portátil)
Baixe o **`AuditorTI-Portatil-x.x.x.zip`** em [Releases](https://github.com/Strikedio/Auditor-de-TI/releases/latest), extraia no pendrive e execute o `AuditorTI.exe`.
No pendrive, **tudo fica no próprio pendrive**: o papel timbrado, as configurações (pasta `dados`) e os relatórios (pasta `Relatorios`). O modo portátil é ativado sozinho quando o programa está num pendrive ou quando existe o arquivo `portable.txt` ao lado dele.

### 3. Direto do GitHub (perdi o pendrive)
Em qualquer computador com internet, abra o **PowerShell** e cole:

```powershell
irm https://raw.githubusercontent.com/Strikedio/Auditor-de-TI/main/run.ps1 | iex
```

Ele baixa a versão mais recente para a pasta temporária e abre o programa (confirme a permissão de Administrador). Os relatórios vão para `Documentos\AuditoriasTI` do computador. Copie a pasta do relatório e apague-a depois, se não quiser deixar nada na máquina do cliente.

## Compatibilidade
Funciona em Windows 10 e 11 e em Windows Server (2016, 2019, 2022 e mais recentes), em instalação normal. Em **Server Core** (sem interface gráfica), rode em modo texto, que gera o relatório sem janela:

```powershell
.\AuditorTI.ps1 -SemInterface -Cliente "Nome do cliente" -Capturar
```

A captura de pacotes usa o **Wireshark** (`dumpcap`) se estiver instalado; senão, usa o **pktmon**, já embutido no Windows 10 1809+/Server 2019+. O arquivo `.pcapng` fica na pasta do relatório para você abrir no Wireshark.

## Interface em abas
Cada teste abre em sua própria aba, com os detalhes completos: a lista de verificações, os pontos encontrados (com cor por gravidade) e todas as tabelas de dados. Isso deixa a auditoria mais fácil de ler e faz os prints do relatório saírem mais detalhados.

## O que é verificado

| Área | Principais verificações |
|---|---|
| Sistema e hardware | Versão e fim de suporte do Windows, ativação, BIOS, TPM, Secure Boot, BitLocker, pontos de restauração, drivers com erro |
| Memória | Quantidade, uso, slots livres, tipo/velocidade, processos que mais consomem e **teste de integridade da RAM** (padrões de memória, estilo MemTest, na memória livre) |
| Discos | SSD/HDD, saúde e **atributos S.M.A.R.T. detalhados** (estilo CrystalDiskInfo: setores realocados/pendentes, temperatura, horas ligado, erros CRC), espaço livre, velocidade de leitura/escrita |
| Processador | Carga em repouso, benchmark, programas na inicialização, bateria |
| Rede | IP/DNS, internet, portas abertas e processos, SMBv1, compartilhamentos, Wi-Fi |
| Segurança de rede | LLMNR / NetBIOS-NS / mDNS (Responder), assinatura SMB, WPAD, túneis IPv6 (Teredo/ISATAP/6to4), IP forwarding, tabela ARP e detecção de spoofing, servidores DNS, descoberta de hosts na LAN e **captura de pacotes** (Wireshark/dumpcap ou pktmon nativo, gera `.pcapng`) |
| Áudio | Dispositivos, serviços e teste audível |
| Serviços | Não essenciais (desativa só com confirmação e gera script de restauração), terceiros sem assinatura, caminhos sem aspas |
| Atualizações | Windows Update, reinicialização pendente, programas desatualizados (winget), acesso remoto instalado, software obsoleto |
| Antivírus | Proteção em tempo real, definições, exclusões suspeitas, ameaças detectadas |
| Firewall | Perfis, regras de entrada perigosas ou órfãs |
| Usuários | Administradores, Convidado, contas sem senha ou inativas, política de senha |
| Registro | Run/RunOnce, Winlogon, IFEO, UAC, RDP/NLA, WDigest, LSA, SmartScreen, hosts, proxy |
| Tarefas agendadas | Tarefas de terceiros e com padrões maliciosos |
| Eventos | Telas azuis, desligamentos, erros de disco/hardware, logons com falha, logs apagados |

## Ações após a auditoria
- **Solucionar problemas** — abre a lista de reparos, já marcando a correção de cada problema encontrado (firewall desligado, proteção em tempo real, SMBv1, conta Convidado, UAC, WDigest, AutoRun, bloqueio de conta, políticas que desligam Defender/Windows Update...) e os reparos gerais: ponto de restauração, **DISM /RestoreHealth**, **SFC /scannow**, **CHKDSK /scan** (e CHKDSK completo no reinício), atualização do antivírus, redefinição e instalação do Windows Update, atualização de programas (winget), limpeza de temporários e redefinição de rede.
- **Otimizar Windows (Standard)** — aplica os mesmos 12 ajustes do modo *Standard* da aba *Tweaks* do [WinUtil](https://github.com/ChrisTitusTech/winutil) do Chris Titus Tech (licença MIT): ponto de restauração, histórico de atividades, ConsumerFeatures, descoberta automática de pastas, WPBT, localização, serviços em manual, telemetria, otimização de entrega, limpeza de disco, temporários e "Finalizar tarefa" na barra.
- **Ativação do Windows** — somente ativação legítima: com a chave OEM gravada na placa-mãe ou com uma chave de produto informada.

Todas as alterações guardam o valor anterior. Na pasta do relatório é gerado o **`desfazer_alteracoes.ps1`**, que volta as configurações ao estado original.

## Relatório auditável
Cada auditoria gera uma pasta com o PDF, o `relatorio.html`, o `evidencias.json` (todos os dados brutos), os prints e, se houver, o `desfazer_alteracoes.ps1`. O PDF traz o **código SHA-256** do arquivo de evidências e de cada print: se alguém alterar esses arquivos, o código muda.

## Publicar uma nova versão (para quem mantém o projeto)
1. Altere o código em `src/AuditorTI.ps1` e atualize `$Global:VersaoApp`.
2. Crie uma tag com a versão, por exemplo `v1.2.0` (em *Releases > Draft a new release > Choose a tag*).
3. O GitHub Actions gera automaticamente o `.exe`, o instalador e o `.zip` portátil e os anexa à release.

Para gerar localmente: `build\Compilar.ps1` (o instalador exige o [Inno Setup 6](https://jrsoftware.org/isdl.php)). Para usar o seu ícone, coloque um `assets\icone.ico`.

## Estrutura
```
src/AuditorTI.ps1        programa (PowerShell + interface Windows Forms)
run.ps1                  execução direta pelo GitHub
Executar.bat             executa o script sem o .exe
build/Compilar.ps1       gera exe, zip portátil e instalador
build/instalador.iss     script do instalador (Inno Setup)
.github/workflows/       build automático
```

Autor: Samuel David Diniz Reis
