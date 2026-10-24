#!/bin/bash
# =====================================================================
# Magnus Utilities — blindar_ssh_magnus.sh
# Versão: 1.0 (24 de outubro de 2026)
# Função: Restringir o acesso SSH exclusivamente aos IPs cadastrados
#         (bloqueia/evita a conexão no firewall para qualquer IP não autorizado)
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root via SSH
#   - Firewalld ou IPtables ativo
#
# Uso: bash blindar_ssh_magnus.sh
# =====================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="$SCRIPT_DIR/../lib/common.sh"
if [ -f "$COMMON_LIB" ]; then
    source "$COMMON_LIB"
elif [ -f "/opt/magnus-utils/scripts/lib/common.sh" ]; then
    source "/opt/magnus-utils/scripts/lib/common.sh"
else
    VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'; AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
    ok() { echo -e "  ${VERDE}✓${NC} $1"; }
    info() { echo -e "  ${AZUL}➜${NC} $1"; }
    warn() { echo -e "  ${AMARELO}⚠${NC} $1"; }
    erro() { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
    titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }
    confirma() {
        read -p "  $1 [s/N]: " RESP
        [[ "$RESP" =~ ^[Ss]$ ]] || erro "Operação cancelada pelo usuário."
    }
fi

[ "$EUID" -ne 0 ] && erro "Este script deve ser executado como root."

clear
titulo "BLINDAGEM DE ACESSO SSH (POR IP CADASTRADO)"

echo ""
info "Este utilitário bloqueia a porta SSH no firewall para qualquer visitante não cadastrado."
info "Diferente da web (que exibe página de bloqueio), o SSH ${NEGRITO}evita e descarta a conexão${NC},"
info "impedindo scanners de porta, ataques de força bruta e tentativas de autenticação."
echo ""

# ---------------------------------------------------------------------
# 1. Identificar Porta SSH Atual
# ---------------------------------------------------------------------
SSH_PORT=$(grep -iE "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
SSH_PORT=${SSH_PORT:-22}
info "Porta SSH detectada no sistema: ${NEGRITO}$SSH_PORT${NC}"

# ---------------------------------------------------------------------
# 2. Coleta dos IPs Autorizados
# ---------------------------------------------------------------------
MY_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
[ -z "$MY_IP" ] && MY_IP="127.0.0.1"

info "Seu IP atual conectado neste momento: ${NEGRITO}$MY_IP${NC}"
echo ""

read -p "  IP/Bloco autorizado 1 [$MY_IP]: " B1
B1=${B1:-$MY_IP}
[ -z "$B1" ] && erro "Informe ao menos um IP ou bloco CIDR autorizado."

ALLOWED_IPS="$B1"
while true; do
    read -p "  Outro IP/Bloco autorizado (ENTER para encerrar): " BX
    [ -z "$BX" ] && break
    ALLOWED_IPS="$ALLOWED_IPS $BX"
done

echo ""
titulo "RESUMO DA BLINDAGEM SSH"
echo "  Porta protegida:     TCP $SSH_PORT"
echo "  IPs com permissão:   $ALLOWED_IPS"
echo "  Demais conexões:     Descartadas/bloqueadas no firewall (sem acesso)"
echo ""
confirma "Deseja aplicar a blindagem no firewall agora?"

# ---------------------------------------------------------------------
# 3. Aplicação no Firewall (Firewalld ou IPtables)
# ---------------------------------------------------------------------
titulo "1. Aplicando regras de firewall"

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    info "Firewall ativo detectado: firewalld (padrão Debian/Magnus)"

    # Backup do estado atual do firewalld
    BKP_FW_DIR="/root/firewalld-ssh-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BKP_FW_DIR"
    cp -rp /etc/firewalld/zones "$BKP_FW_DIR/" 2>/dev/null || true

    # Função de reversão em caso de emergência
    reverter_firewalld() {
        warn "Restaurando configurações anteriores do firewall..."
        cp -rp "$BKP_FW_DIR/zones/"* /etc/firewalld/zones/ 2>/dev/null || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        ok "Configurações restauradas com sucesso."
    }

    # 1. Adicionar rich-rules de permissão para os IPs autorizados
    for IP_AUTH in $ALLOWED_IPS; do
        info "Liberando porta $SSH_PORT para o IP $IP_AUTH..."
        firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$IP_AUTH\" port port=\"$SSH_PORT\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$IP_AUTH\" port port=\"$SSH_PORT\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
        if [ "$SSH_PORT" != "22022" ]; then
            firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$IP_AUTH\" port port=\"22022\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
            firewall-cmd --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$IP_AUTH\" port port=\"22022\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
        fi
    done

    # 2. Remover permissão global irrestrita da porta SSH
    info "Removendo acesso SSH irrestrito da zona pública..."
    firewall-cmd --permanent --zone=public --remove-service=ssh >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=public --remove-port=22/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=public --remove-port=22022/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=public --remove-port="${SSH_PORT}/tcp" >/dev/null 2>&1 || true

    firewall-cmd --zone=public --remove-service=ssh >/dev/null 2>&1 || true
    firewall-cmd --zone=public --remove-port=22/tcp >/dev/null 2>&1 || true
    firewall-cmd --zone=public --remove-port=22022/tcp >/dev/null 2>&1 || true
    firewall-cmd --zone=public --remove-port="${SSH_PORT}/tcp" >/dev/null 2>&1 || true

    ok "Regras aplicadas no firewalld (runtime e permanente)."

elif command -v iptables >/dev/null 2>&1; then
    info "Firewall ativo detectado: iptables"

    BKP_IPT="/root/iptables-backup-$(date +%Y%m%d_%H%M%S).v4"
    iptables-save > "$BKP_IPT"

    reverter_iptables() {
        warn "Restaurando regras do iptables..."
        iptables-restore < "$BKP_IPT"
        ok "Regras restauradas."
    }

    # Garante conexões estabelecidas
    iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Insere permissões para IPs autorizados
    for IP_AUTH in $ALLOWED_IPS; do
        iptables -I INPUT 2 -p tcp --dport "$SSH_PORT" -s "$IP_AUTH" -j ACCEPT
    done

    # Bloqueia qualquer outro acesso na porta SSH
    iptables -A INPUT -p tcp --dport "$SSH_PORT" -j DROP

    ok "Regras aplicadas no iptables."
else
    erro "Nenhum sistema de firewall suportado (firewalld ou iptables) foi localizado."
fi

# ---------------------------------------------------------------------
# 4. Deadman Switch — Proteção Anti-Bloqueio Acidental
# ---------------------------------------------------------------------
echo ""
titulo "TESTE DE CONECTIVIDADE (PROTEÇÃO ANTI-BLOQUEIO)"
warn "A blindagem está ativa agora em runtime."
warn "Por segurança, abra um novo terminal ou teste uma nova conexão a partir do seu IP autorizado."
echo ""

read -t 300 -p "  Você confirma que o acesso SSH continua funcionando normalmente? [s/N] (300s / 5 min timeout): " CONFIRMA_OK || true

if [[ ! "$CONFIRMA_OK" =~ ^[Ss]$ ]]; then
    echo ""
    warn "Tempo esgotado (5 minutos) ou resposta negativa recebida!"
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        reverter_firewalld
    else
        reverter_iptables
    fi
    erro "A blindagem foi revertida por segurança. Você não perdeu o acesso."
fi

# ---------------------------------------------------------------------
# 5. Conclusão
# ---------------------------------------------------------------------
echo ""
titulo "BLINDAGEM SSH CONCLUÍDA COM SUCESSO"
echo ""
echo -e "  ${VERDE}${NEGRITO}✓ Porta SSH $SSH_PORT restrita exclusivamente aos IPs autorizados${NC}"
echo ""
echo "  IPs liberados:  $ALLOWED_IPS"
echo "  Demais IPs:     Conexão evitada (bloqueada/dropada no firewall)"
echo ""
exit 0
