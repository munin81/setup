#!/bin/bash
# =====================================================================
# Magnus Utilities — iptables-magnus.sh
# Versão: 2.0 (19 de junho de 2026)
# Função: Blindagem de firewall (iptables) com proteção anti-lockout
# Autor: Comunidade MagnusBilling
# Baseado em: https://wiki.magnusbilling.org/pt-br/source/security/iptables.html
#
# Pré-requisitos:
#   - Rodar como root, via SSH (deadman switch usa a conexão atual)
#
# Uso: bash iptables-magnus.sh
#
# Idempotência: SIM (zera e reaplica todas as regras a cada execução)
# Modifica estado: SIM (regras iptables + persistência em /etc/iptables/rules.v4)
# Requer janela de manutenção: recomendado console KVM aberto
#
# Mudanças v2.0 (junho 2026):
#   [1] Faixa RTP corrigida para 10000-60000 (antes 10000-20000 cortava áudio)
#   [2] Regras agora PERSISTEM no reboot (iptables-persistent / rules.v4)
#       — antes eram perdidas e o servidor voltava aberto após reiniciar
#   [3] Cabeçalho padrão Magnus Utilities
# =====================================================================

set -e

[ "$EUID" -ne 0 ] && { echo "Rode como root"; exit 1; }

# Detecta o IP atual do usuário que está rodando o script
MY_IP=$(echo $SSH_CLIENT | awk '{ print $1}')
if [ -z "$MY_IP" ]; then
    MY_IP="IP_DESCONHECIDO"
fi

echo "--- AVISO DE SEGURANÇA ---"
echo "Seu IP atual conectado no SSH é: $MY_IP"
echo "O script exigirá IPs ou blocos autorizados (Ex: 1.2.3.4 ou 1.2.3.0/24)."
echo ""

read -p "Informe o Bloco/IP Admin 1 [Ex: $MY_IP]: " ADMIN_BLOCK_1
ADMIN_BLOCK_1=${ADMIN_BLOCK_1:-$MY_IP}

read -p "Informe o Bloco/IP Admin 2 [Opcional, Enter para pular]: " ADMIN_BLOCK_2

# Validação IPv4/CIDR — impede injeção de comando via -s (entrada não confiável)
valida_bloco() { echo "$1" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$'; }
valida_bloco "$ADMIN_BLOCK_1" || { echo "ERRO: Bloco/IP Admin 1 inválido ('$ADMIN_BLOCK_1'). Use IPv4 ou CIDR."; exit 1; }
if [ -n "$ADMIN_BLOCK_2" ]; then
    valida_bloco "$ADMIN_BLOCK_2" || { echo "ERRO: Bloco/IP Admin 2 inválido ('$ADMIN_BLOCK_2'). Use IPv4 ou CIDR."; exit 1; }
fi

echo "[1/15] Limpando regras existentes e setando policy ACCEPT temporária..."
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F
iptables -X
iptables -Z

echo "[2/15] Loopback ACCEPT..."
iptables -A INPUT -i lo -j ACCEPT

echo "[3/15] ESTABLISHED,RELATED ACCEPT (mantém SSH atual vivo)..."
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

echo "[4/15] ICMP echo-request ACCEPT..."
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

echo "[5/15] SSH 22022 só dos blocos Admin..."
iptables -A INPUT -p tcp --dport 22022 -s "$ADMIN_BLOCK_1" -j ACCEPT
if [ -n "$ADMIN_BLOCK_2" ]; then
    iptables -A INPUT -p tcp --dport 22022 -s "$ADMIN_BLOCK_2" -j ACCEPT
fi

echo "[6/15] MySQL 3306 só dos blocos Admin (API)..."
iptables -A INPUT -p tcp --dport 3306 -s "$ADMIN_BLOCK_1" -j ACCEPT
if [ -n "$ADMIN_BLOCK_2" ]; then
    iptables -A INPUT -p tcp --dport 3306 -s "$ADMIN_BLOCK_2" -j ACCEPT
fi

echo "[7/15] HTTP 80 público..."
iptables -A INPUT -p tcp --dport 80 -j ACCEPT

echo "[8/15] HTTPS 443 público..."
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

echo "[9/15] SIP UDP 5060..."
iptables -A INPUT -p udp --dport 5060 -j ACCEPT

echo "[10/15] RTP UDP 10000-60000..."
iptables -A INPUT -p udp --dport 10000:60000 -j ACCEPT

echo "[11/15] IAX UDP 4569..."
iptables -A INPUT -p udp --dport 4569 -j ACCEPT

echo "[12/15] Anti-scanner SIP (friendly-scanner + VaxSIPUserAgent)..."
iptables -I INPUT -p tcp --dport 5060 -m string --string "friendly-scanner" --algo bm -j DROP
iptables -I INPUT -p tcp --dport 5080 -m string --string "friendly-scanner" --algo bm -j DROP
iptables -I INPUT -p udp --dport 5060 -m string --string "friendly-scanner" --algo bm -j DROP
iptables -I INPUT -p udp --dport 5080 -m string --string "friendly-scanner" --algo bm -j DROP
iptables -I INPUT -p tcp --dport 5060 -m string --string "VaxSIPUserAgent" --algo bm -j DROP
iptables -I INPUT -p tcp --dport 5080 -m string --string "VaxSIPUserAgent" --algo bm -j DROP
iptables -I INPUT -p udp --dport 5060 -m string --string "VaxSIPUserAgent" --algo bm -j DROP
iptables -I INPUT -p udp --dport 5080 -m string --string "VaxSIPUserAgent" --algo bm -j DROP

echo "[13/15] Policy INPUT DROP..."
iptables -P INPUT DROP

echo "[14/15] Policy FORWARD DROP..."
iptables -P FORWARD DROP

echo "[15/15] Policy OUTPUT ACCEPT..."
iptables -P OUTPUT ACCEPT

echo ""
echo "=== REGRAS APLICADAS ==="
iptables -L INPUT -n --line-numbers
echo ""
echo "--------------------------------------------------------"
echo "!! DEADMAN SWITCH (PROTEÇÃO DE AUTO-BLOQUEIO) !!"
echo "Verifique se a sua conexão SSH continua funcionando (abra outro terminal)."
echo "Você tem 30 segundos para confirmar, senão o firewall será ZERADO!"
echo "--------------------------------------------------------"

read -t 30 -p "As regras estão OK? [s/N]: " CONFIRM_FIREWALL || true

if [[ ! "$CONFIRM_FIREWALL" =~ ^[Ss]$ ]]; then
    echo ""
    echo "Tempo esgotado ou operação negada! Fazendo ROLLBACK (Limpando o firewall)..."
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -F
    echo "Firewall zerado. Seu acesso foi recuperado."
    exit 1
fi

# ---------------------------------------------------------------------
# PERSISTÊNCIA — regras sobrevivem ao reboot
# Sem isto, após reiniciar a policy volta a ACCEPT e o servidor fica aberto.
# ---------------------------------------------------------------------
echo ""
echo "Persistindo regras para sobreviver a reboot..."
set +e
if ! command -v netfilter-persistent >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null
    apt-get update -y >/dev/null 2>&1
    apt-get install -y iptables-persistent >/dev/null 2>&1
fi
mkdir -p /etc/iptables
if iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    echo "✓ Regras persistidas em /etc/iptables/rules.v4 (carregadas no boot)"
else
    echo "⚠ Não foi possível persistir as regras automaticamente."
    echo "  Salve manualmente: iptables-save > /etc/iptables/rules.v4"
fi
set -e

echo ""
echo "✓ Script concluído e regras consolidadas com segurança!"
