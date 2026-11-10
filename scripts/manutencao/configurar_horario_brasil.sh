#!/bin/bash
# =====================================================================
# Magnus Utilities — configurar_horario_brasil.sh
# Versão: 2.0 (10 de novembro de 2026)
# Função: Verificar e ajustar o fuso horário (Timezone) e sincronismo NTP
#         do servidor (Linux, PHP php.ini + magnusbilling.ini, MariaDB,
#         Asterisk e Cron) para os fusos oficiais do Brasil, corrigindo
#         divergências de horário (+3h UTC) nos CDRs e painel do MB8/MB7.
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
# Modifica estado: SIM (fuso horário do SO, php.ini, magnusbilling.ini, NTP e reload)
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

  local OS_TZ OS_DATE NTP_SYNC PHP_DATE PHP_TZ MAGNUS_INI_TZ MYSQL_NOW
  OS_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || date +"%Z")
  OS_DATE=$(date "+%Y-%m-%d %H:%M:%S (%Z / UTC%z)")
  NTP_SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "desconhecido")

  if command -v php >/dev/null 2>&1; then
    PHP_TZ=$(php -r "echo date_default_timezone_get();" 2>/dev/null)
    PHP_DATE=$(php -r "echo date('Y-m-d H:i:s (e / \U\T\CP)');" 2>/dev/null)
  else
    PHP_TZ="desconhecido"
    PHP_DATE="PHP não encontrado"
  fi

  # No MagnusBilling 8, o install.sh cria /etc/php/X.Y/mods-available/magnusbilling.ini
  # que é carregado DEPOIS do php.ini (via conf.d/20-magnusbilling.ini) e sobrescreve date.timezone!
  MAGNUS_INI_TZ=$(grep -hE "^[[:space:]]*date\.timezone" /etc/php/*/mods-available/magnusbilling.ini /etc/php/*/*/conf.d/*magnusbilling*.ini 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '[:space:]')

  MYSQL_NOW=$(mysql_query "SELECT CONCAT(NOW(), ' (Sistema DB: ', @@system_time_zone, ' / Global: ', @@global.time_zone, ')');")

  echo ""
  echo -e "  • ${NEGRITO}Fuso do Sistema (Linux):${NC}      $OS_TZ"
  echo -e "  • ${NEGRITO}Horário do Linux:${NC}             $OS_DATE"
  if [ "$NTP_SYNC" = "yes" ]; then
    echo -e "  • ${NEGRITO}Sincronismo NTP:${NC}              ${VERDE}Ativo e Sincronizado${NC}"
  else
    echo -e "  • ${NEGRITO}Sincronismo NTP:${NC}              ${AMARELO}$NTP_SYNC${NC}"
  fi
  echo -e "  • ${NEGRITO}Horário no PHP (AGI/CDR):${NC}     $PHP_DATE"
  if [ -n "$MAGNUS_INI_TZ" ]; then
    echo -e "  • ${NEGRITO}Override magnusbilling.ini:${NC}   $MAGNUS_INI_TZ"
  fi
  echo -e "  • ${NEGRITO}Horário no MariaDB:${NC}           ${MYSQL_NOW:-Não foi possível consultar}"
  echo ""

  if [[ "$OS_TZ" == "Etc/UTC" || "$OS_TZ" == "UTC" ]]; then
    warn "ATENÇÃO: O Linux está em UTC (+00:00)!"
  fi
  if [[ "$PHP_TZ" == "Etc/UTC" || "$PHP_TZ" == "UTC" ]]; then
    warn "ATENÇÃO CRÍTICA: O PHP está em '$PHP_TZ'! Como o AGI do MagnusBilling (CalcAgi.php / DidAgi.php)"
    warn "grava o starttime do CDR usando date('Y-m-d H:i:s') do PHP, as chamadas ficam +3h adiantadas!"
  elif [ "$PHP_TZ" != "$OS_TZ" ]; then
    warn "DIVERGÊNCIA: O Linux está em '$OS_TZ', mas o PHP está em '$PHP_TZ'!"
  elif [[ "$OS_TZ" == America/* ]] && [[ "$PHP_TZ" == "$OS_TZ" ]]; then
    ok "Linux, PHP (AGI/Web) e MariaDB estão alinhados no fuso $OS_TZ."
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

# 2. Atualizar TODOS os php.ini E os overrides do MagnusBilling 8 (mods-available/magnusbilling.ini e conf.d)
info "Atualizando date.timezone no php.ini e em /etc/php/*/mods-available/magnusbilling.ini..."
PHP_COUNT=0

# 2a. Arquivos php.ini principais (Apache, CLI, FPM, CGI)
for PHP_INI in /etc/php/*/apache2/php.ini /etc/php/*/cli/php.ini /etc/php/*/fpm/php.ini /etc/php/*/cgi/php.ini /etc/php.ini; do
  [ -f "$PHP_INI" ] || continue
  if grep -qE "^;?[[:space:]]*date\.timezone[[:space:]]*=" "$PHP_INI" 2>/dev/null; then
    sed -i -E "s|^;?[[:space:]]*date\.timezone[[:space:]]*=.*|date.timezone = $TZ_SELECIONADO|" "$PHP_INI"
  else
    echo "date.timezone = $TZ_SELECIONADO" >> "$PHP_INI"
  fi
  PHP_COUNT=$((PHP_COUNT + 1))
done

# 2b. Arquivos de módulos/overrides (.ini em mods-available, conf.d e php.d)
# CRÍTICO NO MB8: O install.sh do MagnusBilling 8 cria /etc/php/8.2/mods-available/magnusbilling.ini
# com 'date.timezone = Etc/UTC' (que é carregado via conf.d/20-magnusbilling.ini DEPOIS do php.ini)!
OVERRIDE_COUNT=0
for EXTRA_INI in /etc/php/*/mods-available/*.ini /etc/php/*/*/conf.d/*.ini /etc/php.d/*.ini; do
  [ -f "$EXTRA_INI" ] || continue
  # Evita editar duas vezes o mesmo arquivo caso seja symlink para mods-available
  REAL_INI=$(readlink -f "$EXTRA_INI" 2>/dev/null || echo "$EXTRA_INI")
  if grep -qE "^;?[[:space:]]*date\.timezone[[:space:]]*=" "$REAL_INI" 2>/dev/null; then
    sed -i -E "s|^;?[[:space:]]*date\.timezone[[:space:]]*=.*|date.timezone = $TZ_SELECIONADO|" "$REAL_INI"
    OVERRIDE_COUNT=$((OVERRIDE_COUNT + 1))
  fi
done

ok "Diretiva date.timezone = $TZ_SELECIONADO aplicada em $PHP_COUNT php.ini e $OVERRIDE_COUNT módulo(s)/override(s) (incluindo magnusbilling.ini)."

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

# Se não houver chamadas ativas, reinicia o Asterisk automaticamente para atualizar o processo pai do AGI
ACTIVE_CALLS=$(asterisk -rx "core show calls" 2>/dev/null | grep -i "active call" | awk '{print $1}')
if [[ "${ACTIVE_CALLS:-0}" =~ ^[0-9]+$ ]] && [ "${ACTIVE_CALLS:-0}" -eq 0 ]; then
  systemctl restart asterisk 2>/dev/null && ok "Asterisk reiniciado automaticamente (0 chamadas ativas)." || true
else
  echo ""
  read -p "  Existem ${ACTIVE_CALLS:-0} chamada(s) ativa(s). Deseja reiniciar o Asterisk agora? [s/N]: " RESTART_AST
  if [[ "$RESTART_AST" =~ ^[Ss]$ ]]; then
    systemctl restart asterisk 2>/dev/null && ok "Asterisk reiniciado." || warn "Aviso ao reiniciar Asterisk."
  else
    info "Asterisk mantido sem restart (o PHP AGI já usará o novo fuso imediatamente a cada nova chamada)."
  fi
fi

# 4. Verificar se existem CDRs gravados com horário no futuro (+3h UTC de hoje) e oferecer correção
FUTURE_CDRS=$(mysql_query "SELECT COUNT(*) FROM mbilling.pkg_cdr WHERE starttime > DATE_ADD(NOW(), INTERVAL 10 MINUTE);" | tr -d '[:space:]')
if [[ "${FUTURE_CDRS:-0}" =~ ^[0-9]+$ ]] && [ "${FUTURE_CDRS:-0}" -gt 0 ]; then
  echo ""
  warn "Detectamos ${FUTURE_CDRS} chamada(s) no Extrato de Chamadas (pkg_cdr) com horário no FUTURO"
  warn "(gravadas antes deste ajuste, quando o PHP ainda estava em UTC +3h)."
  read -p "  Deseja corrigir automaticamente o horário dessas ${FUTURE_CDRS} chamada(s) (-3h) no banco? [S/n]: " FIX_CDR
  FIX_CDR=${FIX_CDR:-S}
  if [[ "$FIX_CDR" =~ ^[Ss]$ ]]; then
    mysql_query "UPDATE mbilling.pkg_cdr SET starttime = DATE_SUB(starttime, INTERVAL 3 HOUR) WHERE starttime > DATE_ADD(NOW(), INTERVAL 10 MINUTE);"
    mysql_query "UPDATE mbilling.pkg_cdr_failed SET starttime = DATE_SUB(starttime, INTERVAL 3 HOUR) WHERE starttime > DATE_ADD(NOW(), INTERVAL 10 MINUTE);"
    ok "Horário das chamadas anteriores corrigido (-3h) em pkg_cdr e pkg_cdr_failed!"
  fi
fi

# 5. Exibir validação final
mostrar_diagnostico_horario
ok "Horário do servidor (Linux + PHP AGI/Web + MariaDB) ajustado e sincronizado com sucesso!"
echo ""
exit 0
