#!/bin/bash
# =====================================================================
# Voxcorp Setup — Menu de Ferramentas (Entrypoint)
# Versão: 1.0 (08/06/2026)
# Função: Script inicial estilo menu interativo (curl | bash)
# Autor: Voxcorp Telecom
# =====================================================================

# Verifica se o diretório do projeto já existe
PROJECT_DIR="/opt/voxcorp-setup"
REPO_URL="https://github.com/Voxcorp/voxcorp-setup.git" # Substitua pela URL real

# Se quiser fazer um "auto-update" rápido antes de rodar o menu:
# Se o script está rodando direto do curl, ele pode clonar para /opt
if [ ! -d "$PROJECT_DIR" ]; then
    echo "Instalando Voxcorp Setup em $PROJECT_DIR..."
    # git clone "$REPO_URL" "$PROJECT_DIR" &>/dev/null
    # Se não tiver o repositório hospedado, o código abaixo assume que estamos no diretório correto:
    PROJECT_DIR="$(pwd)"
else
    # cd "$PROJECT_DIR" && git pull origin main &>/dev/null
    PROJECT_DIR="$(pwd)"
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
    echo " __      __                              _____      _               "
    echo " \ \    / /                             / ____|    | |              "
    echo "  \ \  / /____  __  ___ ___  _ __ _ __ | (___   ___| |_ _   _ _ __  "
    echo "   \ \/ / _ \ \/ / / __/ _ \| '__| '_ \ \___ \ / _ \ __| | | | '_ \ "
    echo "    \  / (_) >  < | (_| (_) | |  | |_) |____) |  __/ |_| |_| | |_) |"
    echo "     \/ \___/_/\_\ \___\___/|_|  | .__/|_____/ \___|\__|\__,_| .__/ "
    echo "                                 | |                         | |    "
    echo "                                 |_|                         |_|    "
    echo -e "${NC}"
    echo -e "Bem-vindo ao ${NEGRITO}Voxcorp Setup${NC} - Utilitários MagnusBilling 7.x"
    echo "------------------------------------------------------------------"
    echo "Selecione uma ferramenta:"
    echo "1. Magnus Health Check (Diagnóstico Read-Only)"
    echo "2. Restaurar Magnus (Migração)"
    echo "3. Alterar Bloco DID (Manutenção)"
    echo "4. Deletar CDR / Oferta (Manutenção)"
    echo "5. Ajustar regras de Firewall/IPtables (Instalação)"
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
            # Como você tem dois scripts com o mesmo nome, vou apontar para o que for principal.
            bash "$PROJECT_DIR/scripts/migracao/restaurar_magnus.sh"
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
            bash "$PROJECT_DIR/scripts/instalacao/iptables-magnus-voxcorp_136.sh"
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
