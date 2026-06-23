#!/bin/bash
# =====================================================================
# Magnus Utilities — criar_usuario_db.sh
# Versão: 1.0 (19 de junho de 2026)
# Função: Criar/atualizar usuário MySQL/MariaDB para acesso remoto
#         (ex.: DBeaver) a partir de um IP de origem escolhido, com
#         privilégios definidos pelo operador.
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#   - MariaDB/MySQL local acessível
#
# Uso: bash criar_usuario_db.sh
#
# Idempotência: SIM (CREATE IF NOT EXISTS + ALTER atualiza a senha)
# Modifica estado: SIM (cria/atualiza usuário + grants)
# Requer janela de manutenção: NÃO
#
# SEGURANÇA (regras do projeto):
#   - Senha root via MYSQL_PWD (nunca em ps aux)
#   - Senha do novo usuário lida com read -s (oculta) e enviada por
#     STDIN/heredoc (nunca em -e nem em ps aux)
#   - NADA é gravado em log (nenhuma senha em disco)
#   - Rejeita senha com caracteres que quebram shell/SQL ($ ! ' " \ ` espaço)
# =====================================================================

set -o pipefail

VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
ok()    { echo -e "  ${VERDE}✓${NC} $1"; }
info()  { echo -e "  ${AZUL}➜${NC} $1"; }
warn()  { echo -e "  ${AMARELO}⚠${NC} $1"; }
erro()  { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
titulo(){ echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }

[ "$EUID" -ne 0 ] && erro "Rode como root"
command -v mysql >/dev/null 2>&1 || erro "cliente mysql não encontrado"

clear
titulo "CRIAR USUÁRIO DE BANCO (DBeaver / acesso remoto)"

# ---------------------------------------------------------------------
# Credenciais root (MYSQL_PWD — nunca na linha de comando)
# ---------------------------------------------------------------------
if [ -f /root/passwordMysql.log ]; then
  ROOT_PW=$(tr -d '[:space:]' < /root/passwordMysql.log)
  info "Senha root lida de /root/passwordMysql.log"
else
  read -sp "  Senha root do MySQL: " ROOT_PW; echo ""
fi
mysql_root() { MYSQL_PWD="$ROOT_PW" mysql -u root "$@"; }
mysql_root -e "SELECT 1;" >/dev/null 2>&1 || erro "Não consegui conectar como root (senha incorreta?)"
ok "Conexão root OK"

# ---------------------------------------------------------------------
# Coleta de parâmetros
# ---------------------------------------------------------------------
titulo "Parâmetros do novo usuário"

read -p "  Nome do usuário (ex: dbeaver): " DBU
[ -z "$DBU" ] && erro "Nome do usuário é obrigatório"
echo "$DBU" | grep -qE '^[A-Za-z0-9_]+$' || erro "Use apenas letras, números e _ no nome"

read -p "  IP de origem (de onde o DBeaver conecta, ex: 1.2.3.4): " DBIP
[ -z "$DBIP" ] && erro "IP de origem é obrigatório"
if [ "$DBIP" = "%" ]; then
  warn "IP '%' libera de QUALQUER lugar — altamente inseguro!"
  read -p "  Tem certeza absoluta? digite 'sim': " C; [ "$C" = "sim" ] || erro "Cancelado"
else
  echo "$DBIP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    || erro "IP inválido. Use um IPv4 (ex: 1.2.3.4)"
fi

# Senha — oculta, com confirmação e validação de charset seguro
read -sp "  Senha do novo usuário: " DBPASS; echo ""
[ -z "$DBPASS" ] && erro "Senha é obrigatória"
read -sp "  Confirme a senha:      " DBPASS2; echo ""
[ "$DBPASS" != "$DBPASS2" ] && erro "As senhas não conferem"
# Rejeita caracteres que quebram heredoc/SQL (regra do projeto)
echo "$DBPASS" | grep -qE '^[A-Za-z0-9@#%._+-]+$' \
  || erro "Senha contém caractere não permitido. Use apenas: A-Z a-z 0-9 @ # % . _ + -"

# Escopo do acesso
echo ""
echo "  Escopo do acesso:"
echo "    [1] TODOS os bancos (*.*) — acesso full (padrão p/ DBeaver admin)"
echo "    [2] Apenas o banco mbilling"
read -p "  Escolha [1]: " ESC; ESC=${ESC:-1}
case "$ESC" in
  1) GRANT_SCOPE="*.*"; GRANT_EXTRA="WITH GRANT OPTION" ;;
  2) GRANT_SCOPE="mbilling.*"; GRANT_EXTRA="" ;;
  *) erro "Opção inválida" ;;
esac

# ---------------------------------------------------------------------
# Resumo e confirmação (NUNCA mostra a senha)
# ---------------------------------------------------------------------
titulo "RESUMO"
echo "  Usuário:    $DBU@$DBIP"
echo "  Privilégio: ALL PRIVILEGES ON $GRANT_SCOPE ${GRANT_EXTRA:-(sem GRANT OPTION)}"
echo "  Senha:      (oculta — não será exibida nem gravada)"
echo ""
read -p "  Confirma a criação? [s/N]: " RESP
[[ "$RESP" =~ ^[Ss]$ ]] || erro "Cancelado pelo usuário"

# ---------------------------------------------------------------------
# Execução — SQL via STDIN (heredoc), senha nunca em ps aux
# ---------------------------------------------------------------------
titulo "Aplicando"
mysql_root 2>/dev/null <<SQL
CREATE USER IF NOT EXISTS '$DBU'@'$DBIP' IDENTIFIED BY '$DBPASS';
ALTER USER '$DBU'@'$DBIP' IDENTIFIED BY '$DBPASS';
GRANT ALL PRIVILEGES ON $GRANT_SCOPE TO '$DBU'@'$DBIP' $GRANT_EXTRA;
FLUSH PRIVILEGES;
SQL
STATUS=$?

# Limpa a senha da memória do shell
DBPASS=""; DBPASS2=""

if [ $STATUS -ne 0 ]; then
  erro "Falha ao criar o usuário (veja erros acima)"
fi

# ---------------------------------------------------------------------
# Verificação (mostra só usuário@host, sem hash/senha)
# ---------------------------------------------------------------------
EXISTE=$(mysql_root -N -e "SELECT CONCAT(User,'@',Host) FROM mysql.user WHERE User='$DBU' AND Host='$DBIP';" 2>/dev/null)
[ -n "$EXISTE" ] && ok "Usuário $EXISTE criado/atualizado" || erro "Usuário não encontrado após criação"

titulo "CONCLUÍDO"
echo ""
echo -e "  ${VERDE}${NEGRITO}✓ $DBU@$DBIP pronto para uso${NC}"
echo ""
echo "  No DBeaver: Host = IP deste servidor | Porta = 3306"
echo "              Usuário = $DBU | Senha = (a que você definiu)"
echo ""
warn "SEGURANÇA: a senha NÃO foi gravada em lugar nenhum."
warn "O MySQL pode estar exposto (bind-address 0.0.0.0). Restrinja a porta"
warn "3306 ao IP $DBIP no firewall (opção 6) — ou prefira túnel SSH no DBeaver."
echo ""
echo -e "${NEGRITO}  Para REMOVER este usuário depois:${NC}"
echo "    mysql -u root -p -e \"DROP USER '$DBU'@'$DBIP'; FLUSH PRIVILEGES;\""
echo ""
exit 0
