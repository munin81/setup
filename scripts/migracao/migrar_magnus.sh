#!/bin/bash
# =====================================================================
# Magnus Utilities — migrar_magnus.sh
# Versão: 5.2.1 (08 de junho de 2026)
# Mudança v5.2 → v5.2.1:
#   - Fase 2: pergunta separadamente nome+IP do usuário admin (DBeaver)
#             e (opcional) nome+IP do usuário API (N8N)
#   - Fase 9: cria os 2 usuários conforme informado (não mais hardcoded)
#   - Removido ALTER USER ... USING PASSWORD (bug: requer hash, não texto)
#   - Tudo via IDENTIFIED BY 'senha' (mais simples e funcional)
# =====================================================================
# Função: Migração de dados de MagnusBilling entre servidores
#         (banco + Asterisk configs + sons + customizações + restart)
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar no servidor DESTINO como root
#   - Magnus 7.x já instalado no destino
#   - SSH para origem na porta 22022 com IP autorizado
#   - sshpass, rsync, mysqldump (script instala se faltar)
#
# Uso:
#   bash migrar_magnus.sh                # interativo
#   bash migrar_magnus.sh --dry-run      # mostra plano e sai
#   bash migrar_magnus.sh --no-restart   # pula restart final (manual)
#   bash migrar_magnus.sh --help         # ajuda
#
# Fluxo (13 fases — escopo enxuto + restart):
#   1.  Validação no destino
#   2.  Coleta de parâmetros (IPs, senhas, IP_VPN_ADMIN)
#   3.  Teste SSH com origem + comparação de versões
#   4.  Backup pré-migração do destino (rollback)
#   5.  Captura do banco da origem
#   6.  Captura /etc/asterisk/ da origem
#   7.  Captura /var/lib/asterisk/sounds/ da origem
#   8.  Aplicação no destino (parar serviços, importar banco, aplicar configs)
#   9.  Customizações de BANCO (mbillingUser, admin_user@IP, runtime, pkg_firewall)
#   10. Validação de dados (banco + permissões, SEM tocar nos serviços)
#   11. Resumo da migração de dados
#   12. Reinício dos serviços (com confirmação) — NOVO na v5.2
#   13. Validação final pós-restart (HTTP, Asterisk, peers) — NOVO na v5.2
#
# ESCOPO REMOVIDO (vs v5.0):
#   - Configuração de firewall (script separado: configurar_firewalld_admin_user.sh)
#   - Apache VirtualHost / SSL Let's Encrypt (script separado)
#   - Cron / logrotate / backup diário / página bloqueada (script separado)
#
# MUDANÇAS v5.1 → v5.2:
#   - Adicionada Fase 12 (restart com confirmação)
#   - Adicionada Fase 13 (validação pós-restart)
#   - Flag --no-restart para pular restart (caso queira manual)
#   - Restart de serviços NÃO toca firewall/SSH (zero risco de trava)
#
# Idempotência: PARCIAL (importação do banco NÃO é, customizações SIM)
# Modifica estado: SIM (banco + /etc/asterisk + /var/lib/asterisk + senhas + serviços reiniciados)
# Requer janela de manutenção: SIM (para Apache+Asterisk no destino)
#
# NÃO RODA update.sh automaticamente.
# NÃO MEXE em firewall / iptables / firewalld.
# =====================================================================

set -o pipefail

# ---------------------------------------------------------------------
# Cores e funções de log
# ---------------------------------------------------------------------
VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'

LOG_FILE=""

ok()    { echo -e "  ${VERDE}✓${NC} $1" | tee -a "${LOG_FILE:-/dev/null}"; }
info()  { echo -e "  ${AZUL}➜${NC} $1" | tee -a "${LOG_FILE:-/dev/null}"; }
warn()  { echo -e "  ${AMARELO}⚠${NC} $1" | tee -a "${LOG_FILE:-/dev/null}"; }
erro()  { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1" | tee -a "${LOG_FILE:-/dev/null}"; exit 1; }
titulo() {
  echo "" | tee -a "${LOG_FILE:-/dev/null}"
  echo -e "${NEGRITO}${AZUL}═══════════════════════════════════════════════════════════════${NC}" | tee -a "${LOG_FILE:-/dev/null}"
  echo -e "${NEGRITO} $1${NC}" | tee -a "${LOG_FILE:-/dev/null}"
  echo -e "${NEGRITO}${AZUL}═══════════════════════════════════════════════════════════════${NC}" | tee -a "${LOG_FILE:-/dev/null}"
}

mysql_local() {
  MYSQL_PWD="$SENHA_ROOT_LOCAL" mysql --user=root "$@"
}

# sshpass -e lê a senha da env SSHPASS (visível só p/ root em /proc/PID/environ),
# em vez de -p, que exporia a senha no ps aux para qualquer usuário local.
ssh_origem() {
  SSHPASS="$ORIGEM_PASS" sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    -p "$ORIGEM_PORT" \
    "$ORIGEM_USER@$ORIGEM_IP" "$@"
}

rsync_origem() {
  local SRC="$1"
  local DST="$2"
  SSHPASS="$ORIGEM_PASS" sshpass -e rsync -az --delete \
    -e "ssh -o StrictHostKeyChecking=accept-new -p $ORIGEM_PORT" \
    "$ORIGEM_USER@$ORIGEM_IP:$SRC" "$DST"
}

confirma() {
  read -p "  $1 [s/N]: " RESP
  [[ "$RESP" =~ ^[Ss]$ ]] || erro "Cancelado pelo usuário"
}

# ---------------------------------------------------------------------
# Parse argumentos
# ---------------------------------------------------------------------
DRY_RUN=0
NO_RESTART=0
for ARG in "$@"; do
  case "$ARG" in
    --dry-run) DRY_RUN=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --help|-h)
      sed -n '/^# Magnus Utilities/,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Opção desconhecida: $ARG"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------
# Diretório e log
# ---------------------------------------------------------------------
LOG_DIR="/var/log/magnus-utils"
mkdir -p "$LOG_DIR" || erro "Sem permissão em $LOG_DIR — rode como root"
chmod 750 "$LOG_DIR"
LOG_FILE="$LOG_DIR/migrar-magnus-$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

clear
titulo "MIGRAÇÃO DE DADOS MAGNUSBILLING (v5.2.1)"
info "Servidor DESTINO: $(hostname) ($(hostname -I | awk '{print $1}'))"
info "Data/hora:        $(date '+%Y-%m-%d %H:%M:%S')"
info "Log:              $LOG_FILE"
echo ""
warn "Este script NÃO mexe em firewall/SSL/cron. Use scripts separados depois."
[ $DRY_RUN -eq 1 ] && warn "MODO DRY-RUN ATIVO — nada será modificado"
[ $NO_RESTART -eq 1 ] && warn "FLAG --no-restart ATIVA — restart final será pulado"

# =====================================================================
# FASE 1 — VALIDAÇÃO DE PRÉ-REQUISITOS NO DESTINO
# =====================================================================
titulo "FASE 1/13 — Validação de pré-requisitos no destino"

[ "$EUID" -ne 0 ] && erro "Rode como root"

for CMD in mysql rsync ssh systemctl; do
  command -v $CMD >/dev/null 2>&1 || erro "$CMD não está instalado"
done
ok "Comandos básicos OK"

if ! command -v sshpass >/dev/null 2>&1; then
  info "Instalando sshpass..."
  apt-get install -y sshpass >/dev/null 2>&1 || erro "Falha ao instalar sshpass"
  ok "sshpass instalado"
fi

[ ! -d "/var/www/html/mbilling" ] && erro "Magnus não está instalado em /var/www/html/mbilling no destino"
[ ! -f "/etc/asterisk/sip.conf" ] && erro "Asterisk não está instalado no destino"
ok "Magnus e Asterisk presentes no destino"

if [ -f "/root/passwordMysql.log" ]; then
  SENHA_ROOT_LOCAL=$(cat /root/passwordMysql.log | tr -d '[:space:]')
  ok "Senha root MySQL lida de /root/passwordMysql.log"
else
  warn "/root/passwordMysql.log não encontrado"
  read -sp "  Senha root MySQL do destino: " SENHA_ROOT_LOCAL
  echo ""
fi

mysql_local -e "SELECT 1;" >/dev/null 2>&1 || erro "Senha MySQL incorreta"
ok "Conexão MySQL local OK"

# =====================================================================
# FASE 2 — COLETA DE PARÂMETROS
# =====================================================================
titulo "FASE 2/13 — Parâmetros da migração"

echo ""
info "Servidor de ORIGEM (de onde vamos copiar):"
read -p "  IP origem: " ORIGEM_IP
read -p "  Porta SSH origem [22022]: " ORIGEM_PORT; ORIGEM_PORT=${ORIGEM_PORT:-22022}
read -p "  Usuário SSH origem [root]: " ORIGEM_USER; ORIGEM_USER=${ORIGEM_USER:-root}
read -sp "  Senha SSH origem: " ORIGEM_PASS; echo ""

[ -z "$ORIGEM_IP" ] || [ -z "$ORIGEM_PASS" ] && erro "IP e senha de origem são obrigatórios"

echo ""
info "Usuário ADMIN do MySQL (para DBeaver):"
read -p "  Nome do usuário admin [admin_user]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin_user}
echo "$ADMIN_USER" | grep -qE '^[A-Za-z0-9_]+$' || erro "Nome de usuário inválido (use A-Z a-z 0-9 _)"
read -p "  IP de origem (para criar $ADMIN_USER@IP): " ADMIN_IP
[ -z "$ADMIN_IP" ] && erro "IP admin é obrigatório"
echo "$ADMIN_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || erro "IP admin inválido (use IPv4)"

echo ""
info "Usuário API do MySQL (N8N/automações — opcional):"
read -p "  Nome do usuário API (ENTER para PULAR): " API_USER
if [ -n "$API_USER" ]; then
  echo "$API_USER" | grep -qE '^[A-Za-z0-9_]+$' || erro "Nome de usuário API inválido (use A-Z a-z 0-9 _)"
  read -p "  IP de origem (para criar $API_USER@IP): " API_IP
  [ -z "$API_IP" ] && erro "IP API é obrigatório se nome foi informado"
  echo "$API_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || erro "IP API inválido (use IPv4)"
fi

echo ""
info "Parar serviços na origem durante a captura?"
echo "  [1] SIM — parar Apache na origem (dump consistente, recomendado)"
echo "  [2] NÃO — manter origem rodando (mais rápido)"
read -p "  Escolha [1]: " PARAR_ORIGEM; PARAR_ORIGEM=${PARAR_ORIGEM:-1}

# Resumo
echo ""
titulo "RESUMO DA MIGRAÇÃO"
echo ""
echo "  ORIGEM:       $ORIGEM_USER@$ORIGEM_IP:$ORIGEM_PORT"
echo "  DESTINO:      $(hostname) ($(hostname -I | awk '{print $1}'))"
echo "  ADMIN MySQL:  $ADMIN_USER@$ADMIN_IP"
[ -n "$API_USER" ] && echo "  API MySQL:    $API_USER@$API_IP" || echo "  API MySQL:    (não será criado)"
echo "  Parar origem: $([ "$PARAR_ORIGEM" = "1" ] && echo "SIM" || echo "NÃO")"
echo ""
warn "Esta operação SUBSTITUI o banco e configs Asterisk do destino pelos dados da origem."
warn "Tabelas customizadas Admin (pkg_password_reset, pkg_tickets, pkg_ticket_messages) virão da origem."
warn "Firewall e SSL NÃO serão configurados — use scripts separados depois."
echo ""
confirma "Confirma todos os parâmetros acima?"

if [ $DRY_RUN -eq 1 ]; then
  warn "Modo dry-run — saindo aqui sem executar"
  exit 0
fi

# =====================================================================
# FASE 3 — TESTE SSH COM ORIGEM
# =====================================================================
titulo "FASE 3/13 — Conexão SSH com origem"

ssh_origem "echo OK" >/dev/null 2>&1 || erro "Falha SSH com $ORIGEM_IP:$ORIGEM_PORT"
ok "SSH com origem OK"

ORIGEM_MAGNUS_VER=$(ssh_origem "mysql mbilling -N -e \"SELECT config_value FROM pkg_configuration WHERE config_key='version';\" 2>/dev/null" | tr -d '[:space:]')
ok "Magnus na origem: ${ORIGEM_MAGNUS_VER:-desconhecido}"

DESTINO_MAGNUS_VER=$(mysql_local mbilling -N -e "SELECT config_value FROM pkg_configuration WHERE config_key='version';" 2>/dev/null | tr -d '[:space:]')
ok "Magnus no destino: ${DESTINO_MAGNUS_VER:-desconhecido}"

if [ "$ORIGEM_MAGNUS_VER" != "$DESTINO_MAGNUS_VER" ] && [ -n "$ORIGEM_MAGNUS_VER" ] && [ -n "$DESTINO_MAGNUS_VER" ]; then
  warn "Versões diferentes! Origem=$ORIGEM_MAGNUS_VER  Destino=$DESTINO_MAGNUS_VER"
  confirma "Prosseguir mesmo assim?"
fi

# =====================================================================
# FASE 4 — BACKUP PRÉ-MIGRAÇÃO DO DESTINO (rollback)
# =====================================================================
titulo "FASE 4/13 — Backup do estado atual do destino"

BACKUP_DIR="/root/magnus-backup-pre-migracao-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

info "Dump do banco mbilling atual..."
MYSQL_PWD="$SENHA_ROOT_LOCAL" mysqldump --routines --triggers --events \
  --single-transaction --quick mbilling > "$BACKUP_DIR/mbilling-destino-antes.sql" 2>/dev/null
ok "Banco salvo em $BACKUP_DIR/mbilling-destino-antes.sql"

info "Backup de /etc/asterisk..."
tar czf "$BACKUP_DIR/etc-asterisk-antes.tar.gz" /etc/asterisk 2>/dev/null
ok "Asterisk config salvo"

info "Backup completo em: $BACKUP_DIR"

# =====================================================================
# FASE 5 — CAPTURA DO BANCO DA ORIGEM
# =====================================================================
titulo "FASE 5/13 — Captura do banco da origem"

if [ "$PARAR_ORIGEM" = "1" ]; then
  info "Parando Apache na origem (Asterisk continua para não derrubar chamadas)..."
  ssh_origem "systemctl stop apache2 2>/dev/null || systemctl stop httpd 2>/dev/null"
  ok "Apache origem parado"
fi

info "Executando mysqldump na origem (pode demorar conforme tamanho)..."
ssh_origem "mysqldump --routines --triggers --events --single-transaction --quick mbilling 2>/dev/null | gzip" > "$BACKUP_DIR/mbilling-origem.sql.gz"
SIZE=$(du -h "$BACKUP_DIR/mbilling-origem.sql.gz" | cut -f1)
ok "Dump da origem capturado ($SIZE)"

[ ! -s "$BACKUP_DIR/mbilling-origem.sql.gz" ] && erro "Dump da origem ficou vazio — abortando"

# =====================================================================
# FASE 6 — CAPTURA DE /etc/asterisk DA ORIGEM
# =====================================================================
titulo "FASE 6/13 — Captura de /etc/asterisk/ da origem"

info "Sincronizando /etc/asterisk/..."
mkdir -p /tmp/migracao-origem/etc-asterisk
rsync_origem "/etc/asterisk/" "/tmp/migracao-origem/etc-asterisk/" >/dev/null 2>&1 || warn "Algumas falhas durante rsync /etc/asterisk"
ok "Configs Asterisk da origem em /tmp/migracao-origem/etc-asterisk/"

# =====================================================================
# FASE 7 — CAPTURA DE /var/lib/asterisk/sounds DA ORIGEM
# =====================================================================
titulo "FASE 7/13 — Captura de /var/lib/asterisk/sounds/ da origem"

info "Sincronizando /var/lib/asterisk/sounds/..."
mkdir -p /tmp/migracao-origem/sounds
rsync_origem "/var/lib/asterisk/sounds/" "/tmp/migracao-origem/sounds/" >/dev/null 2>&1 || warn "Algumas falhas durante rsync de sounds"
ok "Sons capturados"

# Religar Apache na origem
if [ "$PARAR_ORIGEM" = "1" ]; then
  info "Religando Apache na origem..."
  ssh_origem "systemctl start apache2 2>/dev/null || systemctl start httpd 2>/dev/null"
  ok "Apache origem religado"
fi

# =====================================================================
# FASE 8 — APLICAÇÃO NO DESTINO
# =====================================================================
titulo "FASE 8/13 — Aplicação no destino"

info "Parando serviços no destino (Apache + Asterisk)..."
systemctl stop apache2 2>/dev/null
systemctl stop asterisk 2>/dev/null
ok "Apache e Asterisk parados no destino"

info "Importando banco da origem..."
mysql_local -e "DROP DATABASE IF EXISTS mbilling; CREATE DATABASE mbilling CHARACTER SET utf8 COLLATE utf8_general_ci;"
zcat "$BACKUP_DIR/mbilling-origem.sql.gz" | MYSQL_PWD="$SENHA_ROOT_LOCAL" mysql --user=root mbilling
[ $? -ne 0 ] && erro "Falha ao importar banco — rollback com: mysql mbilling < $BACKUP_DIR/mbilling-destino-antes.sql"
ok "Banco importado da origem"

info "Aplicando /etc/asterisk/ da origem..."
# Preservar res_config_mysql.conf do destino (senha local diferente)
cp /etc/asterisk/res_config_mysql.conf /tmp/res_config_mysql.conf.destino 2>/dev/null
rsync -a --delete /tmp/migracao-origem/etc-asterisk/ /etc/asterisk/
cp /tmp/res_config_mysql.conf.destino /etc/asterisk/res_config_mysql.conf 2>/dev/null
chown -R asterisk:asterisk /etc/asterisk/
ok "Asterisk config aplicada (res_config_mysql.conf preservado)"

# Garantir permissão 664 nos arquivos *_magnus*.conf (lição aprendida 28/05)
info "Aplicando chmod 664 nos arquivos regenerados pelo Magnus..."
for F in /etc/asterisk/sip_magnus.conf /etc/asterisk/sip_magnus_user.conf \
         /etc/asterisk/sip_magnus_register.conf /etc/asterisk/iax_magnus.conf \
         /etc/asterisk/iax_magnus_user.conf /etc/asterisk/iax_magnus_register.conf \
         /etc/asterisk/queues_magnus.conf /etc/asterisk/extensions_magnus.conf \
         /etc/asterisk/extensions_magnus_did.conf /etc/asterisk/musiconhold_magnus.conf \
         /etc/asterisk/voicemail_magnus.conf; do
  [ -f "$F" ] && chmod 664 "$F"
done
chown asterisk:asterisk /etc/asterisk/*_magnus*.conf 2>/dev/null
ok "Permissões dos arquivos regenerados ajustadas (664)"

# www-data no grupo asterisk (necessário para regeneração)
if ! groups www-data 2>/dev/null | grep -qw asterisk; then
  usermod -aG asterisk www-data
  ok "www-data adicionado ao grupo asterisk"
else
  ok "www-data já está no grupo asterisk"
fi

info "Aplicando sounds..."
rsync -a /tmp/migracao-origem/sounds/ /var/lib/asterisk/sounds/
chown -R asterisk:asterisk /var/lib/asterisk/sounds/
ok "Sons aplicados"

# =====================================================================
# FASE 9 — CUSTOMIZAÇÕES DE BANCO (Admin)
# =====================================================================
titulo "FASE 9/13 — Customizações de banco Admin"

# 1) Confirmar dbhost preservado
DBHOST_ATUAL=$(grep "^dbhost" /etc/asterisk/res_config_mysql.conf | awk -F= '{print $2}' | tr -d ' ')
ok "dbhost = $DBHOST_ATUAL (preservado do destino)"

# 2) Alinhar senha do mbillingUser com res_config_mysql.conf
SENHA_MBILLING=$(grep "^dbpass" /etc/asterisk/res_config_mysql.conf | awk -F= '{print $2}' | tr -d ' ')

# Senha via stdin (heredoc) — não aparece em ps aux como aconteceria com -e
mysql_local 2>/dev/null <<EOSQL
CREATE USER IF NOT EXISTS 'mbillingUser'@'localhost' IDENTIFIED BY '$SENHA_MBILLING';
CREATE USER IF NOT EXISTS 'mbillingUser'@'127.0.0.1' IDENTIFIED BY '$SENHA_MBILLING';
ALTER USER 'mbillingUser'@'localhost' IDENTIFIED BY '$SENHA_MBILLING';
ALTER USER 'mbillingUser'@'127.0.0.1' IDENTIFIED BY '$SENHA_MBILLING';
GRANT ALL PRIVILEGES ON mbilling.* TO 'mbillingUser'@'localhost';
GRANT ALL PRIVILEGES ON mbilling.* TO 'mbillingUser'@'127.0.0.1';
FLUSH PRIVILEGES;
EOSQL
ok "mbillingUser criado/atualizado com senha do res_config_mysql.conf"

# 3) Validar tabelas customizadas Admin
for T in pkg_password_reset pkg_tickets pkg_ticket_messages; do
  EXISTS=$(mysql_local mbilling -N -e "SHOW TABLES LIKE '$T';" 2>/dev/null)
  [ -n "$EXISTS" ] && ok "Tabela customizada $T: presente" || warn "Tabela customizada $T: AUSENTE"
done

# 4) Salvar senha root em /root/passwordMysql.log
( umask 077; echo "$SENHA_ROOT_LOCAL" > /root/passwordMysql.log )
chmod 600 /root/passwordMysql.log
ok "Senha root salva em /root/passwordMysql.log (chmod 600)"

# 5) Criar usuário ADMIN para DBeaver
echo ""
read -sp "  Senha para $ADMIN_USER@$ADMIN_IP (sem caracteres especiais \$!'\"\\ espaço): " SENHA_ADMIN; echo ""
[ -z "$SENHA_ADMIN" ] && erro "Senha do usuário admin é obrigatória"
echo "$SENHA_ADMIN" | grep -qE "^[A-Za-z0-9@#%._+-]+$" || erro "Senha com caractere não permitido (use A-Z a-z 0-9 @ # % . _ + -)"

mysql_local 2>/dev/null <<EOSQL && ok "$ADMIN_USER@$ADMIN_IP criado" || warn "Erro ao criar $ADMIN_USER@$ADMIN_IP"
DROP USER IF EXISTS '$ADMIN_USER'@'$ADMIN_IP';
CREATE USER '$ADMIN_USER'@'$ADMIN_IP' IDENTIFIED BY '$SENHA_ADMIN';
GRANT ALL PRIVILEGES ON *.* TO '$ADMIN_USER'@'$ADMIN_IP' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOSQL

# 5b) Criar usuário API (se informado)
if [ -n "$API_USER" ]; then
  echo ""
  read -sp "  Senha para $API_USER@$API_IP (sem caracteres especiais \$!'\"\\ espaço): " SENHA_API; echo ""
  if [ -n "$SENHA_API" ]; then echo "$SENHA_API" | grep -qE "^[A-Za-z0-9@#%._+-]+$" || erro "Senha API com caractere não permitido (use A-Z a-z 0-9 @ # % . _ + -)"; fi
  [ -z "$SENHA_API" ] && warn "Senha do usuário API vazia — pulando" || {
    mysql_local 2>/dev/null <<EOSQL && ok "$API_USER@$API_IP criado" || warn "Erro ao criar $API_USER@$API_IP"
DROP USER IF EXISTS '$API_USER'@'$API_IP';
CREATE USER '$API_USER'@'$API_IP' IDENTIFIED BY '$SENHA_API';
GRANT ALL PRIVILEGES ON *.* TO '$API_USER'@'$API_IP' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOSQL
  }
fi

# 6) Limpar pkg_firewall (regras vindas da origem podem ser inválidas)
mysql_local mbilling -e "TRUNCATE TABLE pkg_firewall;" 2>/dev/null && ok "pkg_firewall limpa"

# 7) Limpar runtime do Magnus
rm -rf /var/www/html/mbilling/protected/runtime/* 2>/dev/null
ok "Runtime do Magnus limpo"

# =====================================================================
# FASE 10 — VALIDAÇÃO DE DADOS (banco + permissões)
# =====================================================================
titulo "FASE 10/13 — Validação de dados (banco + permissões)"

# Validar conexão do mbillingUser
MYSQL_PWD="$SENHA_MBILLING" mysql --user=mbillingUser mbilling -e "SELECT 1;" >/dev/null 2>&1 \
  && ok "mbillingUser consegue conectar" \
  || warn "mbillingUser NÃO consegue conectar — verificar senha"

# Contar registros principais
USERS=$(mysql_local mbilling -N -e "SELECT COUNT(*) FROM pkg_user;" 2>/dev/null)
TRUNKS=$(mysql_local mbilling -N -e "SELECT COUNT(*) FROM pkg_trunk;" 2>/dev/null)
RAMAIS=$(mysql_local mbilling -N -e "SELECT COUNT(*) FROM pkg_sip;" 2>/dev/null)
DIDS=$(mysql_local mbilling -N -e "SELECT COUNT(*) FROM pkg_did;" 2>/dev/null)
ok "Banco importado: $USERS usuários, $TRUNKS trunks, $RAMAIS ramais SIP, $DIDS DIDs"

# Versão Magnus final
VERSAO_FINAL=$(mysql_local mbilling -N -e "SELECT config_value FROM pkg_configuration WHERE config_key='version';" 2>/dev/null)
ok "Magnus versão: $VERSAO_FINAL"

# Verificar permissões dos arquivos críticos
PERM_OK=1
for F in /etc/asterisk/sip_magnus.conf /etc/asterisk/sip_magnus_user.conf; do
  if [ -f "$F" ]; then
    PERMS=$(stat -c '%a' "$F")
    [ "$PERMS" = "664" ] || { warn "$F está com permissão $PERMS (esperado 664)"; PERM_OK=0; }
  fi
done
[ $PERM_OK -eq 1 ] && ok "Permissões dos *_magnus*.conf OK"

# =====================================================================
# FASE 11 — RESUMO INTERMEDIÁRIO (antes do restart)
# =====================================================================
titulo "FASE 11/13 — Resumo da migração de dados"

echo ""
echo -e "  ${VERDE}${NEGRITO}✓ DADOS MIGRADOS COM SUCESSO${NC}"
echo ""
echo "  Origem:                    $ORIGEM_IP"
echo "  Destino:                   $(hostname) ($(hostname -I | awk '{print $1}'))"
echo "  Backup pré-migração:       $BACKUP_DIR"
echo "  Log:                       $LOG_FILE"
echo ""
warn "Serviços APACHE e ASTERISK estão PARADOS no destino (parados na Fase 8)."

# =====================================================================
# FASE 12 — REINÍCIO DOS SERVIÇOS (com confirmação)
# =====================================================================
titulo "FASE 12/13 — Reinício dos serviços"

if [ $NO_RESTART -eq 1 ]; then
  warn "Flag --no-restart ativa — pulando reinício automático"
  info "Para subir manualmente depois:"
  echo "    systemctl restart mariadb"
  echo "    systemctl restart php7.4-fpm   # ajuste à sua versão: php7.3 (Deb10), php7.4 (Deb11), php8.2 (Deb12)"
  echo "    systemctl restart apache2"
  echo "    systemctl restart asterisk"
  REINICIOU=0
else
  echo ""
  info "Vou reiniciar nesta ordem: mariadb → php-fpm → apache2 → asterisk"
  info "Esta operação NÃO mexe em firewall/SSH — sem risco de derrubar conexão."
  echo ""
  read -p "  Confirma reinício automático dos serviços? [S/n]: " RESP_RESTART
  RESP_RESTART=${RESP_RESTART:-S}

  if [[ "$RESP_RESTART" =~ ^[Ss]$ ]]; then
    info "Reiniciando MariaDB..."
    systemctl restart mariadb 2>/dev/null && ok "MariaDB OK" || warn "MariaDB com aviso"

    info "Reiniciando PHP-FPM..."
    # Detecta a versão instalada (php7.3/7.4/8.2...) — varia por Debian (10/11/12)
    PHPFPM_SVC=$(systemctl list-unit-files --type=service 2>/dev/null | grep -oE "php[0-9.]*-fpm" | head -1)
    if [ -n "$PHPFPM_SVC" ] && systemctl restart "$PHPFPM_SVC" 2>/dev/null; then
      ok "$PHPFPM_SVC OK"
    elif systemctl restart php-fpm 2>/dev/null; then
      ok "php-fpm OK"
    else
      warn "Nenhum php-fpm reiniciou — verificar versão"
    fi

    info "Reiniciando Apache..."
    systemctl restart apache2 2>/dev/null && ok "Apache OK" || warn "Apache com aviso"

    info "Reiniciando Asterisk (pode demorar até 30s)..."
    systemctl restart asterisk 2>/dev/null && ok "Asterisk OK" || warn "Asterisk com aviso"

    info "Aguardando 5 segundos para serviços estabilizarem..."
    sleep 5
    REINICIOU=1
  else
    warn "Reinício pulado por escolha do operador"
    REINICIOU=0
  fi
fi

# =====================================================================
# FASE 13 — VALIDAÇÃO FINAL PÓS-RESTART
# =====================================================================
titulo "FASE 13/13 — Validação final"

if [ "$REINICIOU" = "1" ]; then
  # Status dos serviços
  echo ""
  info "Estado dos serviços:"
  for SVC in mariadb apache2 asterisk; do
    STATE=$(systemctl is-active $SVC 2>/dev/null)
    if [ "$STATE" = "active" ]; then
      ok "$SVC: $STATE"
    else
      warn "$SVC: $STATE (verificar)"
    fi
  done

  PHPFPM_STATE=$(systemctl list-units --type=service --state=active 2>/dev/null | grep -oE "php[0-9.]+-fpm" | head -1)
  [ -n "$PHPFPM_STATE" ] && ok "$PHPFPM_STATE: active" || warn "Nenhum php-fpm ativo"

  # HTTP local
  echo ""
  info "Testando HTTP local..."
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 http://localhost/ 2>/dev/null)
  case "$HTTP_CODE" in
    200|301|302) ok "HTTP local: $HTTP_CODE (painel respondendo)" ;;
    500)         warn "HTTP local: 500 — verificar /var/www/html/mbilling/protected/runtime/application.log" ;;
    000)         warn "HTTP local: sem resposta — Apache pode estar com problema" ;;
    *)           warn "HTTP local: $HTTP_CODE (incomum, verificar)" ;;
  esac

  # Asterisk respondendo via CLI
  echo ""
  info "Testando Asterisk via CLI..."
  if asterisk -rx "core show uptime" 2>/dev/null | grep -q "uptime"; then
    UPTIME_AST=$(asterisk -rx "core show uptime" 2>/dev/null | head -1)
    ok "Asterisk OK: $UPTIME_AST"
  else
    warn "Asterisk não responde via CLI (pode ainda estar inicializando — aguarde 30s e tente: asterisk -rx 'core show uptime')"
  fi

  # Peers SIP (info sobre quantos foram carregados)
  PEERS=$(asterisk -rx "sip show peers" 2>/dev/null | tail -1 | grep -oE "[0-9]+ sip peers" | head -1)
  [ -n "$PEERS" ] && ok "Asterisk carregou: $PEERS" || info "sip show peers ainda não disponível"

  # Erros recentes
  echo ""
  APP_LOG=/var/www/html/mbilling/protected/runtime/application.log
  if [ -f "$APP_LOG" ]; then
    HOJE=$(date '+%Y/%m/%d')
    ERROS_HOJE=$(grep "^$HOJE" "$APP_LOG" 2>/dev/null | grep -ciE "\[error\]|exception|fatal")
    if [ "$ERROS_HOJE" -eq 0 ]; then
      ok "application.log: sem erros HOJE"
    else
      warn "application.log: $ERROS_HOJE erros hoje — verificar: tail -50 $APP_LOG | grep -i error"
    fi
  fi
else
  warn "Restart pulado — validação pós-restart não aplicada"
  info "Após subir manualmente, rode: bash /root/magnus-health-check.sh"
fi

# Resumo final
echo ""
titulo "MIGRAÇÃO CONCLUÍDA"
echo ""
echo -e "  ${VERDE}${NEGRITO}✓ FLUXO COMPLETO${NC}"
echo ""
echo "  Origem:                    $ORIGEM_IP"
echo "  Destino:                   $(hostname) ($(hostname -I | awk '{print $1}'))"
echo "  Backup pré-migração:       $BACKUP_DIR"
echo "  Log completo:              $LOG_FILE"
echo ""
echo -e "${NEGRITO}  PRÓXIMOS PASSOS RECOMENDADOS:${NC}"
echo ""
echo "  1. Validar painel pelo navegador:"
echo "       http://$(hostname -I | awk '{print $1}')/"
echo ""
echo "  2. Rodar health check completo:"
echo "       bash /root/magnus-health-check.sh"
echo ""
echo "  3. Configurar firewall (script separado):"
echo "       bash /root/configurar_firewalld_admin_user.sh"
echo ""
echo "  4. Configurar Apache VirtualHost + SSL (script separado):"
echo "       bash /root/configurar_ssl_admin_user.sh"
echo ""
echo "  5. Configurar cron, backup diário, logrotate (script separado):"
echo "       bash /root/configurar_seguranca_diaria.sh"
echo ""
echo "  6. (Quando estável) Executar update.sh em janela de manutenção:"
echo "       bash /var/www/html/mbilling/protected/commands/update.sh"
echo ""
echo "  7. Apontar DNS do domínio para este servidor quando confirmar tudo OK."
echo ""
echo -e "${NEGRITO}  ROLLBACK (se algo deu errado):${NC}"
echo ""
echo "       mysql mbilling < $BACKUP_DIR/mbilling-destino-antes.sql"
echo "       tar xzf $BACKUP_DIR/etc-asterisk-antes.tar.gz -C /"
echo "       systemctl restart asterisk apache2 mariadb"
echo ""
warn "TROCAR senhas dos usuários MySQL ($ADMIN_USER@$ADMIN_IP${API_USER:+ e $API_USER@$API_IP}) se foram expostas neste log!"
echo ""
exit 0
