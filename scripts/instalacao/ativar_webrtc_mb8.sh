#!/bin/bash
# =====================================================================
# Magnus Utilities — ativar_webrtc_mb8.sh
# Versão: 1.0 (10 de novembro de 2026)
# Função: Ativar e validar suporte completo a WebRTC / WebPhone (WSS :8089)
#         no Asterisk 20 (PJSIP) do MagnusBilling 8 com SSL Let's Encrypt
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root no MagnusBilling 8 (Asterisk 20 + PJSIP)
#   - Certificado SSL Let's Encrypt emitido em /etc/letsencrypt/live/<DOMINIO>
#
# Uso: bash ativar_webrtc_mb8.sh [dominio]
#
# Idempotência: SIM (pode rodar múltiplas vezes sem duplicar blocos)
# Modifica estado: SIM (/etc/asterisk/keys, http.conf, pjsip.conf, firewall 8089/tcp)
# Requer janela de manutenção: Rápida (reload/restart do Asterisk)
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
command -v asterisk >/dev/null 2>&1 || erro "Asterisk não encontrado neste servidor."

clear
titulo "ATIVAR SUPORTE A WEBRTC / WEBPHONE (WSS :8089) — MAGNUSBILLING 8"

echo ""
info "Na instalação padrão do MagnusBilling 8, o servidor HTTP/WSS interno do Asterisk"
info "(/etc/asterisk/http.conf) vem desativado e a porta 8089/TCP não responde ao WebPhone."
echo ""
info "Este utilitário realiza automaticamente:"
echo "    1. Exportação dos certificados SSL Let's Encrypt para /etc/asterisk/keys"
echo "    2. Ativação do servidor HTTPS/WSS do Asterisk na porta 8089 (/etc/asterisk/http.conf)"
echo "    3. Configuração do transporte [transport-wss] no PJSIP (/etc/asterisk/pjsip.conf)"
echo "    4. Liberação da porta 8089/TCP no Firewall (firewalld e iptables)"
echo "    5. Carregamento dos módulos WebSocket e validação do status HTTPS/WSS"
echo ""

# ---------------------------------------------------------------------
# Diagnóstico Rápido do Estado Atual
# ---------------------------------------------------------------------
titulo "DIAGNÓSTICO ATUAL DO WEBRTC NO ASTERISK"

HTTP_STATUS=$(asterisk -rx "http show status" 2>/dev/null)
if echo "$HTTP_STATUS" | grep -qiE "HTTPS Server Enabled and Bound to.*:8089"; then
    ok "Servidor HTTPS/WSS do Asterisk: ATIVO na porta 8089"
else
    warn "Servidor HTTPS/WSS do Asterisk: INATIVO na porta 8089"
fi

if grep -q "\[transport-wss\]" /etc/asterisk/pjsip.conf 2>/dev/null; then
    ok "Transporte [transport-wss] em /etc/asterisk/pjsip.conf: PRESENTE"
else
    warn "Transporte [transport-wss] em /etc/asterisk/pjsip.conf: AUSENTE"
fi

if [ -s /etc/asterisk/keys/asterisk.pem ] && [ -s /etc/asterisk/keys/asterisk.key ]; then
    ok "Certificados TLS em /etc/asterisk/keys/: PRESENTES"
else
    warn "Certificados TLS em /etc/asterisk/keys/: AUSENTES"
fi

if declare -f verificar_compatibilidade_mb8 >/dev/null 2>&1; then
    verificar_compatibilidade_mb8
fi
echo ""

# ---------------------------------------------------------------------
# 1. Identificação do Domínio Let's Encrypt
# ---------------------------------------------------------------------
DOMINIO="${1:-}"

if [ -z "$DOMINIO" ]; then
    # Detecta domínios existentes em /etc/letsencrypt/live/
    DOMINIOS_DETECTADOS=()
    if [ -d /etc/letsencrypt/live ]; then
        for d in /etc/letsencrypt/live/*; do
            [ -d "$d" ] || continue
            bname=$(basename "$d")
            [ "$bname" = "README" ] && continue
            if [ -f "$d/fullchain.pem" ] && [ -f "$d/privkey.pem" ]; then
                DOMINIOS_DETECTADOS+=("$bname")
            fi
        done
    fi

    if [ "${#DOMINIOS_DETECTADOS[@]}" -eq 1 ]; then
        DEFAULT_DOM="${DOMINIOS_DETECTADOS[0]}"
        info "Certificado SSL Let's Encrypt detectado automaticamente: ${NEGRITO}${DEFAULT_DOM}${NC}"
        read -p "  Domínio para o WebRTC [${DEFAULT_DOM}]: " INPUT_DOM
        DOMINIO="${INPUT_DOM:-$DEFAULT_DOM}"
    elif [ "${#DOMINIOS_DETECTADOS[@]}" -gt 1 ]; then
        info "Múltiplos certificados SSL encontrados em /etc/letsencrypt/live:"
        idx=1
        for d in "${DOMINIOS_DETECTADOS[@]}"; do
            echo "    $idx) $d"
            idx=$((idx + 1))
        done
        echo ""
        DEFAULT_DOM="${DOMINIOS_DETECTADOS[0]}"
        read -p "  Informe o domínio desejado [${DEFAULT_DOM}]: " INPUT_DOM
        DOMINIO="${INPUT_DOM:-$DEFAULT_DOM}"
    else
        warn "Nenhum certificado Let's Encrypt encontrado em /etc/letsencrypt/live/."
        info "O WebRTC nos navegadores modernos exige certificado SSL válido para conectar em wss://dominio:8089/ws."
        echo ""
        read -p "  Deseja executar o instalador de SSL Let's Encrypt (configurar_ssl_mb8.sh) agora? [S/n]: " RODAR_SSL
        RODAR_SSL=${RODAR_SSL:-S}
        if [[ "$RODAR_SSL" =~ ^[Ss]$ ]] && [ -f "$SCRIPT_DIR/configurar_ssl_mb8.sh" ]; then
            exec bash "$SCRIPT_DIR/configurar_ssl_mb8.sh"
        fi
        read -p "  Ou informe manualmente o domínio em /etc/letsencrypt/live/ (ex: painel.seudominio.com): " DOMINIO
    fi
fi

DOMINIO=$(echo "$DOMINIO" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
[ -z "$DOMINIO" ] && erro "O domínio não pode ficar vazio."

LE_DIR="/etc/letsencrypt/live/${DOMINIO}"
if [ ! -f "${LE_DIR}/fullchain.pem" ] || [ ! -f "${LE_DIR}/privkey.pem" ]; then
    erro "Certificados não encontrados em ${LE_DIR}/. Emita o SSL primeiro pela Opção 6 do menu."
fi

echo ""
confirma "Confirma a ativação do WebRTC (WSS :8089) com o certificado de '${DOMINIO}'?"

# ---------------------------------------------------------------------
# 2. Exportação dos Certificados SSL para o Asterisk + Hook de Renovação
# ---------------------------------------------------------------------
titulo "1/4 — Configurando Certificados SSL no Asterisk (/etc/asterisk/keys)"

mkdir -p /etc/asterisk/keys
cp "${LE_DIR}/fullchain.pem" /etc/asterisk/keys/asterisk.pem
cp "${LE_DIR}/fullchain.pem" /etc/asterisk/keys/asterisk.crt
cp "${LE_DIR}/privkey.pem" /etc/asterisk/keys/asterisk.key
chown -R asterisk:asterisk /etc/asterisk/keys
chmod 750 /etc/asterisk/keys
chmod 600 /etc/asterisk/keys/*
ok "Certificados copiados para /etc/asterisk/keys/asterisk.pem e asterisk.key (asterisk:asterisk, chmod 600)."

# Garante hook de renovação automática do Let's Encrypt para não quebrar após 90 dias
HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
mkdir -p "$HOOK_DIR"
HOOK_FILE="$HOOK_DIR/sync-asterisk-certs.sh"
cat << EOF_HOOK > "$HOOK_FILE"
#!/bin/bash
# Sincronização automática pós-renovação de certificado Let's Encrypt para o Asterisk 20 (WebRTC/WSS)
CERT_DIR="/etc/letsencrypt/live/${DOMINIO}"
AST_KEYS="/etc/asterisk/keys"
if [ -d "\$CERT_DIR" ]; then
    mkdir -p "\$AST_KEYS"
    cp "\$CERT_DIR/fullchain.pem" "\$AST_KEYS/asterisk.pem"
    cp "\$CERT_DIR/fullchain.pem" "\$AST_KEYS/asterisk.crt"
    cp "\$CERT_DIR/privkey.pem" "\$AST_KEYS/asterisk.key"
    chown -R asterisk:asterisk "\$AST_KEYS" 2>/dev/null || true
    chmod 750 "\$AST_KEYS"
    chmod 600 "\$AST_KEYS"/* 2>/dev/null || true
    if command -v asterisk >/dev/null 2>&1 && systemctl is-active asterisk >/dev/null 2>&1; then
        asterisk -rx "module reload http" >/dev/null 2>&1 || asterisk -rx "core reload" >/dev/null 2>&1 || true
    fi
fi
EOF_HOOK
chmod +x "$HOOK_FILE"
ok "Hook de renovação automática configurado em $HOOK_FILE."

# ---------------------------------------------------------------------
# 3. Configuração do Servidor HTTP/WSS no Asterisk (/etc/asterisk/http.conf)
# ---------------------------------------------------------------------
titulo "2/4 — Ativando Servidor HTTP/WSS na Porta 8089 (/etc/asterisk/http.conf)"

if [ -f /etc/asterisk/http.conf ]; then
    cp -p /etc/asterisk/http.conf "/etc/asterisk/http.conf.bak.$(date +%Y%m%d_%H%M%S)"
fi

cat << 'EOF' > /etc/asterisk/http.conf
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
tlsenable=yes
tlsbindaddr=0.0.0.0:8089
tlscertfile=/etc/asterisk/keys/asterisk.pem
tlsprivatekey=/etc/asterisk/keys/asterisk.key
EOF

chown asterisk:asterisk /etc/asterisk/http.conf 2>/dev/null || true
chmod 640 /etc/asterisk/http.conf 2>/dev/null || true
ok "/etc/asterisk/http.conf configurado com TLS/WSS ativo em 0.0.0.0:8089."

# ---------------------------------------------------------------------
# 4. Garantia do Transporte [transport-wss] em /etc/asterisk/pjsip.conf
# ---------------------------------------------------------------------
titulo "3/4 — Garantindo Transporte [transport-wss] no PJSIP"

if [ ! -f /etc/asterisk/pjsip.conf ]; then
    erro "Arquivo /etc/asterisk/pjsip.conf não encontrado."
fi

if ! grep -q "\[transport-wss\]" /etc/asterisk/pjsip.conf; then
    cp -p /etc/asterisk/pjsip.conf "/etc/asterisk/pjsip.conf.bak.$(date +%Y%m%d_%H%M%S)"
    cat << 'EOF' >> /etc/asterisk/pjsip.conf

[transport-wss]
type=transport
protocol=wss
bind=0.0.0.0
EOF
    chown asterisk:asterisk /etc/asterisk/pjsip.conf 2>/dev/null || true
    ok "Bloco [transport-wss] adicionado em /etc/asterisk/pjsip.conf."
else
    ok "Bloco [transport-wss] já existe em /etc/asterisk/pjsip.conf."
fi

# ---------------------------------------------------------------------
# 5. Liberação da Porta 8089/TCP no Firewall + Reinício/Reload do Asterisk
# ---------------------------------------------------------------------
titulo "4/4 — Firewall (8089/TCP) e Ativação dos Módulos no Asterisk"

# Libera no firewalld se estiver ativo
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd --zone=public --add-port=8089/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=public --add-port=8089/tcp >/dev/null 2>&1 || true
    ok "Porta 8089/TCP liberada no firewalld (runtime e permanente)."
fi

# Libera no iptables e salva se /etc/iptables/rules.v4 existir
if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 8089 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 8089 -j ACCEPT
    ok "Porta 8089/TCP garantida na chain INPUT do iptables."
    if [ -f /etc/iptables/rules.v4 ] && ! systemctl is-active firewalld >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        ok "Regras persistidas em /etc/iptables/rules.v4."
    fi
fi

# Remove eventual noload dos módulos websocket em /etc/asterisk/modules.conf
if [ -f /etc/asterisk/modules.conf ]; then
    sed -i -E '/^\s*noload\s*=>?\s*res_http_websocket\.so/d' /etc/asterisk/modules.conf 2>/dev/null || true
    sed -i -E '/^\s*noload\s*=>?\s*res_pjsip_transport_websocket\.so/d' /etc/asterisk/modules.conf 2>/dev/null || true
fi

info "Carregando módulos WebSocket e reiniciando Asterisk..."
asterisk -rx "module load res_http_websocket.so" >/dev/null 2>&1 || true
asterisk -rx "module load res_pjsip_transport_websocket.so" >/dev/null 2>&1 || true

# Verifica se há chamadas ativas antes de dar core restart now
ACTIVE_CALLS=$(asterisk -rx "core show calls" 2>/dev/null | grep -i "active call" | awk '{print $1}')
if [[ "${ACTIVE_CALLS:-0}" =~ ^[0-9]+$ ]] && [ "${ACTIVE_CALLS:-0}" -gt 0 ]; then
    warn "Existem ${ACTIVE_CALLS} chamada(s) ativa(s) neste momento."
    read -p "  Deseja reiniciar o Asterisk agora (core restart now) para aplicar o transporte WSS? [S/n]: " RESP_RESTART
    RESP_RESTART=${RESP_RESTART:-S}
    if [[ "$RESP_RESTART" =~ ^[Ss]$ ]]; then
        asterisk -rx "core restart now" >/dev/null 2>&1 || systemctl restart asterisk
    else
        asterisk -rx "module reload http" >/dev/null 2>&1 || true
        asterisk -rx "pjsip reload" >/dev/null 2>&1 || true
        warn "Módulos recarregados sem derrubar chamadas. Se a porta 8089 ainda não subir, execute 'asterisk -rx \"core restart now\"' após o término das chamadas."
    fi
else
    asterisk -rx "core restart now" >/dev/null 2>&1 || systemctl restart asterisk
fi

sleep 2

# ---------------------------------------------------------------------
# 6. Validação Final (Smoke Test WSS :8089)
# ---------------------------------------------------------------------
titulo "VALIDAÇÃO DO SERVIDOR HTTP/WSS NO ASTERISK"

echo ""
HTTP_OUT=$(asterisk -rx "http show status" 2>/dev/null)
echo "$HTTP_OUT" | sed 's/^/  /'
echo ""

if echo "$HTTP_OUT" | grep -qiE "HTTPS Server Enabled and Bound to.*:8089"; then
    ok "HTTPS/WSS ativo e escutando em 0.0.0.0:8089 com sucesso!"
    echo ""
    echo -e "  ${VERDE}${NEGRITO}✓ WEBRTC / WEBPHONE PRONTO PARA USO!${NC}"
    echo "  • Endpoint WSS:   wss://${DOMINIO}:8089/ws"
    echo "  • Certificado:    /etc/asterisk/keys/asterisk.pem (${DOMINIO})"
    echo "  • Transporte:     [transport-wss] ativo no PJSIP"
    echo ""
else
    warn "O status do servidor HTTPS não confirmou bind na porta 8089. Verifique os logs do Asterisk (/var/log/asterisk/full)."
fi

exit 0

