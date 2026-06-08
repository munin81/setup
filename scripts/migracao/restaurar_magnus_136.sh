#!/bin/bash

# 1. PEGA AS SENHAS DO AMBIENTE ATUAL
SENHA_ROOT_SQL=$(cat /root/passwordMysql.log)
# Captura a senha que o Asterisk local espera usar
SENHA_LOCAL_MB=$(grep "dbpass" /etc/asterisk/res_config_mysql.conf | cut -d'=' -f2 | tr -d ' ')

echo "--- INICIANDO RESTAURAÇÃO FIEL (VOXCORP) ---"
read -p "Arquivo de backup (.tgz): " BACKUP

# 2. LIMPEZA E EXTRAÇÃO
DIR_TEMP="/root/restore_temp"
rm -rf $DIR_TEMP && mkdir -p $DIR_TEMP
tar zxf "/root/$BACKUP" -C $DIR_TEMP

# 3. IMPORTAÇÃO DO BANCO (Exatamente como está no arquivo)
echo "Recriando banco mbilling e importando SQL..."
mysql -u root -p"$SENHA_ROOT_SQL" -e "DROP DATABASE IF EXISTS mbilling; CREATE DATABASE mbilling;"
ARQUIVO_SQL=$(find $DIR_TEMP -type f -name "*.sql" | head -n 1)
mysql -u root -p"$SENHA_ROOT_SQL" --force mbilling < "$ARQUIVO_SQL"

# 4. AJUSTE DE PERMISSÃO (Fundamental para o Debian aceitar a conexão local)
# Aqui apenas garantimos que o usuário mbillingUser responda pela senha que está no seu .conf
echo "Ajustando permissões de acesso..."
mysql -u root -p"$SENHA_ROOT_SQL" -e "
    GRANT ALL PRIVILEGES ON mbilling.* TO 'mbillingUser'@'localhost' IDENTIFIED BY '$SENHA_LOCAL_MB';
    GRANT ALL PRIVILEGES ON mbilling.* TO 'mbillingUser'@'127.0.0.1' IDENTIFIED BY '$SENHA_LOCAL_MB';
    FLUSH PRIVILEGES;"

# 5. SINCRONIZAÇÃO DE ARQUIVOS (Asterisk)
echo "Sincronizando arquivos do Asterisk e sons..."
[ -d "$DIR_TEMP/etc/asterisk" ] && cp -r $DIR_TEMP/etc/asterisk/* /etc/asterisk/
[ -d "$DIR_TEMP/var/lib/asterisk/sounds" ] && cp -rp $DIR_TEMP/var/lib/asterisk/sounds/* /var/lib/asterisk/sounds/
chown -R asterisk:asterisk /etc/asterisk/ /var/lib/asterisk/sounds/

# 6. ATUALIZAÇÃO OFICIAL DO MAGNUS (Comando que você indicou)
echo "Executando comando de atualização oficial..."
chown -R www-data:www-data /var/www/html/mbilling
chmod +x /var/www/html/mbilling/protected/commands/update.sh
/var/www/html/mbilling/protected/commands/update.sh

# 7. LIMPEZA DE CACHE DE RUNTIME
rm -rf /var/www/html/mbilling/protected/runtime/*

echo "--- RESTAURAÇÃO CONCLUÍDA ---"