#!/bin/bash
# =====================================================================
# Magnus Utilities — alterar_senha_web.sh
# Versão: 1.0 (23 de outubro de 2026)
# Função: Alterar a senha de acesso ao painel web do MagnusBilling
#         (usuário root ou qualquer outro operador/cliente)
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#   - MariaDB/MySQL local com o banco mbilling ativo
#
# Uso:
#   bash alterar_senha_web.sh
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
  titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }
fi

[ "$EUID" -ne 0 ] && erro "Execute este script como root."

clear
titulo "ALTERAR SENHA DO PAINEL WEB (MAGNUSBILLING)"

# Conexão com MariaDB (tenta socket local do root primeiro, depois passwordMysql.log)
mysql_cmd() {
  if [ -f /root/passwordMysql.log ]; then
    MYSQL_PWD="$(cat /root/passwordMysql.log | tr -d '[:space:]')" mysql -u root mbilling "$@"
  else
    mysql mbilling "$@" 2>/dev/null || mariadb mbilling "$@"
  fi
}

mysql_cmd -e "SELECT 1;" >/dev/null 2>&1 || erro "Não foi possível conectar ao banco mbilling. Verifique se o MariaDB está ativo."

echo ""
read -p "  Informe o usuário do painel que deseja alterar [root]: " USER_WEB
USER_WEB=${USER_WEB:-root}

# Verifica se o usuário existe no banco
EXISTE=$(mysql_cmd -N -e "SELECT COUNT(*) FROM pkg_user WHERE username = '$USER_WEB';")
if [ "$EXISTE" -eq 0 ]; then
  erro "O usuário '$USER_WEB' não foi encontrado no banco de dados do MagnusBilling."
fi

ok "Usuário '$USER_WEB' localizado no sistema."
echo ""

# Coleta da nova senha de forma oculta
read -sp "  Digite a nova senha para '$USER_WEB': " NOVA_SENHA
echo ""
[ -z "$NOVA_SENHA" ] && erro "A senha não pode ser vazia."

read -sp "  Confirme a nova senha: " CONFIRMA_SENHA
echo ""
[ "$NOVA_SENHA" != "$CONFIRMA_SENHA" ] && erro "As senhas digitadas não coincidem."

# Validação: Magnus não aceita espaços na senha
if [[ "$NOVA_SENHA" =~ [[:space:]] ]]; then
  erro "A senha não pode conter espaços."
fi

# Aplicação no banco usando SHA1 (padrão nativo do MagnusBilling)
mysql_cmd -e "UPDATE pkg_user SET password = SHA1('$NOVA_SENHA') WHERE username = '$USER_WEB';" || erro "Falha ao atualizar a senha no banco de dados."

echo ""
ok "Senha do usuário '$USER_WEB' atualizada com sucesso!"
info "Você já pode acessar o painel web com a nova credencial."
echo ""
exit 0
