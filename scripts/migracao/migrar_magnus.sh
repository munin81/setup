#!/bin/bash
# =====================================================================
# Voxcorp Setup — migrar_magnus.sh
# Versão: 5.0 (08 de junho de 2026)
# Função: Migração completa de MagnusBilling entre servidores
#         (cenário base: 136 → 119, mas parametrizável)
# Autor: Voxcorp Telecom (EMB Serviços em Telecomunicações)
#
# Pré-requisitos:
#   - Rodar no servidor DESTINO (alvo da migração) como root
#   - Servidor destino com Magnus 7.x já instalado (instalação limpa)
#   - SSH para origem na porta 22022 com IP autorizado
#   - sshpass, rsync, mysqldump instalados (script instala se faltar)
#
# Uso:
#   bash migrar_magnus.sh                # interativo
#   bash migrar_magnus.sh --dry-run      # simula, mostra ações e sai
#   bash migrar_magnus.sh --help         # mostra ajuda
#
# Fluxo (16 fases):
#   1.  Validação de pré-requisitos no destino
#   2.  Coleta de parâmetros (IPs, senhas, domínio, SSL, parar serviços)
#   3.  Teste SSH com origem
#   4.  Backup do estado atual do destino (rollback)
#   5.  Captura banco da origem (mysqldump via SSH)
#   6.  Captura /etc/asterisk/ da origem (rsync)
#   7.  Captura /var/lib/asterisk/sounds/ da origem (rsync)
#   8.  Aplicação no destino: parar serviços, importar banco, ajustar configs
#   9.  Customizações Voxcorp — Banco (17 itens parte 1)
#   10. Customizações Voxcorp — Segurança / firewalld
#   11. Customizações Voxcorp — DNS / SSL
#   12. Customizações Voxcorp — Cron / Logrotate / Backup
#   13. Customizações Voxcorp — Página de acesso bloqueado
#   14. Reinicialização ordenada dos serviços
#   15. Validação final
#   16. Resumo e próximos passos
#
# Idempotência: PARCIAL (etapas Voxcorp são idempotentes; importação banco NÃO)
# Modifica estado: SIM (massivamente — vide fases 8 em diante)
# Requer janela de manutenção: SIM (parar serviços no destino é obrigatório)
#
# NÃO ROUDA update.sh automaticamente (decisão Edgar 08/06/2026).
# =====================================================================

set -o pipefail

# ---------------------------------------------------------------------
# Cores e funções de log
# ---------------------------------------------------------------------
VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'

LOG_FILE=""  # definido depois

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

ssh_origem() {
  sshpass -p "$ORIGEM_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -p "$ORIGEM_PORT" \
    "$ORIGEM_USER@$ORIGEM_IP" "$@"
}

rsync_origem() {
  local SRC="$1"
  local DST="$2"
  sshpass -p "$ORIGEM_PASS" rsync -az --delete \
    -e "ssh -o StrictHostKeyChecking=no -p $ORIGEM_PORT" \
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
for ARG in "$@"; do
  case "$ARG" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      sed -n '/^# Voxcorp Setup/,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Opção desconhecida: $ARG"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------
# Diretório e log
# ---------------------------------------------------------------------
LOG_DIR="/var/log/voxcorp-setup"
mkdir -p "$LOG_DIR" || erro "Sem permissão em $LOG_DIR — rode como root"
chmod 750 "$LOG_DIR"
LOG_FILE="$LOG_DIR/migrar-magnus-$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

clear
titulo "MIGRAÇÃO COMPLETA MAGNUSBILLING (v5.0)"
info "Servidor DESTINO: $(hostname) ($(hostname -I | awk '{print $1}'))"
info "Data/hora:        $(date '+%Y-%m-%d %H:%M:%S')"
info "Log:              $LOG_FILE"
[ $DRY_RUN -eq 1 ] && warn "MODO DRY-RUN ATIVO — nada será modificado"

# =====================================================================
# FASE 1 — VALIDAÇÃO DE PRÉ-REQUISITOS NO DESTINO
# =====================================================================
titulo "FASE 1/16 — Validação de pré-requisitos no destino"

[ "$EUID" -ne 0 ] && erro "Rode como root"

for CMD in mysql rsync ssh systemctl; do
  command -v $CMD >/dev/null 2>&1 || erro "$CMD não está instalado"
done
ok "Comandos básicos OK"

# sshpass pode faltar
if ! command -v sshpass >/dev/null 2>&1; then
  info "Instalando sshpass..."
  apt-get install -y sshpass >/dev/null 2>&1 || erro "Falha ao instalar sshpass"
  ok "sshpass instalado"
fi

# Confirmar que Magnus está instalado no destino
[ ! -d "/var/www/html/mbilling" ] && erro "Magnus não está instalado em /var/www/html/mbilling no destino"
[ ! -f "/etc/asterisk/sip.conf" ] && erro "Asterisk não está instalado no destino"
ok "Magnus e Asterisk presentes no destino"

# Senha root MySQL
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
titulo "FASE 2/16 — Parâmetros da migração"

echo ""
info "Servidor de ORIGEM (de onde vamos copiar):"
read -p "  IP origem: " ORIGEM_IP
read -p "  Porta SSH origem [22022]: " ORIGEM_PORT; ORIGEM_PORT=${ORIGEM_PORT:-22022}
read -p "  Usuário SSH origem [root]: " ORIGEM_USER; ORIGEM_USER=${ORIGEM_USER:-root}
read -sp "  Senha SSH origem: " ORIGEM_PASS; echo ""

[ -z "$ORIGEM_IP" ] || [ -z "$ORIGEM_PASS" ] && erro "IP e senha de origem são obrigatórios"

echo ""
info "Configurações do destino:"
read -p "  Domínio para este servidor (vazio = só IP): " DOMINIO_DESTINO
read -p "  IP da VPN do administrador (para liberar MySQL/SSH): " IP_VPN_ADMIN
[ -z "$IP_VPN_ADMIN" ] && erro "IP da VPN é obrigatório (para liberar DBeaver e SSH)"

echo ""
info "SSL/HTTPS:"
echo "  [1] Gerar SSL novo via Let's Encrypt (precisa domínio + porta 80 acessível)"
echo "  [2] Pular SSL agora (configurar depois)"
read -p "  Escolha [2]: " SSL_OPCAO; SSL_OPCAO=${SSL_OPCAO:-2}

echo ""
info "Parar serviços na origem durante a captura?"
echo "  [1] SIM — parar Asterisk e Apache na origem (dump consistente, recomendado)"
echo "  [2] NÃO — manter origem rodando (mais rápido, mas risco de inconsistência)"
read -p "  Escolha [1]: " PARAR_ORIGEM; PARAR_ORIGEM=${PARAR_ORIGEM:-1}

# Resumo
echo ""
titulo "RESUMO DA MIGRAÇÃO"
echo ""
echo "  ORIGEM:    $ORIGEM_USER@$ORIGEM_IP:$ORIGEM_PORT"
echo "  DESTINO:   $(hostname) ($(hostname -I | awk '{print $1}'))"
echo "  Domínio:   ${DOMINIO_DESTINO:-(somente IP)}"
echo "  IP VPN:    $IP_VPN_ADMIN"
echo "  SSL:       $([ "$SSL_OPCAO" = "1" ] && echo "Gerar via Let's Encrypt" || echo "Pular")"
echo "  Parar origem: $([ "$PARAR_ORIGEM" = "1" ] && echo "SIM" || echo "NÃO")"
echo ""
warn "Esta operação SUBSTITUI completamente o Magnus do destino pelos dados da origem."
warn "Tabelas customizadas Voxcorp (pkg_password_reset, pkg_tickets, pkg_ticket_messages) virão da origem."
echo ""
confirma "Confirma todos os parâmetros acima?"

if [ $DRY_RUN -eq 1 ]; then
  warn "Modo dry-run — saindo aqui sem executar"
  exit 0
fi

# =====================================================================
# FASE 3 — TESTE SSH COM ORIGEM
# =====================================================================
titulo "FASE 3/16 — Conexão SSH com origem"

ssh_origem "echo OK" >/dev/null 2>&1 || erro "Falha SSH com $ORIGEM_IP:$ORIGEM_PORT (verifique IP, porta, senha)"
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
# FASE 4 — BACKUP DO ESTADO ATUAL DO DESTINO (rollback)
# =====================================================================
titulo "FASE 4/16 — Backup do estado atual do destino"

BACKUP_DIR="/root/voxcorp-backup-pre-migracao-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

info "Dump do banco mbilling atual..."
MYSQL_PWD="$SENHA_ROOT_LOCAL" mysqldump --routines --triggers --events \
  --single-transaction --quick mbilling > "$BACKUP_DIR/mbilling-destino-antes.sql" 2>/dev/null
ok "Banco salvo em $BACKUP_DIR/mbilling-destino-antes.sql"

info "Backup de /etc/asterisk..."
tar czf "$BACKUP_DIR/etc-asterisk-antes.tar.gz" /etc/asterisk 2>/dev/null
ok "Asterisk config salvo"

info "Backup de configs Apache + firewalld..."
tar czf "$BACKUP_DIR/configs-sistema.tar.gz" /etc/apache2 /etc/firewalld 2>/dev/null
ok "Configs sistema salvas"

info "Backup completo em: $BACKUP_DIR"

# =====================================================================
# FASE 5 — CAPTURA DO BANCO DA ORIGEM
# =====================================================================
titulo "FASE 5/16 — Captura do banco da origem"

if [ "$PARAR_ORIGEM" = "1" ]; then
  info "Parando Apache na origem..."
  ssh_origem "systemctl stop apache2 2>/dev/null || systemctl stop httpd 2>/dev/null" || warn "Não consegui parar Apache na origem"
  ok "Apache origem parado"
fi

info "Executando mysqldump na origem (pode demorar conforme tamanho)..."
ssh_origem "mysqldump --routines --triggers --events --single-transaction --quick mbilling 2>/dev/null | gzip" > "$BACKUP_DIR/mbilling-origem.sql.gz"
SIZE=$(du -h "$BACKUP_DIR/mbilling-origem.sql.gz" | cut -f1)
ok "Dump da origem capturado ($SIZE)"

# Verificar que o dump não está vazio
[ ! -s "$BACKUP_DIR/mbilling-origem.sql.gz" ] && erro "Dump da origem ficou vazio — abortando"

# =====================================================================
# FASE 6 — CAPTURA DE /etc/asterisk DA ORIGEM
# =====================================================================
titulo "FASE 6/16 — Captura de /etc/asterisk/ da origem"

info "Sincronizando /etc/asterisk/..."
mkdir -p /tmp/migracao-origem/etc-asterisk
rsync_origem "/etc/asterisk/" "/tmp/migracao-origem/etc-asterisk/" >/dev/null 2>&1 || warn "Algumas falhas durante rsync /etc/asterisk"
ok "Configs Asterisk da origem em /tmp/migracao-origem/etc-asterisk/"

# =====================================================================
# FASE 7 — CAPTURA DE /var/lib/asterisk/sounds DA ORIGEM
# =====================================================================
titulo "FASE 7/16 — Captura de /var/lib/asterisk/sounds/ da origem"

info "Sincronizando /var/lib/asterisk/sounds/..."
mkdir -p /tmp/migracao-origem/sounds
rsync_origem "/var/lib/asterisk/sounds/" "/tmp/migracao-origem/sounds/" >/dev/null 2>&1 || warn "Algumas falhas durante rsync de sounds"
ok "Sons capturados"

# Religar origem se foi parada
if [ "$PARAR_ORIGEM" = "1" ]; then
  info "Religando Apache na origem..."
  ssh_origem "systemctl start apache2 2>/dev/null || systemctl start httpd 2>/dev/null"
  ok "Apache origem religado"
fi

# =====================================================================
# FASE 8 — APLICAÇÃO NO DESTINO
# =====================================================================
titulo "FASE 8/16 — Aplicação no destino"

info "Parando serviços no destino..."
systemctl stop apache2 2>/dev/null
systemctl stop asterisk 2>/dev/null
ok "Apache e Asterisk parados no destino"

info "Importando banco da origem..."
mysql_local -e "DROP DATABASE IF EXISTS mbilling; CREATE DATABASE mbilling CHARACTER SET utf8 COLLATE utf8_general_ci;"
zcat "$BACKUP_DIR/mbilling-origem.sql.gz" | MYSQL_PWD="$SENHA_ROOT_LOCAL" mysql --user=root mbilling
[ $? -ne 0 ] && erro "Falha ao importar banco — execute rollback manual com $BACKUP_DIR/mbilling-destino-antes.sql"
ok "Banco importado da origem"

info "Aplicando /etc/asterisk/ da origem..."
# Preservar res_config_mysql.conf do destino (senha local diferente)
cp /etc/asterisk/res_config_mysql.conf /tmp/res_config_mysql.conf.destino 2>/dev/null
rsync -a --delete /tmp/migracao-origem/etc-asterisk/ /etc/asterisk/
cp /tmp/res_config_mysql.conf.destino /etc/asterisk/res_config_mysql.conf 2>/dev/null
chown -R asterisk:asterisk /etc/asterisk/
ok "Asterisk config aplicada (res_config_mysql.conf preservado)"

info "Aplicando sounds..."
rsync -a /tmp/migracao-origem/sounds/ /var/lib/asterisk/sounds/
chown -R asterisk:asterisk /var/lib/asterisk/sounds/
ok "Sons aplicados"

# =====================================================================
# FASE 9 — CUSTOMIZAÇÕES VOXCORP — BANCO (itens 1-7 da lista)
# =====================================================================
titulo "FASE 9/16 — Customizações Voxcorp: Banco"

# 1) dbhost = 127.0.0.1 (padrão Magnus, já deve estar do res_config_mysql.conf preservado)
DBHOST_ATUAL=$(grep "^dbhost" /etc/asterisk/res_config_mysql.conf | awk -F= '{print $2}' | tr -d ' ')
ok "dbhost = $DBHOST_ATUAL (preservado do destino)"

# 2) Trocar senha do mbillingUser (alinhar com res_config_mysql.conf)
SENHA_MBILLING=$(grep "^dbpass" /etc/asterisk/res_config_mysql.conf | awk -F= '{print $2}' | tr -d ' ')
mysql_local -e "
  ALTER USER 'mbillingUser'@'localhost' IDENTIFIED BY '$SENHA_MBILLING';
  ALTER USER 'mbillingUser'@'127.0.0.1' IDENTIFIED BY '$SENHA_MBILLING';
  FLUSH PRIVILEGES;
" 2>/dev/null || warn "mbillingUser pode não existir ainda — será criado pelo Magnus"

mysql_local -e "
  CREATE USER IF NOT EXISTS 'mbillingUser'@'localhost' IDENTIFIED BY '$SENHA_MBILLING';
  CREATE USER IF NOT EXISTS 'mbillingUser'@'127.0.0.1' IDENTIFIED BY '$SENHA_MBILLING';
  GRANT ALL PRIVILEGES ON mbilling.* TO 'mbillingUser'@'localhost';
  GRANT ALL PRIVILEGES ON mbilling.* TO 'mbillingUser'@'127.0.0.1';
  FLUSH PRIVILEGES;
" 2>/dev/null
ok "mbillingUser criado/atualizado"

# 3) Tabelas customizadas Voxcorp já vieram no dump da origem — só validar
for T in pkg_password_reset pkg_tickets pkg_ticket_messages; do
  EXISTS=$(mysql_local mbilling -N -e "SHOW TABLES LIKE '$T';" 2>/dev/null)
  [ -n "$EXISTS" ] && ok "Tabela customizada $T: presente" || warn "Tabela customizada $T: AUSENTE (verificar origem)"
done

# 4) Salvar senha root em /root/passwordMysql.log
echo "$SENHA_ROOT_LOCAL" > /root/passwordMysql.log
chmod 600 /root/passwordMysql.log
ok "Senha root salva em /root/passwordMysql.log (chmod 600)"

# 5) Criar voxcorp@IP_VPN com plugin correto
mysql_local -e "DROP USER IF EXISTS 'voxcorp'@'$IP_VPN_ADMIN';" 2>/dev/null
read -sp "  Senha para voxcorp@$IP_VPN_ADMIN (sem caracteres especiais \$!'\\): " SENHA_VOXCORP; echo ""
[ -z "$SENHA_VOXCORP" ] && erro "Senha do voxcorp é obrigatória"

mysql_local -e "
  CREATE USER 'voxcorp'@'$IP_VPN_ADMIN' IDENTIFIED BY '$SENHA_VOXCORP';
  GRANT ALL PRIVILEGES ON *.* TO 'voxcorp'@'$IP_VPN_ADMIN' WITH GRANT OPTION;
  ALTER USER 'voxcorp'@'$IP_VPN_ADMIN' IDENTIFIED VIA mysql_native_password USING PASSWORD('$SENHA_VOXCORP');
  FLUSH PRIVILEGES;
" 2>/dev/null
ok "voxcorp@$IP_VPN_ADMIN criado (com plugin mysql_native_password)"

# 6) Limpar pkg_firewall (regras inválidas que vêm do banco da origem)
mysql_local mbilling -e "TRUNCATE TABLE pkg_firewall;" 2>/dev/null && ok "pkg_firewall limpa"

# 7) Limpar runtime do Magnus
rm -rf /var/www/html/mbilling/protected/runtime/* 2>/dev/null
ok "Runtime do Magnus limpo"

# =====================================================================
# FASE 10 — CUSTOMIZAÇÕES VOXCORP — SEGURANÇA / FIREWALLD
# =====================================================================
titulo "FASE 10/16 — Customizações Voxcorp: Segurança / firewalld"

# 8) SSH na porta 22022
if ! grep -qE "^Port 22022" /etc/ssh/sshd_config; then
  sed -i 's/^#\?Port .*/Port 22022/' /etc/ssh/sshd_config
  echo "Port 22022" >> /etc/ssh/sshd_config
  warn "SSH configurado para porta 22022 — vai reiniciar SSH no final"
fi
ok "SSH configurado na porta 22022"

# 9) Permissões dos arquivos *_magnus*.conf (lição aprendida 28/05)
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

# www-data no grupo asterisk
if ! groups www-data | grep -qw asterisk; then
  usermod -aG asterisk www-data
  ok "www-data adicionado ao grupo asterisk"
else
  ok "www-data já está no grupo asterisk"
fi

# 10) firewalld + anti-scanner SIP
if systemctl is-active firewalld >/dev/null 2>&1; then
  ok "firewalld já ativo"
else
  systemctl start firewalld 2>/dev/null
  systemctl enable firewalld 2>/dev/null
  ok "firewalld habilitado"
fi

# Restringir SSH 22022 ao bloco do admin
BLOCO_ADMIN=$(echo "$IP_VPN_ADMIN" | awk -F. '{print $1"."$2"."$3".0/24"}')
firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$BLOCO_ADMIN port port=22022 protocol=tcp accept" 2>/dev/null
firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$BLOCO_ADMIN port port=3306 protocol=tcp accept" 2>/dev/null
firewall-cmd --permanent --remove-port=22022/tcp 2>/dev/null
firewall-cmd --permanent --remove-service=ssh 2>/dev/null

# Adicionar IAX se necessário
firewall-cmd --permanent --add-port=4569/udp 2>/dev/null

# Anti-scanner SIP via direct rules
for STRING in "friendly-scanner" "VaxSIPUserAgent"; do
  for PROTO in tcp udp; do
    for PORT in 5060 5080; do
      firewall-cmd --permanent --direct --add-rule ipv4 filter INPUT 0 \
        -p $PROTO --dport $PORT -m string --string "$STRING" --algo bm -j DROP 2>/dev/null
    done
  done
done

firewall-cmd --reload >/dev/null 2>&1
ok "firewalld configurado: SSH/MySQL restritos ao bloco $BLOCO_ADMIN, anti-scanner ativo, IAX 4569 aberto"

# 11) Fail2ban ativo
systemctl is-active fail2ban >/dev/null 2>&1 && ok "fail2ban ativo" || warn "fail2ban não ativo (instalar manualmente)"

# =====================================================================
# FASE 11 — CUSTOMIZAÇÕES VOXCORP — DNS / SSL
# =====================================================================
titulo "FASE 11/16 — Customizações Voxcorp: DNS / SSL"

if [ -n "$DOMINIO_DESTINO" ]; then
  # 12) Configurar Apache VirtualHost
  if [ ! -f "/etc/apache2/sites-available/voxcorp-magnus.conf" ]; then
    cat > /etc/apache2/sites-available/voxcorp-magnus.conf << APACHEEOF
<VirtualHost *:80>
    ServerName $DOMINIO_DESTINO
    DocumentRoot /var/www/html/mbilling
    <Directory /var/www/html/mbilling>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/voxcorp-magnus-error.log
    CustomLog \${APACHE_LOG_DIR}/voxcorp-magnus-access.log combined
</VirtualHost>
APACHEEOF
    a2ensite voxcorp-magnus.conf >/dev/null 2>&1
    a2enmod rewrite ssl >/dev/null 2>&1
    ok "Apache VirtualHost criado para $DOMINIO_DESTINO"
  else
    ok "Apache VirtualHost já existe"
  fi

  # 13) SSL Let's Encrypt
  if [ "$SSL_OPCAO" = "1" ]; then
    if ! command -v certbot >/dev/null 2>&1; then
      info "Instalando certbot..."
      apt-get install -y certbot python3-certbot-apache >/dev/null 2>&1
    fi
    warn "Vou tentar gerar SSL — domínio $DOMINIO_DESTINO precisa estar apontando para este IP"
    certbot --apache -d "$DOMINIO_DESTINO" --non-interactive --agree-tos --email admin@voxcorptelecom.com.br --redirect 2>&1 | tail -5
    ok "SSL Let's Encrypt configurado (verificar acima)"
  else
    info "SSL pulado conforme opção"
  fi
else
  warn "Sem domínio configurado — Apache mantém configuração padrão"
fi

# =====================================================================
# FASE 12 — CUSTOMIZAÇÕES VOXCORP — CRON / LOGROTATE / BACKUP
# =====================================================================
titulo "FASE 12/16 — Customizações Voxcorp: Cron / Logrotate / Backup"

# 14) Cron do Magnus (geralmente já existe, validar)
CRON_COUNT=$(crontab -l 2>/dev/null | grep -cE "magnus|mbilling|cron\.php")
[ "$CRON_COUNT" -gt 0 ] && ok "Cron Magnus presente ($CRON_COUNT linhas)" || warn "Sem cron Magnus — verificar"

# 15) Logrotate
if [ ! -f "/etc/logrotate.d/voxcorp-magnus" ]; then
  cat > /etc/logrotate.d/voxcorp-magnus << 'LOGROTATEEOF'
/var/www/html/mbilling/protected/runtime/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 664 asterisk asterisk
}
LOGROTATEEOF
  ok "Logrotate configurado"
else
  ok "Logrotate já configurado"
fi

# 16) Backup automático diário
if [ ! -f "/etc/cron.daily/voxcorp-backup-magnus" ]; then
  cat > /etc/cron.daily/voxcorp-backup-magnus << 'BACKUPEOF'
#!/bin/bash
BACKUP_DIR="/var/backups/voxcorp-magnus"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
SENHA=$(cat /root/passwordMysql.log)
MYSQL_PWD="$SENHA" mysqldump --single-transaction --quick --routines --triggers --events mbilling | gzip > "$BACKUP_DIR/mbilling-$(date +%Y%m%d).sql.gz"
# manter últimos 7 dias
find "$BACKUP_DIR" -name "mbilling-*.sql.gz" -mtime +7 -delete
BACKUPEOF
  chmod +x /etc/cron.daily/voxcorp-backup-magnus
  ok "Backup automático diário em /etc/cron.daily/voxcorp-backup-magnus"
else
  ok "Backup automático já configurado"
fi

# =====================================================================
# FASE 13 — PÁGINA DE ACESSO BLOQUEADO
# =====================================================================
titulo "FASE 13/16 — Página de acesso bloqueado"

# 17) Página customizada para acesso negado
mkdir -p /var/www/html/blocked
cat > /var/www/html/blocked/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8">
  <title>Acesso Restrito - Voxcorp</title>
  <style>
    body { font-family: sans-serif; text-align: center; padding: 50px; background: #1E1530; color: white; }
    h1 { color: #FF8A2B; }
    p { color: #ccc; }
  </style>
</head>
<body>
  <h1>Acesso Restrito</h1>
  <p>Este sistema é de uso autorizado apenas.</p>
  <p>Se você precisa acessar, entre em contato com o administrador.</p>
  <p><small>Voxcorp Telecom</small></p>
</body>
</html>
HTMLEOF
ok "Página de acesso bloqueado em /var/www/html/blocked/index.html"

# =====================================================================
# FASE 14 — REINICIALIZAÇÃO DOS SERVIÇOS
# =====================================================================
titulo "FASE 14/16 — Reinicialização ordenada"

info "Reiniciando MariaDB..."
systemctl restart mariadb 2>/dev/null && ok "MariaDB OK" || warn "MariaDB com aviso"

info "Reiniciando Apache..."
systemctl restart apache2 2>/dev/null && ok "Apache OK" || warn "Apache com aviso"

info "Reiniciando php-fpm..."
systemctl restart php7.3-fpm 2>/dev/null || systemctl restart php-fpm 2>/dev/null
ok "PHP-FPM reiniciado"

info "Reiniciando Asterisk..."
systemctl restart asterisk 2>/dev/null && ok "Asterisk OK" || warn "Asterisk com aviso"

info "Reiniciando fail2ban..."
systemctl restart fail2ban 2>/dev/null
ok "fail2ban reiniciado"

info "Reiniciando SSH (porta 22022)..."
systemctl restart sshd 2>/dev/null
ok "SSH reiniciado — próxima conexão usar porta 22022"

sleep 3

# =====================================================================
# FASE 15 — VALIDAÇÃO FINAL
# =====================================================================
titulo "FASE 15/16 — Validação final"

# HTTP
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 http://localhost/)
[ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] && ok "HTTP local: $HTTP_CODE" || warn "HTTP local: $HTTP_CODE (verificar)"

# Asterisk
asterisk -rx "core show uptime" 2>&1 | head -1 | grep -q "uptime" && ok "Asterisk respondendo via CLI" || warn "Asterisk não responde via CLI"

# MySQL local
mysql_local -e "SELECT COUNT(*) FROM mbilling.pkg_user;" >/dev/null 2>&1 && ok "MySQL local OK" || warn "MySQL local com problema"

# Versão Magnus
VERSAO_FINAL=$(mysql_local mbilling -N -e "SELECT config_value FROM pkg_configuration WHERE config_key='version';" 2>/dev/null)
ok "Magnus versão: $VERSAO_FINAL"

# Trunks SIP
TRUNKS=$(mysql_local mbilling -N -e "SELECT COUNT(*) FROM pkg_trunk;" 2>/dev/null)
ok "Trunks SIP no banco: $TRUNKS"

# Sincronia arquivo
PEERS=$(asterisk -rx "sip show peers" 2>/dev/null | tail -1 | grep -oE "[0-9]+ sip peers" | head -1)
ok "Asterisk: $PEERS"

# =====================================================================
# FASE 16 — RESUMO E PRÓXIMOS PASSOS
# =====================================================================
titulo "FASE 16/16 — Resumo e próximos passos"

echo ""
echo -e "  ${VERDE}${NEGRITO}✓ MIGRAÇÃO CONCLUÍDA${NC}"
echo ""
echo "  Origem:           $ORIGEM_IP"
echo "  Destino:          $(hostname) ($(hostname -I | awk '{print $1}'))"
echo "  Backup pré-migração: $BACKUP_DIR"
echo "  Log completo:     $LOG_FILE"
echo ""
echo -e "${NEGRITO}  PRÓXIMOS PASSOS RECOMENDADOS:${NC}"
echo ""
echo "  1. Validar acesso pelo navegador:"
[ -n "$DOMINIO_DESTINO" ] && echo "       https://$DOMINIO_DESTINO/" || echo "       http://$(hostname -I | awk '{print $1}')/"
echo ""
echo "  2. Validar DBeaver com voxcorp@$IP_VPN_ADMIN"
echo ""
echo "  3. Rodar health check:"
echo "       bash /root/magnus-health-check.sh"
echo ""
echo "  4. Executar update.sh em janela de manutenção (NÃO foi rodado neste script):"
echo "       bash /var/www/html/mbilling/protected/commands/update.sh"
echo ""
echo "  5. Apontar DNS de $DOMINIO_DESTINO para $(hostname -I | awk '{print $1}') (se ainda não)"
echo ""
echo "  6. Limpar backup antigo de origem quando confirmar tudo OK:"
echo "       rm -rf /tmp/migracao-origem"
echo ""
echo "  7. ROLLBACK (se algo der errado, restaurar estado anterior):"
echo "       mysql -uroot mbilling < $BACKUP_DIR/mbilling-destino-antes.sql"
echo "       tar xzf $BACKUP_DIR/etc-asterisk-antes.tar.gz -C /"
echo "       systemctl restart asterisk apache2 mariadb"
echo ""
warn "TROCAR a senha do voxcorp@$IP_VPN_ADMIN se foi exposta neste log!"
echo ""
exit 0
