#!/bin/bash
# =====================================================================
# Magnus Utilities — Magnus Health Check
# Versão: 3.0 (08/06/2026)
# Função: Verificação read-only de saúde Magnus + Asterisk
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - MagnusBilling 7.x
#   - Debian 10/11/12
#
# Uso: bash magnus-health-check.sh
#
# Idempotência: SIM
# Modifica estado do servidor: NÃO (apenas leitura)
# Requer janela de manutenção: NÃO
# =====================================================================

# Tenta carregar funções comuns
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
if [ -f "$SCRIPT_DIR/../lib/common.sh" ]; then
  source "$SCRIPT_DIR/../lib/common.sh"
else
  echo "Erro: Arquivo common.sh não encontrado."
  exit 1
fi

# Sobrescrevendo funções para contabilizar estatísticas
warn()  { echo -e "  ${AMARELO}⚠${NC} $1"; AVISOS=$((AVISOS+1)); }
erro()  { echo -e "  ${VERMELHO}✗${NC} $1"; PROBLEMAS=$((PROBLEMAS+1)); }

PROBLEMAS=0
AVISOS=0

clear
echo -e "${NEGRITO}MAGNUS HEALTH CHECK v3${NC}"
echo "Servidor: $(hostname) ($(hostname -I | awk '{print $1}'))"
echo "Data:     $(date '+%Y-%m-%d %H:%M:%S')"

# =====================================================================
titulo "1. SERVIÇOS RODANDO"
# =====================================================================
for SVC in apache2 mariadb asterisk; do
  STATE=$(systemctl is-active $SVC 2>/dev/null)
  [ "$STATE" = "active" ] && ok "$SVC: $STATE" || erro "$SVC: $STATE"
done
PHPFPM=$(systemctl list-units --type=service --state=active 2>/dev/null | grep -oE "php[0-9.]+-fpm" | head -1)
[ -n "$PHPFPM" ] && ok "$PHPFPM: active" || warn "Nenhum php-fpm ativo"

# =====================================================================
titulo "2. VERSÃO MAGNUS E ASTERISK"
# =====================================================================
VERSAO=$(mysql mbilling -N -e "SELECT config_value FROM pkg_configuration WHERE config_key='version';" 2>/dev/null)
[ -n "$VERSAO" ] && ok "Magnus: $VERSAO" || erro "Não conseguiu ler versão"
AST_VER=$(asterisk -rx "core show version" 2>/dev/null | head -1)
[ -n "$AST_VER" ] && ok "Asterisk: $AST_VER" || erro "Asterisk não acessível"

# =====================================================================
titulo "3. PERMISSÕES DOS ARQUIVOS QUE O MAGNUS REGENERA"
# =====================================================================
ARQUIVOS_MAGNUS=(
  /etc/asterisk/sip_magnus.conf
  /etc/asterisk/sip_magnus_user.conf
  /etc/asterisk/sip_magnus_register.conf
  /etc/asterisk/iax_magnus.conf
  /etc/asterisk/iax_magnus_user.conf
  /etc/asterisk/iax_magnus_register.conf
  /etc/asterisk/queues_magnus.conf
  /etc/asterisk/extensions_magnus.conf
  /etc/asterisk/extensions_magnus_did.conf
  /etc/asterisk/musiconhold_magnus.conf
  /etc/asterisk/voicemail_magnus.conf
)
for ARQ in "${ARQUIVOS_MAGNUS[@]}"; do
  [ ! -f "$ARQ" ] && { warn "$(basename $ARQ): NÃO EXISTE"; continue; }
  PERMS=$(stat -c '%a' "$ARQ")
  MTIME=$(stat -c '%y' "$ARQ" | cut -d. -f1)
  if sudo -u www-data test -w "$ARQ"; then
    ok "$(basename $ARQ) [$PERMS] modif: $MTIME"
  else
    erro "$(basename $ARQ) [$PERMS] www-data NÃO ESCREVE ← chmod 664 $ARQ"
  fi
done

# =====================================================================
titulo "4. www-data NO GRUPO asterisk"
# =====================================================================
if groups www-data 2>/dev/null | grep -qw asterisk; then
  ok "www-data está no grupo asterisk"
else
  erro "www-data NÃO está no grupo asterisk ← usermod -aG asterisk www-data && systemctl reload apache2 php*-fpm"
fi

# =====================================================================
titulo "5. SINCRONIA BANCO ↔ ARQUIVO (lógica Magnus)"
# =====================================================================
# Magnus convention:
#   pkg_user.active = 1 → ativo
#   pkg_user.active = 4 → bloqueado por inadimplência (ramal ainda existe no Asterisk)
#   pkg_user.active = 0/NULL → cancelado/desativado (ramal removido do Asterisk)

# --- Trunks SIP ---
TRUNKS_BD=$(mysql mbilling -N -e "SELECT COUNT(*) FROM pkg_trunk WHERE status=1 AND providertech='sip';" 2>/dev/null)
TRUNKS_ARQ=$(grep -c "^\[" /etc/asterisk/sip_magnus.conf 2>/dev/null)
if [ "$TRUNKS_BD" = "$TRUNKS_ARQ" ]; then
  ok "Trunks SIP: banco=$TRUNKS_BD arquivo=$TRUNKS_ARQ"
else
  warn "Trunks SIP: banco=$TRUNKS_BD vs arquivo=$TRUNKS_ARQ (editar+salvar 1 trunk regenera)"
fi

# --- Ramais SIP (lógica v3: active IN (1,4)) ---
RAMAIS_ESPERADOS=$(mysql mbilling -N -e "
  SELECT COUNT(*) FROM pkg_sip s 
  INNER JOIN pkg_user u ON s.id_user=u.id 
  WHERE u.active IN (1,4);" 2>/dev/null)
RAMAIS_CANCELADOS=$(mysql mbilling -N -e "
  SELECT COUNT(*) FROM pkg_sip s 
  INNER JOIN pkg_user u ON s.id_user=u.id 
  WHERE u.active=0 OR u.active IS NULL;" 2>/dev/null)
RAMAIS_INADIMPLENTES=$(mysql mbilling -N -e "
  SELECT COUNT(*) FROM pkg_sip s 
  INNER JOIN pkg_user u ON s.id_user=u.id 
  WHERE u.active=4;" 2>/dev/null)
RAMAIS_ARQ=$(grep -c "^\[" /etc/asterisk/sip_magnus_user.conf 2>/dev/null)

if [ "$RAMAIS_ESPERADOS" = "$RAMAIS_ARQ" ]; then
  ok "Ramais SIP: banco=$RAMAIS_ESPERADOS arquivo=$RAMAIS_ARQ"
else
  erro "Ramais SIP DESSINCRONIZADOS: banco=$RAMAIS_ESPERADOS arquivo=$RAMAIS_ARQ"
fi
[ "$RAMAIS_INADIMPLENTES" -gt 0 ] && info "Ramais inadimplentes (active=4, no arquivo mas chamadas bloqueadas via AGI): $RAMAIS_INADIMPLENTES"
[ "$RAMAIS_CANCELADOS" -gt 0 ] && info "Ramais cancelados (active=0/NULL, fora do arquivo): $RAMAIS_CANCELADOS"

# --- Membros de fila ---
MEMBROS_ATIVOS=$(mysql mbilling -N -e "SELECT COUNT(*) FROM pkg_queue_member WHERE paused=0 OR paused IS NULL;" 2>/dev/null)
MEMBROS_PAUSADOS=$(mysql mbilling -N -e "SELECT COUNT(*) FROM pkg_queue_member WHERE paused=1;" 2>/dev/null)
MEMBROS_ARQ=$(grep -c "^member" /etc/asterisk/queues_magnus.conf 2>/dev/null)
MEMBROS_ASTERISK=$(asterisk -rx "queue show" 2>/dev/null | grep -cE "^      SIP/")

if [ "$MEMBROS_ATIVOS" = "$MEMBROS_ASTERISK" ]; then
  ok "Membros de fila ativos: banco=$MEMBROS_ATIVOS Asterisk=$MEMBROS_ASTERISK"
else
  warn "Membros de fila ativos: banco=$MEMBROS_ATIVOS vs Asterisk=$MEMBROS_ASTERISK"
fi
[ "$MEMBROS_PAUSADOS" -gt 0 ] && info "Membros pausados (no banco/arquivo mas não visíveis em 'queue show'): $MEMBROS_PAUSADOS"
info "Total no arquivo (ativos+pausados): $MEMBROS_ARQ"

# --- Peers SIP em runtime ---
PEERS_ASTERISK=$(asterisk -rx "sip show peers" 2>/dev/null | tail -1 | grep -oE "[0-9]+ sip peers" | grep -oE "[0-9]+")
info "Asterisk reconhece $PEERS_ASTERISK peers SIP em runtime (inclui trunks)"

# =====================================================================
titulo "6. CONFIG DO BANCO (res_config_mysql.conf)"
# =====================================================================
DBHOST=$(grep "^dbhost" /etc/asterisk/res_config_mysql.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
if [ -n "$DBHOST" ]; then
  ok "dbhost = $DBHOST"
  if mysql -e "SELECT 1;" >/dev/null 2>&1; then
    ok "Conexão MySQL local funcionando"
  else
    erro "MySQL local não responde"
  fi
fi
if [ "$DBHOST" = "127.0.0.1" ]; then
  if iptables -S INPUT 2>/dev/null | grep -q "\-i lo"; then
    ok "iptables: regra de loopback OK"
  else
    warn "Verificar regra de loopback no iptables"
  fi
fi

# =====================================================================
titulo "7. APACHE / PHP"
# =====================================================================
HTTP_LOCAL=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 http://localhost/ 2>/dev/null)
HTTPS_LOCAL=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 https://localhost/ 2>/dev/null)
case "$HTTP_LOCAL" in
  200|302|301) ok "HTTP local: $HTTP_LOCAL" ;;
  000)         warn "HTTP local: sem resposta" ;;
  500)         erro "HTTP local: 500 (erro interno)" ;;
  *)           warn "HTTP local: $HTTP_LOCAL" ;;
esac
[ "$HTTPS_LOCAL" != "000" ] && ok "HTTPS local: $HTTPS_LOCAL"

APP_LOG=/var/www/html/mbilling/protected/runtime/application.log
HOJE=$(date '+%Y/%m/%d')
if [ -f "$APP_LOG" ]; then
  ERROS_HOJE=$(grep "^$HOJE" "$APP_LOG" 2>/dev/null | grep -ciE "\[error\]|exception|fatal")
  ERROS_TOUCH=$(grep "^$HOJE" "$APP_LOG" 2>/dev/null | grep -c "LinuxAccess::exec -> touch")
  if [ "$ERROS_HOJE" -eq 0 ]; then
    ok "application.log: sem erros HOJE"
  elif [ "$ERROS_TOUCH" -gt 0 ]; then
    warn "application.log: $ERROS_HOJE erros hoje ($ERROS_TOUCH são de touch — verificar permissões acima)"
  else
    warn "application.log: $ERROS_HOJE erros hoje ← tail -50 $APP_LOG | grep -i error"
  fi
fi

# =====================================================================
titulo "8. UPDATE.SH"
# =====================================================================
UPDATE_SH=/var/www/html/mbilling/protected/commands/update.sh
if [ -f "$UPDATE_SH" ]; then
  [ -x "$UPDATE_SH" ] && ok "update.sh existe e é executável" || warn "update.sh existe mas não executável (chmod +x $UPDATE_SH)"
else
  warn "update.sh não encontrado"
fi

# =====================================================================
titulo "9. CRON DO MAGNUS"
# =====================================================================
CRON_MAGNUS=$(crontab -l 2>/dev/null | grep -cE "magnus|mbilling|cron\.php")
[ "$CRON_MAGNUS" -gt 0 ] && ok "Cron Magnus: $CRON_MAGNUS linha(s)" || warn "Nenhuma linha de cron Magnus"

# =====================================================================
titulo "10. ESPAÇO EM DISCO"
# =====================================================================
df -h / /var /var/log /var/spool/asterisk 2>/dev/null | grep -v "Filesystem" | awk '!seen[$6]++' | while read line; do
  PCT=$(echo $line | awk '{print $5}' | tr -d '%')
  MOUNT=$(echo $line | awk '{print $6}')
  if [ -n "$PCT" ] && [ "$PCT" -gt 85 ] 2>/dev/null; then
    echo -e "  ${VERMELHO}✗${NC} $MOUNT: ${PCT}% usado (crítico)"
  elif [ -n "$PCT" ] && [ "$PCT" -gt 70 ] 2>/dev/null; then
    echo -e "  ${AMARELO}⚠${NC} $MOUNT: ${PCT}% usado"
  else
    echo -e "  ${VERDE}✓${NC} $MOUNT: ${PCT}% usado"
  fi
done

# =====================================================================
titulo "RESUMO"
# =====================================================================
echo ""
if [ "$PROBLEMAS" -eq 0 ] && [ "$AVISOS" -eq 0 ]; then
  echo -e "  ${VERDE}${NEGRITO}✓ TUDO OK${NC}"
elif [ "$PROBLEMAS" -eq 0 ]; then
  echo -e "  ${AMARELO}${NEGRITO}⚠ $AVISOS aviso(s) — não crítico${NC}"
else
  echo -e "  ${VERMELHO}${NEGRITO}✗ $PROBLEMAS problema(s) e $AVISOS aviso(s)${NC}"
fi
echo ""
