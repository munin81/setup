#!/bin/bash
echo "--- AUDITORIA DE SEGURANÇA ATIVA (SÓ LEITURA) ---"

# 1. Validação de SSL e Domínio
echo "[-] Verificando Certificado SSL:"
certbot certificates | grep -E "Domains:|Expiry Date:|Path:" || echo "[!] ALERTA: Domínio brasil.telsemfio.com.br não encontrado!"

# 2. Auditoria de Usuários do MariaDB
# Verifica se existem acessos que NÃO são os autorizados (n8n, suporte local e localhosts)
echo "[-] Analisando permissões de Banco de Dados (MariaDB)..."
# Lista usuários root e voxcorp fora do padrão de segurança definido
mysql -u root -p"$(cat /root/passwordMysql.log)" -e "
SELECT User, Host, 'ACESSO NÃO RECONHECIDO' as Status 
FROM mysql.user 
WHERE (User='root' AND Host NOT IN ('localhost', '127.0.0.1', '186.194.49.134'))
OR (User='voxcorp' AND Host NOT IN ('localhost', '127.0.0.1', '186.194.49.140', '186.194.49.134'));"

# 3. Auditoria de Acessos SSH Ativos
echo "[-] Verificando origem das conexões SSH atuais..."
who | awk '{print $1, $5}' | sed 's/[()]//g' | while read user ip; do
    if [ "$ip" != "186.194.49.134" ] && [ "$ip" != "" ]; then
        echo "[!] ATENÇÃO: Usuário $user conectado via SSH a partir de IP não padrão: $ip"
    else
        echo "[OK] Conexão SSH legítima: $user ($ip)"
    fi
done

# 4. Status de Configuração Apache
echo "[-] Verificando VirtualHosts Ativos (SSL):"
apache2ctl -S | grep "port 443" || echo "[!] ALERTA: HTTPS não configurado corretamente no Apache."

# 5. Verificação de Porta Aberta (MySQL)
echo "[-] Verificando se a porta 3306 aceita conexões externas (Bind Address):"
grep "bind-address" /etc/mysql/mariadb.conf.d/50-server.cnf

echo "--- FIM DA AVERIGUAÇÃO ---"
