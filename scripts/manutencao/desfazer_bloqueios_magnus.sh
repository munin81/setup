#!/bin/bash
# =====================================================================
# Magnus Utilities — desfazer_bloqueios_magnus.sh
# Versão: 1.0 (24 de outubro de 2026)
# Função: Reverter bloqueios de acesso WEB e SSH, restaurando a
#         acessibilidade pública das portas ou da interface web
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#   - Firewalld ou IPtables ativo
#   - Apache2
#
# Uso: bash desfazer_bloqueios_magnus.sh
#
# Idempotência: SIM (pode ser executado repetidamente com segurança)
# Modifica estado: SIM (regras do firewall e confs do Apache)
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

clear
titulo "DESFAZER BLOQUEIOS DE ACESSO WEB E SSH — MAGNUSBILLING"

echo ""
info "Este utilitário remove as restrições por IP e reabre os acessos."
warn "ATENÇÃO: Reabrir portas e painel para qualquer IP da internet remove a blindagem defensiva."
echo ""
echo "  Escolha a operação desejada:"
echo "    1) Desfazer TODOS os bloqueios (Reabrir Web e SSH globalmente)"
echo "    2) Desfazer apenas bloqueio WEB (Liberar painel para qualquer IP)"
echo "    3) Desfazer apenas bloqueio SSH (Liberar porta SSH para qualquer IP)"
echo "    0) Cancelar e sair"
echo ""
read -p "  Opção [1]: " OPCAO
OPCAO=${OPCAO:-1}

[ "$OPCAO" = "0" ] && { echo "Cancelado."; exit 0; }

# ---------------------------------------------------------------------
# Função: Desfazer Bloqueio WEB
# ---------------------------------------------------------------------
desfazer_web() {
    titulo "1. Desfazendo Bloqueio Web do Painel Apache"

    if [ -f /etc/apache2/conf-enabled/magnus-blindagem.conf ] || [ -f /etc/apache2/conf-available/magnus-blindagem.conf ]; then
        info "Desativando configuração 'magnus-blindagem'..."
        a2disconf magnus-blindagem >/dev/null 2>&1 || true
        rm -f /etc/apache2/conf-available/magnus-blindagem.conf 2>/dev/null || true
    fi

    # Limpeza de eventuais regras residuais em sites-enabled
    for VH in /etc/apache2/sites-available/*.conf /etc/apache2/sites-enabled/*.conf; do
        [ -f "$VH" ] || continue
        if grep -q "acesso_negado" "$VH"; then
            sed -i '/<Location \/acesso_negado.html>/,/<\/Location>/d' "$VH" 2>/dev/null || true
            sed -i '\#Alias /acesso_negado.html#d' "$VH" 2>/dev/null || true
            sed -i '\#ErrorDocument 403 /acesso_negado.html#d' "$VH" 2>/dev/null || true
        fi
    done

    # Validação e recarregamento do Apache
    if apache2ctl configtest 2>&1 | grep -qi "Syntax OK"; then
        systemctl reload apache2 2>/dev/null || systemctl restart apache2 2>/dev/null
        ok "Acesso Web liberado: o painel MagnusBilling agora pode ser acessado por qualquer IP."
    else
        warn "Falha na validação de sintaxe do Apache após remoção. Verifique os arquivos em /etc/apache2/."
    fi
}

# ---------------------------------------------------------------------
# Função: Desfazer Bloqueio SSH
# ---------------------------------------------------------------------
desfazer_ssh() {
    titulo "2. Desfazendo Restrição da Porta SSH no Firewall"

    SSH_PORT=$(grep -iE "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    SSH_PORT=${SSH_PORT:-22}
    info "Porta SSH atualmente ativa no sistema: TCP $SSH_PORT"

    echo ""
    read -p "  Deseja também retornar a porta SSH para a padrão (22)? [s/N]: " VOLTAR_22
    if [[ "$VOLTAR_22" =~ ^[Ss]$ ]] && [ "$SSH_PORT" != "22" ]; then
        info "Reconfigurando /etc/ssh/sshd_config para Port 22..."
        sed -i -E "s/^[#]?[Pp]ort\s+[0-9]+/Port 22/" /etc/ssh/sshd_config

        if [ -d /etc/ssh/sshd_config.d ]; then
            for CONF_D in /etc/ssh/sshd_config.d/*.conf; do
                [ -f "$CONF_D" ] || continue
                sed -i -E "s/^[#]?[Pp]ort\s+[0-9]+/Port 22/" "$CONF_D" 2>/dev/null || true
            done
        fi

        if sshd -t >/dev/null 2>&1; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
            ok "Porta SSH reconfigurada para 22."
            SSH_PORT=22
        else
            warn "Erro de sintaxe no sshd_config ao tentar voltar para 22. Mantendo porta $SSH_PORT."
        fi
    fi

    # Aplicação no Firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        info "Firewall ativo detectado: firewalld"

        # 1. Remover todas as rich-rules restritivas de SSH
        info "Removendo rich-rules de SSH restritas por IP..."
        firewall-cmd --zone=public --list-rich-rules 2>/dev/null | while read -r RULE; do
            if echo "$RULE" | grep -qiE "port=\"?(22|22022|[0-9]+)\"?.*protocol=\"?tcp\"?"; then
                firewall-cmd --permanent --zone=public --remove-rich-rule="$RULE" >/dev/null 2>&1 || true
                firewall-cmd --zone=public --remove-rich-rule="$RULE" >/dev/null 2>&1 || true
            fi
        done

        # 2. Reabrir serviço e portas públicas
        info "Reabrindo portas SSH na zona pública (global 0.0.0.0/0)..."
        firewall-cmd --permanent --zone=public --add-service=ssh >/dev/null 2>&1 || true
        firewall-cmd --permanent --zone=public --add-port=22/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --zone=public --add-port="${SSH_PORT}/tcp" >/dev/null 2>&1 || true

        firewall-cmd --zone=public --add-service=ssh >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port=22/tcp >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port="${SSH_PORT}/tcp" >/dev/null 2>&1 || true

        ok "Firewalld atualizado: SSH agora aceita conexões de qualquer IP na porta TCP $SSH_PORT."

    # Aplicação no IPtables
    elif command -v iptables >/dev/null 2>&1; then
        info "Firewall ativo detectado: iptables"

        # Remove regras DROP na porta SSH
        iptables -D INPUT -p tcp --dport "$SSH_PORT" -j DROP 2>/dev/null || true
        iptables -D INPUT -p tcp --dport 22 -j DROP 2>/dev/null || true
        iptables -D INPUT -p tcp --dport 22022 -j DROP 2>/dev/null || true

        # Insere permissão global no topo
        iptables -I INPUT 1 -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || true
        [ "$SSH_PORT" != "22" ] && iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT 2>/dev/null || true

        ok "IPtables atualizado: SSH liberado para qualquer IP."
    fi
}

# ---------------------------------------------------------------------
# Execução conforme a opção escolhida
# ---------------------------------------------------------------------
case $OPCAO in
    1)
        confirma "Tem certeza que deseja DESFAZER TODOS os bloqueios (Web e SSH)?"
        desfazer_web
        desfazer_ssh
        ;;
    2)
        confirma "Tem certeza que deseja DESFAZER o bloqueio WEB do painel?"
        desfazer_web
        ;;
    3)
        confirma "Tem certeza que deseja DESFAZER a restrição de IP do SSH?"
        desfazer_ssh
        ;;
    *)
        erro "Opção inválida."
        ;;
esac

echo ""
titulo "OPERAÇÃO CONCLUÍDA"
echo "  As restrições selecionadas foram removidas com sucesso."
echo "  Caso queira blindar o servidor novamente no futuro, utilize:"
echo "    • Opção 6 do menu para blindar o SSH"
echo "    • Opção 10 do menu para blindar o acesso Web"
echo ""
exit 0
