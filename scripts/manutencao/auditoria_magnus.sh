#!/bin/bash
echo "--- AUDITORIA DE SEGURANÇA ATIVA (SÓ LEITURA) ---"

# 1. Validação de SSL e Domínio
echo "[-] Verificando Certificados SSL Locais (Certbot):"
certbot certificates | grep -E "Domains:|Expiry Date:|Path:" || echo "[!] ALERTA: Nenhum domínio válido detectado pelo Certbot!"

# 2. Auditoria de Usuários do MariaDB
echo "[-] Analisando permissões de Banco de Dados (MariaDB)..."
echo "    Buscando usuários com acesso externo configurado:"
mysql -u root -p"$(cat /root/passwordMysql.log 2>/dev/null)" -e "
SELECT User, Host FROM mysql.user 
WHERE Host NOT IN ('localhost', '127.0.0.1');" 2>/dev/null || echo "[!] Não foi possível checar o DB (Senha em passwordMysql.log ausente?)"

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
grep "bind-address" /etc/mysql/mariadb.conf.d/50-server.cnf

echo "--- FIM DA AVERIGUAÇÃO ---"
