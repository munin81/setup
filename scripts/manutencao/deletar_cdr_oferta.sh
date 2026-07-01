#!/bin/bash
# =====================================================================
# Magnus Utilities — deletar_cdr_oferta.sh
# Versão: 15.0 (19 de junho de 2026)
# Função: Remover usuários inativos (active=0) por período + dados filhos
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root (para backup em /root e leitura de credenciais)
#   - Magnus 7.x + MariaDB acessível em localhost
#
# Uso: bash deletar_cdr_oferta.sh
#
# Idempotência: NÃO (deleção)
# Modifica estado: SIM (DELETE em pkg_user e tabelas filhas)
# Requer janela de manutenção: NÃO (mas é destrutivo)
#
# Mudanças v15.0 (junho 2026):
#   [1] BACKUP obrigatório (mysqldump dos registros afetados) ANTES de deletar
#   [2] Deleção atômica em transação real (START TRANSACTION ... COMMIT);
#       qualquer erro aborta o lote e faz rollback automático
#   [3] Senha via MYSQL_PWD (nunca em ps aux)
#   [4] Cabeçalho padrão Magnus Utilities
# =====================================================================

set -o pipefail

echo "------------------------------------------------------------------"
echo "Script de Deleção de Usuários Inativos por Período (v15)"
echo "------------------------------------------------------------------"
echo

# --- Configuração do Banco de Dados ---
if [ -f "/etc/asterisk/res_config_mysql.conf" ]; then
  DB_USER=$(grep "^dbuser" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')
  DB_PASS=$(grep "^dbpass" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')
  DB_HOST=$(grep "^dbhost" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')
  DB_NAME=$(grep "^dbname" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')
elif [ -f "/var/www/html/mbilling/protected/config/db.php" ]; then
  DB_USER=$(grep "username" /var/www/html/mbilling/protected/config/db.php | cut -d"'" -f4)
  DB_PASS=$(grep "password" /var/www/html/mbilling/protected/config/db.php | cut -d"'" -f4)
  DB_HOST="localhost"
  DB_NAME="mbilling"
else
  read -p "  Usuário do banco: " DB_USER
  read -sp "  Senha do banco: " DB_PASS
  echo ""
  DB_HOST="localhost"
  DB_NAME="mbilling"
fi

# Executa mysql/mysqldump sem expor a senha em ps aux (MYSQL_PWD via env)
mysql_run() {
  MYSQL_PWD="$DB_PASS" mysql --user="$DB_USER" -h "$DB_HOST" -D "$DB_NAME" "$@"
}
mysqldump_run() {
  MYSQL_PWD="$DB_PASS" mysqldump --user="$DB_USER" -h "$DB_HOST" "$@"
}

# Testa conexão antes de prosseguir
mysql_run -e "SELECT 1;" >/dev/null 2>&1 || { echo "ERRO: não foi possível conectar ao banco. Verifique credenciais."; exit 1; }

# --- ETAPA 1: Coleta do Período ---
read -p "Digite a DATA DE INÍCIO (formato AAAA-MM-DD): " START_DATE
read -p "Digite a DATA DE FIM (formato AAAA-MM-DD): " END_DATE

if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    echo "Erro: As datas de início e fim são obrigatórias. Saindo."
    exit 1
fi

# Valida formato AAAA-MM-DD (impede injeção SQL via as datas)
for D in "$START_DATE" "$END_DATE"; do
    echo "$D" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
      || { echo "Erro: data '$D' fora do formato AAAA-MM-DD. Saindo."; exit 1; }
done

echo "------------------------------------------------------------------"
echo "Buscando usuários inativos (active=0) criados entre $START_DATE e $END_DATE..."

# --- ETAPA 2: Listagem dos Usuários ---
QUERY_FIND_USERS="SELECT id, username FROM pkg_user WHERE active = 0 AND DATE(creationdate) BETWEEN '$START_DATE' AND '$END_DATE';"
USER_LIST=$(mysql_run -N -e "$QUERY_FIND_USERS")

if [ $? -ne 0 ]; then
    echo "ERRO ao buscar usuários. Verifique se as datas estão no formato correto (AAAA-MM-DD)."
    exit 1
fi

if [ -z "$USER_LIST" ]; then
    echo "Nenhum usuário inativo encontrado no período especificado. Nada a fazer."
    exit 0
fi

USER_IDS=$(echo "$USER_LIST" | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')

echo "Os seguintes usuários inativos foram encontrados:"
echo "+-------+--------------------+"
echo "| ID    | Username           |"
echo "+-------+--------------------+"
echo "$USER_LIST" | while read -r id name; do
    printf "| %-5s | %-18s |\n" "$id" "$name"
done
echo "+-------+--------------------+"
echo
echo "Total de usuários a serem DELETADOS: $(echo "$USER_LIST" | wc -l)"
echo "------------------------------------------------------------------"

# --- ETAPA 3: Confirmação Final ---
read -p "Deseja executar a LIMPEZA COMPLETA E IRREVERSÍVEL para TODOS os usuários listados acima? (digite 'sim'): " CONFIRM

if [ "$CONFIRM" != "sim" ]; then
    echo "Operação cancelada pelo usuário."
    exit 0
fi

# --- ETAPA 4: BACKUP dos registros afetados (rollback manual possível) ---
BACKUP_FILE="/root/cleanup-cdr-backup-$(date +%Y%m%d_%H%M%S).sql"
echo "Gerando backup dos registros afetados em: $BACKUP_FILE"

: > "$BACKUP_FILE"
chmod 600 "$BACKUP_FILE"

BACKUP_OK=1
# Cada tabela é exportada filtrando apenas os IDs afetados (backup enxuto e restaurável)
mysqldump_run --no-create-info --skip-extended-insert --where="id_user IN ($USER_IDS)" "$DB_NAME" pkg_offer_cdr >> "$BACKUP_FILE" 2>/dev/null || BACKUP_OK=0
mysqldump_run --no-create-info --skip-extended-insert --where="id_user IN ($USER_IDS)" "$DB_NAME" pkg_cdr       >> "$BACKUP_FILE" 2>/dev/null || BACKUP_OK=0
mysqldump_run --no-create-info --skip-extended-insert --where="id_user IN ($USER_IDS)" "$DB_NAME" pkg_offer_use >> "$BACKUP_FILE" 2>/dev/null || BACKUP_OK=0
mysqldump_run --no-create-info --skip-extended-insert --where="id_user IN ($USER_IDS)" "$DB_NAME" pkg_sip       >> "$BACKUP_FILE" 2>/dev/null || BACKUP_OK=0
mysqldump_run --no-create-info --skip-extended-insert --where="id IN ($USER_IDS)"      "$DB_NAME" pkg_user      >> "$BACKUP_FILE" 2>/dev/null || BACKUP_OK=0

if [ "$BACKUP_OK" -ne 1 ] || [ ! -s "$BACKUP_FILE" ]; then
    echo "ERRO: o backup falhou ou ficou vazio. ABORTANDO sem deletar nada."
    echo "Verifique as credenciais/permissões e tente novamente."
    exit 1
fi
echo "Backup concluído com sucesso ($(du -h "$BACKUP_FILE" | cut -f1))."

# --- ETAPA 5: Execução da Limpeza em TRANSAÇÃO ATÔMICA ---
echo "Iniciando a limpeza completa (transação atômica)..."

# Sem --force: o mysql aborta no primeiro erro do lote; como tudo está dentro de
# uma transação, a conexão fecha sem COMMIT e o MariaDB faz ROLLBACK automático.
SQL_COMMANDS="
SET FOREIGN_KEY_CHECKS=0;
START TRANSACTION;

DELETE FROM pkg_offer_cdr WHERE id_user IN ($USER_IDS);
DELETE FROM pkg_cdr       WHERE id_user IN ($USER_IDS);
DELETE FROM pkg_offer_use WHERE id_user IN ($USER_IDS);
DELETE FROM pkg_sip       WHERE id_user IN ($USER_IDS);
DELETE FROM pkg_user      WHERE id      IN ($USER_IDS);

COMMIT;
SET FOREIGN_KEY_CHECKS=1;
"

OUTPUT=$(mysql_run -e "$SQL_COMMANDS" 2>&1)
STATUS=$?

if [ $STATUS -ne 0 ]; then
    echo "------------------------------------------------------------------"
    echo "ERRO DURANTE A LIMPEZA — ROLLBACK AUTOMÁTICO (nada foi deletado):"
    echo "$OUTPUT"
    echo "Backup preservado em: $BACKUP_FILE"
    exit 1
else
    echo "------------------------------------------------------------------"
    echo "SUCESSO! A limpeza completa foi realizada para todos os usuários listados."
    echo "Backup dos registros removidos: $BACKUP_FILE"
    echo "Para restaurar (se necessário): mysql $DB_NAME < $BACKUP_FILE"
fi

echo
echo "Script finalizado."
exit 0
# --- FIM DO SCRIPT ---
