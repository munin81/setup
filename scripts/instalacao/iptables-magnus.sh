#!/bin/bash
# Iptables Magnus + Admin - Servidor 136
# Baseado em: https://wiki.magnusbilling.org/pt-br/source/security/iptables.html
# Customizações Admin interativas e seguras

set -e

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
iptables -A INPUT -p tcp --dport 22022 -s $ADMIN_BLOCK_1 -j ACCEPT
if [ -n "$ADMIN_BLOCK_2" ]; then
    iptables -A INPUT -p tcp --dport 22022 -s $ADMIN_BLOCK_2 -j ACCEPT
fi

echo "[6/15] MySQL 3306 só dos blocos Admin (API N8N)..."
iptables -A INPUT -p tcp --dport 3306 -s $ADMIN_BLOCK_1 -j ACCEPT
if [ -n "$ADMIN_BLOCK_2" ]; then
    iptables -A INPUT -p tcp --dport 3306 -s $ADMIN_BLOCK_2 -j ACCEPT
fi

echo "[7/15] HTTP 80 público..."
iptables -A INPUT -p tcp --dport 80 -j ACCEPT

echo "[8/15] HTTPS 443 público..."
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

echo "[9/15] SIP UDP 5060..."
iptables -A INPUT -p udp --dport 5060 -j ACCEPT

echo "[10/15] RTP UDP 10000-20000..."
iptables -A INPUT -p udp --dport 10000:20000 -j ACCEPT

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

echo ""
echo "✓ Script concluído e regras consolidadas com segurança!"
