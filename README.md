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

## O que é verificado

| Área | Principais verificações |
|---|---|
| Sistema e hardware | Versão e fim de suporte do Windows, ativação, BIOS, TPM, Secure Boot, BitLocker, pontos de restauração, drivers com erro |
| Memória | Quantidade, uso, slots livres, tipo/velocidade, processos que mais consomem |
| Discos | SSD/HDD, saúde SMART, temperatura, desgaste, espaço livre, velocidade de leitura/escrita |
| Processador | Carga em repouso, benchmark, programas na inicialização, bateria |
| Rede | IP/DNS, internet, portas abertas e processos, SMBv1, compartilhamentos, Wi-Fi |
| Áudio | Dispositivos, serviços e teste audível |
| Serviços | Não essenciais (desativa só com confirmação e gera script de restauração), terceiros sem assinatura, caminhos sem aspas |
| Atualizações | Windows Update, reinicialização pendente, programas desatualizados (winget), acesso remoto instalado, software obsoleto |
| Antivírus | Proteção em tempo real, definições, exclusões suspeitas, ameaças detectadas |
| Firewall | Perfis, regras de entrada perigosas ou órfãs |
| Usuários | Administradores, Convidado, contas sem senha ou inativas, política de senha |
| Registro | Run/RunOnce, Winlogon, IFEO, UAC, RDP/NLA, WDigest, LSA, SmartScreen, hosts, proxy |
| Tarefas agendadas | Tarefas de terceiros e com padrões maliciosos |
| Eventos | Telas azuis, desligamentos, erros de disco/hardware, logons com falha, logs apagados |

## Relatório auditável
Cada auditoria gera uma pasta com o PDF, o `relatorio.html`, o `evidencias.json` (todos os dados brutos), os prints e, se houver, o `restaurar_servicos.ps1`. O PDF traz o **código SHA-256** do arquivo de evidências e de cada print: se alguém alterar esses arquivos, o código muda.

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
