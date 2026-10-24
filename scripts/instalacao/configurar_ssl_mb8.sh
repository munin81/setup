#!/bin/bash
# =====================================================================
# Magnus Utilities — configurar_ssl_mb8.sh
# Versão: 1.0 (24 de outubro de 2026)
# Função: Instalação e configuração de SSL Let's Encrypt para MagnusBilling 8
#         (Apache 2.4 + Debian 12 + integração Asterisk 20 WebRTC/PJSIP)
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root no MagnusBilling 8 (Debian 12)
#   - Domínio (Registro A) já apontado para o IP público deste servidor
#   - Portas 80 e 443 liberadas no firewall
#
# Uso: bash configurar_ssl_mb8.sh
# =====================================================================

set -o pipefail

# Carrega biblioteca compartilhada de formatação e cores
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="$SCRIPT_DIR/../lib/common.sh"
if [ -f "$COMMON_LIB" ]; then
    source "$COMMON_LIB"
elif [ -f "/opt/magnus-utils/scripts/lib/common.sh" ]; then
    source "/opt/magnus-utils/scripts/lib/common.sh"
else
    VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'; AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
    ok() { echo -e "  ${VERDE}✓${NC} $1"; }
    info() { echo -e "  ${AZUL}➜${NC} $1"; }
    warn() { echo -e "  ${AMARELO}⚠${NC} $1"; }
    erro() { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
    titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }
    confirma() {
        read -p "  $1 [s/N]: " RESP
        [[ "$RESP" =~ ^[Ss]$ ]] || erro "Operação cancelada pelo usuário."
    }
fi

[ "$EUID" -ne 0 ] && erro "Este script deve ser executado como root."
command -v apache2ctl >/dev/null 2>&1 || erro "Apache2 não encontrado. Verifique a instalação do servidor web."

clear
titulo "CONFIGURAÇÃO DE SSL LET'S ENCRYPT — MAGNUSBILLING 8"

echo ""
info "Este utilitário realiza a emissão de certificado SSL gratuito para o MagnusBilling 8:"
echo "    • Configuração automática de VirtualHost e redirecionamento HTTPS no Apache"
echo "    • Prevenção de falhas de renovação (liberação permanente de ACME Challenge)"
echo "    • Sincronização de certificados para o Asterisk 20 (suporte a WebRTC / WSS)"
echo "    • Ativação do systemd timer para renovação automática perpétua"
echo ""

# ---------------------------------------------------------------------
# 1. Coleta e Validação de Parâmetros
# ---------------------------------------------------------------------
read -p "  Informe o domínio ou subdomínio (ex: painel.seudominio.com): " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
[ -z "$DOMAIN" ] && erro "O domínio não pode ficar vazio."

read -p "  Informe o e-mail para avisos do Let's Encrypt: " EMAIL_ADMIN
EMAIL_ADMIN=$(echo "$EMAIL_ADMIN" | tr -d ' ')
[ -z "$EMAIL_ADMIN" ] && erro "O e-mail do administrador não pode ficar vazio."

# ---------------------------------------------------------------------
# 2. Verificação Prévia de Apontamento DNS
# ---------------------------------------------------------------------
info "Verificando resolução de DNS para o domínio $DOMAIN..."

SERVER_PUBLIC_IP=$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || curl -s4 --max-time 5 https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
RESOLVED_IP=$(getent ahosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)

if [ -n "$RESOLVED_IP" ]; then
    if [ "$RESOLVED_IP" = "$SERVER_PUBLIC_IP" ]; then
        ok "DNS validado com sucesso: $DOMAIN aponta para este servidor ($RESOLVED_IP)."
    else
        warn "Divergência de IP detectada:"
        warn "  IP resolvido para $DOMAIN: $RESOLVED_IP"
        warn "  IP público deste servidor: $SERVER_PUBLIC_IP"
        warn "Se o DNS ainda não propagou, a emissão do certificado falhará."
        echo ""
        confirma "Deseja continuar mesmo assim?"
    fi
else
    warn "Não foi possível resolver o domínio '$DOMAIN' via DNS local."
    warn "Certifique-se de que o Registro A foi criado no seu provedor de domínio."
    echo ""
    confirma "Deseja continuar mesmo assim?"
fi

# ---------------------------------------------------------------------
# 3. Preparação do Apache (Módulos e VirtualHost Base)
# ---------------------------------------------------------------------
titulo "1. Preparação do Apache 2.4"

info "Habilitando módulos essenciais do Apache (ssl, rewrite, headers)..."
a2enmod ssl rewrite headers >/dev/null 2>&1
ok "Módulos do Apache habilitados."

DEFAULT_CONF="/etc/apache2/sites-available/000-default.conf"
if [ -f "$DEFAULT_CONF" ]; then
    info "Ajustando ServerName em $DEFAULT_CONF para identificação precisa do Certbot..."
    cp -p "$DEFAULT_CONF" "${DEFAULT_CONF}.bak.ssl"
    
    # Adiciona ou atualiza ServerName e ServerAdmin no VirtualHost :80
    if grep -qE "^\s*ServerName\s+" "$DEFAULT_CONF"; then
        sed -i -r "s|^\s*ServerName\s+.*|    ServerName $DOMAIN|g" "$DEFAULT_CONF"
    else
        sed -i "/<VirtualHost \*:80>/a \    ServerName $DOMAIN" "$DEFAULT_CONF"
    fi

    if grep -qE "^\s*ServerAdmin\s+" "$DEFAULT_CONF"; then
        sed -i -r "s|^\s*ServerAdmin\s+.*|    ServerAdmin $EMAIL_ADMIN|g" "$DEFAULT_CONF"
    else
        sed -i "/<VirtualHost \*:80>/a \    ServerAdmin $EMAIL_ADMIN" "$DEFAULT_CONF"
    fi
    ok "VirtualHost HTTP pré-configurado."
fi

# Garantir exceção do ACME challenge para não conflitar com blindagens de IP
ACME_CONF="/etc/apache2/conf-available/letsencrypt-acme.conf"
cat << 'EOF_ACME' > "$ACME_CONF"
<Location "/.well-known/acme-challenge">
    Require all granted
</Location>
EOF_ACME
a2enconf letsencrypt-acme >/dev/null 2>&1
ok "Configuração de bypass ACME ativada para renovação contínua."

# Reiniciar Apache para carregar módulos e confs
systemctl restart apache2 || erro "Falha ao reiniciar o Apache após ajustes prévios."

# ---------------------------------------------------------------------
# 4. Instalação do Certbot e Emissão do Certificado
# ---------------------------------------------------------------------
titulo "2. Emissão do Certificado via Certbot"

info "Instalando/atualizando Certbot e plugin Apache..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y certbot python3-certbot-apache >/dev/null 2>&1
ok "Certbot pronto."

info "Solicitando certificado SSL para $DOMAIN..."
certbot --apache \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$EMAIL_ADMIN" \
    --redirect

CERTBOT_STATUS=$?

if [ $CERTBOT_STATUS -ne 0 ]; then
    echo ""
    erro "A emissão do certificado falhou (código de erro: $CERTBOT_STATUS). Verifique mensagens do Certbot acima."
fi

ok "Certificado SSL emitido e vinculado ao Apache com sucesso!"

# ---------------------------------------------------------------------
# 5. Integração com Asterisk 20 (WebRTC / PJSIP WSS)
# ---------------------------------------------------------------------
titulo "3. Integração de Certificados com Asterisk 20"

LE_LIVE_DIR="/etc/letsencrypt/live/$DOMAIN"
AST_KEYS_DIR="/etc/asterisk/keys"

if [ -d "$LE_LIVE_DIR" ]; then
    info "Exportando chaves criptográficas para o Asterisk ($AST_KEYS_DIR)..."
    mkdir -p "$AST_KEYS_DIR"
    
    cp "$LE_LIVE_DIR/fullchain.pem" "$AST_KEYS_DIR/asterisk.crt"
    cp "$LE_LIVE_DIR/privkey.pem" "$AST_KEYS_DIR/asterisk.key"
    cat "$LE_LIVE_DIR/privkey.pem" "$LE_LIVE_DIR/fullchain.pem" > "$AST_KEYS_DIR/asterisk.pem"
    
    chown -R asterisk:asterisk "$AST_KEYS_DIR" 2>/dev/null || true
    chmod 0750 "$AST_KEYS_DIR"
    chmod 0640 "$AST_KEYS_DIR"/* 2>/dev/null || true
    ok "Certificados integrados para Asterisk 20 (WebRTC / WSS)."

    # Hook de renovação automática do Certbot
    HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
    mkdir -p "$HOOK_DIR"
    HOOK_FILE="$HOOK_DIR/sync-asterisk-certs.sh"
    
    cat << EOF_HOOK > "$HOOK_FILE"
#!/bin/bash
# Sincronização automática pós-renovação de certificado para o Asterisk 20
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
AST_KEYS="/etc/asterisk/keys"
if [ -d "\$CERT_DIR" ]; then
    mkdir -p "\$AST_KEYS"
    cp "\$CERT_DIR/fullchain.pem" "\$AST_KEYS/asterisk.crt"
    cp "\$CERT_DIR/privkey.pem" "\$AST_KEYS/asterisk.key"
    cat "\$CERT_DIR/privkey.pem" "\$CERT_DIR/fullchain.pem" > "\$AST_KEYS/asterisk.pem"
    chown -R asterisk:asterisk "\$AST_KEYS" 2>/dev/null || true
    chmod 0750 "\$AST_KEYS"
    chmod 0640 "\$AST_KEYS"/* 2>/dev/null || true
    if command -v asterisk >/dev/null 2>&1 && systemctl is-active asterisk >/dev/null 2>&1; then
        asterisk -rx "core reload" >/dev/null 2>&1 || true
    fi
fi
EOF_HOOK
    chmod +x "$HOOK_FILE"
    ok "Hook de renovação automática para Asterisk instalado em $HOOK_FILE."
fi

# ---------------------------------------------------------------------
# 6. Ativação do Timer de Renovação Automática do Systemd
# ---------------------------------------------------------------------
info "Garantindo timer do systemd para renovações periódicas..."
systemctl enable certbot.timer >/dev/null 2>&1 || true
systemctl start certbot.timer >/dev/null 2>&1 || true
ok "Timer certbot.timer ativo."

# Reiniciar Apache com configuração final
info "Reiniciando servidor web Apache..."
systemctl restart apache2
ok "Apache 2.4 reiniciado."

# ---------------------------------------------------------------------
# 7. Resumo e Validação Final
# ---------------------------------------------------------------------
echo ""
titulo "CONFIGURAÇÃO DE SSL CONCLUÍDA COM SUCESSO"
echo ""
echo -e "  ${VERDE}${NEGRITO}✓ CERTIFICADO ATIVO E VINCULADO AO APACHE E ASTERISK 20${NC}"
echo ""
echo "  Domínio configurado:  https://$DOMAIN"
echo "  E-mail do Certbot:    $EMAIL_ADMIN"
echo "  Redirecionamento:     HTTP (porta 80) ➔ HTTPS (porta 443) permanente"
echo "  Chaves do Asterisk:   $AST_KEYS_DIR (suporte a WebRTC / WSS pronto)"
echo ""
echo -e "${NEGRITO}TESTE DE ACESSO:${NC}"
echo "  Acesse no seu navegador: https://$DOMAIN"
echo "  (ou https://$DOMAIN/mbilling se a URL ainda não tiver sido limpa)"
echo ""
exit 0
