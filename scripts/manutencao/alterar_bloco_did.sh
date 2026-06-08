#!/bin/bash
# =====================================================================
# Voxcorp Setup — alterar_bloco_did.sh
# Versão: 4.0 (08 de junho de 2026)
# Função: Reatribuir DIDs em massa para novo dono + criar rotas SIP
# Autor: Voxcorp Telecom (EMB Serviços em Telecomunicações)
#
# Pré-requisitos:
#   - Magnus 7.x + MariaDB 10.x acessível em localhost
#   - Acesso root ou usuário com permissão de leitura em
#     /etc/asterisk/res_config_mysql.conf
#   - Asterisk acessível via CLI (para validação opcional do peer)
#
# Uso:
#   bash alterar_bloco_did.sh              # modo interativo + execução
#   bash alterar_bloco_did.sh --dry-run    # simula, imprime SQL e sai
#   bash alterar_bloco_did.sh --help       # mostra ajuda
#
# Modos de operação:
#   [1] Bloco de DIDs (intervalo início → fim)
#   [2] DID único
#   [3] Lista de DIDs em arquivo .txt
#   [4] Todos os DIDs de um cliente específico (pelo ID)
#
# Idempotência: NÃO (executar duas vezes duplica rotas em
#               pkg_did_destination se IPs forem diferentes)
# Modifica estado: SIM
#   - UPDATE pkg_did (id_user, reserved, activated)
#   - DELETE pkg_did_destination (rotas antigas dos DIDs alvo)
#   - INSERT pkg_did_destination (novas rotas SIP)
# Requer janela de manutenção: NÃO em geral, mas atenção:
#   - Chamadas em curso para os DIDs alvo são redirecionadas
#     para o novo destino instantaneamente após COMMIT
#
# Mudanças v4.0 (junho 2026):
#   [1] MYSQL_PWD em vez de --password (senha não vaza em ps aux)
#   [2] Validação de alcance do destino SIP (ping + sip show peers)
#   [3] Flag --dry-run para simular sem executar
#   [4] Lógica do prefixo 55 mais robusta (verifica comprimento)
#   [5] Cabeçalho padrão Voxcorp Setup
#   [6] Log em diretório protegido (/var/log/voxcorp-setup, 750/640)
#   [7] Standalone (sem dependência de common.sh)
# =====================================================================

set -o pipefail

# ---------------------------------------------------------------------
# Cores e funções de log
# ---------------------------------------------------------------------
VERDE='\033[0;32m'
AMARELO='\033[1;33m'
VERMELHO='\033[0;31m'
AZUL='\033[0;34m'
NEGRITO='\033[1m'
NC='\033[0m'

# Log file será definido após criar diretório
LOG_FILE=""

ok()    { echo -e "  ${VERDE}✓${NC} $1" | tee -a "${LOG_FILE:-/dev/null}"; }
info()  { echo -e "  ${AZUL}➜${NC} $1" | tee -a "${LOG_FILE:-/dev/null}"; }
warn()  { echo -e "  ${AMARELO}⚠${NC} $1" | tee -a "${LOG_FILE:-/dev/null}"; }
erro()  { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1" | tee -a "${LOG_FILE:-/dev/null}"; exit 1; }
titulo() {
  echo "" | tee -a "${LOG_FILE:-/dev/null}"
  echo -e "${NEGRITO}${AZUL}═══════════════════════════════════════════════════${NC}" | tee -a "${LOG_FILE:-/dev/null}"
  echo -e "${NEGRITO} $1${NC}" | tee -a "${LOG_FILE:-/dev/null}"
  echo -e "${NEGRITO}${AZUL}═══════════════════════════════════════════════════${NC}" | tee -a "${LOG_FILE:-/dev/null}"
}

# ---------------------------------------------------------------------
# Função: executar mysql sem expor senha
# Usa MYSQL_PWD via env (não aparece em ps aux)
# ---------------------------------------------------------------------
mysql_run() {
  MYSQL_PWD="$DB_PASS" mysql --user="$DB_USER" -h "$DB_HOST" -D "$DB_NAME" "$@"
}

# ---------------------------------------------------------------------
# Parse argumentos
# ---------------------------------------------------------------------
DRY_RUN=0
for ARG in "$@"; do
  case "$ARG" in
    --dry-run)
      DRY_RUN=1
      ;;
    --help|-h)
      sed -n '/^# Voxcorp Setup/,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Opção desconhecida: $ARG (use --help para ajuda)"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------
# Diretório e arquivo de log com permissão restrita
# ---------------------------------------------------------------------
LOG_DIR="/var/log/voxcorp-setup"
if [ ! -d "$LOG_DIR" ]; then
  mkdir -p "$LOG_DIR" || { echo "Não consegui criar $LOG_DIR. Rode como root."; exit 1; }
  chmod 750 "$LOG_DIR"
fi
LOG_FILE="$LOG_DIR/did-migration-$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

# ---------------------------------------------------------------------
# Cabeçalho da execução
# ---------------------------------------------------------------------
clear
titulo "MIGRAÇÃO DE DIDs EM MASSA — MagnusBilling (v4.0)"
info "Servidor:    $(hostname) ($(hostname -I | awk '{print $1}'))"
info "Data/hora:   $(date '+%Y-%m-%d %H:%M:%S')"
info "Log:         $LOG_FILE"
if [ $DRY_RUN -eq 1 ]; then
  warn "MODO DRY-RUN ATIVO — nenhuma alteração será gravada"
fi

# ---------------------------------------------------------------------
# Ler credenciais do banco
# ---------------------------------------------------------------------
titulo "1. LEITURA DE CREDENCIAIS"

DB_HOST="localhost"
DB_NAME="mbilling"

if [ -f "/etc/asterisk/res_config_mysql.conf" ]; then
  DB_USER=$(grep "^dbuser" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')
  DB_PASS=$(grep "^dbpass" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')
  DB_HOST=$(grep "^dbhost" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')
  DB_NAME=$(grep "^dbname" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')
  ok "Credenciais lidas de /etc/asterisk/res_config_mysql.conf"
elif [ -f "/var/www/html/mbilling/protected/config/db.php" ]; then
  DB_USER=$(grep "username" /var/www/html/mbilling/protected/config/db.php | cut -d"'" -f4)
  DB_PASS=$(grep "password" /var/www/html/mbilling/protected/config/db.php | cut -d"'" -f4)
  ok "Credenciais lidas de db.php"
else
  warn "Arquivo de configuração não encontrado. Informe manualmente:"
  read -p "  Usuário do banco: " DB_USER
  read -sp "  Senha do banco: " DB_PASS
  echo ""
fi

# Testar conexão (sem expor senha)
mysql_run -e "SELECT 1;" >/dev/null 2>&1 || erro "Falha na conexão com o banco. Verifique credenciais."
ok "Conexão MySQL OK (DB: $DB_NAME @ $DB_HOST)"

# ---------------------------------------------------------------------
# Coleta de filtros e parâmetros
# ---------------------------------------------------------------------
titulo "2. PARÂMETROS DA MIGRAÇÃO"

echo ""
echo -e "  Tipo de operação:"
echo -e "  ${AZUL}[1]${NC} Bloco de DIDs (intervalo início → fim)"
echo -e "  ${AZUL}[2]${NC} DID único"
echo -e "  ${AZUL}[3]${NC} Lista de DIDs (arquivo .txt, um por linha)"
echo -e "  ${AZUL}[4]${NC} Todos os DIDs de um cliente específico (pelo ID atual)"
echo ""
read -p "  Escolha [1]: " MODO_DID
MODO_DID=${MODO_DID:-1}

case "$MODO_DID" in
  1)
    read -p "  DID INICIAL (ex: 551153500000): " DID_START
    read -p "  DID FINAL   (ex: 551153500900): " DID_END
    [ -z "$DID_START" ] || [ -z "$DID_END" ] && erro "DID inicial e final são obrigatórios"
    [ "$DID_START" -gt "$DID_END" ] 2>/dev/null && erro "DID inicial não pode ser maior que o final"
    CONDICAO_WHERE="did >= '${DID_START}' AND did <= '${DID_END}'"
    DESCRICAO_FILTRO="Bloco: $DID_START → $DID_END"
    ;;
  2)
    read -p "  DID (ex: 551153500001): " DID_UNICO
    [ -z "$DID_UNICO" ] && erro "DID é obrigatório"
    CONDICAO_WHERE="did = '${DID_UNICO}'"
    DESCRICAO_FILTRO="DID único: $DID_UNICO"
    ;;
  3)
    read -p "  Caminho do arquivo .txt com DIDs: " ARQUIVO_DIDS
    [ ! -f "$ARQUIVO_DIDS" ] && erro "Arquivo $ARQUIVO_DIDS não encontrado"
    LISTA_DIDS=$(cat "$ARQUIVO_DIDS" | tr '\n' ',' | sed 's/,$//' | sed "s/\([0-9]*\)/'\1'/g")
    [ -z "$LISTA_DIDS" ] && erro "Arquivo vazio ou em formato inválido"
    CONDICAO_WHERE="did IN (${LISTA_DIDS})"
    DESCRICAO_FILTRO="Lista de arquivo: $ARQUIVO_DIDS"
    ;;
  4)
    read -p "  ID do cliente ATUAL (Dono de Origem): " SOURCE_ID_USER
    [ -z "$SOURCE_ID_USER" ] && erro "ID do cliente de origem é obrigatório"
    
    SOURCE_USER_INFO=$(mysql_run -N -e \
      "SELECT CONCAT(username, ' (', email, ')') FROM pkg_user WHERE id = ${SOURCE_ID_USER};" 2>/dev/null)
    
    if [ -z "$SOURCE_USER_INFO" ] && [ "$SOURCE_ID_USER" -ne 0 ]; then
      erro "Usuário de origem ID ${SOURCE_ID_USER} não encontrado no banco"
    elif [ "$SOURCE_ID_USER" -eq 0 ]; then
      SOURCE_USER_INFO="DIDs Livres / Não Atribuídos (ID 0)"
    fi
    
    # Congela a lista para evitar o "Paradoxo do WHERE" durante a transação
    LISTA_DIDS_ORIGEM=$(mysql_run -N -e \
      "SELECT did FROM pkg_did WHERE id_user = ${SOURCE_ID_USER};" 2>/dev/null | \
      tr '\n' ',' | sed 's/,$//' | sed "s/\([0-9]*\)/'\1'/g")
    
    [ -z "$LISTA_DIDS_ORIGEM" ] && erro "Nenhum DID vinculado ao cliente ID ${SOURCE_ID_USER}"
    
    CONDICAO_WHERE="did IN (${LISTA_DIDS_ORIGEM})"
    DESCRICAO_FILTRO="Cliente origem: $SOURCE_USER_INFO"
    ;;
  *)
    erro "Opção inválida"
    ;;
esac

echo ""
read -p "  ID do usuário DESTINO no Magnus (novo dono): " TARGET_ID_USER
[ -z "$TARGET_ID_USER" ] && erro "ID do usuário destino é obrigatório"

USER_INFO=$(mysql_run -N -e \
  "SELECT CONCAT(username, ' (', email, ')') FROM pkg_user WHERE id = ${TARGET_ID_USER};" 2>/dev/null)
[ -z "$USER_INFO" ] && erro "Usuário destino ID ${TARGET_ID_USER} não encontrado no banco"
ok "Usuário destino: $USER_INFO"

echo ""
read -p "  IP:PORTA de destino SIP (ex: 190.89.250.124:5060): " DESTINATION_IP_PORT
[ -z "$DESTINATION_IP_PORT" ] && erro "IP:PORTA é obrigatório"

[[ "$DESTINATION_IP_PORT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]] \
  || erro "Formato inválido. Use IP:PORTA (ex: 190.89.250.124:5060)"

# ---------------------------------------------------------------------
# Validação de alcance do destino SIP (NOVO em v4.0)
# ---------------------------------------------------------------------
titulo "3. VALIDAÇÃO DO DESTINO SIP"

IP_DESTINO=$(echo "$DESTINATION_IP_PORT" | cut -d: -f1)
PORTA_DESTINO=$(echo "$DESTINATION_IP_PORT" | cut -d: -f2)

# Teste 1: ICMP ping (informativo, firewall pode bloquear)
if ping -c 2 -W 2 "$IP_DESTINO" >/dev/null 2>&1; then
  ok "IP $IP_DESTINO responde ping"
else
  warn "IP $IP_DESTINO NÃO responde ping (pode ser firewall ICMP — não bloqueia execução)"
fi

# Teste 2: Asterisk conhece esse IP como peer? (mais relevante)
if command -v asterisk >/dev/null 2>&1; then
  PEER_MATCH=$(asterisk -rx "sip show peers" 2>/dev/null | grep "$IP_DESTINO" | head -3)
  if [ -n "$PEER_MATCH" ]; then
    ok "Asterisk reconhece $IP_DESTINO como peer:"
    echo "$PEER_MATCH" | sed 's/^/      /' | tee -a "$LOG_FILE"
  else
    warn "Asterisk NÃO tem nenhum peer com IP $IP_DESTINO"
    warn "→ Chamadas para os DIDs migrados podem retornar 401 Unauthorized"
    warn "→ Verifique se o trunk de destino está cadastrado no Magnus"
  fi
else
  warn "Comando 'asterisk' não disponível — pulei validação de peer"
fi

# ---------------------------------------------------------------------
# Relatório pré-execução
# ---------------------------------------------------------------------
titulo "4. RELATÓRIO PRÉ-EXECUÇÃO"

COUNT=$(mysql_run -N -e "SELECT COUNT(id) FROM pkg_did WHERE ${CONDICAO_WHERE};" 2>/dev/null)
[ "$COUNT" -eq 0 ] && erro "Nenhum DID encontrado com o critério informado"

JA_ATRIBUIDOS=$(mysql_run -N -e \
  "SELECT COUNT(id) FROM pkg_did WHERE ${CONDICAO_WHERE} AND id_user != 0 AND id_user != ${TARGET_ID_USER};" 2>/dev/null)

ROTAS_EXISTENTES=$(mysql_run -N -e \
  "SELECT COUNT(dest.id) FROM pkg_did_destination dest \
   JOIN pkg_did did ON dest.id_did = did.id \
   WHERE did.${CONDICAO_WHERE};" 2>/dev/null)

AMOSTRA=$(mysql_run -N -e "SELECT did FROM pkg_did WHERE ${CONDICAO_WHERE} LIMIT 5;" 2>/dev/null)

echo "" | tee -a "$LOG_FILE"
echo -e "  ${NEGRITO}Filtro aplicado:${NC}                  $DESCRICAO_FILTRO" | tee -a "$LOG_FILE"
echo -e "  ${NEGRITO}Total de DIDs localizados:${NC}        ${VERDE}${COUNT}${NC}" | tee -a "$LOG_FILE"
if [ "$MODO_DID" -eq 4 ]; then
  echo -e "  ${NEGRITO}Cliente de origem atual:${NC}          ${AMARELO}${SOURCE_USER_INFO} (ID: ${SOURCE_ID_USER})${NC}" | tee -a "$LOG_FILE"
else
  echo -e "  ${NEGRITO}Já atribuídos a outros donos:${NC}     ${AMARELO}${JA_ATRIBUIDOS}${NC}" | tee -a "$LOG_FILE"
fi
echo -e "  ${NEGRITO}Rotas atuais a remover:${NC}           ${AMARELO}${ROTAS_EXISTENTES}${NC}" | tee -a "$LOG_FILE"
echo -e "  ${NEGRITO}Usuário destino final:${NC}            ${VERDE}${USER_INFO} (ID: ${TARGET_ID_USER})${NC}" | tee -a "$LOG_FILE"
echo -e "  ${NEGRITO}Novo destino SIP:${NC}                 ${VERDE}SIP/[DID]@${DESTINATION_IP_PORT}${NC}" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo -e "  ${NEGRITO}Amostra dos primeiros DIDs:${NC}" | tee -a "$LOG_FILE"
echo "$AMOSTRA" | while read DID; do
  echo "     - $DID" | tee -a "$LOG_FILE"
done
echo "" | tee -a "$LOG_FILE"

if [ "$MODO_DID" -ne 4 ] && [ "$JA_ATRIBUIDOS" -gt 0 ]; then
  warn "${JA_ATRIBUIDOS} DIDs atualmente pertencem a outros clientes — serão REATRIBUÍDOS!"
fi

# ---------------------------------------------------------------------
# Lógica do prefixo 55 (NOVO em v4.0 — mais robusta)
# DID brasileiro completo tem mínimo 12 dígitos (55 + DDD + 8N)
# ---------------------------------------------------------------------
LOGICA_PREFIXO="CASE
                WHEN LENGTH(did) >= 12 AND LEFT(did, 2) = '55' THEN did
                ELSE CONCAT('55', did)
            END"

# ---------------------------------------------------------------------
# Bloco SQL que será executado (montado uma vez)
# ---------------------------------------------------------------------
SQL_BLOCO=$(cat << EOSQL
START TRANSACTION;

-- 1. Remover rotas antigas
DELETE dest FROM pkg_did_destination dest
JOIN pkg_did did ON dest.id_did = did.id
WHERE did.${CONDICAO_WHERE};

-- 2. Criar novas rotas SIP
INSERT INTO pkg_did_destination
    (id_did, id_user, destination, voip_call, activated, priority, id_sip, id_ivr, id_queue, creationdate)
SELECT
    id,
    ${TARGET_ID_USER},
    CONCAT('SIP/', ${LOGICA_PREFIXO}, '@${DESTINATION_IP_PORT}'),
    9,
    1,
    1,
    0,
    0,
    0,
    NOW()
FROM pkg_did
WHERE ${CONDICAO_WHERE};

-- 3. Atualizar dono e estado dos DIDs
UPDATE pkg_did
SET
    id_user   = ${TARGET_ID_USER},
    reserved  = 1,
    activated = 1
WHERE ${CONDICAO_WHERE};

COMMIT;
EOSQL
)

echo -e "  ${NEGRITO}Operações SQL:${NC}" | tee -a "$LOG_FILE"
echo -e "  1. ${AZUL}DELETE${NC} em pkg_did_destination  (rotas antigas)" | tee -a "$LOG_FILE"
echo -e "  2. ${AZUL}INSERT${NC} em pkg_did_destination  (novas rotas SIP voip_call=9)" | tee -a "$LOG_FILE"
echo -e "  3. ${AZUL}UPDATE${NC} em pkg_did              (id_user, reserved, activated)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ---------------------------------------------------------------------
# Modo dry-run: imprime SQL e sai sem executar (NOVO em v4.0)
# ---------------------------------------------------------------------
if [ $DRY_RUN -eq 1 ]; then
  titulo "5. MODO DRY-RUN — SQL QUE SERIA EXECUTADO"
  echo "" | tee -a "$LOG_FILE"
  echo "$SQL_BLOCO" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  ok "Dry-run concluído. Nenhuma alteração foi realizada."
  info "Log salvo em: $LOG_FILE"
  exit 0
fi

# ---------------------------------------------------------------------
# Confirmação e execução
# ---------------------------------------------------------------------
titulo "5. EXECUÇÃO"

read -p "  Confirma a execução em produção? (digite 'sim'): " CONFIRM
[ "$CONFIRM" != "sim" ] && { warn "Operação cancelada pelo administrador"; exit 0; }

info "Abrindo transação SQL e aplicando modificações..."
echo "$SQL_BLOCO" | mysql_run 2>&1 | tee -a "$LOG_FILE"
SQL_STATUS=${PIPESTATUS[0]}

# ---------------------------------------------------------------------
# Auditoria pós-execução
# ---------------------------------------------------------------------
titulo "6. RESULTADO"

if [ $SQL_STATUS -eq 0 ]; then
  AFETADOS=$(mysql_run -N -e \
    "SELECT COUNT(id) FROM pkg_did WHERE ${CONDICAO_WHERE} AND id_user = ${TARGET_ID_USER};" 2>/dev/null)
  
  ROTAS_CRIADAS=$(mysql_run -N -e \
    "SELECT COUNT(dest.id) FROM pkg_did_destination dest \
     JOIN pkg_did did ON dest.id_did = did.id \
     WHERE did.${CONDICAO_WHERE} AND dest.id_user = ${TARGET_ID_USER};" 2>/dev/null)

  echo "" | tee -a "$LOG_FILE"
  echo -e "  ${VERDE}${NEGRITO}✓ MIGRAÇÃO EXECUTADA COM SUCESSO${NC}" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  echo -e "  DIDs atualizados sob o novo dono:    ${VERDE}${AFETADOS}${NC}" | tee -a "$LOG_FILE"
  echo -e "  Novas rotas SIP criadas:             ${VERDE}${ROTAS_CRIADAS}${NC}" | tee -a "$LOG_FILE"
  echo -e "  URI gerada:                          ${VERDE}SIP/[DID]@${DESTINATION_IP_PORT}${NC}" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  info "Log completo em: $LOG_FILE"
  exit 0
else
  echo "" | tee -a "$LOG_FILE"
  echo -e "  ${VERMELHO}${NEGRITO}✗ ERRO NA EXECUÇÃO — ROLLBACK AUTOMÁTICO${NC}" | tee -a "$LOG_FILE"
  echo -e "  ${VERMELHO}Nenhuma alteração foi realizada na base.${NC}" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  info "Consulte o log para diagnóstico: $LOG_FILE"
  exit 1
fi