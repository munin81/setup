#!/bin/bash
# =====================================================================
# Magnus Utilities — configurar_horario_brasil.sh
# Versão: 1.0 (06 de novembro de 2026)
# Função: Verificar e ajustar o fuso horário (Timezone) e sincronismo NTP
#         do servidor (Linux, PHP, MariaDB e Cron) para os fusos oficiais
#         do Brasil, corrigindo divergências de horário nos CDRs e painel.
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#
# Uso:
#   bash configurar_horario_brasil.sh              # menu interativo
#   bash configurar_horario_brasil.sh --check      # apenas exibe diagnóstico
#   bash configurar_horario_brasil.sh --sp         # aplica America/Sao_Paulo direto
#   bash configurar_horario_brasil.sh --help       # exibe ajuda
#
# Idempotência: SIM
# Modifica estado: SIM (fuso horário do SO, php.ini, NTP e reload de serviços)
# Requer janela de manutenção: NÃO (reiniciar MariaDB/Apache não derruba chamadas SIP)
# =====================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
if [ -f "$SCRIPT_DIR/../lib/common.sh" ]; then
  source "$SCRIPT_DIR/../lib/common.sh"
else
  VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
  AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
  ok()     { echo -e "  ${VERDE}✓${NC} $1"; }
  warn()   { echo -e "  ${AMARELO}⚠${NC} $1"; }
  erro()   { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
  info()   { echo -e "  ${AZUL}ℹ${NC} $1"; }
  titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }
  confirma() {
    read -p "  $1 [s/N]: " RESP
    [[ "$RESP" =~ ^[Ss]$ ]] || { erro "Operação cancelada pelo usuário."; exit 1; }
  }
fi

[ "$EUID" -ne 0 ] && erro "Este script deve ser executado como root."

CHECK_ONLY=0
AUTO_SP=0
for ARG in "$@"; do
  case "$ARG" in
    --check|--dry-run) CHECK_ONLY=1 ;;
    --sp|--brasilia)   AUTO_SP=1 ;;
    --help|-h)
      sed -n '/^# Magnus Utilities/,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

# Conexão segura com o MariaDB (sem senha no ps aux)
mysql_query() {
  if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
    mysql -u root -N -e "$1" 2>/dev/null
  elif [ -f "/root/passwordMysql.log" ]; then
    local RPW
    RPW=$(cat /root/passwordMysql.log 2>/dev/null | tr -d '[:space:]')
    MYSQL_PWD="$RPW" mysql -u root -N -e "$1" 2>/dev/null
  elif [ -f "/etc/asterisk/res_config_mysql.conf" ]; then
    local DBU DBP DBH
    DBU=$(grep -i "^dbuser" /etc/asterisk/res_config_mysql.conf | head -1 | cut -d'=' -f2 | tr -d ' ')
    DBP=$(grep -i "^dbpass" /etc/asterisk/res_config_mysql.conf | head -1 | cut -d'=' -f2 | tr -d ' ')
    DBH=$(grep -i "^dbhost" /etc/asterisk/res_config_mysql.conf | head -1 | cut -d'=' -f2 | tr -d ' ')
    MYSQL_PWD="$DBP" mysql -u "$DBU" -h "${DBH:-127.0.0.1}" -N -e "$1" 2>/dev/null
  fi
}

mostrar_diagnostico_horario() {
  titulo "DIAGNÓSTICO ATUAL DE DATA, HORA E FUSO HORÁRIO"

  local OS_TZ OS_DATE NTP_SYNC PHP_DATE MYSQL_NOW MYSQL_SYS_TZ
  OS_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || date +"%Z")
  OS_DATE=$(date "+%Y-%m-%d %H:%M:%S (%Z / UTC%z)")
  NTP_SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "desconhecido")

  if command -v php >/dev/null 2>&1; then
    PHP_DATE=$(php -r "echo date('Y-m-d H:i:s (e / \U\T\CP)');" 2>/dev/null)
  else
    PHP_DATE="PHP não encontrado"
  fi

  MYSQL_NOW=$(mysql_query "SELECT CONCAT(NOW(), ' (Sistema DB: ', @@system_time_zone, ' / Global: ', @@global.time_zone, ')');")

  echo ""
  echo -e "  • ${NEGRITO}Fuso do Sistema (Linux):${NC}  $OS_TZ"
  echo -e "  • ${NEGRITO}Horário do Linux:${NC}         $OS_DATE"
  if [ "$NTP_SYNC" = "yes" ]; then
    echo -e "  • ${NEGRITO}Sincronismo NTP:${NC}          ${VERDE}Ativo e Sincronizado${NC}"
  else
    echo -e "  • ${NEGRITO}Sincronismo NTP:${NC}          ${AMARELO}$NTP_SYNC${NC}"
  fi
  echo -e "  • ${NEGRITO}Horário no PHP:${NC}           $PHP_DATE"
  echo -e "  • ${NEGRITO}Horário no MariaDB (CDR):${NC} ${MYSQL_NOW:-Não foi possível consultar}"
  echo ""

  if [[ "$OS_TZ" == "Etc/UTC" || "$OS_TZ" == "UTC" ]]; then
    warn "ATENÇÃO: O servidor está em UTC (+00:00)! Os relatórios de chamadas (CDR) ficarão +3h adiantados em relação a Brasília."
  elif [[ "$OS_TZ" == America/* ]]; then
    ok "O servidor já utiliza um fuso horário das Américas ($OS_TZ)."
  fi
}

clear
mostrar_diagnostico_horario

if [ "$CHECK_ONLY" -eq 1 ]; then
  exit 0
fi

if [ "$AUTO_SP" -eq 1 ]; then
  TZ_SELECIONADO="America/Sao_Paulo"
  DESC_TZ="Horário Oficial de Brasília (UTC-03:00)"
else
  titulo "SELECIONE O FUSO HORÁRIO DO BRASIL"
  echo ""
  echo -e "  ${NEGRITO}1)${NC} ${VERDE}America/Sao_Paulo${NC}   — Horário de Brasília (UTC-03:00) ${NEGRITO}[Padrão / Recomendado]${NC}"
  echo "     (SP, RJ, MG, PR, SC, RS, DF, GO, ES, BA, SE, AL, PE, PB, RN, CE, PI, MA, PA, AP, TO)"
  echo -e "  ${NEGRITO}2)${NC} ${AZUL}America/Cuiaba${NC}      — Mato Grosso e Mato Grosso do Sul (UTC-04:00)"
  echo "     (MT, MS)"
  echo -e "  ${NEGRITO}3)${NC} ${AZUL}America/Manaus${NC}      — Amazônia Ocidental (UTC-04:00)"
  echo "     (AM, RR, RO)"
  echo -e "  ${NEGRITO}4)${NC} ${AZUL}America/Rio_Branco${NC}  — Acre e Sudoeste do Amazonas (UTC-05:00)"
  echo "     (AC)"
  echo -e "  ${NEGRITO}5)${NC} ${AZUL}America/Noronha${NC}     — Fernando de Noronha (UTC-02:00)"
  echo -e "  ${NEGRITO}6)${NC} ${AZUL}America/Fortaleza${NC}   — Nordeste (CE, RN, PB, PI, MA — UTC-03:00)"
  echo -e "  ${NEGRITO}7)${NC} ${AZUL}America/Recife${NC}      — Pernambuco (PE — UTC-03:00)"
  echo -e "  ${NEGRITO}8)${NC} ${AZUL}America/Bahia${NC}       — Bahia (BA — UTC-03:00)"
  echo -e "  ${NEGRITO}9)${NC} ${AZUL}America/Belem${NC}       — Pará e Amapá (PA, AP — UTC-03:00)"
  echo -e "  ${NEGRITO}0)${NC} Sair sem alterar"
  echo ""
  read -p "  Escolha o fuso horário [1]: " OPT_TZ
  OPT_TZ=${OPT_TZ:-1}

  case "$OPT_TZ" in
    1) TZ_SELECIONADO="America/Sao_Paulo";  DESC_TZ="Horário de Brasília (UTC-03:00)" ;;
    2) TZ_SELECIONADO="America/Cuiaba";     DESC_TZ="Mato Grosso / MS (UTC-04:00)" ;;
    3) TZ_SELECIONADO="America/Manaus";     DESC_TZ="Amazônia (UTC-04:00)" ;;
    4) TZ_SELECIONADO="America/Rio_Branco"; DESC_TZ="Acre (UTC-05:00)" ;;
    5) TZ_SELECIONADO="America/Noronha";    DESC_TZ="Fernando de Noronha (UTC-02:00)" ;;
    6) TZ_SELECIONADO="America/Fortaleza";  DESC_TZ="Nordeste / Fortaleza (UTC-03:00)" ;;
    7) TZ_SELECIONADO="America/Recife";     DESC_TZ="Pernambuco / Recife (UTC-03:00)" ;;
    8) TZ_SELECIONADO="America/Bahia";      DESC_TZ="Bahia / Salvador (UTC-03:00)" ;;
    9) TZ_SELECIONADO="America/Belem";      DESC_TZ="Pará / Belém (UTC-03:00)" ;;
    0)
      info "Nenhuma alteração realizada."
      exit 0
      ;;
    *)
      erro "Opção inválida."
      ;;
  esac
fi

if [ ! -f "/usr/share/zoneinfo/$TZ_SELECIONADO" ]; then
  erro "Arquivo de fuso horário /usr/share/zoneinfo/$TZ_SELECIONADO não encontrado neste sistema."
fi

titulo "APLICANDO FUSO HORÁRIO: $TZ_SELECIONADO ($DESC_TZ)"

# 1. Ajustar fuso no Linux e ativar NTP
info "Configurando fuso horário do Sistema Operacional para $TZ_SELECIONADO..."
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone "$TZ_SELECIONADO" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$TZ_SELECIONADO" /etc/localtime
  timedatectl set-ntp true 2>/dev/null || true
else
  ln -sf "/usr/share/zoneinfo/$TZ_SELECIONADO" /etc/localtime
fi
echo "$TZ_SELECIONADO" > /etc/timezone 2>/dev/null || true
ok "Fuso horário do Linux configurado para $TZ_SELECIONADO."

# 2. Atualizar todos os php.ini (Apache, CLI, FPM)
info "Atualizando diretiva date.timezone nos arquivos php.ini..."
PHP_COUNT=0
for PHP_INI in /etc/php/*/apache2/php.ini /etc/php/*/cli/php.ini /etc/php/*/fpm/php.ini /etc/php.ini; do
  [ -f "$PHP_INI" ] || continue
  if grep -qE "^;?[[:space:]]*date\.timezone[[:space:]]*=" "$PHP_INI" 2>/dev/null; then
    sed -i -E "s|^;?[[:space:]]*date\.timezone[[:space:]]*=.*|date.timezone = $TZ_SELECIONADO|" "$PHP_INI"
  else
    echo "date.timezone = $TZ_SELECIONADO" >> "$PHP_INI"
  fi
  PHP_COUNT=$((PHP_COUNT + 1))
done
ok "Diretiva date.timezone = $TZ_SELECIONADO aplicada em $PHP_COUNT arquivo(s) php.ini."

# 3. Reiniciar serviços para assumirem o novo fuso (sem derrubar chamadas SIP)
info "Reiniciando MariaDB, Apache, PHP-FPM e Cron para aplicar o fuso nos relatórios e CDRs..."
info "(Nota: Reiniciar MariaDB e Apache é rápido e NÃO derruba chamadas SIP em andamento no Asterisk)"

systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || warn "Aviso ao reiniciar MariaDB."
ok "MariaDB reiniciado com o novo fuso horário."

PHPFPM_SVC=$(systemctl list-unit-files --type=service 2>/dev/null | grep -oE "php[0-9.]+-fpm\.service" | head -1)
if [ -n "$PHPFPM_SVC" ]; then
  systemctl restart "$PHPFPM_SVC" 2>/dev/null || true
fi

systemctl restart apache2 2>/dev/null || systemctl restart httpd 2>/dev/null || warn "Aviso ao reiniciar Apache."
ok "Apache reiniciado com o novo fuso horário."

systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true
ok "Serviço Cron reiniciado."

echo ""
read -p "  Deseja também reiniciar o Asterisk agora para atualizar os logs internos do PBX? (derruba chamadas ativas) [s/N]: " RESTART_AST
if [[ "$RESTART_AST" =~ ^[Ss]$ ]]; then
  systemctl restart asterisk 2>/dev/null && ok "Asterisk reiniciado." || warn "Aviso ao reiniciar Asterisk."
else
  info "Asterisk mantido sem restart (assumirá na próxima recarga/janela)."
fi

# 4. Exibir validação final
mostrar_diagnostico_horario
ok "Horário do servidor ajustado e sincronizado com sucesso!"
echo ""
exit 0
