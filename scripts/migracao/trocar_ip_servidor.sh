#!/bin/bash
# =====================================================================
# Magnus Utilities — trocar_ip_servidor.sh
# Versão: 1.0 (04 de novembro de 2026)
# Função: Troca de IP do servidor (Cutover de Migração) para assumir o
#         IP do servidor de produção desligado, atualizando rede Linux,
#         Asterisk (PJSIP/chan_sip), MariaDB (mbilling), Fail2ban e
#         gerando script automático de rollback (/root/reverter_ip.sh).
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root no servidor que terá o IP alterado
#   - Servidor de produção antigo JÁ DESLIGADO (o script valida conflito
#     via ping/ARP antes de aplicar para evitar colisão de IP na rede)
#   - Recomendado console KVM/Proxmox aberto durante o cutover
#
# Uso:
#   bash trocar_ip_servidor.sh              # menu interativo completo
#   bash trocar_ip_servidor.sh --dry-run    # audita referências ao IP atual sem alterar
#   bash trocar_ip_servidor.sh --revert     # reverte para o IP anterior (último backup)
#   bash trocar_ip_servidor.sh --help       # exibe ajuda
#
# Idempotência: SIM (gera backup datado e atualiza configurações de forma determinística)
# Modifica estado: SIM (rede do SO, /etc/hosts, /etc/asterisk, banco mbilling, fail2ban)
# Requer janela de manutenção: SIM (encerra sessão SSH no IP antigo e reinicia Asterisk)
# =====================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
if [ -f "$SCRIPT_DIR/../lib/common.sh" ]; then
  source "$SCRIPT_DIR/../lib/common.sh"
else
  VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
  AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
  ok()     { echo -e "  ${VERDE}✓${NC} $1"; }
  info()   { echo -e "  ${AZUL}➜${NC} $1"; }
  warn()   { echo -e "  ${AMARELO}⚠${NC} $1"; }
  erro()   { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
  titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }
  confirma() {
    read -p "  $1 [s/N]: " RESP
    [[ "$RESP" =~ ^[Ss]$ ]] || { erro "Operação cancelada pelo usuário."; }
  }
fi

DRY_RUN=0
REVERT_MODE=0
for ARG in "$@"; do
  case "$ARG" in
    --dry-run|--check) DRY_RUN=1 ;;
    --revert|--rollback) REVERT_MODE=1 ;;
    --help|-h)
      sed -n '/^# Magnus Utilities/,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

[ "$EUID" -ne 0 ] && erro "Este script deve ser executado como root."

# Diretório de logs padrão
LOG_DIR="/var/log/magnus-setup"
mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/trocar_ip_servidor-$TIMESTAMP.log"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# =====================================================================
# Funções Auxiliares de Validação e Conversão de Rede
# =====================================================================
validar_ipv4() {
  local IP="$1"
  if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi
  local IFS='.'
  read -r O1 O2 O3 O4 <<< "$IP"
  for OCT in "$O1" "$O2" "$O3" "$O4"; do
    if [ "$OCT" -lt 0 ] || [ "$OCT" -gt 255 ] 2>/dev/null; then
      return 1
    fi
  done
  return 0
}

prefix_para_netmask() {
  local PREFIX="$1"
  case "$PREFIX" in
    8)  echo "255.0.0.0" ;;
    16) echo "255.255.0.0" ;;
    20) echo "255.255.240.0" ;;
    21) echo "255.255.248.0" ;;
    22) echo "255.255.252.0" ;;
    23) echo "255.255.254.0" ;;
    24) echo "255.255.255.0" ;;
    25) echo "255.255.255.128" ;;
    26) echo "255.255.255.192" ;;
    27) echo "255.255.255.224" ;;
    28) echo "255.255.255.240" ;;
    29) echo "255.255.255.248" ;;
    30) echo "255.255.255.252" ;;
    31) echo "255.255.255.254" ;;
    32) echo "255.255.255.255" ;;
    *)  echo "255.255.255.0" ;;
  esac
}

netmask_para_prefix() {
  local MASK="$1"
  case "$MASK" in
    255.0.0.0)       echo "8" ;;
    255.255.0.0)     echo "16" ;;
    255.255.240.0)   echo "20" ;;
    255.255.248.0)   echo "21" ;;
    255.255.252.0)   echo "22" ;;
    255.255.254.0)   echo "23" ;;
    255.255.255.0)   echo "24" ;;
    255.255.255.128) echo "25" ;;
    255.255.255.192) echo "26" ;;
    255.255.255.224) echo "27" ;;
    255.255.255.240) echo "28" ;;
    255.255.255.248) echo "29" ;;
    255.255.255.252) echo "30" ;;
    255.255.255.254) echo "31" ;;
    255.255.255.255) echo "32" ;;
    *)               echo "" ;;
  esac
}

# =====================================================================
# Conexão Segura com MariaDB (sem expor senha no ps aux)
# =====================================================================
DB_READY=0
setup_mysql_access() {
  if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
    DB_READY=1
    mysql_run() { mysql -u root -D mbilling "$@"; }
  elif [ -f "/root/passwordMysql.log" ]; then
    ROOT_DB_PASS=$(cat /root/passwordMysql.log 2>/dev/null | tr -d '[:space:]')
    if [ -n "$ROOT_DB_PASS" ] && MYSQL_PWD="$ROOT_DB_PASS" mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
      DB_READY=1
      mysql_run() { MYSQL_PWD="$ROOT_DB_PASS" mysql -u root -D mbilling "$@"; }
    fi
  fi

  if [ "$DB_READY" -eq 0 ] && [ -f "/etc/asterisk/res_config_mysql.conf" ]; then
    APP_DB_USER=$(grep -i "^dbuser" /etc/asterisk/res_config_mysql.conf | head -1 | cut -d'=' -f2 | tr -d ' ')
    APP_DB_PASS=$(grep -i "^dbpass" /etc/asterisk/res_config_mysql.conf | head -1 | cut -d'=' -f2 | tr -d ' ')
    APP_DB_HOST=$(grep -i "^dbhost" /etc/asterisk/res_config_mysql.conf | head -1 | cut -d'=' -f2 | tr -d ' ')
    APP_DB_HOST=${APP_DB_HOST:-127.0.0.1}
    if [ -n "$APP_DB_PASS" ] && MYSQL_PWD="$APP_DB_PASS" mysql -u "$APP_DB_USER" -h "$APP_DB_HOST" -D mbilling -e "SELECT 1;" >/dev/null 2>&1; then
      DB_READY=1
      mysql_run() { MYSQL_PWD="$APP_DB_PASS" mysql -u "$APP_DB_USER" -h "$APP_DB_HOST" -D mbilling "$@"; }
    fi
  fi
}

setup_mysql_access

# =====================================================================
# Descoberta Automática da Rede Atual
# =====================================================================
detectar_rede_atual() {
  IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
  if [ -z "$IFACE" ]; then
    IFACE=$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}' | cut -d'@' -f1)
  fi
  [ -z "$IFACE" ] && erro "Não foi possível detectar a interface de rede principal."

  CIDR_ATUAL=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4; exit}')
  [ -z "$CIDR_ATUAL" ] && erro "Não foi possível detectar o endereço IPv4 na interface $IFACE."

  OLD_IP="${CIDR_ATUAL%/*}"
  OLD_PREFIX="${CIDR_ATUAL#*/}"
  OLD_PREFIX=${OLD_PREFIX:-24}
  OLD_NETMASK=$(prefix_para_netmask "$OLD_PREFIX")

  OLD_GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
  OLD_DNS=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | grep -v '^127\.' | tr '\n' ' ' | sed 's/ *$//')
  OLD_DNS=${OLD_DNS:-"8.8.8.8 1.1.1.1"}

  # Detectar gerenciador de configuração de rede
  NET_BACKEND="interfaces"
  if ls /etc/netplan/*.yaml >/dev/null 2>&1 || ls /etc/netplan/*.yml >/dev/null 2>&1; then
    if command -v netplan >/dev/null 2>&1; then
      NET_BACKEND="netplan"
    fi
  elif systemctl is-active NetworkManager >/dev/null 2>&1 && command -v nmcli >/dev/null 2>&1; then
    if [ ! -f /etc/network/interfaces ] || ! grep -q "$IFACE" /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null; then
      NET_BACKEND="nmcli"
    fi
  fi

  # Detectar porta SSH atual
  SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
  if [ -z "$SSH_PORT" ]; then
    SSH_PORT=$(grep -iE "^[[:space:]]*Port[[:space:]]+[0-9]+" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $NF; exit}')
  fi
  SSH_PORT=${SSH_PORT:-22}

  # Detectar IP externo configurado no Asterisk (PJSIP ou chan_sip)
  AST_EXT_IP=$(grep -h -iE "^[[:space:]]*(external_media_address|external_signaling_address|externip|externaddr)[[:space:]]*=" /etc/asterisk/*.conf 2>/dev/null | head -1 | cut -d'=' -f2 | cut -d';' -f1 | tr -d '[:space:]')
}

detectar_rede_atual

# =====================================================================
# Função de Auditoria de Referências ao IP Atual
# =====================================================================
auditar_referencias_ip() {
  local TARGET_IP="$1"
  titulo "AUDITORIA DE REFERÊNCIAS AO IP ($TARGET_IP)"

  info "1. Configuração de Rede do Sistema Operacional ($NET_BACKEND):"
  if [ "$NET_BACKEND" = "interfaces" ]; then
    local NET_FILES
    NET_FILES=$(grep -l "$TARGET_IP" /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null)
    if [ -n "$NET_FILES" ]; then
      for F in $NET_FILES; do
        ok "IP estático encontrado em: $F"
      done
    elif grep -qE "iface[[:space:]]+$IFACE[[:space:]]+inet[[:space:]]+dhcp" /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null; then
      warn "Interface $IFACE está configurada via DHCP em /etc/network/interfaces (será convertida para estático)."
    else
      warn "IP $TARGET_IP não listado diretamente em /etc/network/interfaces (a configuração estática de $IFACE será atualizada/criada)."
    fi
  elif [ "$NET_BACKEND" = "netplan" ]; then
    ok "Gerenciado via Netplan (/etc/netplan/*.yaml)"
  else
    ok "Gerenciado via NetworkManager (nmcli)"
  fi

  if grep -q "$TARGET_IP" /etc/hosts 2>/dev/null; then
    ok "Encontrado em /etc/hosts"
  else
    info "Nenhuma referência em /etc/hosts"
  fi

  echo ""
  info "2. Configurações do Asterisk (/etc/asterisk/*.conf):"
  local AST_FILES
  AST_FILES=$(grep -l "$TARGET_IP" /etc/asterisk/*.conf 2>/dev/null)
  if [ -n "$AST_FILES" ]; then
    for F in $AST_FILES; do
      ok "Referência ao IP em: $F"
    done
  else
    info "Nenhuma referência direta a $TARGET_IP em /etc/asterisk/*.conf"
  fi
  if [ -n "$AST_EXT_IP" ]; then
    info "IP externo SIP/PJSIP atual no Asterisk: $AST_EXT_IP"
  fi

  echo ""
  info "3. Banco de Dados MagnusBilling (mbilling):"
  if [ "$DB_READY" -eq 1 ]; then
    local CNT_SERVERS CNT_CONF CNT_DID
    CNT_SERVERS=$(mysql_run -N -e "SELECT COUNT(*) FROM pkg_servers WHERE host='$TARGET_IP';" 2>/dev/null || echo "0")
    CNT_CONF=$(mysql_run -N -e "SELECT COUNT(*) FROM pkg_configuration WHERE config_value LIKE '%$TARGET_IP%';" 2>/dev/null || echo "0")
    CNT_DID=$(mysql_run -N -e "SELECT COUNT(*) FROM pkg_did_destination WHERE destination LIKE '%@$TARGET_IP%';" 2>/dev/null || echo "0")
    echo "    • pkg_servers (host = $TARGET_IP):              $CNT_SERVERS registro(s)"
    echo "    • pkg_configuration (contendo $TARGET_IP):      $CNT_CONF registro(s)"
    echo "    • pkg_did_destination (SIP URI @$TARGET_IP):    $CNT_DID registro(s)"
  else
    warn "Banco de dados mbilling não acessível no momento para auditoria."
  fi

  echo ""
  info "4. Outros Serviços (Apache, Fail2ban, SSH):"
  if grep -q "$TARGET_IP" /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*.conf 2>/dev/null; then
    ok "Encontrado em /etc/fail2ban (ignoreip)"
  else
    info "Nenhuma referência em /etc/fail2ban"
  fi

  local APACHE_REFS
  APACHE_REFS=$(grep -l "$TARGET_IP" /etc/apache2/sites-available/*.conf /etc/apache2/conf-available/*.conf 2>/dev/null)
  if [ -n "$APACHE_REFS" ]; then
    for F in $APACHE_REFS; do
      ok "Referência no Apache: $F"
    done
  else
    info "Nenhuma referência fixa ao IP nos VirtualHosts do Apache"
  fi

  if grep -qE "^[[:space:]]*ListenAddress[[:space:]]+$TARGET_IP" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
    warn "ListenAddress fixo encontrado no sshd_config ($TARGET_IP) — será atualizado para o novo IP."
  else
    info "SSH escutando em todas as interfaces (0.0.0.0) na porta $SSH_PORT"
  fi
}

# =====================================================================
# Execução de Rollback (--revert ou Opção 2)
# =====================================================================
executar_rollback() {
  titulo "REVERTER PARA O IP ANTERIOR (ROLLBACK)"
  if [ -x "/root/reverter_ip.sh" ]; then
    info "Script de rollback encontrado em /root/reverter_ip.sh"
    echo ""
    grep -E "^# (IP_ANTERIOR|IP_ATUAL|DATA_BACKUP):" /root/reverter_ip.sh 2>/dev/null | sed 's/^# /  • /'
    echo ""
    confirma "Deseja executar o rollback agora e voltar o servidor para o IP anterior?"
    bash /root/reverter_ip.sh
    exit 0
  else
    erro "Nenhum backup/script de reversão (/root/reverter_ip.sh) foi encontrado neste servidor."
  fi
}

if [ "$REVERT_MODE" -eq 1 ]; then
  executar_rollback
fi

if [ "$DRY_RUN" -eq 1 ]; then
  clear
  titulo "SIMULAÇÃO E AUDITORIA DE TROCA DE IP (--dry-run)"
  echo "  • Interface principal:  $IFACE"
  echo "  • IPv4 atual:           $OLD_IP/$OLD_PREFIX (Máscara: $OLD_NETMASK)"
  echo "  • Gateway atual:        $OLD_GW"
  echo "  • DNS atual:            $OLD_DNS"
  echo "  • Gerenciador de rede:  $NET_BACKEND"
  echo "  • Porta SSH ativa:      $SSH_PORT"
  auditar_referencias_ip "$OLD_IP"
  echo ""
  ok "Simulação concluída (modo somente leitura — nenhuma alteração realizada)."
  exit 0
fi

# =====================================================================
# Menu Interativo Principal
# =====================================================================
clear
titulo "TROCA DE IP DO SERVIDOR (CUTOVER DE MIGRAÇÃO / PRODUÇÃO)"
echo ""
echo "  Resumo da Rede Atual deste Servidor:"
echo -e "    • Interface:          ${NEGRITO}$IFACE${NC}"
echo -e "    • IP Atual:           ${NEGRITO}$OLD_IP/$OLD_PREFIX${NC} (Máscara: $OLD_NETMASK)"
echo -e "    • Gateway Padrão:     ${NEGRITO}${OLD_GW:-Não detectado}${NC}"
echo -e "    • Servidores DNS:     ${NEGRITO}$OLD_DNS${NC}"
echo -e "    • Porta SSH:          ${NEGRITO}$SSH_PORT${NC}"
[ -n "$AST_EXT_IP" ] && echo -e "    • IP Externo SIP:     ${NEGRITO}$AST_EXT_IP${NC}"
echo ""
echo "  Escolha uma operação:"
echo -e "    ${NEGRITO}1)${NC} Trocar IP deste servidor (Assumir IP do servidor de produção desligado)"
echo -e "    ${NEGRITO}2)${NC} Reverter para o IP anterior (Rollback automático via /root/reverter_ip.sh)"
echo -e "    ${NEGRITO}3)${NC} Apenas auditar onde o IP atual ($OLD_IP) está configurado (Somente leitura)"
echo -e "    ${NEGRITO}0)${NC} Cancelar e voltar"
echo ""
read -p "  Opção [1]: " MENU_OPT
MENU_OPT=${MENU_OPT:-1}

case "$MENU_OPT" in
  1) ;;
  2) executar_rollback ;;
  3)
    auditar_referencias_ip "$OLD_IP"
    echo ""
    exit 0
    ;;
  0)
    info "Saindo sem alterações."
    exit 0
    ;;
  *)
    erro "Opção inválida."
    ;;
esac

# =====================================================================
# Coleta e Validação do Novo Endereço IP (Cutover)
# =====================================================================
titulo "1. PARÂMETROS DO NOVO IP (IP DE PRODUÇÃO)"
echo ""
info "Importante: A máquina de produção antiga deve ser DESLIGADA antes de aplicar o novo IP."
echo ""

while true; do
  read -p "  Novo endereço IPv4 do servidor (IP de produção): " NEW_IP
  NEW_IP=$(echo "$NEW_IP" | tr -d '[:space:]')
  if ! validar_ipv4 "$NEW_IP"; then
    warn "Endereço IPv4 inválido ('$NEW_IP'). Use o formato X.X.X.X."
    continue
  fi
  if [ "$NEW_IP" = "$OLD_IP" ]; then
    warn "O novo IP informado ($NEW_IP) é idêntico ao IP atual ($OLD_IP)."
    continue
  fi
  if [[ "$NEW_IP" =~ ^127\. ]] || [ "$NEW_IP" = "0.0.0.0" ]; then
    warn "Endereço reservado não permitido ($NEW_IP)."
    continue
  fi
  break
done

while true; do
  read -p "  Prefixo CIDR (ex: 24) ou Máscara [$OLD_PREFIX]: " INPUT_MASK
  INPUT_MASK=${INPUT_MASK:-$OLD_PREFIX}
  INPUT_MASK=$(echo "$INPUT_MASK" | tr -d '[:space:]/')
  if [[ "$INPUT_MASK" =~ ^[0-9]{1,2}$ ]] && [ "$INPUT_MASK" -ge 8 ] && [ "$INPUT_MASK" -le 32 ]; then
    NEW_PREFIX="$INPUT_MASK"
    NEW_NETMASK=$(prefix_para_netmask "$NEW_PREFIX")
    break
  elif validar_ipv4 "$INPUT_MASK"; then
    CONV_PREFIX=$(netmask_para_prefix "$INPUT_MASK")
    if [ -n "$CONV_PREFIX" ]; then
      NEW_PREFIX="$CONV_PREFIX"
      NEW_NETMASK="$INPUT_MASK"
      break
    fi
  fi
  warn "Informe um prefixo CIDR válido entre 8 e 32 (ex: 24) ou máscara (ex: 255.255.255.0)."
done

while true; do
  read -p "  Gateway padrão [$OLD_GW]: " NEW_GW
  NEW_GW=${NEW_GW:-$OLD_GW}
  NEW_GW=$(echo "$NEW_GW" | tr -d '[:space:]')
  if validar_ipv4 "$NEW_GW"; then
    break
  fi
  warn "Gateway inválido ('$NEW_GW'). Informe um IPv4 válido."
done

read -p "  Servidores DNS separados por espaço [$OLD_DNS]: " NEW_DNS
NEW_DNS=${NEW_DNS:-$OLD_DNS}

DEFAULT_AST_IP="$NEW_IP"
read -p "  IP Externo SIP/RTP no Asterisk (external_media_address/externip) [$DEFAULT_AST_IP]: " NEW_AST_IP
NEW_AST_IP=${NEW_AST_IP:-$DEFAULT_AST_IP}
NEW_AST_IP=$(echo "$NEW_AST_IP" | tr -d '[:space:]')
validar_ipv4 "$NEW_AST_IP" || erro "IP externo SIP/RTP inválido: $NEW_AST_IP"

# =====================================================================
# Verificação Anti-Conflito de IP na Rede (Ping / ARP)
# =====================================================================
titulo "2. VERIFICAÇÃO ANTI-CONFLITO NA REDE"

while true; do
  info "Verificando se o IP $NEW_IP está livre na rede (testando ICMP/ARP)..."
  CONFLITO_DETECTADO=0

  if ping -c 2 -W 1 "$NEW_IP" >/dev/null 2>&1; then
    CONFLITO_DETECTADO=1
  elif command -v arping >/dev/null 2>&1 && arping -c 2 -w 1 -I "$IFACE" "$NEW_IP" >/dev/null 2>&1; then
    CONFLITO_DETECTADO=1
  fi

  if [ "$CONFLITO_DETECTADO" -eq 1 ]; then
    echo ""
    warn "ALERTA CRÍTICO: O IP $NEW_IP ESTÁ RESPONDENDO NA REDE AGORA!"
    warn "Isso indica que o servidor de produção antigo AINDA ESTÁ LIGADO com este IP."
    warn "Trocar o IP agora causará conflito de IP (ARP duplicado) e queda das chamadas."
    echo ""
    echo "    [T] Testar novamente (desligue a máquina de produção antiga e escolha T)"
    echo "    [F] Forçar a troca mesmo assim (NÃO recomendado)"
    echo "    [C] Cancelar operação"
    read -p "  Escolha [T/f/c]: " RESP_CONFLITO
    RESP_CONFLITO=${RESP_CONFLITO:-T}
    case "$RESP_CONFLITO" in
      [Tt]) continue ;;
      [Ff])
        warn "Prosseguindo por decisão explícita do operador apesar de resposta no IP $NEW_IP."
        break
        ;;
      *)
        erro "Operação cancelada para evitar conflito de IP."
        ;;
    esac
  else
    ok "O IP $NEW_IP não respondeu na rede (máquina antiga desligada / IP livre para cutover)."
    break
  fi
done

# =====================================================================
# Auditoria e Resumo Antes da Confirmação
# =====================================================================
auditar_referencias_ip "$OLD_IP"

titulo "3. CONFIRMAÇÃO DO PLANO DE CUTOVER"
echo ""
echo -e "  • Interface de Rede:       ${NEGRITO}$IFACE${NC} ($NET_BACKEND)"
echo -e "  • Endereço IPv4:           ${AMARELO}$OLD_IP/$OLD_PREFIX${NC} ➔ ${VERDE}${NEGRITO}$NEW_IP/$NEW_PREFIX${NC} ($NEW_NETMASK)"
echo -e "  • Gateway Padrão:          ${AMARELO}$OLD_GW${NC} ➔ ${VERDE}$NEW_GW${NC}"
echo -e "  • Servidores DNS:          ${VERDE}$NEW_DNS${NC}"
echo -e "  • IP Externo Asterisk:     ${VERDE}$NEW_AST_IP${NC}"
echo -e "  • Script de Rollback:      ${NEGRITO}/root/reverter_ip.sh${NC} (gerado automaticamente)"
echo ""
warn "ATENÇÃO: Assim que o novo IP for ativado, sua conexão SSH atual em $OLD_IP cairá."
info "Você deverá reconectar imediatamente usando: ssh -p $SSH_PORT root@$NEW_IP"
echo ""
confirma "Confirma a execução da troca de IP de $OLD_IP para $NEW_IP agora?"

# =====================================================================
# Criação do Backup Completo e do Script /root/reverter_ip.sh
# =====================================================================
titulo "4. BACKUP DE SEGURANÇA E GERAÇÃO DO SCRIPT DE ROLLBACK"

BKP_DIR="/root/backup-troca-ip-$TIMESTAMP"
mkdir -p "$BKP_DIR/etc_asterisk" "$BKP_DIR/network" "$BKP_DIR/apache2"
chmod 700 "$BKP_DIR"

[ -f /etc/network/interfaces ] && cp -a /etc/network/interfaces "$BKP_DIR/network/"
[ -d /etc/network/interfaces.d ] && cp -a /etc/network/interfaces.d "$BKP_DIR/network/"
[ -d /etc/netplan ] && cp -a /etc/netplan "$BKP_DIR/network/"
[ -f /etc/hosts ] && cp -a /etc/hosts "$BKP_DIR/network/hosts"
cp -a /etc/asterisk/*.conf "$BKP_DIR/etc_asterisk/" 2>/dev/null || true
[ -f /etc/fail2ban/jail.local ] && cp -a /etc/fail2ban/jail.local "$BKP_DIR/network/jail.local"
[ -f /etc/ssh/sshd_config ] && cp -a /etc/ssh/sshd_config "$BKP_DIR/network/sshd_config"

cat << EOF_REVERT > /root/reverter_ip.sh
#!/bin/bash
# =====================================================================
# Script de Rollback Automático — Gerado por trocar_ip_servidor.sh
# DATA_BACKUP: $TIMESTAMP
# IP_ANTERIOR: $OLD_IP/$OLD_PREFIX (Gateway: $OLD_GW)
# IP_ATUAL:    $NEW_IP/$NEW_PREFIX (Gateway: $NEW_GW)
# =====================================================================
set -o pipefail
[ "\$EUID" -ne 0 ] && { echo "Execute como root: bash /root/reverter_ip.sh"; exit 1; }

echo "Restaurando configurações de rede e Asterisk de $BKP_DIR..."
[ -f "$BKP_DIR/network/interfaces" ] && cp -a "$BKP_DIR/network/interfaces" /etc/network/interfaces
[ -d "$BKP_DIR/network/interfaces.d" ] && cp -a "$BKP_DIR/network/interfaces.d/"* /etc/network/interfaces.d/ 2>/dev/null || true
[ -d "$BKP_DIR/network/netplan" ] && cp -a "$BKP_DIR/network/netplan/"* /etc/netplan/ 2>/dev/null || true
[ -f "$BKP_DIR/network/hosts" ] && cp -a "$BKP_DIR/network/hosts" /etc/hosts
[ -f "$BKP_DIR/network/jail.local" ] && cp -a "$BKP_DIR/network/jail.local" /etc/fail2ban/jail.local
[ -f "$BKP_DIR/network/sshd_config" ] && cp -a "$BKP_DIR/network/sshd_config" /etc/ssh/sshd_config
cp -a "$BKP_DIR/etc_asterisk/"*.conf /etc/asterisk/ 2>/dev/null || true

chown asterisk:asterisk /etc/asterisk/*_magnus*.conf 2>/dev/null || true
chmod 664 /etc/asterisk/*_magnus*.conf 2>/dev/null || true

echo "Revertendo banco mbilling de $NEW_IP para $OLD_IP..."
if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
  mysql -u root -D mbilling -e "
    UPDATE pkg_servers SET host='$OLD_IP' WHERE host='$NEW_IP';
    UPDATE pkg_configuration SET config_value=REPLACE(config_value, '$NEW_IP', '$OLD_IP') WHERE config_value LIKE '%$NEW_IP%';
    UPDATE pkg_did_destination SET destination=REPLACE(destination, '@$NEW_IP', '@$OLD_IP') WHERE destination LIKE '%@$NEW_IP%';
  " 2>/dev/null || true
elif [ -f /root/passwordMysql.log ]; then
  RPW=\$(cat /root/passwordMysql.log | tr -d '[:space:]')
  MYSQL_PWD="\$RPW" mysql -u root -D mbilling -e "
    UPDATE pkg_servers SET host='$OLD_IP' WHERE host='$NEW_IP';
    UPDATE pkg_configuration SET config_value=REPLACE(config_value, '$NEW_IP', '$OLD_IP') WHERE config_value LIKE '%$NEW_IP%';
    UPDATE pkg_did_destination SET destination=REPLACE(destination, '@$NEW_IP', '@$OLD_IP') WHERE destination LIKE '%@$NEW_IP%';
  " 2>/dev/null || true
fi

echo "Aplicando retorno do IP $OLD_IP/$OLD_PREFIX na interface $IFACE em segundo plano..."
nohup bash -c '
  sleep 1
  ip addr add "$OLD_IP/$OLD_PREFIX" dev "$IFACE" 2>/dev/null || true
  ip addr del "$NEW_IP/$NEW_PREFIX" dev "$IFACE" 2>/dev/null || true
  ip route replace default via "$OLD_GW" dev "$IFACE" 2>/dev/null || true
  if command -v netplan >/dev/null 2>&1 && ls /etc/netplan/*.y*ml >/dev/null 2>&1; then
    netplan apply 2>/dev/null || true
  fi
  systemctl restart asterisk apache2 fail2ban 2>/dev/null || true
' >> "$LOG_FILE" 2>&1 </dev/null &

echo "Rollback disparado! Reconecte em: ssh -p $SSH_PORT root@$OLD_IP"
EOF_REVERT

chmod 700 /root/reverter_ip.sh
ok "Backup salvo em $BKP_DIR"
ok "Script de rollback de emergência criado em /root/reverter_ip.sh"
log_msg "Backup criado em $BKP_DIR e script /root/reverter_ip.sh gerado ($OLD_IP -> $NEW_IP)."

# =====================================================================
# Atualização dos Arquivos de Configuração e Banco de Dados
# =====================================================================
titulo "5. ATUALIZANDO CONFIGURAÇÕES DO SISTEMA E MAGNUSBILLING"

# 5.1 Desativar sobrescrita de rede do Cloud-Init se existir
if [ -d /etc/cloud/cloud.cfg.d ]; then
  echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  ok "Cloud-init bloqueado para não sobrescrever o IP estático no próximo boot."
fi

# 5.2 Atualizar arquivos de rede do Linux
if [ "$NET_BACKEND" = "interfaces" ]; then
  NET_MODIFIED=0
  for NETF in /etc/network/interfaces /etc/network/interfaces.d/*; do
    [ -f "$NETF" ] || continue
    if grep -q "$OLD_IP" "$NETF" 2>/dev/null; then
      # Substitui IP antigo pelo novo IP
      sed -i "s/\b${OLD_IP//./\\.}\b/$NEW_IP/g" "$NETF"
      # Atualiza gateway se mudou
      if [ -n "$OLD_GW" ] && [ "$OLD_GW" != "$NEW_GW" ]; then
        sed -i "s/\b${OLD_GW//./\\.}\b/$NEW_GW/g" "$NETF"
      fi
      # Atualiza máscara pontilhada se mudou
      if [ "$OLD_NETMASK" != "$NEW_NETMASK" ]; then
        sed -i "s/\b${OLD_NETMASK//./\\.}\b/$NEW_NETMASK/g" "$NETF"
      fi
      # Atualiza sufixo CIDR se estava no formato address X.X.X.X/PREFIX
      sed -i "s|${NEW_IP}/${OLD_PREFIX}|${NEW_IP}/${NEW_PREFIX}|g" "$NETF"
      NET_MODIFIED=1
      ok "Arquivo de rede atualizado com o novo IP estático: $NETF"
    elif grep -qE "^[[:space:]]*iface[[:space:]]+$IFACE[[:space:]]+inet[[:space:]]+dhcp" "$NETF" 2>/dev/null; then
      # Converte interface DHCP em estática
      sed -i -E "s|^([[:space:]]*iface[[:space:]]+$IFACE[[:space:]]+inet[[:space:]]+)dhcp.*|\1static\n    address $NEW_IP/$NEW_PREFIX\n    gateway $NEW_GW\n    dns-nameservers $NEW_DNS|" "$NETF"
      NET_MODIFIED=1
      ok "Interface $IFACE convertida de DHCP para IP estático ($NEW_IP/$NEW_PREFIX) em $NETF"
    fi
  done

  if [ "$NET_MODIFIED" -eq 0 ]; then
    # Cria bloco estático limpo caso não estivesse declarado
    cat << EOF_IFACE >> /etc/network/interfaces

auto $IFACE
iface $IFACE inet static
    address $NEW_IP/$NEW_PREFIX
    gateway $NEW_GW
    dns-nameservers $NEW_DNS
EOF_IFACE
    ok "Bloco estático adicionado para $IFACE em /etc/network/interfaces"
  fi

elif [ "$NET_BACKEND" = "netplan" ]; then
  for NPF in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [ -f "$NPF" ] || continue
    if grep -q "$OLD_IP" "$NPF" 2>/dev/null; then
      sed -i "s|${OLD_IP}/${OLD_PREFIX}|${NEW_IP}/${NEW_PREFIX}|g" "$NPF"
      sed -i "s/\b${OLD_IP//./\\.}\b/$NEW_IP/g" "$NPF"
      if [ -n "$OLD_GW" ] && [ "$OLD_GW" != "$NEW_GW" ]; then
        sed -i "s/\b${OLD_GW//./\\.}\b/$NEW_GW/g" "$NPF"
      fi
      ok "Configuração Netplan atualizada: $NPF"
    fi
  done

elif [ "$NET_BACKEND" = "nmcli" ]; then
  NM_CON=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v dev="$IFACE" '$2 == dev {print $1; exit}')
  if [ -n "$NM_CON" ]; then
    nmcli connection modify "$NM_CON" ipv4.method manual ipv4.addresses "$NEW_IP/$NEW_PREFIX" ipv4.gateway "$NEW_GW" ipv4.dns "$NEW_DNS" >/dev/null 2>&1 || warn "Aviso ao atualizar perfil NetworkManager."
    ok "Perfil NetworkManager '$NM_CON' configurado para $NEW_IP/$NEW_PREFIX"
  fi
fi

# 5.3 Atualizar /etc/hosts e /etc/resolv.conf
if [ -f /etc/hosts ] && grep -q "$OLD_IP" /etc/hosts 2>/dev/null; then
  sed -i "s/\b${OLD_IP//./\\.}\b/$NEW_IP/g" /etc/hosts
  ok "Arquivo /etc/hosts atualizado ($OLD_IP ➔ $NEW_IP)."
fi

if [ -n "$NEW_DNS" ] && [ ! -L /etc/resolv.conf ]; then
  : > /etc/resolv.conf
  for DNS_SRV in $NEW_DNS; do
    echo "nameserver $DNS_SRV" >> /etc/resolv.conf
  done
  ok "Servidores DNS atualizados em /etc/resolv.conf ($NEW_DNS)."
fi

# 5.4 Atualizar Asterisk (PJSIP / chan_sip / RTP)
for ASTF in /etc/asterisk/*.conf; do
  [ -f "$ASTF" ] || continue
  CHANGED_AST=0
  if grep -q "$OLD_IP" "$ASTF" 2>/dev/null; then
    sed -i "s/\b${OLD_IP//./\\.}\b/$NEW_AST_IP/g" "$ASTF"
    CHANGED_AST=1
  fi
  if grep -qE "^[[:space:]]*(external_media_address|external_signaling_address|externip|externaddr)[[:space:]]*=" "$ASTF" 2>/dev/null; then
    sed -i -E "s|^([[:space:]]*(external_media_address|external_signaling_address|externip|externaddr)[[:space:]]*=[[:space:]]*)[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|\1$NEW_AST_IP|g" "$ASTF"
    CHANGED_AST=1
  fi
  [ "$CHANGED_AST" -eq 1 ] && ok "Asterisk atualizado ($NEW_AST_IP): $ASTF"
done

# Garantir permissões obrigatórias 664 nos *_magnus*.conf (Bug 2 MAGNUS_BUGS.md)
chown asterisk:asterisk /etc/asterisk/*_magnus*.conf 2>/dev/null || true
chmod 664 /etc/asterisk/*_magnus*.conf 2>/dev/null || true
usermod -aG asterisk www-data 2>/dev/null || true
ok "Permissões 664 (asterisk:asterisk) garantidas em /etc/asterisk/*_magnus*.conf"

# 5.5 Atualizar Banco de Dados mbilling
if [ "$DB_READY" -eq 1 ]; then
  mysql_run -e "
    UPDATE pkg_servers SET host='$NEW_IP' WHERE host='$OLD_IP';
    UPDATE pkg_configuration SET config_value=REPLACE(config_value, '$OLD_IP', '$NEW_IP') WHERE config_value LIKE '%$OLD_IP%';
    UPDATE pkg_did_destination SET destination=REPLACE(destination, '@$OLD_IP', '@$NEW_IP') WHERE destination LIKE '%@$OLD_IP%';
  " 2>/dev/null && ok "Referências ao IP atualizadas no banco mbilling (pkg_servers, pkg_configuration, pkg_did_destination)." || warn "Aviso ao atualizar referências no banco mbilling."
fi

# 5.6 Atualizar Fail2ban, Apache e SSH (se referenciavam o IP antigo)
for F2BF in /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*.conf; do
  [ -f "$F2BF" ] || continue
  if grep -q "$OLD_IP" "$F2BF" 2>/dev/null; then
    sed -i "s/\b${OLD_IP//./\\.}\b/$NEW_IP/g" "$F2BF"
    ok "Fail2ban atualizado ($OLD_IP ➔ $NEW_IP): $F2BF"
  fi
done

for APF in /etc/apache2/sites-available/*.conf /etc/apache2/conf-available/*.conf; do
  [ -f "$APF" ] || continue
  if grep -q "$OLD_IP" "$APF" 2>/dev/null; then
    sed -i "s/\b${OLD_IP//./\\.}\b/$NEW_IP/g" "$APF"
    ok "Configuração do Apache atualizada: $APF"
  fi
done

for SSHF in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
  [ -f "$SSHF" ] || continue
  if grep -qE "^[[:space:]]*ListenAddress[[:space:]]+$OLD_IP" "$SSHF" 2>/dev/null; then
    sed -i "s/\b${OLD_IP//./\\.}\b/$NEW_IP/g" "$SSHF"
    ok "ListenAddress do SSH atualizado em: $SSHF"
  fi
done

log_msg "Arquivos e banco atualizados de $OLD_IP para $NEW_IP. Disparando transição da interface $IFACE."

# =====================================================================
# Transição Atômica da Interface de Rede em Background (imune a queda SSH)
# =====================================================================
titulo "6. APLICANDO NOVO IP E REINICIANDO SERVIÇOS"
echo ""
echo -e "  ${VERDE}${NEGRITO}✓ TODAS AS CONFIGURAÇÕES FORAM SALVAS COM SUCESSO!${NC}"
echo ""
echo -e "  A troca da placa de rede (${AMARELO}$OLD_IP${NC} ➔ ${VERDE}${NEGRITO}$NEW_IP${NC}) será executada em ${NEGRITO}3 segundos${NC}."
echo "  Sua sessão SSH atual ficará congelada/desconectada assim que o IP mudar."
echo ""
echo -e "  ${NEGRITO}👉 RECONECTE IMEDIATAMENTE NO NOVO IP:${NC}"
echo -e "     ${VERDE}${NEGRITO}ssh -p $SSH_PORT root@$NEW_IP${NC}"
echo ""
echo -e "  ${NEGRITO}🔄 SE PRECISAR REVERTER (via console KVM/Proxmox ou SSH):${NC}"
echo -e "     ${AMARELO}bash /root/reverter_ip.sh${NC}"
echo ""

nohup bash -c "
  sleep 3
  echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Iniciando transição de rede em $IFACE: $OLD_IP -> $NEW_IP\" >> \"$LOG_FILE\"

  # Encerra cliente DHCP caso a máquina tivesse subido via DHCP inicialmente
  pkill -f \"dhclient.*$IFACE\" 2>/dev/null || true
  pkill -f \"dhcpcd.*$IFACE\" 2>/dev/null || true

  # Adiciona o novo IP e gateway e remove o IP antigo da interface
  ip addr add \"$NEW_IP/$NEW_PREFIX\" dev \"$IFACE\" 2>>\"$LOG_FILE\" || true
  ip route replace default via \"$NEW_GW\" dev \"$IFACE\" 2>>\"$LOG_FILE\" || true
  ip addr del \"$OLD_IP/$OLD_PREFIX\" dev \"$IFACE\" 2>>\"$LOG_FILE\" || true

  if [ \"$NET_BACKEND\" = \"netplan\" ] && command -v netplan >/dev/null 2>&1; then
    netplan apply >>\"$LOG_FILE\" 2>&1 || true
  elif [ \"$NET_BACKEND\" = \"nmcli\" ] && command -v nmcli >/dev/null 2>&1; then
    nmcli device reapply \"$IFACE\" >>\"$LOG_FILE\" 2>&1 || true
  fi

  # Envia Gratuitous ARP para atualizar imediatamente o switch / bridge Proxmox / roteador
  if command -v arping >/dev/null 2>&1; then
    arping -c 3 -A -I \"$IFACE\" \"$NEW_IP\" >>\"$LOG_FILE\" 2>&1 || true
    arping -c 3 -U -I \"$IFACE\" \"$NEW_IP\" >>\"$LOG_FILE\" 2>&1 || true
  fi
  ping -c 2 -W 1 \"$NEW_GW\" >>\"$LOG_FILE\" 2>&1 || true

  # Reinicia serviços para assumirem o novo socket/IP
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  systemctl restart mariadb 2>>\"$LOG_FILE\" || true
  systemctl restart apache2 2>>\"$LOG_FILE\" || true
  systemctl restart asterisk 2>>\"$LOG_FILE\" || true
  systemctl restart fail2ban 2>>\"$LOG_FILE\" || true

  echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Cutover de IP concluído com sucesso para $NEW_IP.\" >> \"$LOG_FILE\"
" >>"$LOG_FILE" 2>&1 </dev/null &
disown 2>/dev/null || true

exit 0

