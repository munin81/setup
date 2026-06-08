#!/bin/bash
# =====================================================================
#     RESTAURAÇÃO BLINDADA MAGNUSBILLING - VOXCORP
#     Versão 2.0 - Com migração de arquivos CentOS → Debian
# =====================================================================

VERDE='\033[0;32m'
AMARELO='\033[1;33m'
VERMELHO='\033[0;31m'
AZUL='\033[0;34m'
NC='\033[0m'

ok()    { echo -e "${VERDE}[OK]${NC} $1"; }
info()  { echo -e "${AZUL}[INFO]${NC} $1"; }
warn()  { echo -e "${AMARELO}[AVISO]${NC} $1"; }
erro()  { echo -e "${VERMELHO}[ERRO]${NC} $1"; exit 1; }

echo ""
echo "====================================================="
echo -e "${AZUL}    RESTAURAÇÃO BLINDADA MAGNUSBILLING - VOXCORP${NC}"
echo "====================================================="
echo ""

# =====================================================================
# CONFIGURAÇÕES DO SERVIDOR ORIGEM (CentOS)
# =====================================================================
ORIGEM_IP="186.209.119.190"
ORIGEM_USER="root"
ORIGEM_PASS="hysvir-Xosfy8-cybtoc"
ORIGEM_PORT="22022"
ORIGEM_PATH="/var/www/html/mbilling"
DESTINO_PATH="/var/www/html/mbilling"

# =====================================================================
# PRÉ-REQUISITOS
# =====================================================================
info "Instalando dependências necessárias..."
apt-get install -y sshpass rsync 2>/dev/null | tail -1
ok "Dependências OK"

# =====================================================================
# ETAPA 0 — VERIFICAR CONEXÃO COM ORIGEM
# =====================================================================
echo ""
echo "-----------------------------------------------------"
echo " ETAPA 0/8 — Verificando conexão com servidor origem"
echo "-----------------------------------------------------"

sshpass -p "${ORIGEM_PASS}" ssh \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=15 \
  -p ${ORIGEM_PORT} \
  ${ORIGEM_USER}@${ORIGEM_IP} \
  "echo 'Conexão OK'" > /dev/null 2>&1 \
  && ok "Conexão SSH com CentOS estabelecida (${ORIGEM_IP}:${ORIGEM_PORT})" \
  || erro "Falha na conexão SSH com ${ORIGEM_IP}:${ORIGEM_PORT} — verifique IP, porta e senha"

# =====================================================================
# ETAPA 1 — BACKUP DO BACKUP (salvar configs atuais do Debian)
# =====================================================================
echo ""
echo "-----------------------------------------------------"
echo " ETAPA 1/8 — Salvando configurações atuais do Debian"
echo "-----------------------------------------------------"

mkdir -p /tmp/mbilling_config_bkp
cp ${DESTINO_PATH}/protected/config/main.php /tmp/mbilling_config_bkp/ 2>/dev/null && ok "main.php salvo" || warn "main.php não encontrado (será copiado da origem)"
cp ${DESTINO_PATH}/protected/config/db.php   /tmp/mbilling_config_bkp/ 2>/dev/null && ok "db.php salvo"   || warn "db.php não encontrado (será copiado da origem)"

# =====================================================================
# ETAPA 2 — IMPORTAÇÃO DO BANCO DE DADOS
# =====================================================================
echo ""
echo "-----------------------------------------------------"
echo " ETAPA 2/8 — Banco de dados"
echo "-----------------------------------------------------"

SENHA_ROOT_SQL=$(cat /root/passwordMysql.log 2>/dev/null)
if [ -z "$SENHA_ROOT_SQL" ]; then
  warn "Arquivo /root/passwordMysql.log não encontrado."
  read -sp "Digite a senha root do MySQL: " SENHA_ROOT_SQL
  echo ""
fi

# Verifica se já existe banco restaurado
DB_EXISTE=$(mysql -u root -p"$SENHA_ROOT_SQL" -e "SHOW DATABASES LIKE 'mbilling';" 2>/dev/null | grep mbilling)

if [ -n "$DB_EXISTE" ]; then
  warn "Banco 'mbilling' já existe — pulando importação SQL (backup já restaurado anteriormente)"
  ok "Banco de dados OK"
else
  read -p "Arquivo de backup SQL em /root/ (deixe vazio para pular): " BACKUP
  if [ -n "$BACKUP" ] && [ -f "/root/$BACKUP" ]; then
    DIR_TEMP="/root/restore_temp"
    info "Extraindo backup..."
    rm -rf $DIR_TEMP && mkdir -p $DIR_TEMP
    case "$BACKUP" in
      *.tar.gz|*.tgz)    tar zxf "/root/$BACKUP" -C $DIR_TEMP ;;
      *.tar)             tar xf  "/root/$BACKUP" -C $DIR_TEMP ;;
      *.zip)             unzip -q "/root/$BACKUP" -d $DIR_TEMP ;;
      *.tar.bz2|*.tbz2) tar jxf "/root/$BACKUP" -C $DIR_TEMP ;;
      *)                 erro "Formato de compressão desconhecido!" ;;
    esac

    mysql -u root -p"$SENHA_ROOT_SQL" -e "SET GLOBAL sql_mode = ''; DROP DATABASE IF EXISTS mbilling; CREATE DATABASE mbilling;" 2>/dev/null
    ARQUIVO_SQL=$(find $DIR_TEMP -type f -name "*.sql" | head -n 1)
    if [ -n "$ARQUIVO_SQL" ]; then
      info "Importando $ARQUIVO_SQL..."
      mysql -u root -p"$SENHA_ROOT_SQL" --force mbilling < "$ARQUIVO_SQL" 2>/dev/null
      ok "Banco importado"
    else
      warn "Nenhum .sql encontrado no backup — pulando"
    fi
  else
    warn "Nenhum backup SQL informado — pulando importação"
  fi
fi

# =====================================================================
# ETAPA 3 — ARQUIVOS DO ASTERISK
# =====================================================================
echo ""
echo "-----------------------------------------------------"
echo " ETAPA 3/8 — Sincronizando arquivos do Asterisk"
echo "-----------------------------------------------------"

DIR_TEMP="/root/restore_temp"
if [ -d "$DIR_TEMP/etc/asterisk" ]; then
  cp -r $DIR_TEMP/etc/asterisk/* /etc/asterisk/
  ok "Configs Asterisk restauradas do backup"
else
  info "Copiando configs Asterisk do CentOS origem..."
  sshpass -p "${ORIGEM_PASS}" rsync -az --delete \
    -e "ssh -o StrictHostKeyChecking=no -p ${ORIGEM_PORT}" \
    ${ORIGEM_USER}@${ORIGEM_IP}:/etc/asterisk/ \
    /etc/asterisk/ 2>/dev/null \
    && ok "Asterisk /etc/asterisk OK" || warn "Falha ao copiar /etc/asterisk"
fi

if [ -d "$DIR_TEMP/var/lib/asterisk/sounds" ]; then
  cp -rp $DIR_TEMP/var/lib/asterisk/sounds/* /var/lib/asterisk/sounds/ 2>/dev/null
  ok "Sons Asterisk restaurados do backup"
fi

chown -R asterisk:asterisk /etc/asterisk/ /var/lib/asterisk/ 2>/dev/null
ok "Permissões Asterisk OK"

# =====================================================================
# ETAPA 4 — MIGRAÇÃO DOS ARQUIVOS DO MAGNUSBILLING (CentOS → Debian)
# =====================================================================
echo ""
echo "-----------------------------------------------------"
echo " ETAPA 4/8 — Migrando arquivos MagnusBilling"
echo "            (CentOS ${ORIGEM_IP}:${ORIGEM_PORT} → Debian)"
echo "-----------------------------------------------------"

PASTAS=(app build classic ext packages sass lib fpdf resources yii tmp wiki script)

for PASTA in "${PASTAS[@]}"; do
  echo -n "  [${PASTA}]... "
  sshpass -p "${ORIGEM_PASS}" rsync -az --delete \
    -e "ssh -o StrictHostKeyChecking=no -p ${ORIGEM_PORT}" \
    ${ORIGEM_USER}@${ORIGEM_IP}:${ORIGEM_PATH}/${PASTA}/ \
    ${DESTINO_PATH}/${PASTA}/ 2>/dev/null \
    && echo -e "${VERDE}OK${NC}" || echo -e "${AMARELO}ausente na origem (ignorado)${NC}"
done

echo ""
info "Copiando arquivos raiz..."
ARQUIVOS=(app.js app.json bootstrap.css bootstrap.js build.xml cron.php icons.js index.html index.php locale.js record.php robots.txt workspace.json)

for ARQUIVO in "${ARQUIVOS[@]}"; do
  echo -n "  [${ARQUIVO}]... "
  sshpass -p "${ORIGEM_PASS}" rsync -az \
    -e "ssh -o StrictHostKeyChecking=no -p ${ORIGEM_PORT}" \
    ${ORIGEM_USER}@${ORIGEM_IP}:${ORIGEM_PATH}/${ARQUIVO} \
    ${DESTINO_PATH}/${ARQUIVO} 2>/dev/null \
    && echo -e "${VERDE}OK${NC}" || echo -e "${AMARELO}ausente (ignorado)${NC}"
done

echo ""
info "Copiando protected/ (exceto config e runtime)..."
sshpass -p "${ORIGEM_PASS}" rsync -az --delete \
  -e "ssh -o StrictHostKeyChecking=no -p ${ORIGEM_PORT}" \
  --exclude='config/main.php' \
  --exclude='config/db.php' \
  --exclude='runtime/' \
  ${ORIGEM_USER}@${ORIGEM_IP}:${ORIGEM_PATH}/protected/ \
  ${DESTINO_PATH}/protected/ 2>/dev/null \
  && ok "protected/ copiado" || warn "Erro parcial em protected/"

# =====================================================================
# ETAPA 5 — RESTAURAR CONFIGS ORIGINAIS DO DEBIAN
# =====================================================================
echo ""
echo "-----------------------------------------------------"
echo " ETAPA 5/8 — Restaurando configurações do Debian"
echo "-----------------------------------------------------"

if [ -f "/tmp/mbilling_config_bkp/main.php" ]; then
  cp /tmp/mbilling_config_bkp/main.php ${DESTINO_PATH}/protected/config/main.php
  ok "main.php restaurado"
fi
if [ -f "/tmp/mbilling_config_bkp/db.php" ]; then
  cp /tmp/mbilling_config_bkp/db.php ${DESTINO_PATH}/protected/config/db.php
  ok "db.php restaurado"
fi

# =====================================================================
# ETAPA 6 — ALINHAMENTO DE SENHAS E USUÁRIO DO BANCO
# =====================================================================
echo ""
echo "-----------------------------------------------------"
echo " ETAPA 6/8 — Alinhando credenciais do banco"
echo "-----------------------------------------------------"

SENHA_RESTAURADA=$(grep "dbpass" /etc/asterisk/res_config_mysql.conf 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
if [ -n "$SENHA_RESTAURADA" ]; then
  mysql -u root -p"$SENHA_ROOT_SQL" -e "
    GRANT ALL PRIVILEGES ON mbilling.* TO 'mbillingUser'@'localhost' IDENTIFIED BY '$SENHA_RESTAURADA';
    GRANT ALL PRIVILEGES ON mbilling.* TO 'mbillingUser'@'127.0.0.1' IDENTIFIED BY '$SENHA_RESTAURADA';
    FLUSH PRIVILEGES;
  " 2>/dev/null
  ok "Credenciais alinhadas"
else
  warn "res_config_mysql.conf não encontrado — alinhamento de senha pulado"
fi

# =====================================================================
# ETAPA 7 — GARANTIA DE TABELAS ESSENCIAIS
# =====================================================================
echo ""
echo "-----------------------------------------------------"
echo " ETAPA 7/8 — Verificando tabelas essenciais"
echo "-----------------------------------------------------"

mysql -u root -p"$SENHA_ROOT_SQL" mbilling -e "
  CREATE TABLE IF NOT EXISTS pkg_status_system (
    id int(11) NOT NULL AUTO_INCREMENT,
    id_server int(11) DEFAULT 1,
    cpu varchar(255), ram varchar(255),
    disk varchar(255), network varchar(255),
    date datetime, PRIMARY KEY (id)
  ) ENGINE=InnoDB;

  CREATE TABLE IF NOT EXISTS pkg_call_chart (
    id int(11) NOT NULL AUTO_INCREMENT,
    answer varchar(255) DEFAULT '0',
    date datetime,
    total varchar(255) DEFAULT '0',
    PRIMARY KEY (id)
  ) ENGINE=InnoDB;

  CREATE TABLE IF NOT EXISTS pkg_cdr_failed LIKE pkg_cdr;
  CREATE TABLE IF NOT EXISTS pkg_cdr_archive LIKE pkg_cdr;
" 2>/dev/null
ok "Tabelas essenciais verificadas"

# =====================================================================
# ETAPA 8 — PERMISSÕES, LIMPEZA E ATUALIZAÇÃO
# =====================================================================
echo ""
echo "-----------------------------------------------------"
echo " ETAPA 8/8 — Permissões, limpeza e atualização"
echo "-----------------------------------------------------"

info "Limpando firewall e cache..."
mysql -u root -p"$SENHA_ROOT_SQL" -e "
  TRUNCATE TABLE mbilling.pkg_firewall;
" 2>/dev/null
ok "pkg_firewall limpa"

fail2ban-client set ip-blacklist unbanip 186.194.49.140 2>/dev/null && ok "IP desbloqueado no fail2ban"

info "Ajustando permissões..."
chown -R asterisk:asterisk ${DESTINO_PATH}/
chmod -R 555 ${DESTINO_PATH}/
chmod -R 774 ${DESTINO_PATH}/protected/runtime/
chmod -R 700 ${DESTINO_PATH}/resources/reports/ 2>/dev/null
chmod -R 700 ${DESTINO_PATH}/lib/
chmod -R 777 /tmp
rm -rf ${DESTINO_PATH}/protected/runtime/*
ok "Permissões ajustadas"

info "Executando atualização do MagnusBilling..."
if [ -f "${DESTINO_PATH}/protected/commands/update.sh" ]; then
  chmod +x ${DESTINO_PATH}/protected/commands/update.sh
  bash ${DESTINO_PATH}/protected/commands/update.sh 2>/dev/null
  ok "update.sh executado"
fi

php ${DESTINO_PATH}/cron.php updatemysql 2>/dev/null && ok "updatemysql OK" || warn "updatemysql com aviso"

rm -rf ${DESTINO_PATH}/protected/runtime/*

info "Reiniciando serviços..."
systemctl restart apache2 2>/dev/null && ok "Apache reiniciado"
systemctl restart asterisk 2>/dev/null && ok "Asterisk reiniciado"
systemctl restart fail2ban 2>/dev/null && ok "Fail2ban reiniciado"

# =====================================================================
# RESUMO FINAL
# =====================================================================
echo ""
echo "====================================================="
echo -e "${VERDE}    RESTAURAÇÃO CONCLUÍDA COM SUCESSO!${NC}"
echo "====================================================="
echo ""
echo -e "  URL:    ${AZUL}https://oss.voxcorptelecom.com.br${NC}"
echo -e "  Usuário: root"
echo -e "  Senha:  magnus (padrão) ou a senha do backup"
echo ""
echo -e "${AMARELO}  IMPORTANTE: Troque a senha SSH do CentOS origem!${NC}"
echo "====================================================="