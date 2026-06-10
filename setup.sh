#!/bin/bash
# =====================================================================
# Magnus Utilities — Menu de Ferramentas (Entrypoint)
# Versão: 1.0 (08/06/2026)
# Função: Script inicial estilo menu interativo (curl | bash)
# Autor: Comunidade MagnusBilling
# =====================================================================

# Verifica se o diretório do projeto já existe
PROJECT_DIR="/opt/magnus-utils"
REPO_URL="https://github.com/munin81/setup.git" # Repositório no GitHub

# Se quiser fazer um "auto-update" rápido antes de rodar o menu:
# Se o script está rodando direto do curl, ele pode clonar para /opt
if [ ! -d "$PROJECT_DIR" ]; then
    echo "Baixando Magnus Utilities de $REPO_URL para $PROJECT_DIR..."
    git clone "$REPO_URL" "$PROJECT_DIR" >/dev/null 2>&1
else
    cd "$PROJECT_DIR" && git pull origin main >/dev/null 2>&1
fi

# Garante que o usuário sempre veja o menu atualizado mesmo que o script rodado pelo curl esteja em cache
if [ "$(realpath "$0")" != "$PROJECT_DIR/setup.sh" ] && [ "$1" != "--no-reload" ]; then
    exec bash "$PROJECT_DIR/setup.sh" --no-reload
fi

# Tenta importar common.sh
if [ -f "$PROJECT_DIR/scripts/lib/common.sh" ]; then
    source "$PROJECT_DIR/scripts/lib/common.sh"
else
    echo "Erro: Não foi possível carregar scripts/lib/common.sh"
    exit 1
fi

show_menu() {
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
    echo -e "  Bem-vindo ao ${NEGRITO}Magnus Utilities${NC} - Utilitários MagnusBilling 7.x"
    echo "=================================================================="
    echo -e "${NEGRITO}${AZUL}                 [ DIAGNÓSTICO E AUDITORIA ]${NC}"
    echo "=================================================================="
    echo -e " ${NEGRITO}1.${NC} Auditoria de Saúde e Segurança (Health Check)"
    echo -e "    ${AZUL}↳${NC} Varre serviços, corrige permissões, alerta erros e audita."
    echo ""
    echo "=================================================================="
    echo -e "${NEGRITO}${AZUL}                 [ INSTALAÇÃO E MIGRAÇÃO ]${NC}"
    echo "=================================================================="
    echo -e " ${NEGRITO}2.${NC} Instalação Oficial do MagnusBilling 7"
    echo -e "    ${AZUL}↳${NC} Baixa e executa o instalador limpo direto do GitHub oficial."
    echo -e " ${NEGRITO}3.${NC} Migrar Dados de Outro Servidor Magnus"
    echo -e "    ${AZUL}↳${NC} Conecta via SSH, copia banco, áudios e configurações base."
    echo ""
    echo "=================================================================="
    echo -e "${NEGRITO}${AZUL}               [ CONFIGURAÇÃO DE SERVIDOR WEB ]${NC}"
    echo "=================================================================="
    echo -e " ${NEGRITO}4.${NC} Configurar Certificado SSL (HTTPS Let's Encrypt)"
    echo -e "    ${AZUL}↳${NC} Emite SSL gratuito e aplica redirecionamento seguro no Apache."
    echo -e " ${NEGRITO}5.${NC} Limpar URL do Painel (Remover /mbilling)"
    echo -e "    ${AZUL}↳${NC} Altera o Apache para exibir o painel direto na raiz do domínio."
    echo ""
    echo "=================================================================="
    echo -e "${NEGRITO}${AZUL}                  [ SEGURANÇA E FIREWALL ]${NC}"
    echo "=================================================================="
    echo -e " ${NEGRITO}6.${NC} Blindagem de Firewall Interativo (IPtables)"
    echo -e "    ${AZUL}↳${NC} Trava acesso admin (SSH/MySQL) com proteção anti-bloqueio."
    echo ""
    echo "=================================================================="
    echo -e "${NEGRITO}${AZUL}                  [ MANUTENÇÃO DE BANCO ]${NC}"
    echo "=================================================================="
    echo -e " ${NEGRITO}7.${NC} Repasse em Massa de DIDs"
    echo -e "    ${AZUL}↳${NC} Transfere DIDs para outro cliente e atualiza as rotas SIP."
    echo -e " ${NEGRITO}8.${NC} Limpeza Profunda de Inativos (CDR e Ofertas)"
    echo -e "    ${AZUL}↳${NC} Exclui histórico de usuários cancelados por período."
    echo ""
    echo -e " ${NEGRITO}0.${NC} Sair"
    echo "=================================================================="
    read -p "Opção: " OPTION
}

while true; do
    show_menu
    case $OPTION in
        1)
            bash "$PROJECT_DIR/scripts/diagnostico/magnus-health-check.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        2)
            bash "$PROJECT_DIR/scripts/instalacao/instalar_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        3)
            bash "$PROJECT_DIR/scripts/migracao/migrar_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        4)
            bash "$PROJECT_DIR/scripts/instalacao/configurar_ssl_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        5)
            bash "$PROJECT_DIR/scripts/instalacao/limpar_url_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        6)
            bash "$PROJECT_DIR/scripts/instalacao/iptables-magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        7)
            bash "$PROJECT_DIR/scripts/manutencao/alterar_bloco_did.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        8)
            bash "$PROJECT_DIR/scripts/manutencao/deletar_cdr_oferta.sh"
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
