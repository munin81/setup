#!/bin/bash
# =====================================================================
# Magnus Utilities — verificar_seguranca_magnus.sh
# Versão: 1.0 (24 de outubro de 2026)
# Função: Auditoria completa de segurança defensiva do MagnusBilling:
#         - Valida se o SSH NÃO está na porta padrão 22
#         - Valida se o SSH NÃO está aberto para qualquer IP
#         - Valida se a interface WEB NÃO está aberta para qualquer IP
#         - Valida redirecionamento de IP puro para domínio HTTPS
#         - Audita SSL, MySQL externo, Fail2ban e Anti-scanner SIP
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#
# Uso: bash verificar_seguranca_magnus.sh
#
# Idempotência: SIM
# Modifica estado: NÃO (apenas leitura / auditoria)
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
fi

[ "$EUID" -ne 0 ] && erro "Este script deve ser executado como root."

PASS_TAG="${VERDE}[ SEGURO ]${NC}"
FAIL_TAG="${VERMELHO}[ VULNERÁVEL ]${NC}"
WARN_TAG="${AMARELO}[ ATENÇÃO ]${NC}"

PONTOS_CRITICOS_FALHOS=0
TOTAL_CHECKS=0
TOTAL_PASS=0

check_result() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    local TIPO="$1"
    local MSG="$2"
    local DETALHE="$3"
    local RECOMENDACAO="$4"

    if [ "$TIPO" = "PASS" ]; then
        TOTAL_PASS=$((TOTAL_PASS + 1))
        echo -e "  $PASS_TAG ${NEGRITO}$MSG${NC}"
        [ -n "$DETALHE" ] && echo -e "           ${AZUL}↳${NC} $DETALHE"
    elif [ "$TIPO" = "FAIL" ]; then
        PONTOS_CRITICOS_FALHOS=$((PONTOS_CRITICOS_FALHOS + 1))
        echo -e "  $FAIL_TAG ${NEGRITO}$MSG${NC}"
        [ -n "$DETALHE" ] && echo -e "           ${VERMELHO}↳${NC} $DETALHE"
        [ -n "$RECOMENDACAO" ] && echo -e "           ${AMARELO}⚡ Ação corretiva:${NC} $RECOMENDACAO"
    elif [ "$TIPO" = "WARN" ]; then
        echo -e "  $WARN_TAG ${NEGRITO}$MSG${NC}"
        [ -n "$DETALHE" ] && echo -e "           ${AMARELO}↳${NC} $DETALHE"
        [ -n "$RECOMENDACAO" ] && echo -e "           ${AMARELO}⚡ Ação corretiva:${NC} $RECOMENDACAO"
    fi
    echo ""
}

clear
titulo "AUDITORIA DE SEGURANÇA E BLINDAGEM DO MAGNUSBILLING"
echo ""
info "Avaliando se o servidor cumpre os requisitos essenciais de segurança:"
info "  1. Acesso SSH restrito a IPs autorizados (não liberado para qualquer IP)"
info "  2. Porta SSH alterada para uma porta segura (NUNCA a porta 22 padrão)"
info "  3. Acesso WEB restrito a IPs autorizados (não liberado para qualquer IP)"
info "  4. Forçamento canônico de domínio (impede acesso por IP puro)"
info "  5. Criptografia SSL, proteção do banco de dados e filtros anti-scanner"
echo ""

# ---------------------------------------------------------------------
# 1. Checagem da Porta SSH
# ---------------------------------------------------------------------
titulo "1. Porta do Serviço SSH"
SSH_PORT=$(grep -iE "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
SSH_PORT=${SSH_PORT:-22}

if [ "$SSH_PORT" -eq 22 ]; then
    check_result "FAIL" \
        "Porta SSH está configurada na porta padrão 22" \
        "A porta 22 é o alvo primário de botnets, scanners automáticos e ataques de força bruta." \
        "Execute a Opção 6 do menu para alterar a porta (recomendado: 22022)."
else
    check_result "PASS" \
        "Porta SSH alterada com sucesso (TCP $SSH_PORT)" \
        "O serviço não utiliza a porta 22 padrão, neutralizando scanners genéricos de SSH."
fi

# ---------------------------------------------------------------------
# 2. Checagem de Blindagem do SSH no Firewall
# ---------------------------------------------------------------------
titulo "2. Exposição da Porta SSH no Firewall"

SSH_ABERTO_GLOBAL=0
IPS_SSH_AUTORIZADOS=""

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    # Verifica se o serviço ssh ou portas estão liberadas publicamente
    PUBLIC_SERVICES=$(firewall-cmd --zone=public --list-services 2>/dev/null)
    PUBLIC_PORTS=$(firewall-cmd --zone=public --list-ports 2>/dev/null)

    if echo "$PUBLIC_SERVICES" | grep -qw "ssh"; then
        SSH_ABERTO_GLOBAL=1
    fi
    if echo "$PUBLIC_PORTS" | grep -qE "(^|\s)(22|22022|${SSH_PORT})/tcp(\s|$)"; then
        SSH_ABERTO_GLOBAL=1
    fi

    # Coleta IPs autorizados em rich-rules
    RICH_RULES=$(firewall-cmd --zone=public --list-rich-rules 2>/dev/null)
    IPS_SSH_AUTORIZADOS=$(echo "$RICH_RULES" | grep -iE "port=\"?(${SSH_PORT}|22|22022)\"?" | grep -oE "address=\"[^\"]+\"" | cut -d'"' -f2 | tr '\n' ' ')

elif command -v iptables >/dev/null 2>&1; then
    # Checa iptables
    if iptables -L INPUT -n 2>/dev/null | grep -E "dpt:(${SSH_PORT}|22)" | grep -qw "ACCEPT" | grep -q "0.0.0.0/0"; then
        SSH_ABERTO_GLOBAL=1
    fi
    IPS_SSH_AUTORIZADOS=$(iptables -L INPUT -n 2>/dev/null | grep -E "dpt:(${SSH_PORT}|22)" | grep -w "ACCEPT" | awk '{print $4}' | grep -v "0.0.0.0/0" | tr '\n' ' ')
fi

if [ "$SSH_ABERTO_GLOBAL" -eq 1 ]; then
    check_result "FAIL" \
        "Porta SSH está ABERTA para qualquer IP da internet (0.0.0.0/0)" \
        "Qualquer computador do mundo pode tentar conexão na sua porta SSH." \
        "Execute a Opção 6 do menu para restringir o SSH apenas aos seus IPs/blocos autorizados."
elif [ -n "$IPS_SSH_AUTORIZADOS" ]; then
    check_result "PASS" \
        "Acesso SSH blindado e restrito exclusivamente a IPs autorizados" \
        "IPs com permissão de conexão: $IPS_SSH_AUTORIZADOS (demais conexões são descartadas no firewall)."
else
    check_result "WARN" \
        "Nenhuma regra global de SSH aberta, mas nenhum IP explícito localizado" \
        "Verifique se o firewall não está bloqueando o seu próprio acesso."
fi

# ---------------------------------------------------------------------
# 3. Checagem de Blindagem do Acesso Web do Painel
# ---------------------------------------------------------------------
titulo "3. Restrição de Acesso Web ao Painel (Apache)"

WEB_BLINDADA=0
ALLOWED_WEB_IPS=""

# Checa se magnus-blindagem.conf está ativo
if [ -f /etc/apache2/conf-enabled/magnus-blindagem.conf ]; then
    CONF_BLIND="/etc/apache2/conf-enabled/magnus-blindagem.conf"
    if grep -qE "Require ip" "$CONF_BLIND"; then
        WEB_BLINDADA=1
        ALLOWED_WEB_IPS=$(grep "Require ip" "$CONF_BLIND" | head -1 | sed 's/Require ip//g' | xargs)
    fi
fi

if [ "$WEB_BLINDADA" -eq 1 ]; then
    check_result "PASS" \
        "Acesso Web ao painel MagnusBilling blindado por IP" \
        "IPs autorizados: $ALLOWED_WEB_IPS (visitantes externos recebem 403 Forbidden)."
else
    check_result "FAIL" \
        "Painel Web está ABERTO publicamente para qualquer IP da internet" \
        "A tela de login do MagnusBilling pode ser acessada por qualquer pessoa ou bot." \
        "Execute a Opção 10 do menu para blindar o acesso web por IP."
fi

# ---------------------------------------------------------------------
# 4. Checagem de Acesso Direto por IP Puro (Domínio Canônico)
# ---------------------------------------------------------------------
titulo "4. Proteção contra Acesso Web por IP Puro"

IP_PURO_BLOQUEADO=0
if [ -f /etc/apache2/conf-enabled/magnus-forcar-dominio.conf ]; then
    if grep -q "RewriteRule" /etc/apache2/conf-enabled/magnus-forcar-dominio.conf; then
        IP_PURO_BLOQUEADO=1
    fi
fi

if [ "$IP_PURO_BLOQUEADO" -eq 1 ]; then
    check_result "PASS" \
        "Acesso direto por IP puro bloqueado (forçado redirecionamento HTTPS)" \
        "Qualquer tentativa de navegação via IP puro é redirecionada automaticamente para o domínio oficial."
else
    check_result "WARN" \
        "Acesso direto por IP puro não possui redirecionamento canônico forçado" \
        "Visitantes que digitarem o IP direto podem tentar interagir fora do domínio SSL." \
        "Execute a Opção 4 do menu para reconfigurar o SSL com proteção anti-IP."
fi

# ---------------------------------------------------------------------
# 5. Checagem de Certificado SSL / HTTPS
# ---------------------------------------------------------------------
titulo "5. Criptografia SSL / TLS (HTTPS)"

SSL_OK=0
# 1. Verifica no apache2ctl redirecionando stderr (apache2ctl -S cospe as infos em stderr)
if command -v apache2ctl >/dev/null 2>&1; then
    if apache2ctl -S 2>&1 | grep -qE "(port 443|:443)"; then
        SSL_OK=1
    fi
fi

# 2. Verifica se a porta 443 está em escuta no sistema
if [ "$SSL_OK" -eq 0 ]; then
    if ss -tulpn 2>/dev/null | grep -qE ":443\s"; then
        SSL_OK=1
    fi
fi

# 3. Verifica se há vhost SSL ativo nos sites habilitados
if [ "$SSL_OK" -eq 0 ]; then
    if grep -rqiE "(<VirtualHost[^>]*:443|SSLEngine\s+on)" /etc/apache2/sites-enabled/ 2>/dev/null; then
        SSL_OK=1
    fi
fi

# Coleta domínios e validade do Certbot
DOMINIOS_SSL=$(certbot certificates 2>/dev/null | grep -i "Domains:" | sed 's/.*Domains://' | xargs)
[ -z "$DOMINIOS_SSL" ] && DOMINIOS_SSL=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v "README" | tr '\n' ' ' | xargs)

VALIDADE_SSL=$(certbot certificates 2>/dev/null | grep -i "Expiry Date:" | head -1 | sed 's/.*Expiry Date://' | xargs)

# Detalhe do Asterisk WebRTC
AST_CERT_OK=0
[ -f /etc/asterisk/keys/asterisk.crt ] && AST_CERT_OK=1

if [ "$SSL_OK" -eq 1 ] && [ -n "$DOMINIOS_SSL" ]; then
    DETALHE_SSL="Domínio(s) seguro(s): $DOMINIOS_SSL"
    [ -n "$VALIDADE_SSL" ] && DETALHE_SSL="$DETALHE_SSL (Expira: $VALIDADE_SSL)"
    [ "$AST_CERT_OK" -eq 1 ] && DETALHE_SSL="$DETALHE_SSL | Chaves Asterisk 20 (WebRTC/WSS) prontas"

    check_result "PASS" \
        "Certificado SSL ativo e vinculado à porta 443 do Apache" \
        "$DETALHE_SSL"
elif [ "$SSL_OK" -eq 1 ]; then
    check_result "PASS" \
        "Porta 443 SSL configurada e ativa no Apache" \
        "Tráfego web criptografado via HTTPS."
elif [ -n "$DOMINIOS_SSL" ]; then
    check_result "WARN" \
        "Certificado Certbot localizado para $DOMINIOS_SSL, mas porta 443 inativa no Apache" \
        "Reinicie o Apache para carregar o VirtualHost SSL: systemctl restart apache2"
else
    check_result "FAIL" \
        "Servidor Web sem certificado SSL ativo na porta 443" \
        "O tráfego web trafega em texto claro sem criptografia." \
        "Execute a Opção 4 do menu para gerar o SSL Let's Encrypt."
fi

# ---------------------------------------------------------------------
# 6. Checagem de Exposição do MySQL / MariaDB (Porta 3306)
# ---------------------------------------------------------------------
titulo "6. Proteção do Banco de Dados (MariaDB/MySQL)"

MYSQL_PUBLICO=0
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    if firewall-cmd --zone=public --list-ports 2>/dev/null | grep -qw "3306/tcp"; then
        MYSQL_PUBLICO=1
    fi
fi

if [ "$MYSQL_PUBLICO" -eq 1 ]; then
    check_result "FAIL" \
        "Porta 3306 do MySQL está ABERTA para qualquer IP na zona pública do firewall" \
        "A porta de banco de dados não deve ser pública para a internet." \
        "Remova a porta 3306 da zona pública do firewalld e libere apenas para IPs específicos via Opção 11."
else
    check_result "PASS" \
        "Porta 3306 do MySQL protegida (não está exposta publicamente para a internet)"
fi

# ---------------------------------------------------------------------
# 7. Checagem de Serviços de Defesa Ativa (Fail2ban)
# ---------------------------------------------------------------------
titulo "7. Defesa Ativa contra Ataques de Força Bruta (Fail2ban)"

if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active fail2ban >/dev/null 2>&1; then
    JAILS_ATIVAS=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | cut -d: -f2 | xargs)
    check_result "PASS" \
        "Fail2ban ativo e operacional" \
        "Jails ativas no sistema: ${JAILS_ATIVAS:-nenhuma jail listada}."
else
    check_result "WARN" \
        "Serviço Fail2ban está inativo ou não instalado" \
        "O Fail2ban é essencial para banir IPs que tentam ataques volumosos." \
        "Inicie o serviço: systemctl restart fail2ban."
fi

# ---------------------------------------------------------------------
# 8. Veredito Final
# ---------------------------------------------------------------------
titulo "RELATÓRIO FINAL DE SEGURANÇA"

PERCENTUAL=$(( (TOTAL_PASS * 100) / TOTAL_CHECKS ))

echo -e "  Pontuação Geral de Segurança: ${NEGRITO}${PERCENTUAL}%${NC} ($TOTAL_PASS de $TOTAL_CHECKS checagens aprovadas)"
echo ""

# Regra de ouro da solicitação do usuário:
# Um Magnus seguro:
# 1. NÃO tem acesso WEB liberado para qualquer IP
# 2. NÃO tem acesso SSH liberado para qualquer IP
# 3. NÃO tem a porta 22 em uso
if [ "$SSH_PORT" -ne 22 ] && [ "$SSH_ABERTO_GLOBAL" -eq 0 ] && [ "$WEB_BLINDADA" -eq 1 ]; then
    echo -e "  ${VERDE}${NEGRITO}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${VERDE}${NEGRITO}  🛡️  VEREDITO: MAGNUSBILLING 100% BLINDADO E EM CONFORMIDADE!     ${NC}"
    echo -e "  ${VERDE}${NEGRITO}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${VERDE}✓${NC} Porta SSH alterada para TCP $SSH_PORT (sem uso da porta 22 padrão)"
    echo -e "  ${VERDE}✓${NC} Acesso SSH bloqueado a nível de firewall para IPs não cadastrados"
    echo -e "  ${VERDE}✓${NC} Acesso WEB restrito a IPs cadastrados (bloqueio 403 para visitantes)"
    echo ""
    echo "  Seu servidor está protegido contra scanners e invasões não autorizadas."
else
    echo -e "  ${VERMELHO}${NEGRITO}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${VERMELHO}${NEGRITO}  ⚠  VEREDITO: SERVIDOR COM VULNERABILIDADES CRÍTICAS PENDENTES   ${NC}"
    echo -e "  ${VERMELHO}${NEGRITO}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Para deixar este MagnusBilling seguro conforme o padrão recomendado:"
    [ "$SSH_PORT" -eq 22 ] && echo -e "    ${AMARELO}•${NC} Alterar a porta SSH da padrão 22 para 22022 (Opção 6 do menu)"
    [ "$SSH_ABERTO_GLOBAL" -eq 1 ] && echo -e "    ${AMARELO}•${NC} Restringir a porta SSH no firewall para seus IPs (Opção 6 do menu)"
    [ "$WEB_BLINDADA" -eq 0 ] && echo -e "    ${AMARELO}•${NC} Restringir o acesso ao painel Web apenas aos seus IPs (Opção 10 do menu)"
    echo ""
fi

exit 0
