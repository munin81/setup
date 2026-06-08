#!/bin/bash
# =====================================================================
# Voxcorp Setup — Instalar MagnusBilling
# Versão: 1.0 (08/06/2026)
# Função: Baixar e executar o script de instalação oficial do MagnusBilling 7
# Autor: Voxcorp Telecom
#
# Pré-requisitos:
#   - Servidor Debian 10/11 recém-instalado (limpo)
#
# Uso: bash instalar_magnus.sh
#
# Idempotência: NÃO (instalação de sistema base)
# Modifica estado do servidor: SIM (Instala banco, apache, asterisk, php, etc)
# Requer janela de manutenção: SIM
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
if [ -f "$SCRIPT_DIR/../lib/common.sh" ]; then
  source "$SCRIPT_DIR/../lib/common.sh"
else
  echo "Erro: Arquivo common.sh não encontrado."
  exit 1
fi

titulo "Instalação Oficial do MagnusBilling 7"

confirma "Esta ação irá baixar e executar o script de instalação oficial do Magnus. Recomenda-se rodar APENAS em um servidor limpo. Deseja continuar?"

info "Acessando diretório /usr/src/..."
cd /usr/src/ || { erro "Falha ao acessar /usr/src/"; exit 1; }

info "Baixando script install.sh do repositório oficial..."
if wget -qO install.sh https://raw.githubusercontent.com/magnussolution/magnusbilling7/source/script/install.sh; then
    ok "Download concluído."
else
    erro "Falha ao baixar install.sh"
    exit 1
fi

info "Aplicando permissões e executando a instalação..."
chmod +x install.sh
./install.sh

ok "Processo de instalação concluído."
