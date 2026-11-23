#!/bin/sh
# shellcheck shell=sh
# =====================================================================
#  AuditorTI Linux 1.0 - Auditoria tecnica de servidores Linux e NAS QNAP
#  Gera um relatorio HTML com notas de desempenho e seguranca.
#
#  Uso:
#    sh auditor-linux.sh -c "Cliente" -t "Tecnico" [-o pasta] [-l timbrado.png]
#
#  Rode como root (ou admin, no QNAP) para uma analise completa.
#  Nao altera nada no sistema: apenas le informacoes.
# =====================================================================

VERSAO="1.0.0"
CLIENTE=""
TECNICO=""
OUTDIR="."
TIMBRADO=""
OS_CHAMADO=""

while [ $# -gt 0 ]; do
    case "$1" in
        -c) CLIENTE="$2"; shift 2 ;;
        -t) TECNICO="$2"; shift 2 ;;
        -o) OUTDIR="$2"; shift 2 ;;
        -l) TIMBRADO="$2"; shift 2 ;;
        -n) OS_CHAMADO="$2"; shift 2 ;;
        -h|--help)
            echo "Uso: sh auditor-linux.sh -c \"Cliente\" -t \"Tecnico\" [-o pasta] [-l timbrado.png] [-n OS]"
            exit 0 ;;
        *) echo "Opcao desconhecida: $1"; exit 1 ;;
    esac
done

[ -z "$CLIENTE" ] && CLIENTE="(cliente nao informado)"
US=$(printf '\037')              # separador de campos
TMP=$(mktemp -d 2>/dev/null || echo "/tmp/auditorti.$$")
mkdir -p "$TMP" "$OUTDIR" 2>/dev/null
FIND="$TMP/find"; ITEM="$TMP/item"; EVID="$TMP/evid.txt"
: > "$FIND"; : > "$ITEM"; : > "$EVID"
INICIO=$(date '+%Y-%m-%d %H:%M:%S')
INICIO_TS=$(date +%s)
IDAUD="AUD-L-$(date '+%Y%m%d-%H%M')-$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | tr 'a-z' 'A-Z')"

# ---------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
ev() { printf '%s\n' "$*" >> "$EVID"; }

# add_item AREA ITEM VALOR STATUS
add_item() {
    printf '%s%s%s%s%s%s%s\n' "$1" "$US" "$2" "$US" "$3" "$US" "$4" >> "$ITEM"
    ev "[$4] $1 / $2: $3"
}
# add_find CATEGORIA SEVERIDADE AREA TEXTO RECOMENDACAO [PENALIDADE]
add_find() {
    cat="$1"; sev="$2"; area="$3"; txt="$4"; rec="$5"; pen="$6"
    if [ -z "$pen" ]; then
        case "$sev" in
            "Critico") pen="2.5" ;;
            "Alto")    pen="1.2" ;;
            "Medio")   pen="0.5" ;;
            "Baixo")   pen="0.15" ;;
            *)         pen="0" ;;
        esac
    fi
    printf '%s%s%s%s%s%s%s%s%s%s%s\n' "$cat" "$US" "$sev" "$US" "$area" "$US" "$txt" "$US" "$rec" "$US" "$pen" >> "$FIND"
    ev "ACHADO [$sev/$cat] $area: $txt -> $rec"
}

# =====================================================================
#  COLETA
# =====================================================================
IS_QNAP=0
if [ -f /etc/config/uLinux.conf ] || have getcfg || [ -d /share/CACHEDEV1_DATA ] || [ -f /etc/platform.conf ]; then IS_QNAP=1; fi
getcfgq() { if have getcfg; then getcfg "$1" "$2" -f "${3:-/etc/config/uLinux.conf}" 2>/dev/null; fi; }

# ---------- 1. Sistema ----------
echo "Coletando informacoes do sistema..."
HOST=$(hostname 2>/dev/null)
KERNEL=$(uname -sr 2>/dev/null)
ARCH=$(uname -m 2>/dev/null)
add_item "Sistema" "Nome do host" "$HOST" "Info"
add_item "Sistema" "Kernel" "$KERNEL ($ARCH)" "Info"

SO_NOME=""
if [ "$IS_QNAP" = "1" ]; then
    MODELO=$(getcfgq System "Model"); [ -z "$MODELO" ] && MODELO=$(getsysinfo model 2>/dev/null)
    FW=$(getcfgq System "Version"); FWB=$(getcfgq System "Build Number")
    [ -z "$FW" ] && [ -f /etc/version ] && FW=$(cat /etc/version 2>/dev/null)
    SO_NOME="QNAP QTS ${FW} (build ${FWB})"
    add_item "Sistema" "Equipamento" "QNAP ${MODELO}" "Info"
    add_item "Sistema" "Firmware QTS" "${FW} build ${FWB}" "Info"
    add_find "Seguranca" "Baixo" "Sistema" "Confirmar se o firmware do QNAP esta na versao mais recente (versao atual: ${FW})." "No QTS: Painel de Controle > Atualizacao de firmware > Verificar atualizacao. Manter o firmware atualizado corrige falhas de seguranca." "0.15"
else
    if [ -f /etc/os-release ]; then SO_NOME=$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME"); fi
    [ -z "$SO_NOME" ] && SO_NOME=$(uname -o 2>/dev/null)
    add_item "Sistema" "Distribuicao" "$SO_NOME" "Info"
fi

if have uptime; then
    UP=$(uptime 2>/dev/null | sed 's/.*up //; s/,.*user.*//; s/,  *load.*//')
    add_item "Sistema" "Tempo ligado" "$UP" "Info"
fi
add_item "Sistema" "Data/hora local" "$(date '+%d/%m/%Y %H:%M:%S %Z')" "Info"

# ---------- 2. CPU e carga (desempenho) ----------
echo "Analisando CPU e carga..."
NCPU=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null); [ -z "$NCPU" ] && NCPU=1
CPUMODEL=$(grep -m1 -E 'model name|Hardware|Processor' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//')
[ -z "$CPUMODEL" ] && CPUMODEL="(nao identificado)"
add_item "Processador" "Modelo" "$CPUMODEL" "Info"
add_item "Processador" "Nucleos logicos" "$NCPU" "Info"
if [ -r /proc/loadavg ]; then
    LOAD1=$(cut -d' ' -f1 /proc/loadavg)
    # carga por nucleo = load1 / ncpu
    RATIO=$(awk -v l="$LOAD1" -v n="$NCPU" 'BEGIN{ if(n<1)n=1; printf "%.2f", l/n }')
    ST="OK"
    awk -v r="$RATIO" 'BEGIN{ exit !(r>=1.0) }' && ST="Atencao"
    awk -v r="$RATIO" 'BEGIN{ exit !(r>=2.0) }' && ST="Critico"
    add_item "Processador" "Carga media (1 min)" "$LOAD1 (= ${RATIO} por nucleo)" "$ST"
    if [ "$ST" = "Critico" ]; then
        add_find "Desempenho" "Alto" "Processador" "Carga do processador muito alta: ${RATIO}x o numero de nucleos." "Identificar o processo que consome CPU (comando top). Pode indicar sobrecarga, processo travado ou mineracao maliciosa." "1.5"
    elif [ "$ST" = "Atencao" ]; then
        add_find "Desempenho" "Medio" "Processador" "Carga do processador elevada: ${RATIO}x o numero de nucleos." "Revisar os processos em execucao (top). Avaliar se o equipamento atende a demanda." "0.5"
    fi
fi
if have ps; then
    ps -eo pcpu,pmem,comm 2>/dev/null | sort -rn | head -6 | tail -5 > "$TMP/topcpu" 2>/dev/null
fi

# ---------- 3. Memoria (desempenho) ----------
echo "Analisando memoria..."
if [ -r /proc/meminfo ]; then
    MT=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    MA=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    [ -z "$MA" ] && MA=$(awk '/MemFree/{print $2}' /proc/meminfo)
    ST=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
    SF=$(awk '/SwapFree/{print $2}' /proc/meminfo)
    MTG=$(awk -v k="$MT" 'BEGIN{printf "%.1f", k/1048576}')
    USOPCT=$(awk -v t="$MT" -v a="$MA" 'BEGIN{ if(t<1)t=1; printf "%.0f", (1-a/t)*100 }')
    STt="OK"; [ "$USOPCT" -ge 85 ] 2>/dev/null && STt="Atencao"; [ "$USOPCT" -ge 95 ] 2>/dev/null && STt="Critico"
    add_item "Memoria" "RAM total" "${MTG} GB" "Info"
    add_item "Memoria" "Uso de RAM" "${USOPCT}%" "$STt"
    if [ "$STt" = "Critico" ]; then
        add_find "Desempenho" "Alto" "Memoria" "Memoria RAM com ${USOPCT}% de uso." "Fechar/otimizar servicos que consomem memoria ou ampliar a RAM do equipamento." "1"
    elif [ "$STt" = "Atencao" ]; then
        add_find "Desempenho" "Medio" "Memoria" "Memoria RAM com ${USOPCT}% de uso." "Monitorar o consumo de memoria dos servicos." "0.5"
    fi
    if [ -n "$ST" ] && [ "$ST" -gt 0 ] 2>/dev/null; then
        SWUSO=$(awk -v t="$ST" -v f="$SF" 'BEGIN{ if(t<1)t=1; printf "%.0f", (1-f/t)*100 }')
        STsw="OK"; [ "$SWUSO" -ge 50 ] 2>/dev/null && STsw="Atencao"
        add_item "Memoria" "Uso de swap" "${SWUSO}%" "$STsw"
        [ "$STsw" = "Atencao" ] && add_find "Desempenho" "Medio" "Memoria" "Uso de swap em ${SWUSO}% (memoria fisica insuficiente)." "Ampliar a RAM; uso intenso de swap deixa o sistema lento." "0.5"
    fi
fi

# ---------- 4. Discos e SMART (desempenho) ----------
echo "Analisando discos e saude SMART..."
# RAID
if [ -r /proc/mdstat ]; then
    if grep -q '\[.*_.*\]' /proc/mdstat 2>/dev/null; then
        DEG=$(grep -o '\[[U_]*\]' /proc/mdstat | grep '_' | head -1)
        add_item "Discos" "RAID (mdadm)" "DEGRADADO $DEG" "Critico"
        add_find "Desempenho" "Critico" "Discos" "Arranjo RAID DEGRADADO (um ou mais discos fora): $DEG." "Substituir o disco com falha IMEDIATAMENTE e reconstruir o RAID. Com disco a menos, uma nova falha causa perda total dos dados." "3"
    elif grep -q 'active' /proc/mdstat 2>/dev/null; then
        add_item "Discos" "RAID (mdadm)" "Ativo e integro" "OK"
    fi
fi
# dispositivos de bloco
DISKS=""
if have lsblk; then
    DISKS=$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}')
fi
[ -z "$DISKS" ] && DISKS=$(ls /dev/sd? /dev/nvme?n1 /dev/hd? 2>/dev/null)
SMARTBIN=""
for s in smartctl /usr/sbin/smartctl /sbin/smartctl /usr/local/sbin/smartctl; do
    if command -v "$s" >/dev/null 2>&1 || [ -x "$s" ]; then SMARTBIN="$s"; break; fi
done
if [ -n "$SMARTBIN" ] && [ -n "$DISKS" ]; then
    for d in $DISKS; do
        H=$("$SMARTBIN" -H "$d" 2>/dev/null)
        HEALTH=$(echo "$H" | grep -iE 'overall-health|SMART Health|test result' | head -1 | sed 's/.*: *//')
        [ -z "$HEALTH" ] && HEALTH="(sem SMART)"
        A=$("$SMARTBIN" -A "$d" 2>/dev/null)
        TEMP=$(echo "$A" | grep -iE 'Temperature_Celsius|Airflow_Temp|Current Drive Temperature' | head -1 | awk '{print $10}')
        [ -z "$TEMP" ] && TEMP=$(echo "$A" | grep -i 'Temperature:' | head -1 | awk '{print $2}')
        POH=$(echo "$A" | grep -iE 'Power_On_Hours|Power On Hours' | head -1 | awk '{print $10}')
        REALLOC=$(echo "$A" | grep -iE 'Reallocated_Sector|Reallocated_Event' | head -1 | awk '{print $10}')
        PENDING=$(echo "$A" | grep -iE 'Current_Pending_Sector' | head -1 | awk '{print $10}')
        MODEL=$("$SMARTBIN" -i "$d" 2>/dev/null | grep -iE 'Device Model|Model Number' | head -1 | sed 's/.*: *//')
        STd="OK"
        echo "$HEALTH" | grep -qiE 'PASSED|OK' || STd="Critico"
        add_item "Discos" "SMART $d ($MODEL)" "$HEALTH | temp ${TEMP:-?}C | horas ${POH:-?} | realoc ${REALLOC:-0} | pend ${PENDING:-0}" "$STd"
        if [ "$STd" = "Critico" ]; then
            add_find "Desempenho" "Critico" "Discos" "Disco $d ($MODEL) com SMART reprovado ($HEALTH)." "Fazer backup imediato e substituir o disco." "3"
        fi
        if [ -n "$REALLOC" ] && [ "$REALLOC" -gt 0 ] 2>/dev/null; then
            add_find "Desempenho" "Alto" "Discos" "Disco $d com ${REALLOC} setor(es) realocado(s)." "Monitorar de perto e planejar a substituicao; setores realocados crescentes indicam disco em degradacao." "1"
        fi
        if [ -n "$PENDING" ] && [ "$PENDING" -gt 0 ] 2>/dev/null; then
            add_find "Desempenho" "Alto" "Discos" "Disco $d com ${PENDING} setor(es) pendente(s)." "Fazer backup e testar o disco; setores pendentes costumam virar setores defeituosos." "1"
        fi
        if [ -n "$TEMP" ] && [ "$TEMP" -ge 55 ] 2>/dev/null; then
            add_find "Desempenho" "Medio" "Discos" "Disco $d operando quente (${TEMP}C)." "Melhorar a ventilacao/limpeza do equipamento." "0.3"
        fi
    done
else
    add_item "Discos" "SMART" "smartctl indisponivel - saude dos discos nao verificada" "Atencao"
fi
# espaco em disco
echo "Verificando espaco em disco..."
df -P -k 2>/dev/null | awk 'NR>1 && $1 !~ /tmpfs|devtmpfs|overlay|udev/ && $2+0>0 {print}' | while read fsdev blocks used avail usep mount rest; do
    pct=$(echo "$usep" | tr -d '%')
    gb=$(awk -v b="$blocks" 'BEGIN{printf "%.0f", b/1048576}')
    [ "$gb" -lt 1 ] 2>/dev/null && continue
    st="OK"; livre=$((100-pct))
    [ "$livre" -lt 20 ] 2>/dev/null && st="Atencao"; [ "$livre" -lt 10 ] 2>/dev/null && st="Critico"
    printf '%s\037%s\037%s\037%s\n' "Discos" "Volume $mount" "${usep} usado (${gb} GB total)" "$st" >> "$ITEM"
    if [ "$livre" -lt 10 ] 2>/dev/null; then
        printf '%s\037%s\037%s\037%s\037%s\037%s\n' "Desempenho" "Alto" "Discos" "Volume $mount com apenas ${livre}% livre." "Liberar espaco ou ampliar o armazenamento; volumes muito cheios causam lentidao e falhas." "1.5" >> "$FIND"
    fi
done

# ---------- 5. Rede e portas (seguranca) ----------
echo "Analisando rede e portas abertas..."
if have ip; then
    IPS=$(ip -4 -o addr show 2>/dev/null | awk '{print $2": "$4}' | grep -v '127.0.0.1' | tr '\n' ' ')
    GW=$(ip route 2>/dev/null | awk '/default/{print $3; exit}')
elif have ifconfig; then
    IPS=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | sed 's/addr://' | grep -v '127.0.0.1' | tr '\n' ' ')
    GW=$(route -n 2>/dev/null | awk '/^0.0.0.0/{print $2; exit}')
fi
add_item "Rede" "Enderecos IP" "${IPS:-?}" "Info"
add_item "Rede" "Gateway padrao" "${GW:-?}" "Info"
[ -r /etc/resolv.conf ] && add_item "Rede" "Servidores DNS" "$(awk '/nameserver/{print $2}' /etc/resolv.conf | tr '\n' ' ')" "Info"

# portas em escuta
PORTSRAW=""
if have ss; then PORTSRAW=$(ss -tlnH 2>/dev/null); fi
if [ -z "$PORTSRAW" ] && have netstat; then PORTSRAW=$(netstat -tln 2>/dev/null | grep LISTEN); fi
EXPOSTAS=0; LOCAIS=0
echo "$PORTSRAW" | while read l; do
    [ -z "$l" ] && continue
    addr=$(echo "$l" | grep -oE '[0-9.]+:[0-9]+|\*:[0-9]+|\[::\]?:[0-9]+|:::[0-9]+' | head -1)
    [ -z "$addr" ] && continue
    port=$(echo "$addr" | sed 's/.*://')
    ip=$(echo "$addr" | sed 's/:[0-9]*$//')
    case "$ip" in
        127.0.0.1|::1|"[::1]") echo "L" >> "$TMP/portcount" ;;
        *) echo "$port" >> "$TMP/expostas" ;;
    esac
done
if [ -f "$TMP/expostas" ]; then
    EXPOSTAS=$(sort -un "$TMP/expostas" | wc -l | tr -d ' ')
    add_item "Rede" "Portas TCP abertas para a rede" "$EXPOSTAS" "Info"
    add_item "Rede" "Portas expostas" "$(sort -un "$TMP/expostas" | tr '\n' ' ')" "Info"
    for p in $(sort -un "$TMP/expostas"); do
        case "$p" in
            23)   add_find "Seguranca" "Alto" "Rede" "Telnet (porta 23) aberto para a rede - trafego sem criptografia." "Desativar o Telnet e usar SSH. No QNAP: Painel de Controle > Telnet/SSH, desmarcar Telnet." ;;
            21)   add_find "Seguranca" "Medio" "Rede" "FTP (porta 21) aberto - credenciais podem trafegar sem criptografia." "Usar SFTP/FTPS ou restringir o FTP; exigir TLS." ;;
            513|514) add_find "Seguranca" "Medio" "Rede" "Servico r* (rlogin/rsh porta $p) aberto - inseguro." "Desativar; usar SSH." ;;
            5900) add_find "Seguranca" "Medio" "Rede" "VNC (porta 5900) aberto para a rede." "Restringir por firewall/VPN e exigir senha forte." ;;
            3389) add_find "Seguranca" "Medio" "Rede" "RDP (porta 3389) aberto." "Restringir por firewall/VPN." ;;
        esac
    done
fi
[ -f "$TMP/portcount" ] && add_item "Rede" "Portas TCP apenas locais" "$(wc -l < "$TMP/portcount" | tr -d ' ')" "Info"

# ---------- 6. SSH (seguranca) ----------
echo "Verificando configuracao do SSH..."
SSHD=""
for f in /etc/ssh/sshd_config /etc/config/ssh/sshd_config; do [ -r "$f" ] && SSHD="$f" && break; done
if [ -n "$SSHD" ]; then
    sg() { grep -iE "^[[:space:]]*$1[[:space:]]" "$SSHD" 2>/dev/null | grep -v '^#' | tail -1 | awk '{print $2}'; }
    SPORT=$(sg Port); [ -z "$SPORT" ] && SPORT="22"
    SROOT=$(sg PermitRootLogin)
    SPASS=$(sg PasswordAuthentication)
    add_item "SSH" "Porta" "$SPORT" "$( [ "$SPORT" = "22" ] && echo Info || echo OK )"
    add_item "SSH" "Login de root" "${SROOT:-padrao}" "$( echo "$SROOT" | grep -qiE 'yes' && echo Atencao || echo OK )"
    if echo "$SROOT" | grep -qiE 'yes'; then
        add_find "Seguranca" "Alto" "SSH" "Login de root permitido via SSH (PermitRootLogin yes)." "Definir 'PermitRootLogin no' (ou 'prohibit-password') e usar um usuario comum com sudo."
    fi
    if echo "$SPASS" | grep -qiE 'yes' || [ -z "$SPASS" ]; then
        add_item "SSH" "Autenticacao por senha" "${SPASS:-padrao (sim)}" "Atencao"
        add_find "Seguranca" "Medio" "SSH" "SSH aceita login por senha (sujeito a forca bruta)." "Preferir chaves SSH e desativar a senha ('PasswordAuthentication no'); usar fail2ban ou a Protecao de Acesso do QNAP."
    else
        add_item "SSH" "Autenticacao por senha" "$SPASS" "OK"
    fi
fi

# ---------- 7. Usuarios (seguranca) ----------
echo "Verificando contas de usuario..."
if [ -r /etc/passwd ]; then
    NU=$(wc -l < /etc/passwd | tr -d ' ')
    add_item "Usuarios" "Contas no /etc/passwd" "$NU" "Info"
    # UID 0 alem de root
    UID0=$(awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd | tr '\n' ' ')
    if [ -n "$UID0" ]; then
        add_item "Usuarios" "Outras contas com UID 0" "$UID0" "Critico"
        add_find "Seguranca" "Critico" "Usuarios" "Conta(s) com privilegio de root (UID 0) alem do root: $UID0." "Remover o privilegio ou a conta; UID 0 e acesso total ao sistema."
    else
        add_item "Usuarios" "Contas com UID 0" "Apenas root" "OK"
    fi
    # senhas vazias (se shadow legivel)
    if [ -r /etc/shadow ]; then
        VAZIAS=$(awk -F: '($2==""){print $1}' /etc/shadow | tr '\n' ' ')
        if [ -n "$VAZIAS" ]; then
            add_item "Usuarios" "Contas SEM senha" "$VAZIAS" "Critico"
            add_find "Seguranca" "Critico" "Usuarios" "Conta(s) sem senha: $VAZIAS." "Definir senha forte ou bloquear a conta (passwd -l)."
        fi
    fi
    # QNAP: conta admin padrao
    if [ "$IS_QNAP" = "1" ]; then
        if awk -F: '$1=="admin"{found=1} END{exit !found}' /etc/passwd 2>/dev/null; then
            ADMEN=$(getcfgq "admin" "status" 2>/dev/null)
            add_item "Usuarios" "Conta 'admin' padrao do QNAP" "presente" "Atencao"
            add_find "Seguranca" "Medio" "Usuarios" "Conta administrativa padrao 'admin' do QNAP existe (alvo comum de ataques)." "Criar um administrador com outro nome, usar senha forte e DESATIVAR a conta 'admin' padrao (QTS: Painel de Controle > Usuarios)."
        fi
    fi
fi
have last && add_item "Usuarios" "Ultimos logins" "$(last -n 3 2>/dev/null | head -3 | tr '\n' '; ')" "Info"
# tentativas de login com falha
FAILS=0
if have lastb; then FAILS=$(lastb 2>/dev/null | grep -c -v '^$'); fi
if [ "$FAILS" -gt 50 ] 2>/dev/null; then
    add_item "Usuarios" "Logins com falha (lastb)" "$FAILS" "Atencao"
    add_find "Seguranca" "Medio" "Usuarios" "$FAILS tentativas de login com falha registradas (possivel forca bruta)." "Ativar bloqueio apos tentativas (fail2ban ou Protecao de Acesso a Rede do QNAP) e restringir o acesso."
fi

# ---------- 8. Servicos e firewall (seguranca) ----------
echo "Verificando firewall e servicos..."
FWON=0
if have iptables; then
    RULES=$(iptables -S 2>/dev/null | grep -cvE '^-P|^$')
    POLDROP=$(iptables -S 2>/dev/null | grep -E '^-P INPUT' | grep -c DROP)
    if [ "$RULES" -gt 0 ] || [ "$POLDROP" -gt 0 ]; then FWON=1; fi
fi
if have nft && [ "$FWON" = "0" ]; then nft list ruleset 2>/dev/null | grep -q 'chain' && FWON=1; fi
if [ "$FWON" = "1" ]; then
    add_item "Seguranca" "Firewall" "Ativo (regras presentes)" "OK"
else
    add_item "Seguranca" "Firewall" "Nenhuma regra ativa detectada" "Atencao"
    add_find "Seguranca" "Medio" "Seguranca" "Nenhuma regra de firewall detectada no host." "Configurar o firewall. No QNAP: Painel de Controle > Seguranca > Protecao de Acesso e Lista de permissoes/negacoes de IP."
fi
# QNAP: servicos de risco e seguranca
if [ "$IS_QNAP" = "1" ]; then
    TELNET=$(getcfgq "LOGIN" "Telnet Enable")
    [ "$TELNET" = "TRUE" ] && add_find "Seguranca" "Alto" "Seguranca" "Telnet habilitado no QNAP." "Desativar o Telnet (sem criptografia); usar apenas SSH."
    UPNP=$(getcfgq "UPNP" "Enable"); [ -z "$UPNP" ] && UPNP=$(getcfgq "Misc" "UPNP")
    [ "$UPNP" = "TRUE" ] && add_find "Seguranca" "Medio" "Seguranca" "UPnP/encaminhamento automatico de portas habilitado." "Desativar o UPnP no roteador e no NAS; ele pode expor servicos diretamente na internet."
    # Malware Remover / Security Counselor instalados?
    if [ -d /share/CACHEDEV1_DATA/.qpkg/MalwareRemover ] || [ -d /mnt/ext/opt/MalwareRemover ]; then
        add_item "Seguranca" "QNAP Malware Remover" "instalado" "OK"
    else
        add_find "Seguranca" "Baixo" "Seguranca" "QNAP Malware Remover nao encontrado." "Instalar o Malware Remover e o Security Counselor pela App Center e executar uma verificacao." "0.15"
    fi
    add_find "Seguranca" "Baixo" "Seguranca" "Confirmar protecoes recomendadas do QNAP." "Ativar verificacao em 2 etapas (2FA) para os administradores, snapshots (protecao contra ransomware), auto-logout e trocar as portas padrao do painel (8080/443)." "0.15"
fi

# ---------- 9. Atualizacoes ----------
echo "Verificando atualizacoes pendentes..."
if have apt-get; then
    UPD=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst')
    add_item "Atualizacoes" "Pacotes com atualizacao (apt)" "${UPD:-0}" "$( [ "${UPD:-0}" -gt 0 ] 2>/dev/null && echo Atencao || echo OK )"
    [ "${UPD:-0}" -gt 0 ] 2>/dev/null && add_find "Seguranca" "Medio" "Atualizacoes" "${UPD} pacote(s) com atualizacao disponivel." "Aplicar as atualizacoes: apt update && apt upgrade."
elif have yum; then
    UPD=$(yum check-update -q 2>/dev/null | grep -c '^[a-zA-Z0-9]')
    add_item "Atualizacoes" "Pacotes com atualizacao (yum)" "${UPD:-0}" "$( [ "${UPD:-0}" -gt 0 ] 2>/dev/null && echo Atencao || echo OK )"
    [ "${UPD:-0}" -gt 0 ] 2>/dev/null && add_find "Seguranca" "Medio" "Atualizacoes" "${UPD} pacote(s) com atualizacao disponivel." "Aplicar as atualizacoes: yum update."
fi

echo "Coleta concluida. Gerando relatorio..."
FIM=$(date '+%Y-%m-%d %H:%M:%S')
DUR=$(( $(date +%s) - INICIO_TS ))

# =====================================================================
#  NOTAS
# =====================================================================
calc_nota() {
    cat="$1"
    awk -F"$US" -v cat="$cat" '
        $1==cat { pen+=$6; if($2=="Critico") crit=1 }
        END {
            nota=10-pen; if(nota<0)nota=0;
            if(crit && nota>5) nota=5;
            printf "%.1f", nota
        }' "$FIND"
}
cont_sev() { awk -F"$US" -v s="$1" '$2==s{c++} END{print c+0}' "$FIND"; }
NOTA_D=$(calc_nota "Desempenho")
NOTA_S=$(calc_nota "Seguranca")
NC=$(cont_sev "Critico"); NA=$(cont_sev "Alto"); NM=$(cont_sev "Medio"); NB=$(cont_sev "Baixo")

conceito() { awk -v n="$1" 'BEGIN{ if(n>=9)print "Excelente #1e8e3e"; else if(n>=7)print "Bom #43a047"; else if(n>=5)print "Regular #f9a825"; else if(n>=3)print "Ruim #ef6c00"; else print "Critico #c62828" }'; }
CD=$(conceito "$NOTA_D"); CS=$(conceito "$NOTA_S")
CD_T=${CD% *}; CD_C=${CD#* }; CS_T=${CS% *}; CS_C=${CS#* }

# =====================================================================
#  RELATORIO HTML
# =====================================================================
esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
e() { printf '%s' "$1" | esc; }

LIMPO=$(printf '%s' "$CLIENTE" | tr -cd 'A-Za-z0-9._ -' | tr ' ' '_'); [ -z "$LIMPO" ] && LIMPO="cliente"
REL="$OUTDIR/Relatorio_Auditoria_Linux_${LIMPO}_$(date '+%Y%m%d_%H%M').html"

# papel timbrado (base64)
TIMB_CSS=""
if [ -n "$TIMBRADO" ] && [ -r "$TIMBRADO" ] && have base64; then
    EXT=$(echo "$TIMBRADO" | sed 's/.*\.//' | tr 'A-Z' 'a-z')
    MIME="image/png"; [ "$EXT" = "jpg" -o "$EXT" = "jpeg" ] && MIME="image/jpeg"
    B64=$(base64 "$TIMBRADO" 2>/dev/null | tr -d '\n')
    TIMB_CSS=".timbrado{position:fixed;top:0;left:0;width:210mm;height:297mm;z-index:-1}.timbrado img{width:210mm;height:297mm}"
fi

{
cat <<HEADER
<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8">
<title>Auditoria Linux/QNAP - $(e "$CLIENTE") - $(e "$HOST")</title>
<style>
@page{size:A4;margin:0}*{box-sizing:border-box}
body{font-family:'Segoe UI',Arial,sans-serif;font-size:10pt;color:#1f2933;line-height:1.4;margin:0}
.pg{padding:18mm 16mm}
$TIMB_CSS
h1{font-size:18pt;color:#123456;margin:0 0 2mm}
.sub{color:#486581;margin-bottom:5mm}
h2{font-size:13pt;color:#123456;border-bottom:2px solid #123456;padding-bottom:1mm;margin:7mm 0 3mm}
.ident{display:grid;grid-template-columns:1fr 1fr;gap:1mm 6mm;background:#f0f4f8;padding:3mm 4mm;border-radius:2mm;font-size:9.5pt}
.ident b{color:#486581}
.notas{display:flex;gap:5mm;margin:4mm 0}
.nota{flex:1;border:1px solid #d9e2ec;border-radius:3mm;padding:4mm;display:flex;align-items:center;gap:4mm}
.dial{width:26mm;height:26mm;border-radius:50%;display:flex;align-items:center;justify-content:center;color:#fff;font-size:17pt;font-weight:700;flex-shrink:0}
.chips{display:flex;gap:3mm;margin:3mm 0}
.chip{flex:1;text-align:center;border-radius:2mm;padding:2mm;color:#fff;font-weight:600}
.chip b{display:block;font-size:15pt}
table{width:100%;border-collapse:collapse;margin:2mm 0;font-size:8.5pt}
th{background:#123456;color:#fff;text-align:left;padding:1.3mm}
td{border-bottom:1px solid #d9e2ec;padding:1mm 1.3mm;vertical-align:top}
tr:nth-child(even) td{background:#f0f4f8}
.badge{display:inline-block;padding:.2mm 2mm;border-radius:3mm;font-size:7.5pt;font-weight:600;color:#fff}
.Critico{background:#c62828}.Alto{background:#e65100}.Medio{background:#f9a825;color:#222}.Baixo{background:#78909c}
.OK{background:#2e7d32}.Atencao{background:#f9a825;color:#222}.Info{background:#90a4ae}
.ach{border-left:2.5mm solid #90a4ae;padding:1.5mm 3mm;margin:1.5mm 0;background:#fafbfc}
.ach.Critico{border-color:#c62828}.ach.Alto{border-color:#e65100}.ach.Medio{border-color:#f9a825}.ach.Baixo{border-color:#78909c}
.rec{color:#334e68;font-size:8.5pt;margin-top:.5mm}
.obs{font-size:8pt;color:#627d98}
</style></head><body>
HEADER

[ -n "$TIMB_CSS" ] && printf '<div class="timbrado"><img src="data:%s;base64,%s"></div>\n' "$MIME" "$B64"

cat <<CAPA
<div class="pg">
<h1>RELATORIO DE AUDITORIA - LINUX / QNAP</h1>
<div class="sub">Servidor/NAS - diagnostico de desempenho e seguranca</div>
<div class="ident">
<div><b>Cliente:</b> $(e "$CLIENTE")</div><div><b>Tecnico:</b> $(e "$TECNICO")</div>
<div><b>Equipamento:</b> $(e "${SO_NOME:-$HOST}")</div><div><b>Host:</b> $(e "$HOST")</div>
<div><b>No OS/chamado:</b> $(e "$OS_CHAMADO")</div><div><b>ID do relatorio:</b> $IDAUD</div>
<div><b>Inicio:</b> $INICIO</div><div><b>Termino:</b> $FIM (${DUR}s)</div>
</div>

<h2>Avaliacao geral</h2>
<div class="notas">
<div class="nota"><div class="dial" style="background:$CD_C">$NOTA_D</div><div><b>Nota de desempenho</b><br><span style="color:$CD_C;font-weight:700">$CD_T</span><br><span class="obs">0 a 10 - CPU, memoria, discos, RAID</span></div></div>
<div class="nota"><div class="dial" style="background:$CS_C">$NOTA_S</div><div><b>Nota de seguranca</b><br><span style="color:$CS_C;font-weight:700">$CS_T</span><br><span class="obs">0 a 10 - rede, SSH, usuarios, firewall</span></div></div>
</div>
<div class="chips"><div class="chip Critico"><b>$NC</b>Critico</div><div class="chip Alto"><b>$NA</b>Alto</div><div class="chip Medio"><b>$NM</b>Medio</div><div class="chip Baixo"><b>$NB</b>Baixo</div></div>
CAPA

# Pontos prioritarios
echo '<h2>Pontos que exigem atencao</h2>'
PRIOR=$(awk -F"$US" '$2=="Critico"||$2=="Alto"' "$FIND")
if [ -n "$PRIOR" ]; then
    for sev in Critico Alto; do
        awk -F"$US" -v s="$sev" '$2==s' "$FIND" | while IFS="$US" read c sv ar tx rc pn; do
            printf '<div class="ach %s"><span class="badge %s">%s</span> <b>%s:</b> %s<div class="rec">&#10140; %s</div></div>\n' "$sv" "$sv" "$sv" "$(e "$ar")" "$(e "$tx")" "$(e "$rc")"
        done
    done
else
    echo '<p>Nenhum ponto critico ou de severidade alta encontrado.</p>'
fi

# Plano de acao (todas as recomendacoes)
echo '<h2>Melhorias recomendadas (plano de acao)</h2>'
echo '<table><thead><tr><th>Prioridade</th><th>Area</th><th>Categoria</th><th>Acao recomendada</th></tr></thead><tbody>'
for sev in Critico Alto Medio Baixo; do
    prio=$(awk -v s="$sev" 'BEGIN{if(s=="Critico")print "Imediata";else if(s=="Alto")print "Alta";else if(s=="Medio")print "Media";else print "Baixa"}')
    awk -F"$US" -v s="$sev" '$2==s' "$FIND" | while IFS="$US" read c sv ar tx rc pn; do
        printf '<tr><td><span class="badge %s">%s</span></td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$sv" "$prio" "$(e "$ar")" "$(e "$c")" "$(e "$rc")"
    done
done
echo '</tbody></table>'

# Detalhamento por area
echo '<h2>Detalhamento por area</h2>'
AREAS=$(cut -d"$US" -f1 "$ITEM" | awk '!seen[$0]++')
for area in $AREAS; do
    printf '<h3 style="color:#334e68;margin:4mm 0 1mm">%s</h3>\n' "$(e "$area")"
    echo '<table><thead><tr><th style="width:40%">Verificacao</th><th>Resultado</th><th style="width:18mm">Situacao</th></tr></thead><tbody>'
    awk -F"$US" -v a="$area" '$1==a' "$ITEM" | while IFS="$US" read ar it vl st; do
        printf '<tr><td>%s</td><td>%s</td><td><span class="badge %s">%s</span></td></tr>\n' "$(e "$it")" "$(e "$vl")" "$st" "$st"
    done
    echo '</tbody></table>'
    # achados da area
    awk -F"$US" -v a="$area" '$3==a' "$FIND" | while IFS="$US" read c sv ar tx rc pn; do
        printf '<div class="ach %s"><span class="badge %s">%s</span> <span class="obs">[%s]</span> %s<div class="rec">&#10140; %s</div></div>\n' "$sv" "$sv" "$sv" "$(e "$c")" "$(e "$tx")" "$(e "$rc")"
    done
done

# Integridade
HASH="(sha256sum indisponivel)"
have sha256sum && HASH=$(sha256sum "$EVID" | awk '{print $1}')
cat <<RODAPE
<h2>Metodologia e integridade</h2>
<p class="obs">Auditoria realizada pelo AuditorTI Linux $VERSAO, que apenas le informacoes do sistema (nao altera nada). Cada area comeca com nota 10; cada achado desconta pontos conforme a gravidade (Critico 2,5 | Alto 1,2 | Medio 0,5 | Baixo 0,15). Qualquer achado critico limita a nota a 5,0.</p>
<p class="obs">Dados coletados: arquivo evidencias.txt (entregue junto). SHA-256: $HASH</p>
<p class="obs" style="text-align:center;margin-top:6mm">Gerado em $(date '+%d/%m/%Y %H:%M') - $IDAUD</p>
</div></body></html>
RODAPE
} > "$REL"

cp "$EVID" "$OUTDIR/evidencias.txt" 2>/dev/null

echo ""
echo "==================================================================="
echo " Auditoria concluida."
echo "  Nota de desempenho: $NOTA_D / 10 ($CD_T)"
echo "  Nota de seguranca:  $NOTA_S / 10 ($CS_T)"
echo "  Achados: $NC critico(s), $NA alto(s), $NM medio(s), $NB baixo(s)"
echo ""
echo " Relatorio: $REL"
echo " Evidencias: $OUTDIR/evidencias.txt"
echo "==================================================================="
rm -rf "$TMP" 2>/dev/null
exit 0
