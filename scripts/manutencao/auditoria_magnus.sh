#!/bin/bash
# =====================================================================
# Magnus Utilities — auditoria_magnus.sh
# Versão: 2.0 (19 de junho de 2026)
# Função: Auditoria de segurança read-only (SSL, usuários DB, SSH, Apache)
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#
# Uso: bash auditoria_magnus.sh
#
# Idempotência: SIM
# Modifica estado: NÃO (apenas leitura)
# Requer janela de manutenção: NÃO
#
# Mudanças v2.0 (junho 2026):
#   [1] Senha root via MYSQL_PWD (nunca em ps aux — antes usava -p"...")
#   [2] Cabeçalho padrão Magnus Utilities
# =====================================================================

echo "--- AUDITORIA DE SEGURANÇA ATIVA (SÓ LEITURA) ---"

# Lê a senha root do MySQL sem expô-la na linha de comando (MYSQL_PWD via env)
ROOT_PW=$(cat /root/passwordMysql.log 2>/dev/null | tr -d '[:space:]')
mysql_root() { MYSQL_PWD="$ROOT_PW" mysql -u root "$@"; }

# 1. Validação de SSL e Domínio
echo "[-] Verificando Certificados SSL Locais (Certbot):"
certbot certificates 2>/dev/null | grep -E "Domains:|Expiry Date:|Path:" || echo "[!] ALERTA: Nenhum domínio válido detectado pelo Certbot!"

# 2. Auditoria de Usuários do MariaDB
echo "[-] Analisando permissões de Banco de Dados (MariaDB)..."
echo "    Buscando usuários com acesso externo configurado:"
if [ -z "$ROOT_PW" ]; then
    echo "[!] Não foi possível checar o DB (senha em /root/passwordMysql.log ausente?)"
else
    mysql_root -e "
SELECT User, Host FROM mysql.user
WHERE Host NOT IN ('localhost', '127.0.0.1');" 2>/dev/null || echo "[!] Falha ao consultar mysql.user (senha incorreta?)"
fi

# 3. Auditoria de Acessos SSH Ativos
echo "[-] Verificando origem das conexões SSH atuais..."
who | awk '{print $1, $5}' | sed 's/[()]//g' | while read user ip; do
    if [ "$ip" != "" ]; then
        echo "    Usuário logado: $user, Origem: $ip"
    fi
done

# 4. Status de Configuração Apache
echo "[-] Verificando VirtualHosts Ativos (SSL):"
apache2ctl -S 2>/dev/null | grep "port 443" || echo "[!] ALERTA: HTTPS não configurado corretamente no Apache."

# 5. Verificação de Porta Aberta (MySQL)
echo "[-] Verificando se a porta 3306 aceita conexões externas (Bind Address):"
grep "bind-address" /etc/mysql/mariadb.conf.d/50-server.cnf 2>/dev/null || echo "[!] bind-address não encontrado em 50-server.cnf"

echo "--- FIM DA AVERIGUAÇÃO ---"
