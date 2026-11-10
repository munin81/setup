#!/bin/bash
# =====================================================================
# Magnus Utilities — gerar_csv_cdr.sh
# Versão: 1.0 (16 de julho de 2026)
# Função: Gerar relatório de CDR em CSV por usuário e período
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root (para salvar o CSV em /root e ler credenciais)
#   - Magnus 7.x + MariaDB acessível
#
# Uso: bash gerar_csv_cdr.sh
#
# Idempotência: SIM (apenas leitura)
# Modifica estado: NÃO
# Requer janela de manutenção: NÃO
# =====================================================================

set -o pipefail

# Cores e funções padronizadas
VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'

ok()    { echo -e "  ${VERDE}✓${NC} $1"; }
info()  { echo -e "  ${AZUL}➜${NC} $1"; }
warn()  { echo -e "  ${AMARELO}⚠${NC} $1"; }
erro()  { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }

echo "------------------------------------------------------------------"
echo "Script de Geração de Relatório de CDR (CSV) (v1.0)"
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
  DB_HOST="127.0.0.1"
  DB_NAME="mbilling"
else
  read -p "  Usuário do banco: " DB_USER
  read -sp "  Senha do banco: " DB_PASS
  echo ""
  DB_HOST="127.0.0.1"
  DB_NAME="mbilling"
fi

# Executa mysql sem expor a senha em ps aux (MYSQL_PWD via env)
mysql_run() {
  MYSQL_PWD="$DB_PASS" mysql --user="$DB_USER" -h "$DB_HOST" -D "$DB_NAME" "$@"
}

# Testa conexão antes de prosseguir
mysql_run -e "SELECT 1;" >/dev/null 2>&1 || { erro "Não foi possível conectar ao banco. Verifique credenciais."; }
ok "Conexão com o banco de dados estabelecida."

# --- ETAPA 1: Coleta de Dados ---
titulo "Filtros do Relatório"

read -p "  ID do Usuário (ex: 1): " ID_USER
read -p "  Data de Início (AAAA-MM-DD): " START_DATE
read -p "  Data Final (AAAA-MM-DD): " END_DATE

if [ -z "$ID_USER" ] || [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    erro "ID, Data de Início e Data Final são obrigatórios. Saindo."
fi

# Valida formato numérico do ID
if ! [[ "$ID_USER" =~ ^[0-9]+$ ]]; then
    erro "O ID do usuário deve ser um número inteiro."
fi

# Valida formato AAAA-MM-DD
for D in "$START_DATE" "$END_DATE"; do
    echo "$D" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
      || { erro "Data '$D' fora do formato AAAA-MM-DD. Saindo."; }
done

# Verifica se o usuário existe
USER_NAME=$(mysql_run -N -e "SELECT username FROM pkg_user WHERE id = '$ID_USER';")
if [ -z "$USER_NAME" ]; then
    erro "Usuário com ID $ID_USER não encontrado no banco de dados."
fi
ok "Usuário encontrado: $USER_NAME"

# --- ETAPA 2: Consulta e Geração do CSV ---
titulo "Geração do CSV"

FILE_NAME="/root/cdr_usuario_${ID_USER}_${START_DATE}_a_${END_DATE}.csv"
info "Buscando chamadas para o usuário ID $ID_USER entre $START_DATE e $END_DATE..."

# Comando SQL para extrair todas as colunas
QUERY="SELECT * FROM pkg_cdr WHERE id_user = '$ID_USER' AND starttime >= '${START_DATE} 00:00:00' AND starttime <= '${END_DATE} 23:59:59';"

# Executando a consulta. O modo batch (-B) retorna colunas separadas por TAB.
# O awk transforma as abas em vírgulas e envolve os campos em aspas duplas, gerando um CSV seguro.
mysql_run -B -e "$QUERY" | awk 'BEGIN {FS="\t"; OFS=","} {
    for (i=1; i<=NF; i++) {
        # Escapa aspas duplas preexistentes
        gsub(/"/, "\"\"", $i)
        # Envolve o campo em aspas
        $i = "\"" $i "\""
    }
    print $0
}' > "$FILE_NAME"

if [ $? -ne 0 ]; then
    erro "Falha ao gerar o arquivo CSV."
fi

# Verifica o tamanho e total de linhas do arquivo
if [ -s "$FILE_NAME" ]; then
    # Conta as linhas ignorando o cabeçalho (-1)
    TOTAL_LINES=$(wc -l < "$FILE_NAME")
    RECORDS=$((TOTAL_LINES - 1))
    
    if [ "$RECORDS" -lt 0 ]; then RECORDS=0; fi

    ok "Arquivo CSV gerado com sucesso!"
    info "Local: $FILE_NAME"
    info "Total de registros: $RECORDS chamadas"
else
    warn "O arquivo foi gerado, mas está vazio. Verifique se existem chamadas no período."
    info "Local: $FILE_NAME"
fi

echo
echo "------------------------------------------------------------------"
echo "Script finalizado."
exit 0
