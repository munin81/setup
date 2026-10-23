#!/bin/bash
# =====================================================================
# Magnus Utilities — instalar_magnus.sh
# Versão: 2.0 (23 de outubro de 2026)
# Função: Baixar e executar o script de instalação oficial do MagnusBilling
#         com suporte a MagnusBilling 8 (Asterisk 20 + PJSIP) e MB7 legado
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Servidor limpo recém-instalado (Debian 11, 12, 13 ou Ubuntu LTS)
#   - Rodar como root
#
# Uso:
#   bash instalar_magnus.sh              # modo interativo
#   bash instalar_magnus.sh --mb8        # instala direto MagnusBilling 8
#   bash instalar_magnus.sh --mb7        # instala direto MagnusBilling 7
#
# Idempotência: NÃO (instalação de sistema operacional base)
# Modifica estado do servidor: SIM (banco, web, Asterisk, PHP)
# Requer janela de manutenção: SIM (servidor limpo)
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
if [ -f "$SCRIPT_DIR/../lib/common.sh" ]; then
  source "$SCRIPT_DIR/../lib/common.sh"
else
  VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'; AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
  ok()     { echo -e "  ${VERDE}✓${NC} $1"; }
  warn()   { echo -e "  ${AMARELO}⚠${NC} $1"; }
  erro()   { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
  info()   { echo -e "  ${AZUL}➜${NC} $1"; }
  titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }
  confirma() {
    read -p "  $1 [s/N]: " RESP
    [[ "$RESP" =~ ^[Ss]$ ]] || { erro "Operação cancelada pelo usuário."; exit 1; }
  }
fi

[ "$EUID" -ne 0 ] && erro "Este script deve ser executado como root."

clear
titulo "Instalação Oficial do MagnusBilling"

echo ""
echo "Selecione a versão do MagnusBilling que deseja instalar:"
echo -e "  ${AZUL}[1]${NC} ${NEGRITO}MagnusBilling 8${NC} (Atual — Asterisk 20 + PJSIP, PHP 8.x) [Recomendado]"
echo -e "  ${AZUL}[2]${NC} ${NEGRITO}MagnusBilling 7${NC} (Legado — Asterisk 13 + chan_sip, PHP 7.x/8.x)"
echo ""

ESCOLHA=""
for ARG in "$@"; do
  case "$ARG" in
    --mb8) ESCOLHA="1" ;;
    --mb7) ESCOLHA="2" ;;
  esac
done

if [ -z "$ESCOLHA" ]; then
  read -p "Opção [1]: " ESCOLHA
  ESCOLHA=${ESCOLHA:-1}
fi

# Valida distribuição do Linux
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO="$ID"
  VERSAO_SO="$VERSION_ID"
else
  DISTRO="desconhecida"
  VERSAO_SO="desconhecida"
fi

case "$ESCOLHA" in
  1)
    TITULO_VERSAO="MagnusBilling 8 (Asterisk 20 + PJSIP)"
    URL_INSTALLER="https://raw.githubusercontent.com/magnussolution/magnusbilling/source/script/install.sh"
    
    info "Validando compatibilidade para MagnusBilling 8..."
    case "$DISTRO" in
      debian)
        case "${VERSAO_SO%%.*}" in
          11|12|13) ok "Debian $VERSAO_SO detectado — suportado pelo instalador oficial do MB8." ;;
          *) warn "Debian $VERSAO_SO — o instalador do MB8 recomenda Debian 11, 12 ou 13." ;;
        esac
        ;;
      ubuntu)
        case "$VERSAO_SO" in
          22.04|24.04|26.04) ok "Ubuntu $VERSAO_SO LTS detectado — suportado pelo instalador oficial do MB8." ;;
          *) warn "Ubuntu $VERSAO_SO — o instalador do MB8 recomenda Ubuntu 22.04, 24.04 ou 26.04." ;;
        esac
        ;;
      *)
        warn "Distribuição '$PRETTY_NAME' não testada oficialmente para o MB8."
        ;;
    esac
    ;;
  2)
    TITULO_VERSAO="MagnusBilling 7 (Asterisk 13 + chan_sip)"
    URL_INSTALLER="https://raw.githubusercontent.com/magnussolution/magnusbilling7/source/script/install.sh"
    
    info "Validando compatibilidade para MagnusBilling 7..."
    case "$DISTRO" in
      debian)
        case "${VERSAO_SO%%.*}" in
          11|12) ok "Debian $VERSAO_SO detectado — suportado pelo instalador oficial do MB7." ;;
          10)    warn "Debian 10 detectado — o instalador do MB7 oficial requer Debian 11 ou 12." ;;
          *)     warn "Debian $VERSAO_SO — o instalador oficial do MB7 requer Debian 11 ou 12." ;;
        esac
        ;;
      *)
        warn "Distribuição '$PRETTY_NAME' — MagnusBilling 7 homologado apenas para Debian 11/12."
        ;;
    esac
    ;;
  *)
    erro "Opção inválida."
    ;;
esac

echo ""
warn "ATENÇÃO: A instalação do $TITULO_VERSAO substitui serviços de rede e banco."
warn "Execute EXCLUSIVAMENTE em um servidor limpo recém-formatado."
confirma "Deseja prosseguir com o download e execução do instalador oficial?"

info "Acessando diretório /usr/src/..."
cd /usr/src/ || erro "Falha ao acessar /usr/src/"

info "Baixando script install.sh oficial de $URL_INSTALLER..."
if wget -qO install.sh "$URL_INSTALLER"; then
  ok "Download concluído com sucesso."
else
  erro "Falha ao baixar o instalador oficial. Verifique sua conexão com a internet."
fi

info "Configurando permissão de execução..."
chmod +x install.sh

info "Iniciando instalação oficial do $TITULO_VERSAO..."
echo ""
./install.sh

ok "Processo do instalador finalizado."
exit 0
