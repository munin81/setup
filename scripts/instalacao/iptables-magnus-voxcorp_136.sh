#!/bin/bash
# Iptables Magnus + Voxcorp - Servidor 136
# Baseado em: https://wiki.magnusbilling.org/pt-br/source/security/iptables.html
# Customizações Voxcorp: SSH 22022, blocos 190.89.250.0/24 e 186.194.49.0/24,
# MySQL 3306 para API N8N, sem firewalld, deadman switch via 'at'

set -e

VOXCORP_BLOCK_1="190.89.250.0/24"
VOXCORP_BLOCK_2="186.194.49.0/24"

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

echo "[5/15] SSH 22022 só dos blocos Voxcorp..."
iptables -A INPUT -p tcp --dport 22022 -s $VOXCORP_BLOCK_1 -j ACCEPT
iptables -A INPUT -p tcp --dport 22022 -s $VOXCORP_BLOCK_2 -j ACCEPT

echo "[6/15] MySQL 3306 só dos blocos Voxcorp (API N8N)..."
iptables -A INPUT -p tcp --dport 3306 -s $VOXCORP_BLOCK_1 -j ACCEPT
iptables -A INPUT -p tcp --dport 3306 -s $VOXCORP_BLOCK_2 -j ACCEPT

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
echo "✓ Script concluído. Deadman switch agendado em script separado."
