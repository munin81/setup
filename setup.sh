#!/bin/bash
# =====================================================================
# Magnus Utilities — setup.sh
# Versão: 3.0 (24 de outubro de 2026)
# Função: Painel de Controle Interativo paginado para MagnusBilling 8 (Principal)
#         e MagnusBilling 7 (Legado)
# Autor: Comunidade MagnusBilling
# =====================================================================

# Verifica se o diretório do projeto já existe
PROJECT_DIR="/opt/magnus-utils"
REPO_URL="https://github.com/munin81/setup.git" # Repositório no GitHub

# Verifica se o git está instalado
if ! command -v git >/dev/null 2>&1; then
    echo "Instalando pacote 'git' necessário para baixar os utilitários..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y git ca-certificates >/dev/null 2>&1
    fi
    if ! command -v git >/dev/null 2>&1; then
        echo "Erro: O git não está instalado e não pôde ser instalado automaticamente."
        echo "Execute manualmente: apt update && apt install -y git"
        exit 1
    fi
fi

# Auto-update resiliente
if [ ! -d "$PROJECT_DIR/.git" ]; then
    echo "Baixando Magnus Utilities de $REPO_URL para $PROJECT_DIR..."
    rm -rf "$PROJECT_DIR"
    if ! git clone "$REPO_URL" "$PROJECT_DIR"; then
        echo "Erro: Falha ao clonar o repositório $REPO_URL"
        exit 1
    fi
else
    cd "$PROJECT_DIR" || exit 1
    git fetch origin >/dev/null 2>&1
    if ! git reset --hard origin/main >/dev/null 2>&1; then
        echo "Atualização normal falhou — re-clonando do zero..."
        cd / && rm -rf "$PROJECT_DIR"
        if ! git clone "$REPO_URL" "$PROJECT_DIR"; then
            echo "Erro: Falha ao clonar o repositório $REPO_URL"
            exit 1
        fi
    fi
fi

# Garante auto-reload se executado externamente
SELF_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
if [ "$SELF_PATH" != "$PROJECT_DIR/setup.sh" ] && [ "$1" != "--no-reload" ]; then
    if [ -f "$PROJECT_DIR/setup.sh" ]; then
        exec bash "$PROJECT_DIR/setup.sh" --no-reload
    else
        echo "Erro: $PROJECT_DIR/setup.sh não foi encontrado."
        exit 1
    fi
fi

# Importa biblioteca de cores e funções
if [ -f "$PROJECT_DIR/scripts/lib/common.sh" ]; then
    source "$PROJECT_DIR/scripts/lib/common.sh"
else
    VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'; AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
    ok() { echo -e "  ${VERDE}✓${NC} $1"; }
    info() { echo -e "  ${AZUL}➜${NC} $1"; }
    warn() { echo -e "  ${AMARELO}⚠${NC} $1"; }
    erro() { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
    titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }
fi

CURRENT_PAGE=1

show_header() {
    clear
    echo -e "${NEGRITO}${AZUL}"
    cat << "EOF_ASCII"
  __  __                             _    _ _   _ _     
 |  \/  |                           | |  | | | (_) |    
 | \  / | __ _  __ _ _ __  _   _ ___| |  | | |_ _| |___ 
 | |\/| |/ _` |/ _` | '_ \| | | / __| |  | | __| | / __|
 | |  | | (_| | (_| | | | | |_| \__ \ |__| | |_| | \__ \
 |_|  |_|\__,_|\__, |_| |_|\__,_|___/\____/ \__|_|_|___/
                __/ |                                   
               |___/                                    
EOF_ASCII
    echo -e "${NC}"
    echo -e "  ${NEGRITO}Bem-vindo ao Magnus Utils${NC} — Automação e Gerenciamento VoIP"
    echo ""
}

show_page_1() {
    show_header
    echo -e "${NEGRITO}${VERDE}▶ PÁGINA 1/2 — MAGNUSBILLING 8 (PRIORIDADE / PRODUÇÃO ATUAL)${NC}"
    echo "=================================================================="
    echo -e "${NEGRITO}${AZUL}                  [ SEGURANÇA E FIREWALL ]${NC}"
    echo "=================================================================="
    echo -e " ${NEGRITO}1.${NC} Auditoria de Segurança e Blindagem (SSH, Web, Portas, Firewall)"
    echo -e "    ${AZUL}↳${NC} Valida se o SSH não usa porta 22 e se Web e SSH estão restritos por IP."
    echo -e " ${NEGRITO}2.${NC} Blindar Acesso SSH no Firewall (por IP e Porta)"
    echo -e "    ${AZUL}↳${NC} Altera porta para 22022, restringe aos seus IPs e descarta invasores."
    echo -e " ${NEGRITO}3.${NC} Blindar Acesso Web do Painel (por IP)"
    echo -e "    ${AZUL}↳${NC} Restringe painel aos seus IPs (visitantes externos recebem 403 Forbidden)."
    echo -e " ${NEGRITO}4.${NC} Liberar IP no Firewall (SSH / Migração)"
    echo -e "    ${AZUL}↳${NC} Libera o IP de outro servidor no firewalld/iptables e fail2ban."
    echo -e " ${NEGRITO}5.${NC} Desfazer Bloqueios de Segurança (Reabrir Web e SSH)"
    echo -e "    ${AZUL}↳${NC} Remove restrições de IP e restaura o acesso global se necessário."
    echo ""
    echo "=================================================================="
    echo -e "${NEGRITO}${AZUL}             [ SERVIDOR WEB E CERTIFICADO SSL ]${NC}"
    echo "=================================================================="
    echo -e " ${NEGRITO}6.${NC} Configurar Certificado SSL — MagnusBilling 8 (Let's Encrypt)"
    echo -e "    ${AZUL}↳${NC} Emite SSL no Apache, bloqueia IP puro e integra WSS/WebRTC no Asterisk 20."
    echo -e " ${NEGRITO}7.${NC} Limpar URL do Painel (Remover /mbilling)"
    echo -e "    ${AZUL}↳${NC} Faz o painel responder na raiz (https://dominio/) mantendo compatibilidade."
    echo ""
    echo "=================================================================="
    echo -e "${NEGRITO}${AZUL}                 [ INSTALAÇÃO E MIGRAÇÃO ]${NC}"
    echo "=================================================================="
    echo -e " ${NEGRITO}8.${NC} Instalação Limpa do MagnusBilling 8 Oficial"
    echo -e "    ${AZUL}↳${NC} Instalação oficial do MB8 (Asterisk 20 + PJSIP nativo)."
    echo -e " ${NEGRITO}9.${NC} Migrar MagnusBilling 7 para MagnusBilling 8"
    echo -e "    ${AZUL}↳${NC} Conecta via SSH no MB7, migra dados, converte PJSIP e executa UpdateMysql."
    echo ""
    echo "=================================================================="
    echo -e "${NEGRITO}${AZUL}                  [ MANUTENÇÃO DE BANCO ]${NC}"
    echo "=================================================================="
    echo -e " ${NEGRITO}10.${NC} Repasse em Massa de DIDs"
    echo -e "    ${AZUL}↳${NC} Transfere DIDs para outro cliente e atualiza as rotas SIP."
    echo -e " ${NEGRITO}11.${NC} Limpeza Profunda de Inativos (CDR e Ofertas)"
    echo -e "    ${AZUL}↳${NC} Exclui histórico de usuários cancelados por período."
    echo -e " ${NEGRITO}12.${NC} Criar Usuário de Banco (DBeaver / N8N / acesso remoto)"
    echo -e "    ${AZUL}↳${NC} Cria usuário MySQL por IP com senha oculta fora do ps aux."
    echo -e " ${NEGRITO}13.${NC} Gerar Relatório CSV de CDR"
    echo -e "    ${AZUL}↳${NC} Exporta histórico de chamadas (CDR) por usuário e período."
    echo -e " ${NEGRITO}14.${NC} Trocar Senha do Painel Web (root / usuário)"
    echo -e "    ${AZUL}↳${NC} Altera com segurança a senha de acesso web do MagnusBilling."
    echo ""
    echo "=================================================================="
    echo -e " ${NEGRITO}[P]${NC} ou ${NEGRITO}[2]${NC} 👉 Próxima Página: Utilitários MagnusBilling 7 Legado"
    echo -e " ${NEGRITO}[0]${NC} Sair"
    echo "=================================================================="
    read -p "Opção: " OPTION
}

show_page_2() {
    show_header
    echo -e "${NEGRITO}${AMARELO}▶ PÁGINA 2/2 — MAGNUSBILLING 7 (LEGADO / CENTOS / DEBIAN 10-11)${NC}"
    echo "=================================================================="
    echo -e "${NEGRITO}${AZUL}                 [ UTILITÁRIOS LEGADOS MB7 ]${NC}"
    echo "=================================================================="
    echo -e " ${NEGRITO}21.${NC} Instalação Oficial do MagnusBilling 7 Legado"
    echo -e "    ${AZUL}↳${NC} Script de instalação clássica do MB7 com chan_sip."
    echo -e " ${NEGRITO}22.${NC} Migrar Dados entre Servidores MagnusBilling 7 (MB7 ➔ MB7)"
    echo -e "    ${AZUL}↳${NC} Conecta via SSH, migra banco e peers chan_sip entre dois servidores MB7."
    echo -e " ${NEGRITO}23.${NC} Configurar Certificado SSL — MagnusBilling 7 Legado"
    echo -e "    ${AZUL}↳${NC} Emissão e configuração de SSL no Apache para servidores MB7 clássicos."
    echo -e " ${NEGRITO}24.${NC} Auditoria de Saúde e Segurança (Health Check Legado)"
    echo -e "    ${AZUL}↳${NC} Varre serviços, corrige permissões dos confs e alerta erros."
    echo -e " ${NEGRITO}25.${NC} Blindagem de Firewall IPtables (Legado MB7)"
    echo -e "    ${AZUL}↳${NC} Script de regras iptables puras clássicas da documentação antiga do MB7."
    echo ""
    echo "=================================================================="
    echo -e " ${NEGRITO}[A]${NC} ou ${NEGRITO}[1]${NC} 👈 Página Anterior: MagnusBilling 8 (Principal)"
    echo -e " ${NEGRITO}[0]${NC} Sair"
    echo "=================================================================="
    read -p "Opção: " OPTION
}

while true; do
    if [ "$CURRENT_PAGE" -eq 1 ]; then
        show_page_1
    else
        show_page_2
    fi

    # Tratamento de navegação entre páginas
    if [[ "$OPTION" =~ ^[Pp2]$ ]] && [ "$CURRENT_PAGE" -eq 1 ]; then
        CURRENT_PAGE=2
        continue
    elif [[ "$OPTION" =~ ^[Aa1]$ ]] && [ "$CURRENT_PAGE" -eq 2 ]; then
        CURRENT_PAGE=1
        continue
    fi

    case $OPTION in
        # --- PÁGINA 1: MB8 ---
        1)
            bash "$PROJECT_DIR/scripts/diagnostico/verificar_seguranca_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        2)
            bash "$PROJECT_DIR/scripts/instalacao/blindar_ssh_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        3)
            bash "$PROJECT_DIR/scripts/instalacao/blindar_web_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        4)
            bash "$PROJECT_DIR/scripts/manutencao/liberar_ip_firewall.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        5)
            bash "$PROJECT_DIR/scripts/manutencao/desfazer_bloqueios_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        6)
            bash "$PROJECT_DIR/scripts/instalacao/configurar_ssl_mb8.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        7)
            bash "$PROJECT_DIR/scripts/instalacao/limpar_url_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        8)
            bash "$PROJECT_DIR/scripts/instalacao/instalar_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        9)
            bash "$PROJECT_DIR/scripts/migracao/migrar_mb7_para_mb8.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        10)
            bash "$PROJECT_DIR/scripts/manutencao/alterar_bloco_did.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        11)
            bash "$PROJECT_DIR/scripts/manutencao/deletar_cdr_oferta.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        12)
            bash "$PROJECT_DIR/scripts/manutencao/criar_usuario_db.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        13)
            bash "$PROJECT_DIR/scripts/relatorios/gerar_csv_cdr.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        14)
            bash "$PROJECT_DIR/scripts/manutencao/alterar_senha_web.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;

        # --- PÁGINA 2: MB7 LEGADO ---
        21)
            bash "$PROJECT_DIR/scripts/instalacao/instalar_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        22)
            bash "$PROJECT_DIR/scripts/migracao/migrar_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        23)
            bash "$PROJECT_DIR/scripts/instalacao/configurar_ssl_mb7_legado.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        24)
            bash "$PROJECT_DIR/scripts/diagnostico/magnus-health-check.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        25)
            bash "$PROJECT_DIR/scripts/instalacao/iptables-magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;

        0)
            echo "Saindo..."
            exit 0
            ;;
        *)
            echo "Opção inválida!"
            sleep 2
            ;;
    esac
done
