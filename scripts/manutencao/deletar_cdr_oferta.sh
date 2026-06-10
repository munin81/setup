#!/bin/bash

# --- Script de Limpeza Automática por Período (v14 - Final Completo) ---

echo "------------------------------------------------------------------"
echo "Script de Deleção de Usuários Inativos por Período"
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

mysql_run() {
  MYSQL_PWD="$DB_PASS" mysql --user="$DB_USER" -h "$DB_HOST" -D "$DB_NAME" "$@"
}

# --- ETAPA 1: Coleta do Período ---
read -p "Digite a DATA DE INÍCIO (formato AAAA-MM-DD): " START_DATE
read -p "Digite a DATA DE FIM (formato AAAA-MM-DD): " END_DATE

if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    echo "Erro: As datas de início e fim são obrigatórias. Saindo."
    exit 1
fi

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

# --- ETAPA 4: Execução da Limpeza em Bloco Único ---
echo "Iniciando a limpeza completa..."

# Bloco de comandos SQL para a exclusão massiva e direta
SQL_COMMANDS="
-- Desativa a verificação de chaves para evitar erros de ordem
SET FOREIGN_KEY_CHECKS=0;

-- Limpa todas as tabelas filhas conhecidas
DELETE FROM pkg_offer_cdr WHERE id_user IN ($USER_IDS);
DELETE FROM pkg_cdr WHERE id_user IN ($USER_IDS);
DELETE FROM pkg_offer_use WHERE id_user IN ($USER_IDS);
DELETE FROM pkg_sip WHERE id_user IN ($USER_IDS); -- <<< ADICIONADO AQUI

-- Deleta os próprios usuários da tabela principal
DELETE FROM pkg_user WHERE id IN ($USER_IDS);

-- Reativa a verificação de chaves para normalizar o sistema
SET FOREIGN_KEY_CHECKS=1;

-- Salva permanentemente todas as alterações
COMMIT;
"

# Executa o bloco de comandos
OUTPUT=$(mysql_run -e "$SQL_COMMANDS" 2>&1)

if [ $? -ne 0 ]; then
    echo "ERRO DURANTE A EXECUÇÃO DA LIMPEZA:"
    echo "$OUTPUT"
    echo "Por segurança, tente reativar as chaves estrangeiras manualmente: SET FOREIGN_KEY_CHECKS=1;"
    exit 1
else
    echo "------------------------------------------------------------------"
    echo "SUCESSO! A limpeza completa foi realizada para todos os usuários listados."
fi

echo
echo "Script finalizado."
exit 0
# --- FIM DO SCRIPT ---