#!/bin/bash
# =====================================================================
#      MIGRAÇÃO DE DIDs EM MASSA - MAGNUSBILLING
#      Versão 3.2 - Profissional & Automatizado
#
#      MELHORIAS DESTA VERSÃO:
#      [1] Credenciais do banco lidas automaticamente do sistema
#      [2] Validação de intervalo DID (início <= fim)
#      [3] Validação se usuário destino existe no banco
#      [4] Suporte a DID individual, bloco, lista ou por ID do Cliente
#      [5] Relatório detalhado com validação de origem e destino
#      [6] Verifica DIDs já atribuídos a outros usuários
#      [7] Corrige prefixo 55 apenas se necessário (não duplica)
#      [8] Log de execução completo salvo em arquivo corporativo
#      [9] Rollback automático via transações SQL (InnoDb)
#      [10] Resumo final consolidado com contagem em tempo real
#      [FIX] Correção do pipeline de injeção SQL e captura de erro
#      [FIX] Resolução do Paradoxo WHERE na Opção 4 + Reordenação SQL
# =====================================================================

VERDE='\033[0;32m'
AMARELO='\033[1;33m'
VERMELHO='\033[0;31m'
AZUL='\033[0;34m'
NEGRITO='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${VERDE}✔ $1${NC}"; }
info() { echo -e "  ${AZUL}➜ $1${NC}"; }
warn() { echo -e "  ${AMARELO}⚠ $1${NC}"; }
erro() { echo -e "  ${VERMELHO}✘ ERRO: $1${NC}"; exit 1; }

LOG_FILE="/var/log/magnus_did_migration_$(date +%Y%m%d_%H%M%S).log"

log() {
  echo -e "$1" | tee -a "$LOG_FILE"
}

clear
echo ""
log "${NEGRITO}${AZUL}====================================================="
log "      MIGRAÇÃO DE DIDs EM MASSA - MAGNUSBILLING"
log "                    Versão 3.2"
log "=====================================================${NC}"
echo ""

# =====================================================================
# LER CREDENCIAIS DO BANCO
# =====================================================================
DB_HOST="localhost"
DB_NAME="mbilling"

if [ -f "/etc/asterisk/res_config_mysql.conf" ]; then
  DB_USER=$(grep "dbuser" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')
  DB_PASS=$(grep "dbpass" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')
  DB_HOST=$(grep "dbhost" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')
  DB_NAME=$(grep "dbname" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')
  ok "Credenciais lidas de res_config_mysql.conf"
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

# Testar conexão com o banco
mysql --user="$DB_USER" --password="$DB_PASS" -h "$DB_HOST" -D "$DB_NAME" -e "SELECT 1;" > /dev/null 2>&1 \
  || erro "Falha na conexão com o banco. Verifique as credenciais."
ok "Conexão com banco de dados OK"

# =====================================================================
# COLETA DE DADOS & FILTROS
# =====================================================================
echo ""
log "${NEGRITO}-----------------------------------------------------${NC}"
log " INFORMAÇÕES DA MIGRAÇÃO"
log "${NEGRITO}-----------------------------------------------------${NC}"
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
    [ "$DID_START" -gt "$DID_END" ] 2>/dev/null && erro "DID inicial não pode ser maior que o DID final"
    CONDICAO_WHERE="did >= '${DID_START}' AND did <= '${DID_END}'"
    ;;
  2)
    read -p "  DID (ex: 551153500001): " DID_UNICO
    [ -z "$DID_UNICO" ] && erro "DID é obrigatório"
    CONDICAO_WHERE="did = '${DID_UNICO}'"
    ;;
  3)
    read -p "  Caminho do arquivo .txt com DIDs: " ARQUIVO_DIDS
    [ ! -f "$ARQUIVO_DIDS" ] && erro "Arquivo $ARQUIVO_DIDS não encontrado"
    LISTA_DIDS=$(cat "$ARQUIVO_DIDS" | tr '\n' ',' | sed 's/,$//' | sed "s/\([0-9]*\)/'\1'/g")
    CONDICAO_WHERE="did IN (${LISTA_DIDS})"
    ;;
  4)
    read -p "  ID do cliente ATUAL (Dono de Origem): " SOURCE_ID_USER
    [ -z "$SOURCE_ID_USER" ] && erro "ID do cliente de origem é obrigatório"
    
    # Validar se o usuário de origem existe
    SOURCE_USER_INFO=$(mysql --user="$DB_USER" --password="$DB_PASS" -h "$DB_HOST" -D "$DB_NAME" -N -e \
      "SELECT CONCAT(username, ' (', email, ')') FROM pkg_user WHERE id = ${SOURCE_ID_USER};" 2>/dev/null)
    
    if [ -z "$SOURCE_USER_INFO" ] && [ "$SOURCE_ID_USER" -ne 0 ]; then
      erro "Usuário de origem ID ${SOURCE_ID_USER} não encontrado no banco!"
    elif [ "$SOURCE_ID_USER" -eq 0 ]; then
      SOURCE_USER_INFO="DIDs Livres / Não Atribuídos (ID 0)"
    fi
    
    # [FIX] Congela a lista de DIDs para evitar o Paradoxo do WHERE durante a transação
    LISTA_DIDS_ORIGEM=$(mysql --user="$DB_USER" --password="$DB_PASS" -h "$DB_HOST" -D "$DB_NAME" -N -e \
      "SELECT did FROM pkg_did WHERE id_user = ${SOURCE_ID_USER};" 2>/dev/null | tr '\n' ',' | sed 's/,$//' | sed "s/\([0-9]*\)/'\1'/g")
    
    [ -z "$LISTA_DIDS_ORIGEM" ] && erro "Nenhum DID encontrado vinculado ao cliente ID ${SOURCE_ID_USER}."
    
    CONDICAO_WHERE="did IN (${LISTA_DIDS_ORIGEM})"
    ;;
  *)
    erro "Opção inválida"
    ;;
esac

echo ""
read -p "  ID do usuário DESTINO no Magnus (novo dono): " TARGET_ID_USER
[ -z "$TARGET_ID_USER" ] && erro "ID do usuário destino é obrigatório"

# Validar se o usuário destino existe
USER_INFO=$(mysql --user="$DB_USER" --password="$DB_PASS" -h "$DB_HOST" -D "$DB_NAME" -N -e \
  "SELECT CONCAT(username, ' (', email, ')') FROM pkg_user WHERE id = ${TARGET_ID_USER};" 2>/dev/null)
[ -z "$USER_INFO" ] && erro "Usuário destino ID ${TARGET_ID_USER} não encontrado no banco!"
ok "Usuário destino: ${USER_INFO}"

echo ""
read -p "  IP:PORTA de destino SIP (ex: 190.89.250.124:5060): " DESTINATION_IP_PORT
[ -z "$DESTINATION_IP_PORT" ] && erro "IP:PORTA é obrigatório"

# Validar formato IP:PORTA
[[ "$DESTINATION_IP_PORT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]] \
  || erro "Formato inválido. Use IP:PORTA (ex: 190.89.250.124:5060)"

# =====================================================================
# RELATÓRIO PRÉ-EXECUÇÃO
# =====================================================================
echo ""
log "${NEGRITO}-----------------------------------------------------${NC}"
log " RELATÓRIO PRÉ-EXECUÇÃO"
log "${NEGRITO}-----------------------------------------------------${NC}"
echo ""

# Contar DIDs correspondentes ao filtro
COUNT=$(mysql --user="$DB_USER" --password="$DB_PASS" -h "$DB_HOST" -D "$DB_NAME" -N -e \
  "SELECT COUNT(id) FROM pkg_did WHERE ${CONDICAO_WHERE};" 2>/dev/null)

[ "$COUNT" -eq 0 ] && erro "Nenhum DID encontrado com o critério informado na tabela pkg_did"

# Verificar se algum DID já pertence a terceiros (relevante para as opções 1, 2 e 3)
JA_ATRIBUIDOS=$(mysql --user="$DB_USER" --password="$DB_PASS" -h "$DB_HOST" -D "$DB_NAME" -N -e \
  "SELECT COUNT(id) FROM pkg_did WHERE ${CONDICAO_WHERE} AND id_user != 0 AND id_user != ${TARGET_ID_USER};" 2>/dev/null)

# Verificar rotas existentes que serão substituídas
ROTAS_EXISTENTES=$(mysql --user="$DB_USER" --password="$DB_PASS" -h "$DB_HOST" -D "$DB_NAME" -N -e \
  "SELECT COUNT(dest.id) FROM pkg_did_destination dest \
   JOIN pkg_did did ON dest.id_did = did.id \
   WHERE did.${CONDICAO_WHERE};" 2>/dev/null)

# Amostra para conferência visual rápida
AMOSTRA=$(mysql --user="$DB_USER" --password="$DB_PASS" -h "$DB_HOST" -D "$DB_NAME" -N -e \
  "SELECT did FROM pkg_did WHERE ${CONDICAO_WHERE} LIMIT 5;" 2>/dev/null)

log "  ${NEGRITO}Total de DIDs localizados:${NC}       ${VERDE}${COUNT}${NC}"
if [ "$MODO_DID" -eq 4 ]; then
  log "  ${NEGRITO}Cliente de Origem Atual:${NC}         ${AMARELO}${SOURCE_USER_INFO} (ID: ${SOURCE_ID_USER})${NC}"
else
  log "  ${NEGRITO}Já atribuídos a outros donos:${NC}    ${AMARELO}${JA_ATRIBUIDOS}${NC}"
fi
log "  ${NEGRITO}Rotas atuais a remover:${NC}          ${AMARELO}${ROTAS_EXISTENTES}${NC}"
log "  ${NEGRITO}Usuário destino final:${NC}           ${VERDE}${USER_INFO} (ID: ${TARGET_ID_USER})${NC}"
log "  ${NEGRITO}Novo Destino SIP URI:${NC}            ${VERDE}SIP/[DID]@${DESTINATION_IP_PORT}${NC}"
echo ""
log "  ${NEGRITO}Amostra dos primeiros DIDs do filtro:${NC}"
echo "$AMOSTRA" | while read DID; do
  log "     - ${DID}"
done
echo ""

if [ "$MODO_DID" -ne 4 ] && [ "$JA_ATRIBUIDOS" -gt 0 ]; then
  warn "${JA_ATRIBUIDOS} DIDs atualmente pertencem a outros clientes e serão REATRIBUÍDOS!"
  echo ""
fi

echo -e "  ${NEGRITO}Operações estruturais na transação:${NC}"
echo -e "  1. ${AZUL}DELETE pkg_did_destination${NC}  → Expurgar rotas antigas vinculadas."
echo -e "  2. ${AZUL}INSERT pkg_did_destination${NC}  → Inserir novas rotas personalizadas (voip_call=9) com IP:Porta."
echo -e "  3. ${AZUL}UPDATE pkg_did${NC}              → Alterar dono (id_user=${TARGET_ID_USER}), reservar e ativar."
echo ""

read -p "  Confirma a execução em produção? (digite 'sim'): " CONFIRM
[ "$CONFIRM" != "sim" ] && echo "  Operação cancelada pelo administrador." && exit 0

# =====================================================================
# EXECUÇÃO DA TRANSAÇÃO ACID ATÔMICA
# =====================================================================
echo ""
info "Abrindo transação SQL e aplicando modificações..."

mysql --user="$DB_USER" --password="$DB_PASS" -h "$DB_HOST" -D "$DB_NAME" << EOF 2>&1 | tee -a "$LOG_FILE"
START TRANSACTION;

-- 1. Remoção cirúrgica de rotas antigas
DELETE dest FROM pkg_did_destination dest
JOIN pkg_did did ON dest.id_did = did.id
WHERE did.${CONDICAO_WHERE};

-- 2. Geração das novas strings de roteamento SIP
INSERT INTO pkg_did_destination
    (id_did, id_user, destination, voip_call, activated, priority, id_sip, id_ivr, id_queue, creationdate)
SELECT
    id,
    ${TARGET_ID_USER},
    CONCAT(
        'SIP/',
        CASE
            WHEN LEFT(did, 2) = '55' THEN did
            ELSE CONCAT('55', did)
        END,
        '@${DESTINATION_IP_PORT}'
    ),
    9,
    1,
    1,
    0,
    0,
    0,
    NOW()
FROM pkg_did
WHERE ${CONDICAO_WHERE};

-- 3. Atualização dos metadados e da posse do DID na tabela principal
UPDATE pkg_did
SET
    id_user   = ${TARGET_ID_USER},
    reserved  = 1,
    activated = 1
WHERE ${CONDICAO_WHERE};

COMMIT;
EOF

SQL_STATUS=${PIPESTATUS[0]}

# =====================================================================
# AUDITORIA & CONSOLIDADO FINAL
# =====================================================================
echo ""
if [ $SQL_STATUS -eq 0 ]; then
  # Coleta estatísticas reais pós-commit
  AFETADOS=$(mysql --user="$DB_USER" --password="$DB_PASS" -h "$DB_HOST" -D "$DB_NAME" -N -e \
    "SELECT COUNT(id) FROM pkg_did WHERE ${CONDICAO_WHERE} AND id_user = ${TARGET_ID_USER};" 2>/dev/null)

  ROTAS_CRIADAS=$(mysql --user="$DB_USER" --password="$DB_PASS" -h "$DB_HOST" -D "$DB_NAME" -N -e \
    "SELECT COUNT(dest.id) FROM pkg_did_destination dest \
     JOIN pkg_did did ON dest.id_did = did.id \
     WHERE did.${CONDICAO_WHERE} AND dest.id_user = ${TARGET_ID_USER};" 2>/dev/null)

  log ""
  log "${VERDE}====================================================="
  log "       MIGRAÇÃO EXECUTADA COM SUCESSO!"
  log "=====================================================${NC}"
  log ""
  log "  ${NEGRITO}DIDs atualizados sob o novo proprietário:${NC}  ${VERDE}${AFETADOS}${NC}"
  log "  ${NEGRITO}Novas rotas SIP Custom criadas:${NC}          ${VERDE}${ROTAS_CRIADAS}${NC}"
  log "  ${NEGRITO}URI de Destino Final gravada:${NC}            ${VERDE}SIP/[DID]@${DESTINATION_IP_PORT}${NC}"
  log ""
  log "  Relatório detalhado registrado em: ${AZUL}${LOG_FILE}${NC}"
  log ""
else
  log ""
  log "${VERMELHO}====================================================="
  log "       CRITICAL ERROR — ROLLBACK AUTOMÁTICO"
  log "       Nenhuma alteração foi realizada na base."
  log "=====================================================${NC}"
  log ""
  log "  Consulte o arquivo de log para diagnóstico: ${AZUL}${LOG_FILE}${NC}"
  exit 1
fi