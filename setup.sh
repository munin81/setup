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
    echo -e "Bem-vindo ao ${NEGRITO}Magnus Utilities${NC} - Utilitários MagnusBilling 7.x"
    echo "------------------------------------------------------------------"
    echo "Selecione uma ferramenta:"
    echo "1. Diagnóstico Geral (Health Check)"
    echo "2. Migração Completa de MagnusBilling"
    echo "3. Alterar Bloco DID (Manutenção)"
    echo "4. Deletar CDR / Oferta (Manutenção)"
    echo "5. Ajustar regras de Firewall/IPtables (Instalação)"
    echo "6. Instalar MagnusBilling 7 Oficial (Instalação base)"
    echo "7. Configurar SSL Let's Encrypt (Apache)"
    echo "0. Sair"
    echo "------------------------------------------------------------------"
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
            bash "$PROJECT_DIR/scripts/migracao/migrar_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        3)
            bash "$PROJECT_DIR/scripts/manutencao/alterar_bloco_did.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        4)
            bash "$PROJECT_DIR/scripts/manutencao/deletar_cdr_oferta.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        5)
            bash "$PROJECT_DIR/scripts/instalacao/iptables-magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        6)
            bash "$PROJECT_DIR/scripts/instalacao/instalar_magnus.sh"
            echo ""
            read -p "Pressione ENTER para voltar ao menu..."
            ;;
        7)
            bash "$PROJECT_DIR/scripts/instalacao/configurar_ssl_magnus.sh"
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
