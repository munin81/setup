#!/bin/bash
# =====================================================================
# Magnus Utilities — blindar_web_magnus.sh
# Versão: 2.0 (19 de junho de 2026)
# Função: Restringir o acesso WEB ao painel MagnusBilling a um ou mais
#         IPs/blocos autorizados, exibindo uma página "Acesso Não
#         Autorizado" para todos os demais (domínio E IP direto).
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#   - Apache2 (Debian 10/11/12, Apache 2.4)
#   - MagnusBilling em /var/www/html/mbilling
#
# Uso: bash blindar_web_magnus.sh
#
# Idempotência: SIM (pode rodar várias vezes; reaplica e limpa resíduos)
# Modifica estado: SIM (conf do Apache + página de bloqueio)
# Requer janela de manutenção: NÃO
#
# COMO FECHA TODOS OS CAMINHOS (corrige o defeito do "IP direto"):
#   - Restrição via <Location /> em conf-enabled: por precedência, a
#     <Location> sobrepõe qualquer <Directory>, valendo para TODO vhost
#     (domínio E IP, portas 80 e 443) — sem precisar editar <Directory>.
#   - Torna o redirect :80 incondicional (todo HTTP -> HTTPS).
#   - Limpa automaticamente blindagens antigas (acesso_negado.html).
#   - Libera /.well-known/acme-challenge para a renovação do Let's Encrypt
#     não quebrar.
# =====================================================================

set -o pipefail

VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
ok()    { echo -e "  ${VERDE}✓${NC} $1"; }
info()  { echo -e "  ${AZUL}➜${NC} $1"; }
warn()  { echo -e "  ${AMARELO}⚠${NC} $1"; }
erro()  { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
titulo(){ echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }

[ "$EUID" -ne 0 ] && erro "Rode como root"
command -v apache2ctl >/dev/null 2>&1 || erro "Apache2 não encontrado"

clear
titulo "BLINDAR ACESSO WEB DO PAINEL MAGNUS (por IP) — v2"
echo ""
info "Tranca o painel para IPs/blocos autorizados (domínio E IP direto)."
info "Quem não estiver na lista vê a página 'Acesso Não Autorizado'."
info "Limpa blindagens antigas e padroniza a configuração."
echo ""

# ---------------------------------------------------------------------
# IPs/blocos autorizados
# ---------------------------------------------------------------------
MY_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
[ -z "$MY_IP" ] && MY_IP="seu.ip.aqui"

info "Seu IP atual de SSH: $MY_IP"
echo ""
read -p "  IP/bloco autorizado 1 [$MY_IP]: " B1
B1=${B1:-$MY_IP}
{ [ -z "$B1" ] || [ "$B1" = "seu.ip.aqui" ]; } && erro "Informe ao menos um IP/bloco autorizado"

ALLOWED="$B1"
while true; do
  read -p "  Outro IP/bloco autorizado (ENTER para terminar): " BX
  [ -z "$BX" ] && break
  ALLOWED="$ALLOWED $BX"
done

for IPB in $ALLOWED; do
  echo "$IPB" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?$' \
    || warn "'$IPB' não parece IPv4/CIDR — confira (o Apache valida no final)"
done

read -p "  Nome para o rodapé da página de bloqueio [Magnus]: " EMPRESA
EMPRESA=${EMPRESA:-Magnus}
ANO=$(date +%Y)
REQUIRE_LINE="Require ip 127.0.0.1 ::1 $ALLOWED"

echo ""
titulo "RESUMO"
echo "  Autorizados: $ALLOWED (+ 127.0.0.1/::1)"
echo "  Rodapé:      © $ANO $EMPRESA"
echo ""
read -p "  Confirma aplicar/padronizar a blindagem? [s/N]: " RESP
[[ "$RESP" =~ ^[Ss]$ ]] || erro "Cancelado pelo usuário"

# ---------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------
titulo "1. Backup das configurações"
BKP_DIR="/root/magnus-blindagem-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BKP_DIR"; chmod 700 "$BKP_DIR"
cp -a /etc/apache2/sites-available "$BKP_DIR/sites-available" 2>/dev/null
cp -a /etc/apache2/conf-available  "$BKP_DIR/conf-available"  2>/dev/null
ok "Backup em $BKP_DIR"

# ---------------------------------------------------------------------
# Página de bloqueio
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
    * { margin:0; padding:0; box-sizing:border-box; }
    html, body { height:100%; }
    body { font-family:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
      background:#0a0e16; color:#e6edf3; display:flex; align-items:center;
      justify-content:center; min-height:100vh; }
    .card { background:#161b24; border:1px solid #232a36; border-radius:16px;
      padding:56px 72px; text-align:center; box-shadow:0 24px 60px rgba(0,0,0,.45);
      max-width:90%; }
    .lock { font-size:72px; line-height:1; margin-bottom:28px; }
    h1 { font-size:30px; font-weight:800; margin-bottom:28px;
      background:linear-gradient(90deg,#ef4444,#f97316);
      -webkit-background-clip:text; -webkit-text-fill-color:transparent;
      background-clip:text; }
    .footer { font-size:13px; color:#5b6573; }
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
# Regra global (conf-enabled): <Location /> sobrepõe qualquer <Directory>
# ---------------------------------------------------------------------
titulo "3. Regra global de blindagem"
cat > /etc/apache2/conf-available/magnus-blindagem.conf <<CONFEOF
# Magnus Utilities — Blindagem de acesso web do painel por IP
# Gerado por blindar_web_magnus.sh — não editar manualmente.

# Página de bloqueio liberada a todos (mais específica vence a regra global)
Alias /acesso-bloqueado /var/www/html/blocked
<Location /acesso-bloqueado>
    Require all granted
</Location>

# Exceção: validação do Let's Encrypt (senão a renovação do SSL quebra)
<Location /.well-known/acme-challenge>
    Require all granted
</Location>

# Restrição GLOBAL — vale para todo VirtualHost (domínio e IP, :80 e :443)
<Location />
    Require ip 127.0.0.1 ::1 $ALLOWED
</Location>

# Visitantes não autorizados recebem a página de bloqueio (HTTP 403)
ErrorDocument 403 /acesso-bloqueado/index.html
CONFEOF
a2enconf magnus-blindagem >/dev/null 2>&1
ok "conf-available/magnus-blindagem.conf criado e habilitado"

# ---------------------------------------------------------------------
# Limpeza/normalização dos vhosts (sem tocar em <Directory>)
#   - remove blindagem antiga acesso_negado.html
#   - torna o redirect :80 incondicional (todo HTTP -> HTTPS)
# ---------------------------------------------------------------------
titulo "4. Limpeza de blindagens antigas e normalização"
LIMPOS=0
for VH in /etc/apache2/sites-enabled/*.conf; do
  [ -e "$VH" ] || continue
  REAL=$(readlink -f "$VH"); [ -f "$REAL" ] || continue
  grep -qE "DocumentRoot[[:space:]]+/var/www/html" "$REAL" || continue

  ALTEROU=0
  # remove bloco <Location /acesso_negado.html> ... </Location>
  if grep -q "acesso_negado" "$REAL"; then
    sed -i '/<Location \/acesso_negado.html>/,/<\/Location>/d' "$REAL"
    sed -i '\#Alias /acesso_negado.html#d' "$REAL"
    sed -i '\#ErrorDocument 403 /acesso_negado.html#d' "$REAL"
    ALTEROU=1
  fi
  # redirect :80 incondicional (remove a condição por nome)
  if grep -q "RewriteCond %{SERVER_NAME}" "$REAL"; then
    sed -i '/RewriteCond %{SERVER_NAME}/d' "$REAL"
    ALTEROU=1
  fi
  [ "$ALTEROU" -eq 1 ] && { ok "Normalizado: $(basename "$REAL")"; LIMPOS=$((LIMPOS+1)); }
done
[ "$LIMPOS" -eq 0 ] && info "Nenhuma blindagem antiga encontrada (nada a limpar)"

# ---------------------------------------------------------------------
# Validação + aplicação com deadman switch
# ---------------------------------------------------------------------
titulo "5. Validação e aplicação"
reverter() {
  a2disconf magnus-blindagem >/dev/null 2>&1
  cp -a "$BKP_DIR/sites-available/." /etc/apache2/sites-available/ 2>/dev/null
  cp -a "$BKP_DIR/conf-available/."  /etc/apache2/conf-available/  2>/dev/null
  systemctl reload apache2 2>/dev/null
}

if ! apache2ctl configtest 2>&1 | grep -qi "Syntax OK"; then
  warn "configtest falhou — REVERTENDO"
  reverter
  apache2ctl configtest
  erro "Sintaxe inválida — nada aplicado. Backup em $BKP_DIR"
fi
ok "Sintaxe do Apache OK"

systemctl reload apache2 && ok "Apache recarregado" || warn "Falha ao recarregar"

echo ""
warn "TESTE AGORA: do seu IP autorizado o painel deve abrir;"
warn "de fora (4G/TOR), domínio E IP devem mostrar 'Acesso Não Autorizado'."
echo ""
read -t 60 -p "  Você AINDA acessa o painel do IP autorizado? [s/N] (60s p/ auto-reverter): " OKW || true
if [[ ! "$OKW" =~ ^[Ss]$ ]]; then
  echo ""; warn "Tempo esgotado ou negado — REVERTENDO..."
  reverter
  warn "Revertido. Acesso restaurado. Backup em $BKP_DIR"
  exit 1
fi

# ---------------------------------------------------------------------
# Conclusão
# ---------------------------------------------------------------------
titulo "BLINDAGEM PADRONIZADA"
echo ""
echo -e "  ${VERDE}${NEGRITO}✓ Painel restrito aos IPs autorizados (domínio e IP, :80 e :443)${NC}"
echo ""
echo "  Autorizados:  $ALLOWED (+ local)"
echo "  Página 403:   /var/www/html/blocked/index.html"
echo "  Config:       /etc/apache2/conf-available/magnus-blindagem.conf"
echo "  Backup:       $BKP_DIR"
echo ""
echo -e "${NEGRITO}  PARA REMOVER depois:${NC}"
echo "    a2disconf magnus-blindagem && systemctl reload apache2"
echo ""
exit 0
