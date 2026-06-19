#!/bin/bash
# =====================================================================
# Magnus Utilities — limpar_url_magnus.sh
# Versão: 1.0 (10 de junho de 2026)
# Função: Alterar o DocumentRoot do Apache para remover o /mbilling da URL
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#   - Apache instalado
#   - MagnusBilling instalado em /var/www/html/mbilling
# =====================================================================

set -o pipefail

# Carrega funções comuns (se existir)
if [ -f "/opt/magnus-utils/scripts/lib/common.sh" ]; then
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

[ "$EUID" -ne 0 ] && erro "Rode como root"

clear
titulo "LIMPEZA DE URL (REMOVER /MBILLING)"

echo ""
info "Este script vai alterar as configurações do servidor Apache para"
info "apontar diretamente para a pasta interna do MagnusBilling."
warn "Sua URL deixará de ser 'http://IP/mbilling' e passará a ser apenas 'http://IP/'."
echo ""
confirma "Deseja aplicar esta alteração no Apache agora?"
echo ""

[ ! -d "/var/www/html/mbilling" ] && erro "Pasta /var/www/html/mbilling não encontrada. O Magnus está instalado?"

info "Buscando e alterando DocumentRoot nas configurações do Apache..."

MODIFICADO=0

# Modifica todos os arquivos de configuração do site no Apache
for conf in /etc/apache2/sites-available/*.conf; do
    if [ -f "$conf" ]; then
        # Altera "DocumentRoot /var/www/html" (com ou sem barra no final) para o mbilling
        if grep -qE "DocumentRoot\s+/var/www/html/?(\s|$)" "$conf"; then
            sed -i -r 's|(DocumentRoot\s+)/var/www/html/?|\1/var/www/html/mbilling|g' "$conf"
            MODIFICADO=1
        fi
        
        # Altera blocos <Directory /var/www/html>
        if grep -qE "<Directory\s+/var/www/html/?>" "$conf"; then
            sed -i -r 's|(<Directory\s+)/var/www/html/?(>)| \1/var/www/html/mbilling\2|g' "$conf"
            MODIFICADO=1
        fi
    fi
done

# Altera o arquivo principal do Apache também, caso a permissão Directory esteja lá
if grep -qE "<Directory\s+/var/www/html/?>" /etc/apache2/apache2.conf; then
    sed -i -r 's|(<Directory\s+)/var/www/html/?(>)| \1/var/www/html/mbilling\2|g' /etc/apache2/apache2.conf
    MODIFICADO=1
fi

if [ "$MODIFICADO" -eq 1 ]; then
    info "Reiniciando serviço Apache2..."
    systemctl restart apache2
    echo ""
    ok "Configurações alteradas com sucesso!"
    ok "A URL do seu painel agora está limpa (respondendo na raiz)."
else
    echo ""
    warn "Nenhuma configuração de /var/www/html padrão foi encontrada."
    warn "Pode ser que o seu servidor já esteja com a URL limpa ou use um diretório customizado."
fi

exit 0
