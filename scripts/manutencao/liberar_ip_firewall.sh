#!/bin/bash
# =====================================================================
# Magnus Utilities — liberar_ip_firewall.sh
# Versão: 1.0 (23/10/2026)
# Função: Libera IP no firewall (firewalld/iptables) e fail2ban para migração e SSH
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos: Executar como root no servidor de origem (MB7) ou destino
# Uso: bash liberar_ip_firewall.sh [IP] [--all]
#
# Idempotência: SIM
# Modifica estado: SIM (adiciona regras de liberação no firewall)
# Requer janela de manutenção: NÃO
# =====================================================================

set -e

[ "$EUID" -ne 0 ] && { echo "Execute como root."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="$SCRIPT_DIR/../lib/common.sh"
[ -f "$COMMON_LIB" ] && source "$COMMON_LIB" || {
  VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'; AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
  ok()    { echo -e "  ${VERDE}✓${NC} $1"; }
  warn()  { echo -e "  ${AMARELO}⚠${NC} $1"; }
  erro()  { echo -e "  ${VERMELHO}✗${NC} $1"; exit 1; }
  info()  { echo -e "  ${AZUL}ℹ${NC} $1"; }
  titulo(){ echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }
}

titulo "LIBERAR IP NO FIREWALL (SSH / MIGRAÇÃO)"

# Validação IPv4 / CIDR
valida_ip() {
  echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
}

LIB_IP="$1"

while [ -z "$LIB_IP" ] || ! valida_ip "$LIB_IP"; do
  if [ -n "$LIB_IP" ]; then
    warn "IP ou bloco inválido: '$LIB_IP'"
  fi
  read -p "  Informe o IP do outro servidor a ser liberado (ex: IP do MB8): " LIB_IP
  LIB_IP=$(echo "$LIB_IP" | tr -d ' ')
done

echo ""
info "Selecione o nível de liberação para o IP ${NEGRITO}$LIB_IP${NC}:"
echo "  1) SSH (portas 22 e 22022) — [Recomendado para migração]"
echo "  2) Acesso Total (todas as portas / Zona de Confiança) — [Ideal entre servidores confiáveis]"
echo "  3) SSH + MySQL (portas 22, 22022 e 3306) — [Migração + DBeaver/Admin]"
echo ""
read -p "  Escolha a opção [1-3, padrão 1]: " OPCAO_PORTA
OPCAO_PORTA=${OPCAO_PORTA:-1}

# ---------------------------------------------------------------------
# 1. Desbloquear no Fail2ban (se instalado e ativo)
# ---------------------------------------------------------------------
if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active fail2ban >/dev/null 2>&1; then
  info "Verificando se o IP $LIB_IP está bloqueado no Fail2ban..."
  fail2ban-client unbanip "$LIB_IP" >/dev/null 2>&1 || true
  ok "Fail2ban verificado (IP desbloqueado se estava em ban)."
fi

# ---------------------------------------------------------------------
# 2. Aplicar no Firewalld (se instalado e ativo)
# ---------------------------------------------------------------------
APLICOU=0

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
  info "firewalld detectado ativo — aplicando regras permanentes..."

  case "$OPCAO_PORTA" in
    1)
      firewall-cmd --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$LIB_IP\" port port=\"22\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$LIB_IP\" port port=\"22\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      firewall-cmd --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$LIB_IP\" port port=\"22022\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$LIB_IP\" port port=\"22022\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      ok "Portas 22 e 22022/tcp liberadas para $LIB_IP no firewalld (runtime e permanente)."
      ;;
    2)
      firewall-cmd --zone=trusted --add-source="$LIB_IP" >/dev/null 2>&1 || true
      firewall-cmd --permanent --zone=trusted --add-source="$LIB_IP" >/dev/null 2>&1 || true
      ok "IP $LIB_IP adicionado à zona 'trusted' (acesso total) no firewalld (runtime e permanente)."
      ;;
    3)
      firewall-cmd --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$LIB_IP\" port port=\"22\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$LIB_IP\" port port=\"22\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      firewall-cmd --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$LIB_IP\" port port=\"22022\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$LIB_IP\" port port=\"22022\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      firewall-cmd --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$LIB_IP\" port port=\"3306\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$LIB_IP\" port port=\"3306\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      ok "Portas 22, 22022 e 3306/tcp liberadas para $LIB_IP no firewalld (runtime e permanente)."
      ;;
    *)
      erro "Opção inválida."
      ;;
  esac

  APLICOU=1
fi

# ---------------------------------------------------------------------
# 3. Aplicar no IPtables (APENAS se o firewalld não estiver ativo)
# ---------------------------------------------------------------------
if [ $APLICOU -eq 0 ] && command -v iptables >/dev/null 2>&1; then
  info "Aplicando regra no iptables..."
  case "$OPCAO_PORTA" in
    1)
      iptables -C INPUT -p tcp -s "$LIB_IP" --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s "$LIB_IP" --dport 22 -j ACCEPT
      iptables -C INPUT -p tcp -s "$LIB_IP" --dport 22022 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s "$LIB_IP" --dport 22022 -j ACCEPT
      ok "Portas 22 e 22022/tcp liberadas no iptables."
      ;;
    2)
      iptables -C INPUT -s "$LIB_IP" -j ACCEPT 2>/dev/null || iptables -I INPUT -s "$LIB_IP" -j ACCEPT
      ok "Acesso total liberado para $LIB_IP no iptables."
      ;;
    3)
      iptables -C INPUT -p tcp -s "$LIB_IP" --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s "$LIB_IP" --dport 22 -j ACCEPT
      iptables -C INPUT -p tcp -s "$LIB_IP" --dport 22022 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s "$LIB_IP" --dport 22022 -j ACCEPT
      iptables -C INPUT -p tcp -s "$LIB_IP" --dport 3306 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s "$LIB_IP" --dport 3306 -j ACCEPT
      ok "Portas 22, 22022 e 3306/tcp liberadas no iptables."
      ;;
  esac

  # Persistir se rules.v4 existir
  if [ -f /etc/iptables/rules.v4 ]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ok "Regras salvas em /etc/iptables/rules.v4."
  fi
  APLICOU=1
fi

[ $APLICOU -eq 0 ] && warn "Nenhum firewall ativo detectado neste servidor. Verifique suas regras manualmente."

# ---------------------------------------------------------------------
# Resumo Final
# ---------------------------------------------------------------------
titulo "IP LIBERADO COM SUCESSO"
echo ""
echo -e "  O IP ${NEGRITO}$LIB_IP${NC} agora tem permissão de conexão neste servidor."
echo ""
echo "  Para testar a partir do outro servidor (MB8):"
echo "    ssh -p 22022 root@<IP_DESTE_SERVIDOR>"
echo "    (ou porta 22 se o SSH ainda estiver na porta padrão)"
echo ""
exit 0
