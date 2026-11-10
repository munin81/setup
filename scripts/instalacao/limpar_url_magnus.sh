#!/bin/bash
# =====================================================================
# Magnus Utilities — limpar_url_magnus.sh
# Versão: 2.0 (24 de outubro de 2026)
# Função: Alterar o DocumentRoot do Apache para remover o /mbilling da URL
#         no MagnusBilling 8 e 7 (com compatibilidade retroativa e opção de desfazer)
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#   - Apache instalado
#   - MagnusBilling instalado em /var/www/html/mbilling
#
# Uso: bash limpar_url_magnus.sh
#
# Idempotência: SIM
# Modifica estado: SIM (confs do Apache)
# Requer janela de manutenção: NÃO
# =====================================================================

set -o pipefail

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
[ ! -d "/var/www/html/mbilling" ] && erro "Diretório /var/www/html/mbilling não encontrado. O MagnusBilling está instalado?"

clear
titulo "CONFIGURAÇÃO DA URL DO PAINEL — MAGNUSBILLING"

echo ""
info "Este utilitário gerencia o DocumentRoot do Apache:"
echo "    1) [Recomendado] Limpar URL: Painel abre direto na raiz (ex: https://dominio/)"
echo "       * Mantém compatibilidade retroativa (Alias /mbilling continua funcionando)"
echo "    2) Restaurar URL padrão: Painel volta a abrir em /mbilling (ex: https://dominio/mbilling)"
echo "    0) Cancelar e sair"
echo ""
read -p "  Escolha a opção desejada [1]: " OPCAO
OPCAO=${OPCAO:-1}

[ "$OPCAO" = "0" ] && { echo "Cancelado."; exit 0; }

BKP_DIR="/root/apache-url-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BKP_DIR"
cp -rp /etc/apache2/sites-available "$BKP_DIR/" 2>/dev/null
cp -rp /etc/apache2/sites-enabled "$BKP_DIR/" 2>/dev/null
cp -a /etc/apache2/apache2.conf "$BKP_DIR/" 2>/dev/null
ok "Backup das configurações do Apache salvo em $BKP_DIR."

reverter_apache() {
    warn "Restaurando configurações do Apache a partir do backup..."
    cp -rp "$BKP_DIR/sites-available/"* /etc/apache2/sites-available/ 2>/dev/null || true
    cp -a "$BKP_DIR/apache2.conf" /etc/apache2/apache2.conf 2>/dev/null || true
    rm -f /etc/apache2/conf-available/magnus-alias-compat.conf /etc/apache2/conf-enabled/magnus-alias-compat.conf 2>/dev/null || true
    systemctl reload apache2 2>/dev/null || true
}

# ---------------------------------------------------------------------
# Opção 1: Limpar URL (Raiz)
# ---------------------------------------------------------------------
if [ "$OPCAO" = "1" ]; then
    titulo "1. Ajustando DocumentRoot para /var/www/html/mbilling"

    MODIFICADO=0

    # 1. Modifica VirtualHosts HTTP e SSL (incluindo 000-default-le-ssl.conf do MB8)
    for conf in /etc/apache2/sites-available/*.conf /etc/apache2/sites-enabled/*.conf; do
        [ -f "$conf" ] || continue
        # Resolve links simbólicos para evitar alterar o mesmo arquivo duas vezes
        REAL_CONF=$(readlink -f "$conf")
        [ -f "$REAL_CONF" ] || continue

        if grep -qE "DocumentRoot\s+/var/www/html/?(\s|$)" "$REAL_CONF"; then
            sed -i -r 's|(DocumentRoot\s+)/var/www/html/?|\1/var/www/html/mbilling|g' "$REAL_CONF"
            MODIFICADO=1
        fi

        if grep -qE "<Directory\s+/var/www/html/?>" "$REAL_CONF"; then
            sed -i -r 's|(<Directory\s+)/var/www/html/?(>)| \1/var/www/html/mbilling\2|g' "$REAL_CONF"
            MODIFICADO=1
        fi
    done

    # 2. Ajusta apache2.conf se contiver diretiva de diretório
    if grep -qE "<Directory\s+/var/www/html/?>" /etc/apache2/apache2.conf; then
        sed -i -r 's|(<Directory\s+)/var/www/html/?(>)| \1/var/www/html/mbilling\2|g' /etc/apache2/apache2.conf
        MODIFICADO=1
    fi

    # 3. Cria Alias de compatibilidade retroativa para não quebrar links /mbilling
    ALIAS_CONF="/etc/apache2/conf-available/magnus-alias-compat.conf"
    cat << 'EOF_ALIAS' > "$ALIAS_CONF"
# Magnus Utilities — Compatibilidade para acessos legados com /mbilling
Alias /mbilling /var/www/html/mbilling
<Directory /var/www/html/mbilling>
    Options Indexes FollowSymLinks MultiViews
    AllowOverride All
    Require all granted
</Directory>
EOF_ALIAS
    a2enconf magnus-alias-compat >/dev/null 2>&1 || true

    # 4. Habilita mod_rewrite se não estiver ativo
    a2enmod rewrite >/dev/null 2>&1 || true

    # 5. Validação de Sintaxe
    info "Validando sintaxe das alterações do Apache..."
    if ! apache2ctl configtest 2>&1 | grep -qi "Syntax OK"; then
        warn "Erro de sintaxe no Apache após a modificação!"
        reverter_apache
        erro "Alteração cancelada por segurança. Sintaxe do Apache foi restaurada."
    fi

    info "Recarregando Apache 2.4..."
    systemctl reload apache2 || systemctl restart apache2
    echo ""
    ok "Configurações aplicadas com sucesso!"
    echo ""
    echo -e "  ${VERDE}${NEGRITO}✓ URL do painel limpa com sucesso!${NC}"
    echo "  • Acesso Principal: https://seu-dominio/ (abre direto na raiz)"
    echo "  • Acesso Retroativo: https://seu-dominio/mbilling/ (continua funcionando via Alias)"
    echo ""

# ---------------------------------------------------------------------
# Opção 2: Restaurar URL Padrão (/mbilling)
# ---------------------------------------------------------------------
elif [ "$OPCAO" = "2" ]; then
    titulo "1. Restaurando DocumentRoot para /var/www/html"

    for conf in /etc/apache2/sites-available/*.conf /etc/apache2/sites-enabled/*.conf; do
        [ -f "$conf" ] || continue
        REAL_CONF=$(readlink -f "$conf")
        [ -f "$REAL_CONF" ] || continue

        if grep -qE "DocumentRoot\s+/var/www/html/mbilling/?(\s|$)" "$REAL_CONF"; then
            sed -i -r 's|(DocumentRoot\s+)/var/www/html/mbilling/?|\1/var/www/html|g' "$REAL_CONF"
        fi

        if grep -qE "<Directory\s+/var/www/html/mbilling/?>" "$REAL_CONF"; then
            sed -i -r 's|(<Directory\s+)/var/www/html/mbilling/?(>)| \1/var/www/html\2|g' "$REAL_CONF"
        fi
    done

    if grep -qE "<Directory\s+/var/www/html/mbilling/?>" /etc/apache2/apache2.conf; then
        sed -i -r 's|(<Directory\s+)/var/www/html/mbilling/?(>)| \1/var/www/html\2|g' /etc/apache2/apache2.conf
    fi

    # Desativa Alias de compatibilidade
    a2disconf magnus-alias-compat >/dev/null 2>&1 || true
    rm -f /etc/apache2/conf-available/magnus-alias-compat.conf 2>/dev/null || true

    if ! apache2ctl configtest 2>&1 | grep -qi "Syntax OK"; then
        reverter_apache
        erro "Erro de sintaxe ao restaurar. Revertido."
    fi

    systemctl reload apache2 || systemctl restart apache2
    echo ""
    ok "DocumentRoot restaurado para /var/www/html."
    ok "O painel agora responde novamente em https://seu-dominio/mbilling/."
    echo ""
fi

exit 0
