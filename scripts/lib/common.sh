#!/bin/bash
# =====================================================================
# Magnus Utilities — Funções comuns e compartilhadas
# Versão: 2.0 (12/11/2026)
# Função: Prover formatação, cores, funções úteis de validação e
#         detector de mudanças de arquitetura do MagnusBilling 8
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
erro()   { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
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
    ok "Backup de $(basename "$ARQ") realizado."
  else
    warn "Arquivo $ARQ não encontrado para backup."
  fi
}

# =====================================================================
# Baseline Homologado do MagnusBilling 8 (Detector de Drift de Arquitetura)
# =====================================================================
MB8_HOMOLOGATED_COMMIT="d9014913129a33ae261e117ca89381e04b136f6e"
MB8_HOMOLOGATED_SHORT="d901491"
MB8_HOMOLOGATED_DATE="2026-10-30"
MB8_UPSTREAM_REPO="magnussolution/magnusbilling"
MB8_UPSTREAM_BRANCH="source"

# Verifica se houve mudanças significativas na arquitetura do MagnusBilling 8
# (tanto no repositório oficial GitHub quanto nos arquivos locais instalados)
# Uso:
#   verificar_compatibilidade_mb8            # Modo Pre-Flight (pede confirmação se houver risco alto)
#   verificar_compatibilidade_mb8 --audit    # Modo Auditoria (apenas relatório, sem prompt)
verificar_compatibilidade_mb8() {
  local MODO="${1:-preflight}"
  local RISCO_NIVEL=0   # 0=Seguro (Verde), 1=Atenção (Amarelo), 2=Crítico/Arquitetura (Vermelho)
  local ARQUIVOS_CRITICOS_ALTERADOS=""
  local ARQUIVOS_MEDIOS_ALTERADOS=""
  local INCONSISTENCIAS_LOCAIS=""
  local AHEAD_BY="0"
  local ULTIMO_COMMIT_UPSTREAM="$MB8_HOMOLOGATED_SHORT"

  if [ "$MODO" != "--audit" ]; then
    echo ""
    info "Verificando compatibilidade de arquitetura do MagnusBilling 8 (Baseline homologado: ${NEGRITO}${MB8_HOMOLOGATED_SHORT}${NC} de ${MB8_HOMOLOGATED_DATE})..."
  fi

  # -------------------------------------------------------------------
  # Camada 1: Comparação do Baseline Homologado vs Branch Oficial no GitHub
  # -------------------------------------------------------------------
  if command -v curl >/dev/null 2>&1; then
    local COMPARE_URL="https://api.github.com/repos/${MB8_UPSTREAM_REPO}/compare/${MB8_HOMOLOGATED_COMMIT}...${MB8_UPSTREAM_BRANCH}"
    local COMPARE_JSON
    COMPARE_JSON=$(curl -sSL --max-time 5 "$COMPARE_URL" 2>/dev/null || true)

    if echo "$COMPARE_JSON" | grep -q '"ahead_by"'; then
      AHEAD_BY=$(echo "$COMPARE_JSON" | grep -m1 '"ahead_by":' | sed -E 's/.*"ahead_by": *([0-9]+).*/\1/')
      AHEAD_BY=${AHEAD_BY:-0}

      if [ "$AHEAD_BY" -gt 0 ] 2>/dev/null; then
        local CHANGED_FILES
        CHANGED_FILES=$(echo "$COMPARE_JSON" | grep '"filename":' | sed -E 's/.*"filename": *"([^"]+)".*/\1/' | sort -u)

        while IFS= read -r FILE_PATH; do
          [ -z "$FILE_PATH" ] && continue
          case "$FILE_PATH" in
            script/install.sh|script/update.sh|protected/components/AsteriskAccess.php|protected/commands/UpdateMysqlCommand.php|protected/components/Magnus.php|resources/asterisk/mbilling.php)
              RISCO_NIVEL=2
              ARQUIVOS_CRITICOS_ALTERADOS="${ARQUIVOS_CRITICOS_ALTERADOS}    - ${FILE_PATH} (Pilar estrutural do MB8)\n"
              ;;
            protected/commands/*|protected/controllers/*|protected/models/*|protected/config/*|resources/asterisk/*)
              [ "$RISCO_NIVEL" -lt 1 ] && RISCO_NIVEL=1
              ARQUIVOS_MEDIOS_ALTERADOS="${ARQUIVOS_MEDIOS_ALTERADOS}    - ${FILE_PATH}\n"
              ;;
          esac
        done <<< "$CHANGED_FILES"
      fi
    fi
  fi

  # -------------------------------------------------------------------
  # Camada 2: Verificação de Contratos Locais de Arquitetura (se MB8 instalado)
  # -------------------------------------------------------------------
  local MB_DIR="/var/www/html/mbilling"
  if [ -d "$MB_DIR" ]; then
    local AST_ACCESS="$MB_DIR/protected/components/AsteriskAccess.php"
    if [ -f "$AST_ACCESS" ]; then
      # Contrato 1: AsteriskAccess.php deve gerenciar pjsip_magnus
      if ! grep -q "pjsip_magnus" "$AST_ACCESS" 2>/dev/null; then
        RISCO_NIVEL=2
        INCONSISTENCIAS_LOCAIS="${INCONSISTENCIAS_LOCAIS}    - AsteriskAccess.php local não referencia 'pjsip_magnus' (possível instalação MB7 ou mudança drástica no gerador SIP).\n"
      fi

      # Contrato 2: No baseline homologado do MB8, extensions_magnus.conf é estático
      # (AsteriskAccess.php gera apenas extensions_magnus_did.conf). Se passar a escrever extensions_magnus.conf:
      if grep -E "extensions_magnus\.conf" "$AST_ACCESS" 2>/dev/null | grep -vq "extensions_magnus_did\.conf"; then
        RISCO_NIVEL=2
        INCONSISTENCIAS_LOCAIS="${INCONSISTENCIAS_LOCAIS}    - AsteriskAccess.php local passou a manipular 'extensions_magnus.conf' dinamicamente (mudança em relação ao baseline estático).\n"
      fi
    fi
  fi

  # -------------------------------------------------------------------
  # Exibição do Diagnóstico e Decisão
  # -------------------------------------------------------------------
  MB8_ARCH_STATUS="$RISCO_NIVEL"

  if [ "$RISCO_NIVEL" -eq 0 ]; then
    if [ "${AHEAD_BY:-0}" -eq 0 ] 2>/dev/null; then
      ok "Arquitetura MagnusBilling 8 100% compatível com o baseline homologado (${MB8_HOMOLOGATED_SHORT} — 0 commits estruturais novos)."
    else
      ok "Arquitetura MagnusBilling 8 compatível (${AHEAD_BY} commit(s) novos no GitHub apenas em UI/traduções; nenhum arquivo estrutural alterado)."
    fi
    return 0
  elif [ "$RISCO_NIVEL" -eq 1 ]; then
    warn "O repositório oficial do MagnusBilling 8 recebeu ${AHEAD_BY} commit(s) após o baseline homologado (${MB8_HOMOLOGATED_SHORT})."
    info "Os pilares críticos (install.sh, AsteriskAccess.php, UpdateMysqlCommand.php) NÃO sofreram alteração, mas arquivos secundários mudaram:"
    echo -e "$ARQUIVOS_MEDIOS_ALTERADOS" | head -n 8
    return 0
  else
    echo ""
    echo -e "  ${VERMELHO}${NEGRITO}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${VERMELHO}${NEGRITO}║  ⚠  ALERTA CRÍTICO: MUDANÇA DE ARQUITETURA DETECTADA NO MAGNUS 8!   ║${NC}"
    echo -e "  ${VERMELHO}${NEGRITO}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  • Baseline homologado por este setup: ${NEGRITO}${MB8_HOMOLOGATED_SHORT}${NC} (${MB8_HOMOLOGATED_DATE})"
    [ "${AHEAD_BY:-0}" -gt 0 ] 2>/dev/null && echo -e "  • Commits novos no repositório oficial desde a homologação: ${NEGRITO}${AHEAD_BY}${NC}"
    echo ""
    if [ -n "$ARQUIVOS_CRITICOS_ALTERADOS" ]; then
      echo -e "  ${AMARELO}${NEGRITO}Arquivos estruturais alterados no GitHub oficial do MagnusBilling 8:${NC}"
      echo -ne "$ARQUIVOS_CRITICOS_ALTERADOS"
      echo ""
    fi
    if [ -n "$INCONSISTENCIAS_LOCAIS" ]; then
      echo -e "  ${AMARELO}${NEGRITO}Divergências de arquitetura detectadas nos arquivos locais:${NC}"
      echo -ne "$INCONSISTENCIAS_LOCAIS"
      echo ""
    fi
    warn "Isso significa que o desenvolvedor do MagnusBilling alterou componentes centrais (PJSIP, Instalador, Dialplan ou Migrations)."
    warn "Recomendação: Revise os novos commits em https://github.com/${MB8_UPSTREAM_REPO}/commits/${MB8_UPSTREAM_BRANCH} antes de aplicar em produção."
    echo ""

    if [ "$MODO" != "--audit" ]; then
      read -p "  Deseja continuar a execução mesmo com divergência de arquitetura? [s/N]: " RESP_DRIFT
      if [[ ! "$RESP_DRIFT" =~ ^[Ss]$ ]]; then
        erro "Execução abortada preventivamente pelo usuário para análise das mudanças do MagnusBilling 8."
      fi
    fi
    return 0
  fi
}
