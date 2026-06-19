#!/bin/bash
# =====================================================================
# Magnus Utilities — configurar_ssl_magnus.sh
# Versão: 1.0 (10 de junho de 2026)
# Função: Instalação automática do SSL Let's Encrypt para o Apache
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#   - Domínio (A record) já apontado para o IP do servidor
#   - Portas 80 e 443 liberadas no firewall
#
# Uso: bash configurar_ssl_magnus.sh
# =====================================================================

set -o pipefail

# Carrega funções comuns (se existir)
if [ -f "/opt/magnus-utils/scripts/lib/common.sh" ]; then
    source "/opt/magnus-utils/scripts/lib/common.sh"
else
    # Fallback se rodar standalone
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
titulo "CONFIGURAÇÃO DE SSL LET'S ENCRYPT (APACHE)"

echo ""
warn "PRÉ-REQUISITO EXTREMAMENTE IMPORTANTE:"
warn "Você já DEVE ter criado um apontamento DNS (Tipo A) no seu provedor de domínio"
warn "apontando a sua URL exata para o IP deste servidor ($(hostname -I | awk '{print $1}'))."
warn "Se o DNS ainda não estiver propagado, o script VAI FALHAR e bloquear tentativas futuras."
echo ""
confirma "Seu domínio já está apontando para o IP deste servidor e as portas 80/443 estão liberadas?"
echo ""

info "Informe a URL (domínio ou subdomínio) que deseja configurar no Magnus."
info "Exemplo: painel.seudominio.com.br"
read -p "  Domínio: " DOMAIN

[ -z "$DOMAIN" ] && erro "Domínio não pode ficar vazio"

read -p "  E-mail do administrador (para renovações do Let's Encrypt): " EMAIL_ADMIN
[ -z "$EMAIL_ADMIN" ] && erro "E-mail não pode ficar vazio"

echo ""
info "Iniciando processo de instalação do SSL para: $DOMAIN"
info "E-mail de notificação: $EMAIL_ADMIN"
echo ""

info "Atualizando pacotes e instalando Certbot..."
apt-get update -y >/dev/null 2>&1
apt-get install -y certbot python3-certbot-apache >/dev/null 2>&1
if [ $? -eq 0 ]; then
    ok "Certbot instalado com sucesso."
else
    erro "Falha ao instalar o Certbot. Verifique sua conexão ou repositórios do apt."
fi

info "Solicitando certificado SSL via Certbot..."
certbot --apache -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL_ADMIN" --redirect

if [ $? -eq 0 ]; then
    echo ""
    ok "Certificado SSL emitido e configurado com sucesso!"
    ok "O Apache foi configurado para forçar o redirecionamento para HTTPS."
    
    info "Reiniciando Apache para aplicar as configurações..."
    systemctl restart apache2
    
    echo ""
    titulo "RESUMO DA INSTALAÇÃO"
    echo -e "  Acesse seu painel agora em: ${VERDE}${NEGRITO}https://$DOMAIN${NC}"
    echo "  O Certbot cuidará da renovação automática (crontab integrado)."
else
    echo ""
    erro "Falha na emissão do certificado. Verifique as mensagens de erro do Certbot acima."
    warn "Causas comuns: DNS não propagado ou porta 80 bloqueada no firewall."
fi

exit 0
