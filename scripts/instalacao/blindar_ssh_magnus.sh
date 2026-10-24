#!/bin/bash
# =====================================================================
# Magnus Utilities — blindar_ssh_magnus.sh
# Versão: 2.0 (24 de outubro de 2026)
# Função: Restringir o acesso SSH exclusivamente aos IPs cadastrados
#         e permitir alteração segura da porta SSH (ex: 22022)
#         (bloqueia/evita a conexão no firewall para qualquer IP não autorizado)
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root via SSH
#   - Firewalld ou IPtables ativo
#
# Uso: bash blindar_ssh_magnus.sh
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

clear
titulo "BLINDAGEM DE ACESSO SSH (POR IP CADASTRADO E PORTA)"

echo ""
info "Este utilitário bloqueia a porta SSH no firewall para qualquer visitante não cadastrado."
info "Diferente da web (que exibe página de bloqueio), o SSH ${NEGRITO}evita e descarta a conexão${NC},"
info "impedindo scanners de porta, ataques de força bruta e tentativas de autenticação."
echo ""

# ---------------------------------------------------------------------
# 1. Identificar e Configurar Porta SSH
# ---------------------------------------------------------------------
CURRENT_SSH_PORT=$(grep -iE "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}

info "Porta SSH atual detectada no sistema: ${NEGRITO}$CURRENT_SSH_PORT${NC}"
echo ""

read -p "  Deseja alterar a porta SSH do servidor? [s/N]: " QUER_MUDAR_PORTA
if [[ "$QUER_MUDAR_PORTA" =~ ^[Ss]$ ]]; then
    read -p "  Informe a nova porta SSH [22022]: " DESIRED_PORT
    TARGET_SSH_PORT=${DESIRED_PORT:-22022}
    if ! [[ "$TARGET_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$TARGET_SSH_PORT" -lt 1 ] || [ "$TARGET_SSH_PORT" -gt 65535 ]; then
        erro "Porta inválida ('$TARGET_SSH_PORT'). Deve ser um número entre 1 e 65535."
    fi
else
    TARGET_SSH_PORT="$CURRENT_SSH_PORT"
fi

# ---------------------------------------------------------------------
# 2. Coleta dos IPs Autorizados
# ---------------------------------------------------------------------
MY_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
[ -z "$MY_IP" ] && MY_IP="127.0.0.1"

echo ""
info "Seu IP atual conectado neste momento: ${NEGRITO}$MY_IP${NC}"
echo ""

read -p "  IP/Bloco autorizado 1 [$MY_IP]: " B1
B1=${B1:-$MY_IP}
[ -z "$B1" ] && erro "Informe ao menos um IP ou bloco CIDR autorizado."

ALLOWED_IPS="$B1"
while true; do
    read -p "  Outro IP/Bloco autorizado (ENTER para encerrar): " BX
    [ -z "$BX" ] && break
    ALLOWED_IPS="$ALLOWED_IPS $BX"
done

echo ""
titulo "RESUMO DA CONFIGURAÇÃO"
if [ "$TARGET_SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
    echo "  Porta SSH atual:     TCP $CURRENT_SSH_PORT"
    echo "  Nova Porta SSH:      TCP $TARGET_SSH_PORT (será reconfigurada)"
else
    echo "  Porta protegida:     TCP $TARGET_SSH_PORT (inalterada)"
fi
echo "  IPs com permissão:   $ALLOWED_IPS"
echo "  Demais conexões:     Descartadas/bloqueadas no firewall (sem handshake)"
echo ""
confirma "Deseja aplicar a blindagem e configurações agora?"

# ---------------------------------------------------------------------
# 3. Backup de Segurança
# ---------------------------------------------------------------------
titulo "1. Criando backups de segurança"
BKP_DIR="/root/ssh-blindagem-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BKP_DIR"

# Backup do SSH
cp -a /etc/ssh/sshd_config "$BKP_DIR/sshd_config"
[ -d /etc/ssh/sshd_config.d ] && cp -rp /etc/ssh/sshd_config.d "$BKP_DIR/" 2>/dev/null

# Detecta se Debian 12 usa socket activation
SOCKET_WAS_ACTIVE=0
if systemctl is-active ssh.socket >/dev/null 2>&1; then
    SOCKET_WAS_ACTIVE=1
fi

# Backup do Firewall
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    cp -rp /etc/firewalld/zones "$BKP_DIR/" 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
    iptables-save > "$BKP_DIR/iptables.v4"
fi
ok "Backup armazenado em $BKP_DIR"

# Função universal de reversão
reverter_geral() {
    warn "Restaurando configurações anteriores por segurança..."
    if [ -f "$BKP_DIR/sshd_config" ]; then
        cp -a "$BKP_DIR/sshd_config" /etc/ssh/sshd_config
        [ -d "$BKP_DIR/sshd_config.d" ] && cp -rp "$BKP_DIR/sshd_config.d/"* /etc/ssh/sshd_config.d/ 2>/dev/null
        if [ "$SOCKET_WAS_ACTIVE" -eq 1 ]; then
            systemctl disable --now ssh.service >/dev/null 2>&1 || true
            systemctl enable --now ssh.socket >/dev/null 2>&1 || true
            systemctl restart ssh.socket >/dev/null 2>&1 || true
        else
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
        fi
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        cp -rp "$BKP_DIR/zones/"* /etc/firewalld/zones/ 2>/dev/null || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1 && [ -f "$BKP_DIR/iptables.v4" ]; then
        iptables-restore < "$BKP_DIR/iptables.v4"
    fi
    ok "Configurações anteriores restauradas com sucesso."
}

# ---------------------------------------------------------------------
# 4. Aplicação das Regras no Firewall
# ---------------------------------------------------------------------
titulo "2. Aplicando regras no Firewall"

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    info "Firewall ativo: firewalld"

    # Libera a nova porta (e mantém temporariamente a antiga durante o teste)
    for IP_AUTH in $ALLOWED_IPS; do
        info "Liberando TCP $TARGET_SSH_PORT para o IP $IP_AUTH..."
        firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$IP_AUTH\" port port=\"$TARGET_SSH_PORT\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$IP_AUTH\" port port=\"$TARGET_SSH_PORT\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true

        if [ "$TARGET_SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
            firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$IP_AUTH\" port port=\"$CURRENT_SSH_PORT\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
            firewall-cmd --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$IP_AUTH\" port port=\"$CURRENT_SSH_PORT\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
        fi
    done

    # Remove acesso público global das portas SSH
    info "Removendo portas SSH públicas irrestritas da zona pública..."
    firewall-cmd --permanent --zone=public --remove-service=ssh >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=public --remove-port=22/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=public --remove-port=22022/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=public --remove-port="${CURRENT_SSH_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=public --remove-port="${TARGET_SSH_PORT}/tcp" >/dev/null 2>&1 || true

    firewall-cmd --zone=public --remove-service=ssh >/dev/null 2>&1 || true
    firewall-cmd --zone=public --remove-port=22/tcp >/dev/null 2>&1 || true
    firewall-cmd --zone=public --remove-port=22022/tcp >/dev/null 2>&1 || true
    firewall-cmd --zone=public --remove-port="${CURRENT_SSH_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --zone=public --remove-port="${TARGET_SSH_PORT}/tcp" >/dev/null 2>&1 || true

    ok "Regras do Firewalld ativas em runtime e permanentes."

elif command -v iptables >/dev/null 2>&1; then
    info "Firewall ativo: iptables"

    iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT

    for IP_AUTH in $ALLOWED_IPS; do
        iptables -I INPUT 2 -p tcp --dport "$TARGET_SSH_PORT" -s "$IP_AUTH" -j ACCEPT
        if [ "$TARGET_SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
            iptables -I INPUT 3 -p tcp --dport "$CURRENT_SSH_PORT" -s "$IP_AUTH" -j ACCEPT
        fi
    done

    iptables -A INPUT -p tcp --dport "$TARGET_SSH_PORT" -j DROP
    [ "$TARGET_SSH_PORT" != "$CURRENT_SSH_PORT" ] && iptables -A INPUT -p tcp --dport "$CURRENT_SSH_PORT" -j DROP

    ok "Regras do iptables aplicadas."
fi

# ---------------------------------------------------------------------
# 5. Aplicação da Mudança de Porta no SSH (se solicitado)
# ---------------------------------------------------------------------
if [ "$TARGET_SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
    titulo "3. Reconfigurando serviço SSH para a porta $TARGET_SSH_PORT"

    # No Debian 12 com socket activation, desativa o ssh.socket para respeitar a porta do sshd_config
    if [ "$SOCKET_WAS_ACTIVE" -eq 1 ]; then
        info "Ajustando systemd Debian 12: desativando ssh.socket e ativando ssh.service..."
        systemctl disable --now ssh.socket >/dev/null 2>&1 || true
        systemctl enable --now ssh.service >/dev/null 2>&1 || true
    fi

    # Atualiza /etc/ssh/sshd_config
    info "Atualizando /etc/ssh/sshd_config com 'Port $TARGET_SSH_PORT'..."
    if grep -qiE "^[#]?Port\s+" /etc/ssh/sshd_config; then
        sed -i -E "s/^[#]?[Pp]ort\s+[0-9]+/Port $TARGET_SSH_PORT/" /etc/ssh/sshd_config
    else
        echo "Port $TARGET_SSH_PORT" >> /etc/ssh/sshd_config
    fi

    # Atualiza eventuais arquivos drop-in em sshd_config.d
    if [ -d /etc/ssh/sshd_config.d ]; then
        for CONF_D in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$CONF_D" ] || continue
            if grep -qiE "^[#]?Port\s+" "$CONF_D"; then
                sed -i -E "s/^[#]?[Pp]ort\s+[0-9]+/Port $TARGET_SSH_PORT/" "$CONF_D"
            fi
        done
    fi

    # Valida sintaxe antes de reiniciar
    if ! sshd -t >/dev/null 2>&1; then
        warn "Erro de sintaxe detectado no sshd_config!"
        reverter_geral
        erro "Configuração inválida do SSH. Revertido para segurança."
    fi

    # Reinicia o serviço SSH
    info "Reiniciando o serviço SSH..."
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
        ok "Serviço SSH reiniciado na porta $TARGET_SSH_PORT."
    else
        warn "Falha ao reiniciar o serviço SSH!"
        reverter_geral
        erro "Não foi possível reiniciar o SSH. Revertido."
    fi
fi

# ---------------------------------------------------------------------
# 6. Deadman Switch — Proteção Anti-Bloqueio Acidental (5 minutos)
# ---------------------------------------------------------------------
echo ""
titulo "TESTE DE CONECTIVIDADE (PROTEÇÃO ANTI-BLOQUEIO)"
warn "A blindagem está ativa agora em runtime."
if [ "$TARGET_SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
    echo -e "  ${AMARELO}⚠ ATENÇÃO:${NC} A porta SSH agora é ${NEGRITO}TCP $TARGET_SSH_PORT${NC}."
    echo -e "  Abra uma ${NEGRITO}NOVA JANELA DE TERMINAL${NC} (sem fechar esta) e teste:"
    echo -e "      ${VERDE}${NEGRITO}ssh -p $TARGET_SSH_PORT root@<IP_DO_SERVIDOR>${NC}"
else
    echo -e "  Abra uma ${NEGRITO}NOVA JANELA DE TERMINAL${NC} e confirme que o acesso do IP autorizado continua funcionando."
fi
echo ""

read -t 300 -p "  Você confirma que o acesso SSH continua funcionando normalmente? [s/N] (300s / 5 min timeout): " CONFIRMA_OK || true

if [[ ! "$CONFIRMA_OK" =~ ^[Ss]$ ]]; then
    echo ""
    warn "Tempo esgotado (5 minutos) ou resposta negativa recebida!"
    reverter_geral
    erro "A blindagem foi revertida por segurança. Você não perdeu o acesso."
fi

# Limpeza da regra provisória da porta antiga pós-confirmação
if [ "$TARGET_SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
    info "Removendo regra temporária da porta antiga ($CURRENT_SSH_PORT)..."
    for IP_AUTH in $ALLOWED_IPS; do
        if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
            firewall-cmd --permanent --zone=public --remove-rich-rule="rule family=\"ipv4\" source address=\"$IP_AUTH\" port port=\"$CURRENT_SSH_PORT\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-rich-rule="rule family=\"ipv4\" source address=\"$IP_AUTH\" port port=\"$CURRENT_SSH_PORT\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
        fi
    done
fi

# ---------------------------------------------------------------------
# 7. Conclusão
# ---------------------------------------------------------------------
echo ""
titulo "BLINDAGEM SSH CONCLUÍDA COM SUCESSO"
echo ""
echo -e "  ${VERDE}${NEGRITO}✓ Porta SSH TCP $TARGET_SSH_PORT restrita exclusivamente aos IPs autorizados${NC}"
echo ""
echo "  Porta ativa:    TCP $TARGET_SSH_PORT"
echo "  IPs liberados:  $ALLOWED_IPS"
echo "  Demais IPs:     Conexão evitada (bloqueada/dropada no firewall)"
echo "  Backup salvo:   $BKP_DIR"
echo ""
exit 0
