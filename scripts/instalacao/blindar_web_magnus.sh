#!/bin/bash
# =====================================================================
# Magnus Utilities — blindar_web_magnus.sh
# Versão: 1.0 (19 de junho de 2026)
# Função: Restringir o acesso WEB ao painel MagnusBilling a um ou mais
#         IPs/blocos autorizados, exibindo uma página "Acesso Não
#         Autorizado" para todos os demais visitantes.
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#   - Apache2 instalado (Debian 10/11, Apache 2.4)
#   - MagnusBilling em /var/www/html/mbilling
#
# Uso: bash blindar_web_magnus.sh
#
# Idempotência: SIM (reaplica a configuração; pode rodar várias vezes)
# Modifica estado: SIM (configs do Apache + página de bloqueio)
# Requer janela de manutenção: NÃO (mas recomenda-se acesso SSH ativo)
#
# IMPORTANTE — corrige o defeito da blindagem antiga:
#   A blindagem por VirtualHost de domínio NÃO impedia o acesso direto
#   pelo IP do servidor (o VirtualHost default servia o mesmo conteúdo).
#   Esta versão fecha os DOIS caminhos:
#     1) <Directory> global em conf-enabled (vale para todo VirtualHost
#        por especificidade — domínio E IP direto)
#     2) Neutraliza "Require all granted" nos vhosts que servem o painel
#        (inclusive o 000-default que responde pelo IP)
# =====================================================================

set -o pipefail

# ---------------------------------------------------------------------
# Cores e logs
# ---------------------------------------------------------------------
VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
ok()    { echo -e "  ${VERDE}✓${NC} $1"; }
info()  { echo -e "  ${AZUL}➜${NC} $1"; }
warn()  { echo -e "  ${AMARELO}⚠${NC} $1"; }
erro()  { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
titulo(){ echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }

[ "$EUID" -ne 0 ] && erro "Rode como root"
command -v apache2ctl >/dev/null 2>&1 || erro "Apache2 não encontrado neste servidor"
[ ! -d /var/www/html/mbilling ] && warn "/var/www/html/mbilling não encontrado — confirme se o Magnus está instalado"

clear
titulo "BLINDAR ACESSO WEB DO PAINEL MAGNUS (por IP)"
echo ""
info "Este script tranca o painel web do Magnus para IPs/blocos autorizados."
info "Quem não estiver na lista verá a página 'Acesso Não Autorizado'."
warn "Vale para o acesso pelo domínio E pelo IP direto do servidor."
echo ""

# ---------------------------------------------------------------------
# Coleta dos IPs/blocos autorizados
# ---------------------------------------------------------------------
MY_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
[ -z "$MY_IP" ] && MY_IP="seu.ip.aqui"

info "Seu IP atual de SSH: $MY_IP"
echo ""
read -p "  IP/bloco autorizado 1 [$MY_IP]: " B1
B1=${B1:-$MY_IP}
[ -z "$B1" ] || [ "$B1" = "seu.ip.aqui" ] && erro "Informe ao menos um IP/bloco autorizado"

ALLOWED="$B1"
while true; do
  read -p "  Outro IP/bloco autorizado (ENTER para terminar): " BX
  [ -z "$BX" ] && break
  ALLOWED="$ALLOWED $BX"
done

# Validação leve (IPv4 ou CIDR). configtest do Apache valida de novo no final.
for IPB in $ALLOWED; do
  echo "$IPB" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?$' \
    || warn "'$IPB' não parece um IPv4/CIDR válido — confira (o Apache vai validar)"
done

# Nome exibido no rodapé da página de bloqueio
read -p "  Nome para o rodapé da página de bloqueio [Magnus]: " EMPRESA
EMPRESA=${EMPRESA:-Magnus}
ANO=$(date +%Y)

# Linha Require final (inclui loopback para não quebrar processos locais)
REQUIRE_LINE="Require ip 127.0.0.1 ::1 $ALLOWED"

echo ""
titulo "RESUMO"
echo "  IPs/blocos autorizados: $ALLOWED (+ 127.0.0.1/::1 local)"
echo "  Rodapé da página:       © $ANO $EMPRESA"
echo ""
read -p "  Confirma aplicar a blindagem? [s/N]: " RESP
[[ "$RESP" =~ ^[Ss]$ ]] || erro "Operação cancelada pelo usuário"

# ---------------------------------------------------------------------
# Backup das configs do Apache (rollback)
# ---------------------------------------------------------------------
titulo "1. Backup das configurações"
BKP_DIR="/root/magnus-blindagem-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BKP_DIR"; chmod 700 "$BKP_DIR"
cp -a /etc/apache2/sites-available "$BKP_DIR/sites-available" 2>/dev/null
cp -a /etc/apache2/conf-available  "$BKP_DIR/conf-available"  2>/dev/null
ok "Backup em $BKP_DIR"

# ---------------------------------------------------------------------
# Página de bloqueio "Acesso Não Autorizado"
# ---------------------------------------------------------------------
titulo "2. Página de bloqueio"
mkdir -p /var/www/html/blocked
cat > /var/www/html/blocked/index.html <<HTMLEOF
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex,nofollow">
  <title>Acesso Não Autorizado</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { height: 100%; }
    body {
      font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: #0a0e16;
      color: #e6edf3;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
    }
    .card {
      background: #161b24;
      border: 1px solid #232a36;
      border-radius: 16px;
      padding: 56px 72px;
      text-align: center;
      box-shadow: 0 24px 60px rgba(0,0,0,0.45);
      max-width: 90%;
    }
    .lock { font-size: 72px; line-height: 1; margin-bottom: 28px; }
    h1 {
      font-size: 30px;
      font-weight: 800;
      margin-bottom: 28px;
      background: linear-gradient(90deg, #ef4444, #f97316);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
    }
    .footer { font-size: 13px; color: #5b6573; }
  </style>
</head>
<body>
  <div class="card">
    <div class="lock">🔒</div>
    <h1>Acesso Não Autorizado</h1>
    <div class="footer">© $ANO $EMPRESA — Todos os direitos reservados</div>
  </div>
</body>
</html>
HTMLEOF
chown -R www-data:www-data /var/www/html/blocked 2>/dev/null
chmod 755 /var/www/html/blocked
chmod 644 /var/www/html/blocked/index.html
ok "Página criada em /var/www/html/blocked/index.html"

# ---------------------------------------------------------------------
# Config global da blindagem (conf-enabled)
# <Directory> aplica a TODO VirtualHost por especificidade (domínio E IP)
# ---------------------------------------------------------------------
titulo "3. Regra global de blindagem"
cat > /etc/apache2/conf-available/magnus-blindagem.conf <<CONFEOF
# Magnus Utilities — Blindagem de acesso web do painel por IP
# Gerado por blindar_web_magnus.sh — não editar manualmente.

# Página de bloqueio liberada para todos (mais específica vence a restrição abaixo)
Alias /acesso-bloqueado /var/www/html/blocked
<Directory /var/www/html/blocked>
    Require all granted
</Directory>

# Restringe o painel aos IPs autorizados (cobre acesso direto pelo IP do servidor)
<Directory /var/www/html>
    $REQUIRE_LINE
</Directory>
<Directory /var/www/html/mbilling>
    $REQUIRE_LINE
</Directory>

# Visitantes não autorizados recebem a página de bloqueio (HTTP 403)
ErrorDocument 403 /acesso-bloqueado/index.html
CONFEOF
a2enconf magnus-blindagem >/dev/null 2>&1
ok "conf-available/magnus-blindagem.conf criado e habilitado"

# ---------------------------------------------------------------------
# Neutraliza "Require all granted" nos vhosts que servem o painel
# (é isto que fecha o buraco do acesso direto pelo IP / 000-default)
# ---------------------------------------------------------------------
titulo "4. Ajuste dos VirtualHosts que servem o painel"
ALTERADOS=0
for VH in /etc/apache2/sites-enabled/*.conf; do
  [ -e "$VH" ] || continue
  REAL=$(readlink -f "$VH")
  [ -f "$REAL" ] || continue
  if grep -qE "DocumentRoot[[:space:]]+/var/www/html" "$REAL" && grep -q "Require all granted" "$REAL"; then
    sed -i "s|Require all granted|$REQUIRE_LINE|g" "$REAL"
    ok "Ajustado: $(basename "$REAL")"
    ALTERADOS=$((ALTERADOS+1))
  fi
done
[ "$ALTERADOS" -eq 0 ] && info "Nenhum vhost com 'Require all granted' no painel (a regra global já cobre)"

# ---------------------------------------------------------------------
# Valida e aplica (com deadman switch anti-lockout do painel)
# ---------------------------------------------------------------------
titulo "5. Validação e aplicação"
if ! apache2ctl configtest 2>&1 | grep -qi "Syntax OK"; then
  warn "configtest falhou — REVERTENDO tudo"
  a2disconf magnus-blindagem >/dev/null 2>&1
  cp -a "$BKP_DIR/sites-available/." /etc/apache2/sites-available/ 2>/dev/null
  cp -a "$BKP_DIR/conf-available/."  /etc/apache2/conf-available/  2>/dev/null
  apache2ctl configtest
  erro "Sintaxe inválida do Apache — nada foi aplicado. Backup em $BKP_DIR"
fi
ok "Sintaxe do Apache OK"

systemctl reload apache2 && ok "Apache recarregado" || warn "Falha ao recarregar Apache"

echo ""
warn "TESTE AGORA no navegador (atualize a página do painel pelo seu IP autorizado)."
warn "Confirme também, de outra rede/celular, que aparece 'Acesso Não Autorizado'."
echo ""
read -t 60 -p "  Você AINDA consegue acessar o painel do IP autorizado? [s/N] (60s p/ auto-reverter): " OK_WEB || true

if [[ ! "$OK_WEB" =~ ^[Ss]$ ]]; then
  echo ""
  warn "Tempo esgotado ou negado — REVERTENDO a blindagem..."
  a2disconf magnus-blindagem >/dev/null 2>&1
  cp -a "$BKP_DIR/sites-available/." /etc/apache2/sites-available/ 2>/dev/null
  cp -a "$BKP_DIR/conf-available/."  /etc/apache2/conf-available/  2>/dev/null
  systemctl reload apache2
  warn "Blindagem revertida. Acesso restaurado. Backup preservado em $BKP_DIR"
  exit 1
fi

# ---------------------------------------------------------------------
# Conclusão
# ---------------------------------------------------------------------
titulo "BLINDAGEM APLICADA"
echo ""
echo -e "  ${VERDE}${NEGRITO}✓ Painel restrito aos IPs autorizados${NC}"
echo ""
echo "  Autorizados:  $ALLOWED (+ local)"
echo "  Página 403:   /var/www/html/blocked/index.html"
echo "  Config:       /etc/apache2/conf-available/magnus-blindagem.conf"
echo "  Backup:       $BKP_DIR"
echo ""
echo -e "${NEGRITO}  PARA REMOVER A BLINDAGEM depois:${NC}"
echo "    a2disconf magnus-blindagem"
echo "    cp -a $BKP_DIR/sites-available/. /etc/apache2/sites-available/"
echo "    systemctl reload apache2"
echo ""
exit 0
