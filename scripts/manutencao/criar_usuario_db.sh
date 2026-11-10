#!/bin/bash
# =====================================================================
# Magnus Utilities — criar_usuario_db.sh
# Versão: 2.0 (23 de outubro de 2026)
# Função: Criar/atualizar usuário MySQL/MariaDB para acesso remoto
#         (ex.: DBeaver), configurar bind-address e liberar firewall
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#   - MariaDB/MySQL local acessível
#
# Uso: bash criar_usuario_db.sh
# =====================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
if [ -f "$SCRIPT_DIR/../lib/common.sh" ]; then
  source "$SCRIPT_DIR/../lib/common.sh"
else
  VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
  AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
  ok()    { echo -e "  ${VERDE}✓${NC} $1"; }
  info()  { echo -e "  ${AZUL}➜${NC} $1"; }
  warn()  { echo -e "  ${AMARELO}⚠${NC} $1"; }
  erro()  { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
  titulo(){ echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }
fi

[ "$EUID" -ne 0 ] && erro "Rode como root"

clear
titulo "CRIAR USUÁRIO DE BANCO (DBeaver / acesso remoto)"

# ---------------------------------------------------------------------
# 1. Conexão root inteligente (Unix Socket automático sem pedir senha)
# ---------------------------------------------------------------------
if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
  mysql_root() { mysql -u root "$@"; }
  ok "Conexão root validada automaticamente via Unix Socket (sem necessidade de senha)."
elif mariadb -u root -e "SELECT 1;" >/dev/null 2>&1; then
  mysql_root() { mariadb -u root "$@"; }
  ok "Conexão root validada automaticamente via Unix Socket (sem necessidade de senha)."
elif [ -f /root/passwordMysql.log ]; then
  ROOT_PW=$(tr -d '[:space:]' < /root/passwordMysql.log)
  mysql_root() { MYSQL_PWD="$ROOT_PW" mysql -u root "$@"; }
  mysql_root -e "SELECT 1;" >/dev/null 2>&1 || erro "Falha ao conectar com senha de /root/passwordMysql.log"
  ok "Senha root lida automaticamente de /root/passwordMysql.log"
else
  read -sp "  Senha root do MariaDB/MySQL: " ROOT_PW; echo ""
  mysql_root() { MYSQL_PWD="$ROOT_PW" mysql -u root "$@"; }
  mysql_root -e "SELECT 1;" >/dev/null 2>&1 || erro "Não consegui conectar como root (senha incorreta?)"
  ok "Conexão root OK"
fi

# ---------------------------------------------------------------------
# 2. Coleta de parâmetros
# ---------------------------------------------------------------------
titulo "Parâmetros do novo usuário"

read -p "  Nome do usuário [dbeaver]: " DBU
DBU=${DBU:-dbeaver}
echo "$DBU" | grep -qE '^[A-Za-z0-9_]+$' || erro "Use apenas letras, números e _ no nome"

read -p "  IP de origem (de onde o DBeaver conecta, ex: 1.2.3.4): " DBIP
[ -z "$DBIP" ] && erro "IP de origem é obrigatório"
if [ "$DBIP" = "%" ]; then
  warn "IP '%' libera de QUALQUER lugar da internet — altamente arriscado!"
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

echo "$DBPASS" | grep -qE '^[A-Za-z0-9@#%._+-]+$' \
  || erro "Senha contém caractere não permitido. Use apenas: A-Z a-z 0-9 @ # % . _ + -"

# Escopo do acesso
echo ""
echo "  Escopo do acesso:"
echo "    [1] TODOS os bancos (*.*) — acesso completo com GRANT (DBeaver admin)"
echo "    [2] Apenas o banco mbilling"
read -p "  Escolha [1]: " ESC; ESC=${ESC:-1}
case "$ESC" in
  1) GRANT_SCOPE="*.*"; GRANT_EXTRA="WITH GRANT OPTION" ;;
  2) GRANT_SCOPE="mbilling.*"; GRANT_EXTRA="" ;;
  *) erro "Opção inválida" ;;
esac

# ---------------------------------------------------------------------
# 3. Resumo e confirmação
# ---------------------------------------------------------------------
titulo "RESUMO"
echo "  Usuário:    $DBU@$DBIP"
echo "  Privilégio: ALL PRIVILEGES ON $GRANT_SCOPE ${GRANT_EXTRA:-(sem GRANT OPTION)}"
echo "  Senha:      (oculta — não exibida nem gravada em disco)"
echo ""
read -p "  Confirma a criação e liberação de acesso? [s/N]: " RESP
[[ "$RESP" =~ ^[Ss]$ ]] || erro "Cancelado pelo usuário"

# ---------------------------------------------------------------------
# 4. Execução SQL
# ---------------------------------------------------------------------
titulo "1. Aplicando permissões no MariaDB"
mysql_root 2>/dev/null <<SQL
CREATE USER IF NOT EXISTS '$DBU'@'$DBIP' IDENTIFIED BY '$DBPASS';
ALTER USER '$DBU'@'$DBIP' IDENTIFIED BY '$DBPASS';
GRANT ALL PRIVILEGES ON $GRANT_SCOPE TO '$DBU'@'$DBIP' $GRANT_EXTRA;
FLUSH PRIVILEGES;
SQL
STATUS=$?

DBPASS=""; DBPASS2=""

[ $STATUS -ne 0 ] && erro "Falha ao criar o usuário no MariaDB."

EXISTE=$(mysql_root -N -e "SELECT CONCAT(User,'@',Host) FROM mysql.user WHERE User='$DBU' AND Host='$DBIP';" 2>/dev/null)
[ -n "$EXISTE" ] && ok "Usuário $EXISTE criado no MariaDB." || erro "Usuário não localizado após criação."

# ---------------------------------------------------------------------
# 5. Configurar bind-address (permitir que o MariaDB escute na rede)
# ---------------------------------------------------------------------
titulo "2. Verificando escuta de rede do MariaDB (bind-address)"

CNF_FILES=(
  /etc/mysql/mariadb.conf.d/50-server.cnf
  /etc/mysql/my.cnf
  /etc/mysql/mariadb.cnf
)

ALTEROU_BIND=0
for F in "${CNF_FILES[@]}"; do
  if [ -f "$F" ]; then
    if grep -qE "^bind-address\s*=\s*127\.0\.0\.1" "$F"; then
      info "Alterando bind-address de 127.0.0.1 para 0.0.0.0 em $(basename "$F")..."
      sed -i 's/^bind-address\s*=\s*127\.0\.0\.1/bind-address = 0.0.0.0/' "$F"
      ALTEROU_BIND=1
    fi
  fi
done

if [ $ALTEROU_BIND -eq 1 ]; then
  info "Reiniciando MariaDB para aplicar novo bind-address..."
  systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true
  ok "MariaDB reiniciado e escutando conexões externas."
else
  ok "bind-address já configurado para conexões externas."
fi

# ---------------------------------------------------------------------
# 6. Liberar firewall na porta 3306 especificamente para o IP informado
# ---------------------------------------------------------------------
titulo "3. Liberando porta 3306 no firewall para $DBIP"

if systemctl is-active firewalld >/dev/null 2>&1; then
  info "firewalld detectado — adicionando rich-rule para o IP $DBIP..."
  firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"$DBIP\" port port=\"3306\" protocol=\"tcp\" accept" >/dev/null 2>&1
  firewall-cmd --reload >/dev/null 2>&1
  ok "Porta 3306/tcp liberada no firewalld exclusivamente para $DBIP."
elif command -v iptables >/dev/null 2>&1; then
  info "iptables detectado — liberando porta 3306 para $DBIP..."
  iptables -C INPUT -p tcp --dport 3306 -s "$DBIP" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport 3306 -s "$DBIP" -j ACCEPT
  ok "Porta 3306/tcp liberada no iptables para $DBIP."
else
  warn "Nenhum firewall local ativo (firewalld/iptables) detectado."
fi

# ---------------------------------------------------------------------
# Conclusão e instruções de uso
# ---------------------------------------------------------------------
titulo "CONCLUÍDO COM SUCESSO"
echo ""
echo -e "  ${VERDE}${NEGRITO}✓ $DBU@$DBIP liberado e pronto para conectar!${NC}"
echo ""
echo -e "${NEGRITO}COMO CONFIGURAR O DBEAVER:${NC}"
echo ""
echo -e "  ${AZUL}Opção A — Conexão Direta:${NC}"
echo "    • Host:    $(hostname -I | awk '{print $1}')"
echo "    • Porta:   3306"
echo "    • Banco:   mbilling"
echo "    • Usuário: $DBU"
echo "    • Senha:   (a que você definiu)"
echo ""
echo -e "  ${AZUL}Opção B — Túnel SSH (Ainda mais seguro — não precisa de porta 3306 aberta):${NC}"
echo "    • Aba Principal do DBeaver:"
echo "        Host = localhost | Porta = 3306 | Usuário = $DBU | Senha = (a sua senha)"
echo "    • Aba 'SSH' do DBeaver:"
echo "        Marque 'Usar Túnel SSH'"
echo "        Host = $(hostname -I | awk '{print $1}')"
echo "        Porta = 22 (ou a sua porta SSH)"
echo "        Usuário = root"
echo "        Método de autenticação = Senha ou Chave privada"
echo ""
echo -e "${NEGRITO}Para REMOVER o acesso deste usuário depois:${NC}"
echo "  mysql -e \"DROP USER '$DBU'@'$DBIP'; FLUSH PRIVILEGES;\""
if systemctl is-active firewalld >/dev/null 2>&1; then
  echo "  firewall-cmd --permanent --remove-rich-rule=\"rule family=\\\"ipv4\\\" source address=\\\"$DBIP\\\" port port=\\\"3306\\\" protocol=\\\"tcp\\\" accept\" && firewall-cmd --reload"
fi
echo ""
exit 0
