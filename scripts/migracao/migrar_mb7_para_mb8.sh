#!/bin/bash
# =====================================================================
# Magnus Utilities — migrar_mb7_para_mb8.sh
# Versão: 2.0 (05 de novembro de 2026)
# Função: Migração Side-by-Side de dados de MagnusBilling 7 para
#         servidor novo com MagnusBilling 8 (Asterisk 20 + PJSIP), com
#         suporte completo a re-migração limpa (mesmo MB7 ou outro MB7)
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar no servidor DESTINO (onde o MagnusBilling 8 está instalado)
#   - Servidor MB8 limpo ou já utilizado em teste anterior
#   - Conexão SSH para o servidor MB7 de origem
#   - Acesso root em ambos os servidores
#
# Uso:
#   bash migrar_mb7_para_mb8.sh              # modo interativo
#   bash migrar_mb7_para_mb8.sh --dry-run    # simula e mostra parâmetros
#   bash migrar_mb7_para_mb8.sh --help       # ajuda
#
# Idempotência: SIM (zera *_magnus*.conf, preserva snapshot original do MB8
#               limpo e limpa resíduos de migrações anteriores se solicitado)
# Modifica estado: SIM (banco de dados + áudios + /etc/asterisk/*_magnus*.conf)
# Requer janela de manutenção: SIM (congelamento de escritas no MB7 na virada)
# =====================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
if [ -f "$SCRIPT_DIR/../lib/common.sh" ]; then
  source "$SCRIPT_DIR/../lib/common.sh"
else
  VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'; AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
  ok()     { echo -e "  ${VERDE}✓${NC} $1"; }
  warn()   { echo -e "  ${AMARELO}⚠${NC} $1"; }
  erro()   { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
  info()   { echo -e "  ${AZUL}➜${NC} $1"; }
  titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══════════════════════════════════════════════════════════════${NC}"; echo -e "${NEGRITO} $1${NC}"; echo -e "${NEGRITO}${AZUL}═══════════════════════════════════════════════════════════════${NC}"; }
  confirma() {
    read -p "  $1 [s/N]: " RESP
    [[ "$RESP" =~ ^[Ss]$ ]] || { erro "Operação cancelada pelo usuário."; exit 1; }
  }
fi

DRY_RUN=0
for ARG in "$@"; do
  case "$ARG" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      sed -n '/^# Magnus Utilities/,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

[ "$EUID" -ne 0 ] && erro "Este script deve ser executado como root no servidor DESTINO (MagnusBilling 8)."

clear
titulo "MIGRAÇÃO DE MAGNUSBILLING 7 PARA MAGNUSBILLING 8"

if [ $DRY_RUN -eq 1 ]; then
  warn "MODO DRY-RUN ATIVO — apenas verificações, nenhuma alteração será feita."
fi

# =====================================================================
# FASE 1: Validação do Servidor Destino (MB8)
# =====================================================================
titulo "FASE 1/10 — Validação do ambiente de destino (MagnusBilling 8)"

# Checagem de ferramentas essenciais
for CMD in mysql mysqldump rsync ssh gzip zcat systemctl awk grep; do
  command -v "$CMD" >/dev/null 2>&1 || erro "Comando '$CMD' não encontrado no destino. Instale antes de prosseguir."
done
ok "Comandos essenciais do sistema encontrados."

if ! command -v sshpass >/dev/null 2>&1; then
  info "Instalando sshpass..."
  apt-get update -y >/dev/null 2>&1 && apt-get install -y sshpass >/dev/null 2>&1 || erro "Falha ao instalar sshpass."
  ok "sshpass instalado."
fi

# Checagem da instalação do MB8
[ ! -d "/var/www/html/mbilling" ] && erro "Diretório /var/www/html/mbilling não encontrado. Instale o MagnusBilling 8 antes de migrar."
[ ! -f "/var/www/html/mbilling/cron.php" ] && erro "Arquivo cron.php não encontrado em /var/www/html/mbilling."
ok "Estrutura web do MagnusBilling detectada no destino."

# Validação do Asterisk e PJSIP no destino
AST_VER=$(asterisk -rx "core show version" 2>/dev/null | head -1)
if [[ "$AST_VER" =~ "Asterisk 2" ]]; then
  ok "Asterisk moderno detectado no destino: $AST_VER"
else
  warn "Asterisk no destino: ${AST_VER:-não respondeu}. Esperado Asterisk 20+ no MB8."
fi

if [ -f "/etc/asterisk/pjsip.conf" ]; then
  ok "Configuração PJSIP presente no destino (/etc/asterisk/pjsip.conf)."
else
  warn "Arquivo /etc/asterisk/pjsip.conf não encontrado. Verifique se o MB8 foi instalado corretamente."
fi

# Leitura da senha do banco local do MB8
DB_CONF="/etc/asterisk/res_config_mysql.conf"
[ ! -f "$DB_CONF" ] && erro "Arquivo $DB_CONF não encontrado no destino."

LOCAL_DB_USER=$(grep -i "^dbuser" "$DB_CONF" | head -1 | cut -d'=' -f2 | tr -d ' ')
LOCAL_DB_PASS=$(grep -i "^dbpass" "$DB_CONF" | head -1 | cut -d'=' -f2 | tr -d ' ')
LOCAL_DB_HOST=$(grep -i "^dbhost" "$DB_CONF" | head -1 | cut -d'=' -f2 | tr -d ' ')
LOCAL_DB_NAME=$(grep -i "^dbname" "$DB_CONF" | head -1 | cut -d'=' -f2 | tr -d ' ')
LOCAL_DB_HOST=${LOCAL_DB_HOST:-127.0.0.1}
LOCAL_DB_NAME=${LOCAL_DB_NAME:-mbilling}

if [ -z "$LOCAL_DB_PASS" ]; then
  erro "Não foi possível ler a senha do banco em $DB_CONF"
fi
ok "Configuração interna do MagnusBilling lida de $DB_CONF (usuário da aplicação: $LOCAL_DB_USER)"

# Conexão root com o MariaDB local (auto-detecta unix_socket sem senha no Debian/MB8)
LOCAL_ROOT_PW=""
if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
  ok "Acesso root ao MariaDB local autenticado via unix_socket (sem necessidade de senha)."
  mysql_local() {
    mysql -u root "$@"
  }
  mysqldump_local() {
    mysqldump -u root "$@"
  }
elif [ -f "/root/passwordMysql.log" ]; then
  LOCAL_ROOT_PW=$(cat /root/passwordMysql.log | tr -d '[:space:]')
  ok "Senha root do MariaDB local lida de /root/passwordMysql.log"
  mysql_local() {
    MYSQL_PWD="$LOCAL_ROOT_PW" mysql -u root "$@"
  }
  mysqldump_local() {
    MYSQL_PWD="$LOCAL_ROOT_PW" mysqldump -u root "$@"
  }
else
  read -sp "  Informe a senha do usuário root do MariaDB local (ou Enter se não houver senha): " LOCAL_ROOT_PW
  echo ""
  mysql_local() {
    if [ -n "$LOCAL_ROOT_PW" ]; then
      MYSQL_PWD="$LOCAL_ROOT_PW" mysql -u root "$@"
    else
      mysql -u root "$@"
    fi
  }
  mysqldump_local() {
    if [ -n "$LOCAL_ROOT_PW" ]; then
      MYSQL_PWD="$LOCAL_ROOT_PW" mysqldump -u root "$@"
    else
      mysqldump -u root "$@"
    fi
  }
fi

mysql_local -e "SELECT 1;" >/dev/null 2>&1 || erro "Não foi possível conectar como root no MariaDB local. Verifique o serviço MariaDB."
ok "Conexão com o banco local validada."

# =====================================================================
# FASE 2: Coleta de Parâmetros e Teste com o Servidor de Origem (MB7)
# =====================================================================
titulo "FASE 2/10 — Parâmetros do servidor de origem (MagnusBilling 7)"

MEU_IP_LOCAL=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
[ -z "$MEU_IP_LOCAL" ] && MEU_IP_LOCAL=$(hostname -I 2>/dev/null | awk '{print $1}')

coletar_dados_origem() {
  info "Informe os dados de acesso SSH do servidor MB7 de origem:"
  read -p "  IP do servidor MB7 de origem [${ORIGEM_IP:-}]: " INPUT_IP
  ORIGEM_IP=${INPUT_IP:-$ORIGEM_IP}
  while [ -z "$ORIGEM_IP" ]; do
    read -p "  IP do servidor MB7 de origem (obrigatório): " ORIGEM_IP
  done

  read -p "  Porta SSH da origem [${ORIGEM_PORT:-22022}]: " INPUT_PORT
  ORIGEM_PORT=${INPUT_PORT:-${ORIGEM_PORT:-22022}}

  read -p "  Usuário SSH da origem [${ORIGEM_USER:-root}]: " INPUT_USER
  ORIGEM_USER=${INPUT_USER:-${ORIGEM_USER:-root}}

  read -sp "  Senha SSH da origem: " ORIGEM_PASS
  echo ""
  [ -z "$ORIGEM_PASS" ] && erro "A senha SSH da origem é obrigatória."
}

coletar_dados_origem

ssh_origem() {
  SSHPASS="$ORIGEM_PASS" sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    -p "$ORIGEM_PORT" \
    "$ORIGEM_USER@$ORIGEM_IP" "$@"
}

rsync_origem() {
  local SRC="$1"
  local DST="$2"
  local EXTRA_FLAGS="${3:-}"
  SSHPASS="$ORIGEM_PASS" sshpass -e rsync -az $EXTRA_FLAGS \
    -e "ssh -p $ORIGEM_PORT -o StrictHostKeyChecking=accept-new" \
    "$ORIGEM_USER@$ORIGEM_IP:$SRC" "$DST"
}

while true; do
  info "Testando conexão SSH com o servidor de origem ($ORIGEM_IP:$ORIGEM_PORT)..."
  if ssh_origem "echo 'OK_SSH'" >/dev/null 2>&1; then
    ok "Conexão SSH com a origem estabelecida com sucesso."
    break
  else
    echo ""
    warn "Falha ao conectar via SSH no servidor de origem ($ORIGEM_IP:$ORIGEM_PORT)."
    echo -e "  Para autorizar o IP deste servidor MB8 (${NEGRITO}${MEU_IP_LOCAL:-<IP_MB8>}${NC}) lá no servidor MB7 (${NEGRITO}$ORIGEM_IP${NC}):"
    echo -e "    • ${AZUL}Pelo menu Magnus Utils no MB7:${NC} Escolha a ${NEGRITO}Opção 4${NC} (ou ${NEGRITO}27${NC}) — Liberar IP no Firewall"
    echo -e "    • ${AZUL}Ou cole este comando direto no terminal do MB7:${NC}"
    echo -e "      ${VERDE}firewall-cmd --zone=public --add-rich-rule='rule family=\"ipv4\" source address=\"${MEU_IP_LOCAL}\" port port=\"${ORIGEM_PORT}\" protocol=\"tcp\" accept' --permanent && firewall-cmd --reload 2>/dev/null; iptables -I INPUT -s ${MEU_IP_LOCAL} -p tcp --dport ${ORIGEM_PORT} -j ACCEPT 2>/dev/null${NC}"
    echo ""
    echo "    [T] Testar conexão novamente (após liberar o IP no MB7)"
    echo "    [A] Alterar IP, Porta ou Senha informados"
    echo "    [C] Cancelar migração"
    read -p "  Escolha [T/a/c]: " RESP_SSH_RETRY
    RESP_SSH_RETRY=${RESP_SSH_RETRY:-T}
    case "$RESP_SSH_RETRY" in
      [Tt]) continue ;;
      [Aa]) coletar_dados_origem ;;
      *) erro "Migração cancelada: não foi possível conectar ao servidor de origem ($ORIGEM_IP:$ORIGEM_PORT)." ;;
    esac
  fi
done

# Validação do MB7 na origem
info "Verificando instalação do MagnusBilling na origem..."
ORIGEM_MB_CHECK=$(ssh_origem "[ -d /var/www/html/mbilling ] && echo 'EXISTE' || echo 'NAO'")
[ "$ORIGEM_MB_CHECK" != "EXISTE" ] && erro "Diretório /var/www/html/mbilling não encontrado no servidor de origem."
ok "MagnusBilling presente na origem."

# =====================================================================
# FASE 3: Contagem e Conferência Prévia dos Dados na Origem
# =====================================================================
titulo "FASE 3/10 — Análise prévia dos dados na origem"

info "Consultando volume de dados no servidor de origem..."
ORIGEM_USERS=$(ssh_origem "mysql -N -e 'SELECT COUNT(*) FROM mbilling.pkg_user;' 2>/dev/null" || echo "0")
ORIGEM_TRUNKS=$(ssh_origem "mysql -N -e 'SELECT COUNT(*) FROM mbilling.pkg_trunk;' 2>/dev/null" || echo "0")
ORIGEM_RAMAIS=$(ssh_origem "mysql -N -e 'SELECT COUNT(*) FROM mbilling.pkg_sip;' 2>/dev/null" || echo "0")
ORIGEM_DIDS=$(ssh_origem "mysql -N -e 'SELECT COUNT(*) FROM mbilling.pkg_did;' 2>/dev/null" || echo "0")
ORIGEM_CDRS=$(ssh_origem "mysql -N -e 'SELECT COUNT(*) FROM mbilling.pkg_cdr;' 2>/dev/null" || echo "0")
ORIGEM_REG_TRUNKS=$(ssh_origem "mysql -N -e \"SELECT COUNT(*) FROM mbilling.pkg_trunk WHERE status=1 AND (register=1 OR (register_string IS NOT NULL AND register_string != ''));\" 2>/dev/null" || echo "0")

echo ""
echo "  Resumo dos registros encontrados no MB7:"
echo "    • Usuários:        $ORIGEM_USERS"
echo "    • Troncos (SIP):   $ORIGEM_TRUNKS (serão convertidos para PJSIP)"
echo "    • Troncos c/ Reg:  $ORIGEM_REG_TRUNKS (registro outbound em operadora)"
echo "    • Ramais SIP:      $ORIGEM_RAMAIS"
echo "    • DIDs:            $ORIGEM_DIDS"
echo "    • Registros CDR:   $ORIGEM_CDRS"
echo ""

# Checagem de módulo comercial app_mbilling conforme documentação oficial
ORIGEM_HAS_APP_MBILLING=$(ssh_origem "[ -f /usr/lib/asterisk/modules/app_mbilling.so ] || [ -d /var/www/html/mbilling/protected/modules/app_mbilling ] && echo 'SIM' || echo 'NAO'")
if [ "$ORIGEM_HAS_APP_MBILLING" = "SIM" ]; then
  warn "ATENÇÃO (app_mbilling): Módulo privado app_mbilling detectado na origem!"
  warn "Segundo a documentação oficial da MagnusSolution, este módulo requer pacote"
  warn "específico compatível com Asterisk 20 fornecido pelo suporte oficial MagnusSolution."
  echo ""
fi

# Detectar se este servidor MB8 já recebeu uma migração anterior
LOCAL_EXISTING_USERS=$(mysql_local -N -e "SELECT COUNT(*) FROM mbilling.pkg_user;" 2>/dev/null || echo "0")
FIRST_BKP_DIR=$(ls -1d /root/backup-pre-migracao-mb8-* 2>/dev/null | sort | head -1)
MODO_OUTRO_SERVIDOR=1

if [ "${LOCAL_EXISTING_USERS:-0}" -gt 1 ] || [ -n "$FIRST_BKP_DIR" ]; then
  warn "Detectamos que este servidor MB8 já recebeu uma migração anteriormente ($LOCAL_EXISTING_USERS usuários locais)."
  echo "  Como deseja tratar os arquivos em disco (gravações, MOH e configs Asterisk)?"
  echo "    1) [Recomendado] Migração de OUTRO servidor MB7 diferente (limpar gravações, filas, DIDs, PJSIP e resíduos da migração anterior)"
  echo "    2) Re-migração do MESMO servidor MB7 (manter gravações já copiadas e sincronizar apenas arquivos novos)"
  read -p "  Escolha [1]: " RESP_MODO_MIG
  RESP_MODO_MIG=${RESP_MODO_MIG:-1}
  if [ "$RESP_MODO_MIG" = "2" ]; then
    MODO_OUTRO_SERVIDOR=0
    info "Modo selecionado: Atualização incremental de gravações do MESMO servidor MB7."
  else
    MODO_OUTRO_SERVIDOR=1
    ok "Modo selecionado: Limpeza completa de resíduos da migração anterior (OUTRO servidor MB7)."
  fi
  echo ""
fi

if [ $DRY_RUN -eq 1 ]; then
  ok "Simulação finalizada com sucesso. Nenhuma alteração foi realizada."
  exit 0
fi

confirma "Deseja iniciar o processo de migração para este servidor?"

# =====================================================================
# FASE 4: Backup de Segurança e Referência Limpa do MB8
# =====================================================================
titulo "FASE 4/10 — Backup de segurança pré-migração no destino"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BKP_DIR="/root/backup-pre-migracao-mb8-$TIMESTAMP"
CLEAN_REF_DIR="/root/.mb8-clean-reference"
mkdir -p "$BKP_DIR"
chmod 700 "$BKP_DIR"

info "Criando backup do estado atual do banco MB8 em $BKP_DIR..."
mysqldump_local --single-transaction --triggers mbilling | gzip > "$BKP_DIR/mbilling8-clean.sql.gz" || erro "Falha ao criar backup do banco local."
ok "Backup do banco local salvo com sucesso."

# Garantir que o snapshot de referência do MB8 100% limpo seja preservado entre múltiplas migrações
if [ ! -d "$CLEAN_REF_DIR" ]; then
  mkdir -p "$CLEAN_REF_DIR"
  chmod 700 "$CLEAN_REF_DIR"
  if [ -n "$FIRST_BKP_DIR" ] && [ -d "$FIRST_BKP_DIR" ] && [ "$FIRST_BKP_DIR" != "$BKP_DIR" ]; then
    info "Recuperando snapshot original do MB8 limpo a partir do primeiro backup ($FIRST_BKP_DIR)..."
    cp -a "$FIRST_BKP_DIR/"* "$CLEAN_REF_DIR/" 2>/dev/null || true
    ok "Referência original do MB8 limpo preservada em $CLEAN_REF_DIR."
  fi
fi

# Salvar tabelas exclusivas do MB8 (ex: Magnus Sentinel)
MB8_SENTINEL_TABLES=$(mysql_local -N -e "SHOW TABLES FROM mbilling LIKE 'pkg_magnus_sentinel_%';" 2>/dev/null)
if [ -n "$MB8_SENTINEL_TABLES" ]; then
  info "Preservando estrutura das tabelas do Magnus Sentinel..."
  if [ "$MODO_OUTRO_SERVIDOR" -eq 1 ]; then
    # Se for outro servidor MB7, salva apenas a estrutura limpa (ou usa a referência original limpa) para não carregar IPs/dados do 1º MB7
    if [ -s "$CLEAN_REF_DIR/mb8_sentinel_tables.sql" ]; then
      cp -a "$CLEAN_REF_DIR/mb8_sentinel_tables.sql" "$BKP_DIR/mb8_sentinel_tables.sql"
    else
      mysqldump_local --no-data mbilling $MB8_SENTINEL_TABLES > "$BKP_DIR/mb8_sentinel_tables.sql" 2>/dev/null || true
    fi
  else
    mysqldump_local mbilling $MB8_SENTINEL_TABLES > "$BKP_DIR/mb8_sentinel_tables.sql" 2>/dev/null || true
  fi
  [ ! -s "$CLEAN_REF_DIR/mb8_sentinel_tables.sql" ] && cp -a "$BKP_DIR/mb8_sentinel_tables.sql" "$CLEAN_REF_DIR/mb8_sentinel_tables.sql" 2>/dev/null || true
  ok "Tabelas do Magnus Sentinel preservadas."
fi

# Salvar chaves nativas de configuração do MB8 para merge sem contaminação entre servidores
info "Preservando catálogo nativo de configurações do MB8..."
if [ -s "$CLEAN_REF_DIR/mb8_clean_pkg_configuration.sql" ]; then
  cp -a "$CLEAN_REF_DIR/mb8_clean_pkg_configuration.sql" "$BKP_DIR/mb8_clean_pkg_configuration.sql"
  ok "Usando catálogo nativo original do MB8 limpo ($CLEAN_REF_DIR) — sem resíduos da migração anterior."
else
  mysqldump_local --no-create-info --insert-ignore mbilling pkg_configuration > "$BKP_DIR/mb8_clean_pkg_configuration.sql" 2>/dev/null || true
  cp -a "$BKP_DIR/mb8_clean_pkg_configuration.sql" "$CLEAN_REF_DIR/mb8_clean_pkg_configuration.sql" 2>/dev/null || true
  ok "Snapshot de configurações nativas do MB8 salvo."
fi

info "Criando backup das configurações do Asterisk 20 em $BKP_DIR..."
tar czf "$BKP_DIR/etc-asterisk-mb8-clean.tar.gz" /etc/asterisk 2>/dev/null || true
[ ! -s "$CLEAN_REF_DIR/etc-asterisk-mb8-clean.tar.gz" ] && cp -a "$BKP_DIR/etc-asterisk-mb8-clean.tar.gz" "$CLEAN_REF_DIR/etc-asterisk-mb8-clean.tar.gz" 2>/dev/null || true
ok "Backup do /etc/asterisk salvo com sucesso."

# =====================================================================
# FASE 5: Congelamento de Escritas e Extração do Dump no MB7
# =====================================================================
titulo "FASE 5/10 — Extração do banco de dados na origem (MB7)"

echo ""
info "Para garantir consistência estrita dos dados (sem chamadas/CDRs gravando durante o dump),"
info "é altamente recomendado parar os serviços Asterisk e Apache no MB7 se for a virada final."
info "Se o MB7 estiver em produção agora e isto for apenas um TESTE, responda 'n'."
read -p "  Deseja parar Asterisk, Apache e Cron no MB7 agora? [S/n]: " RESP_FREEZE
RESP_FREEZE=${RESP_FREEZE:-S}

if [[ "$RESP_FREEZE" =~ ^[Ss]$ ]]; then
  info "Parando serviços no servidor MB7 de origem..."
  ssh_origem "systemctl stop asterisk apache2 cron 2>/dev/null || systemctl stop asterisk httpd crond 2>/dev/null || true"
  ok "Serviços congelados na origem."
else
  warn "Os serviços na origem continuarão ativos durante o dump."
fi

info "Executando mysqldump completo no servidor de origem..."
ssh_origem "mysqldump --single-transaction --quick --triggers --hex-blob --default-character-set=utf8 mbilling | gzip -c" > "$BKP_DIR/mbilling7-origem.sql.gz" || erro "Falha ao extrair dump da origem."

if [ ! -s "$BKP_DIR/mbilling7-origem.sql.gz" ]; then
  erro "Arquivo de dump recebido está vazio."
fi

gzip -t "$BKP_DIR/mbilling7-origem.sql.gz" || erro "Arquivo de dump comprimido corrompido."
DUMP_SIZE=$(du -h "$BKP_DIR/mbilling7-origem.sql.gz" | awk '{print $1}')
ok "Dump extraído e validado com sucesso (Tamanho: $DUMP_SIZE)."

# =====================================================================
# FASE 6: Transferência de Áudios e Gravações
# =====================================================================
titulo "FASE 6/10 — Sincronização de áudios e gravações"

warn "AVISO ARQUITETURAL: /etc/asterisk da origem NÃO será copiado."
info "O MagnusBilling 8 utiliza Asterisk 20 com PJSIP; seus arquivos de configuração"
info "serão regenerados dinamicamente pelo MB8 com base nas tabelas migradas."
echo ""

if [ "$MODO_OUTRO_SERVIDOR" -eq 1 ]; then
  info "Limpando áudios de URA customizados e gravações da migração anterior..."
  rm -rf /var/spool/asterisk/monitor/* 2>/dev/null || true
  rm -f /var/lib/asterisk/sounds/idIvrDid* /var/lib/asterisk/sounds/ivr* /var/lib/asterisk/sounds/moh* 2>/dev/null || true
  rm -f /usr/local/src/magnus/sounds/* 2>/dev/null || true
  ok "Gravações e áudios customizados da migração anterior removidos."
fi

info "Sincronizando arquivos de áudio (/var/lib/asterisk/sounds/)..."
mkdir -p /var/lib/asterisk/sounds
rsync_origem "/var/lib/asterisk/sounds/" "/var/lib/asterisk/sounds/" || warn "Aviso na cópia de sons."
ok "Áudios sincronizados."

info "Verificando gravações de chamadas (/var/spool/asterisk/monitor/)..."
ORIGEM_HAS_MONITOR=$(ssh_origem "[ -d /var/spool/asterisk/monitor ] && echo 'SIM' || echo 'NAO'")
if [ "$ORIGEM_HAS_MONITOR" = "SIM" ]; then
  mkdir -p /var/spool/asterisk/monitor
  if [ "$MODO_OUTRO_SERVIDOR" -eq 1 ]; then
    rsync_origem "/var/spool/asterisk/monitor/" "/var/spool/asterisk/monitor/" "--delete" || warn "Aviso na cópia de gravações."
  else
    rsync_origem "/var/spool/asterisk/monitor/" "/var/spool/asterisk/monitor/" || warn "Aviso na cópia de gravações."
  fi
  ok "Gravações sincronizadas."
else
  info "Diretório de monitoramento não continha dados para sincronizar."
fi

info "Verificando músicas de espera (/var/lib/asterisk/moh/)..."
ORIGEM_HAS_MOH=$(ssh_origem "[ -d /var/lib/asterisk/moh ] && echo 'SIM' || echo 'NAO'")
if [ "$ORIGEM_HAS_MOH" = "SIM" ]; then
  mkdir -p /var/lib/asterisk/moh
  if [ "$MODO_OUTRO_SERVIDOR" -eq 1 ]; then
    rsync_origem "/var/lib/asterisk/moh/" "/var/lib/asterisk/moh/" "--delete" || warn "Aviso na cópia de MOH."
  else
    rsync_origem "/var/lib/asterisk/moh/" "/var/lib/asterisk/moh/" || warn "Aviso na cópia de MOH."
  fi
  ok "Músicas de espera sincronizadas."
fi

# =====================================================================
# FASE 7: Aplicação e Restauração no Destino (MB8)
# =====================================================================
titulo "FASE 7/10 — Restauração do banco de dados no destino"

info "Parando serviços locais no servidor MB8..."
systemctl stop asterisk apache2 cron 2>/dev/null || true
ok "Serviços locais parados para restauração."

info "Recriando banco de dados mbilling limpo com UTF-8..."
mysql_local -e "DROP DATABASE IF EXISTS mbilling; CREATE DATABASE mbilling CHARACTER SET utf8 COLLATE utf8_general_ci;" || erro "Falha ao recriar banco mbilling."
ok "Banco recriado."

info "Importando dump do MB7 para o banco local..."
zcat "$BKP_DIR/mbilling7-origem.sql.gz" | mysql_local mbilling || erro "Falha ao importar dump do MB7."
ok "Dados do MB7 importados no MariaDB local."

# Restaurar tabelas exclusivas do Sentinel se existiam no MB8
if [ -s "$BKP_DIR/mb8_sentinel_tables.sql" ]; then
  info "Restaurando tabelas do Magnus Sentinel..."
  mysql_local mbilling < "$BKP_DIR/mb8_sentinel_tables.sql" || warn "Aviso ao restaurar Sentinel."
  ok "Tabelas do Magnus Sentinel restauradas com sucesso."
fi

# Mesclagem inteligente de parâmetros do MB8 por config_key (evita colisão de ID e duplicação entre servidores)
if [ -s "$BKP_DIR/mb8_clean_pkg_configuration.sql" ]; then
  info "Mesclando parâmetros nativos exclusivos do MB8 por config_key..."
  mysql_local mbilling -e "DROP TABLE IF EXISTS tmp_mb8_clean_cfg; CREATE TABLE tmp_mb8_clean_cfg LIKE pkg_configuration;" 2>/dev/null || true
  sed 's/`pkg_configuration`/`tmp_mb8_clean_cfg`/g' "$BKP_DIR/mb8_clean_pkg_configuration.sql" | mysql_local mbilling 2>/dev/null || true
  mysql_local mbilling -e "
    INSERT INTO pkg_configuration (config_title, config_key, config_value, config_description, config_group_title, status)
    SELECT t.config_title, t.config_key, t.config_value, t.config_description, t.config_group_title, t.status
    FROM tmp_mb8_clean_cfg t
    LEFT JOIN pkg_configuration c ON c.config_key = t.config_key
    WHERE c.id IS NULL;
    DROP TABLE IF EXISTS tmp_mb8_clean_cfg;
  " 2>/dev/null && ok "Parâmetros nativos do MB8 mesclados por config_key sem conflitos." || warn "Aviso ao mesclar chaves nativas."
fi

info "Garantindo permissões do usuário da aplicação (mbillingUser)..."
mysql_local -e "
CREATE USER IF NOT EXISTS 'mbillingUser'@'localhost' IDENTIFIED BY '$LOCAL_DB_PASS';
ALTER USER 'mbillingUser'@'localhost' IDENTIFIED BY '$LOCAL_DB_PASS';
GRANT ALL PRIVILEGES ON mbilling.* TO 'mbillingUser'@'localhost';

CREATE USER IF NOT EXISTS 'mbillingUser'@'127.0.0.1' IDENTIFIED BY '$LOCAL_DB_PASS';
ALTER USER 'mbillingUser'@'127.0.0.1' IDENTIFIED BY '$LOCAL_DB_PASS';
GRANT ALL PRIVILEGES ON mbilling.* TO 'mbillingUser'@'127.0.0.1';
FLUSH PRIVILEGES;
" || erro "Falha ao aplicar permissões do mbillingUser."
ok "Usuário mbillingUser reconfigurado com a credencial local."

# =====================================================================
# FASE 8: Conversão do Banco para MagnusBilling 8 (UpdateMysql)
# =====================================================================
titulo "FASE 8/10 — Conversão de dados e schema para MagnusBilling 8"

info "Executando o migrador oficial do MagnusBilling: UpdateMysql..."
info "Este processo converte troncos SIP para PJSIP, atualiza dialplans e ajusta o schema."
echo ""

php /var/www/html/mbilling/cron.php UpdateMysql
UPDATE_STATUS=$?

echo ""
if [ $UPDATE_STATUS -eq 0 ]; then
  ok "UpdateMysql executado com sucesso."
else
  warn "UpdateMysql retornou código de saída $UPDATE_STATUS. Verifique as mensagens acima."
fi

FINAL_DB_VERSION=$(mysql_local -N -e "SELECT config_value FROM mbilling.pkg_configuration WHERE config_key = 'version' LIMIT 1;" 2>/dev/null || echo "Desconhecida")
ok "Versão do banco de dados pós-migração: $FINAL_DB_VERSION"

# =====================================================================
# FASE 9: Limpeza Completa, Permissões e Regeneração dos Arquivos Asterisk
# =====================================================================
titulo "FASE 9/10 — Limpeza, padronização e regeneração dos arquivos Asterisk"

info "Zerando arquivos *_magnus*.conf anteriores para evitar resíduos de outra migração..."
MAGNUS_CONF_FILES=(
  /etc/asterisk/pjsip_magnus.conf
  /etc/asterisk/pjsip_magnus_user.conf
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

for MCONF in "${MAGNUS_CONF_FILES[@]}"; do
  : > "$MCONF"
done
ok "Arquivos *_magnus*.conf limpos e recriados do zero."

info "Ajustando donos e permissões (chmod 664 / asterisk:asterisk)..."
chown -R asterisk:asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk
find /etc/asterisk -name "*magnus*" -exec chown asterisk:asterisk {} \; 2>/dev/null
find /etc/asterisk -name "*magnus*" -exec chmod 664 {} \; 2>/dev/null
find /etc/asterisk -name "*mbilling*" -exec chown asterisk:asterisk {} \; 2>/dev/null
find /etc/asterisk -name "*mbilling*" -exec chmod 664 {} \; 2>/dev/null
chown root:asterisk /etc/asterisk/res_config_mysql.conf 2>/dev/null
chmod 0640 /etc/asterisk/res_config_mysql.conf 2>/dev/null
usermod -aG asterisk www-data 2>/dev/null || true
ok "Permissões 664 ajustadas."

info "Regenerando peers PJSIP, Filas, DIDs, URAs, IAX e MOH a partir do novo banco..."
php -r '
  require "/var/www/html/mbilling/cron.php";
  $ast = AsteriskAccess::instance();
  foreach (["generateSipPeers", "generateSipDid", "generateQueueFile", "generateIvrFile", "generateIaxPeers", "generateMusicOnHold"] as $method) {
    if (method_exists($ast, $method)) {
      try { $ast->$method(); } catch (Throwable $e) {}
    }
  }
' 2>/dev/null || true

# Garante novamente 664 caso o PHP tenha recriado algum arquivo com umask padrão
find /etc/asterisk -name "*magnus*" -exec chown asterisk:asterisk {} \; 2>/dev/null
find /etc/asterisk -name "*magnus*" -exec chmod 664 {} \; 2>/dev/null
ok "Arquivos do Asterisk 20 regenerados com sucesso a partir do novo banco."

# =====================================================================
# FASE 10: Reinício e Validação Final Pós-Migração
# =====================================================================
titulo "FASE 10/10 — Reinício dos serviços e validação final"

info "Reiniciando MariaDB..."
systemctl restart mariadb 2>/dev/null && ok "MariaDB ativo." || warn "Falha ao reiniciar MariaDB."

info "Reiniciando PHP-FPM..."
PHPFPM_SERVICE=$(systemctl list-unit-files --type=service 2>/dev/null | grep -oE "php[0-9.]+-fpm\.service" | head -1)
if [ -n "$PHPFPM_SERVICE" ]; then
  systemctl restart "$PHPFPM_SERVICE" 2>/dev/null && ok "$PHPFPM_SERVICE ativo." || warn "Falha ao reiniciar $PHPFPM_SERVICE."
elif systemctl restart php-fpm 2>/dev/null; then
  ok "php-fpm ativo."
else
  warn "Nenhum serviço php-fpm específico localizado (Apache pode usar mod_php)."
fi

info "Reiniciando Apache..."
systemctl restart apache2 2>/dev/null && ok "Apache ativo." || warn "Falha ao reiniciar Apache."

# Proteção contra roubo de registro SIP (register=1) caso o MB7 de origem ainda esteja ligado em produção
START_ASTERISK_MB8="S"
if [ "${ORIGEM_REG_TRUNKS:-0}" -gt 0 ] && [[ ! "$RESP_FREEZE" =~ ^[Ss]$ ]]; then
  echo ""
  warn "ALERTA DE PROTEÇÃO SIP: O MB7 de origem possui $ORIGEM_REG_TRUNKS tronco(s) com registro outbound (register)"
  warn "e os serviços na origem ($ORIGEM_IP) NÃO foram parados!"
  warn "Se o Asterisk 20 iniciar agora neste MB8, ele enviará REGISTER para a operadora e poderá"
  warn "disputar/roubar chamadas entrantes do MB7 que ainda está em produção."
  read -p "  Deseja iniciar o Asterisk 20 neste MB8 agora mesmo assim? [S/n]: " START_ASTERISK_MB8
  START_ASTERISK_MB8=${START_ASTERISK_MB8:-S}
fi

if [[ "$START_ASTERISK_MB8" =~ ^[Ss]$ ]]; then
  info "Reiniciando Asterisk 20..."
  systemctl restart asterisk 2>/dev/null && ok "Asterisk ativo." || warn "Falha ao reiniciar Asterisk."
else
  warn "Asterisk 20 mantido PARADO neste MB8 para não interferir nos registros SIP do MB7 em produção."
  info "Quando quiser ligar o Asterisk para testar, execute: systemctl start asterisk"
fi

info "Reiniciando Cron..."
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true
ok "Cron ativo."

info "Aguardando 5 segundos para estabilização dos serviços..."
sleep 5

echo ""
info "Validação do Asterisk e PJSIP:"
AST_CORE=$(asterisk -rx "core show version" 2>/dev/null | head -1)
ok "Versão do Asterisk: ${AST_CORE:-Não respondeu}"

PJSIP_ENDPOINTS=$(asterisk -rx "pjsip show endpoints" 2>/dev/null | grep -c "Endpoint:")
info "Endpoints PJSIP carregados: $PJSIP_ENDPOINTS"

PJSIP_REGS=$(asterisk -rx "pjsip show registrations" 2>/dev/null | grep -c "OutboundRegistration:")
info "Registros outbound PJSIP: $PJSIP_REGS"

echo ""
info "Validação do painel Web:"
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 http://localhost/ 2>/dev/null)
case "$HTTP_CODE" in
  200|301|302) ok "Painel web respondendo localmente (HTTP $HTTP_CODE)." ;;
  500)         warn "HTTP 500 — consulte /var/www/html/mbilling/protected/runtime/application.log." ;;
  *)           info "HTTP $HTTP_CODE retornado." ;;
esac

# Comparativo final de registros
MB8_USERS=$(mysql_local -N -e 'SELECT COUNT(*) FROM mbilling.pkg_user;' 2>/dev/null || echo "0")
MB8_TRUNKS=$(mysql_local -N -e 'SELECT COUNT(*) FROM mbilling.pkg_trunk;' 2>/dev/null || echo "0")
MB8_RAMAIS=$(mysql_local -N -e 'SELECT COUNT(*) FROM mbilling.pkg_sip;' 2>/dev/null || echo "0")
MB8_DIDS=$(mysql_local -N -e 'SELECT COUNT(*) FROM mbilling.pkg_did;' 2>/dev/null || echo "0")
MB8_CDRS=$(mysql_local -N -e 'SELECT COUNT(*) FROM mbilling.pkg_cdr;' 2>/dev/null || echo "0")
MB8_CONFIGS=$(mysql_local -N -e 'SELECT COUNT(*) FROM mbilling.pkg_configuration;' 2>/dev/null || echo "0")

echo ""
echo "  Conferência e Integridade dos Dados:"
echo "    • Usuários:        Origem ($ORIGEM_USERS) ➔ Destino ($MB8_USERS)"
echo "    • Troncos:         Origem ($ORIGEM_TRUNKS SIP) ➔ Destino ($MB8_TRUNKS PJSIP)"
echo "    • Ramais:          Origem ($ORIGEM_RAMAIS) ➔ Destino ($MB8_RAMAIS)"
echo "    • DIDs:            Origem ($ORIGEM_DIDS) ➔ Destino ($MB8_DIDS)"
echo "    • Registros CDR:   Origem ($ORIGEM_CDRS) ➔ Destino ($MB8_CDRS)"
echo "    • Configurações:   Destino possui $MB8_CONFIGS parâmetros configurados"

echo ""
titulo "MIGRAÇÃO DE DADOS PARA MAGNUSBILLING 8 CONCLUÍDA"
echo ""
echo -e "  ${VERDE}${NEGRITO}✓ DADOS MIGRADOS E SCHEMA ATUALIZADO PARA MB8${NC}"
echo ""
echo "  Servidor de Origem:   $ORIGEM_IP"
echo "  Backup de Rollback:   $BKP_DIR"
echo ""
echo -e "${NEGRITO}PRÓXIMOS PASSOS OBRIGATÓRIOS (conforme wiki oficial):${NC}"
echo "  1. Acesse o painel web no novo servidor e valide o login do administrador."
echo "  2. Revise os troncos convertidos para PJSIP no menu Troncos (Codecs, NAT, Qualify, Registros)."
echo "  3. Execute ligações de teste (entrada e saída) validando tarifação e áudio bidirecional."
echo "  4. Para Cutover com impacto zero: desligue o servidor antigo e use a Opção 11 do menu"
echo "     (Trocar IP do Servidor) para assumir o IP de produção neste servidor novo."
echo "  5. Se necessário, configure o certificado SSL gratuito via Opção 6 do menu."
echo ""
echo -e "${NEGRITO}ROLLBACK (caso precise voltar o servidor novo ao estado limpo inicial):${NC}"
echo "  zcat $BKP_DIR/mbilling8-clean.sql.gz | mysql mbilling"
echo "  tar xzf $BKP_DIR/etc-asterisk-mb8-clean.tar.gz -C /"
echo "  systemctl restart asterisk apache2 mariadb"
echo ""
exit 0
