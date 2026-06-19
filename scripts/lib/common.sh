#!/bin/bash
# =====================================================================
# Magnus Utilities — Funções comuns e compartilhadas
# Versão: 1.0 (08/06/2026)
# Função: Prover formatação, cores e funções úteis de validação
# Autor: Comunidade MagnusBilling
# =====================================================================

# Cores e logs padronizados
VERDE='\033[0;32m'
AMARELO='\033[1;33m'
VERMELHO='\033[0;31m'
AZUL='\033[0;34m'
NEGRITO='\033[1m'
NC='\033[0m'

ok()     { echo -e "  ${VERDE}✓${NC} $1"; }
warn()   { echo -e "  ${AMARELO}⚠${NC} $1"; }
erro()   { echo -e "  ${VERMELHO}✗${NC} $1"; }
info()   { echo -e "  ${AZUL}ℹ${NC} $1"; }
titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }

# Confirmação obrigatória antes de operação destrutiva
confirma() {
  read -p "  $1 [s/N]: " RESP
  [[ "$RESP" =~ ^[Ss]$ ]] || { erro "Operação cancelada pelo usuário."; exit 1; }
}

# Backup antes de modificar arquivo de sistema
backup_arquivo() {
  local ARQ="$1"
  if [ -f "$ARQ" ]; then
    cp -p "$ARQ" "${ARQ}.bak.$(date +%Y%m%d_%H%M%S)"
    ok "Backup de $(basename $ARQ) realizado."
  else
    warn "Arquivo $ARQ não encontrado para backup."
  fi
}
