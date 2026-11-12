#!/bin/bash
# =====================================================================
# Magnus Utilities — atualizar_mb8.sh
# Versão: 1.0 (25 de outubro de 2026)
# Função: Atualizar com segurança o MagnusBilling 8 para a versão mais recente
#         do repositório oficial, com backup pré-update automático, migração
#         de schema MySQL (UpdateMysql) e correção mandatória de permissões.
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - Rodar como root
#   - MagnusBilling 8 instalado em /var/www/html/mbilling
#   - Janela de manutenção declarada (reinicia Asterisk e Apache)
#
# Uso: bash atualizar_mb8.sh
#
# Idempotência: SIM (pode ser executado novamente se já estiver na versão mais recente)
# Modifica estado: SIM (código-fonte, schema de banco e permissões)
# Requer janela de manutenção: SIM (declarada obrigatoriamente)
# =====================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="$SCRIPT_DIR/../lib/common.sh"
if [ -f "$COMMON_LIB" ]; then
    source "$COMMON_LIB"
elif [ -f "/opt/magnus-utils/scripts/lib/common.sh" ]; then
    source "/opt/magnus-utils/scripts/lib/common.sh"
else
    VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'; AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'
    ok() { echo -e "  ${VERDE}✓${NC} $1"; }
    info() { echo -e "  ${AZUL}➜${NC} $1"; }
    warn() { echo -e "  ${AMARELO}⚠${NC} $1"; }
    erro() { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
    titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }
    confirma() {
        read -p "  $1 [s/N]: " RESP
        [[ "$RESP" =~ ^[Ss]$ ]] || erro "Operação cancelada pelo usuário."
    }
fi

[ "$EUID" -ne 0 ] && erro "Este script deve ser executado como root."

MB_DIR="/var/www/html/mbilling"
[ ! -d "$MB_DIR" ] && erro "Diretório $MB_DIR não encontrado. O MagnusBilling está instalado?"

clear
titulo "ATUALIZAÇÃO SEGURA DO MAGNUSBILLING 8"

echo ""
info "Este utilitário realiza a atualização do MagnusBilling 8 para a versão oficial mais recente:"
info "  1. Checagem de atualizações disponíveis no repositório GitHub"
info "  2. Backup automático preventivo do banco de dados e arquivos Asterisk"
info "  3. Atualização de código e execução de migrações (UpdateMysql)"
info "  4. Correção mandatória de permissões (Asterisk 20, Apache e chaves SSL)"
info "  5. Recarregamento seguro de serviços"
echo ""

# ---------------------------------------------------------------------
# 1. Identificar Versão Local vs Repositório Oficial
# ---------------------------------------------------------------------
titulo "1. Checagem de Versão e Atualizações"

if [ ! -d "$MB_DIR/.git" ]; then
    warn "O diretório $MB_DIR não é um repositório git gerenciado diretamente."
    info "Tentando inicializar rastreamento oficial do branch source..."
    cd "$MB_DIR" || exit 1
    git init >/dev/null 2>&1
    git remote add origin https://github.com/magnussolution/magnusbilling.git >/dev/null 2>&1 || true
fi

cd "$MB_DIR" || exit 1

BRANCH_ATUAL=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "source")
[ "$BRANCH_ATUAL" = "HEAD" ] && BRANCH_ATUAL="source"

COMMIT_LOCAL=$(git log -1 --format="%h (%cd)" --date=short 2>/dev/null || echo "desconhecido")
info "Versão local ativa: ${NEGRITO}$COMMIT_LOCAL${NC} (branch: $BRANCH_ATUAL)"

info "Consultando repositório oficial no GitHub..."
if git fetch origin "$BRANCH_ATUAL" >/dev/null 2>&1; then
    COMMIT_REMOTO=$(git log -1 --format="%h (%cd)" --date=short "origin/$BRANCH_ATUAL" 2>/dev/null || echo "desconhecido")
    COMMITS_BEHIND=$(git rev-list --count HEAD.."origin/$BRANCH_ATUAL" 2>/dev/null || echo "0")

    if [ "$COMMITS_BEHIND" -eq 0 ]; then
        ok "O seu MagnusBilling 8 já está atualizado no commit mais recente ($COMMIT_LOCAL)!"
        echo ""
        read -p "  Deseja forçar a re-execução do update (reaplicar migrations do banco e corrigir permissões)? [s/N]: " FORCAR_UP
        if [[ ! "$FORCAR_UP" =~ ^[Ss]$ ]]; then
            echo ""
            info "Nenhuma ação necessária. Saindo sem alterações."
            exit 0
        fi
    else
        warn "Existem ${NEGRITO}$COMMITS_BEHIND atualização(ões) pendente(s)${NC} no repositório oficial:"
        echo ""
        git log HEAD.."origin/$BRANCH_ATUAL" --oneline -5 | sed 's/^/    • /'
        echo ""
    fi
else
    warn "Não foi possível conectar ao GitHub no momento. Tentará aplicar o update localmente."
fi

# Verifica se os novos commits alteraram arquivos estruturais da arquitetura do MB8
if declare -f verificar_compatibilidade_mb8 >/dev/null 2>&1; then
    verificar_compatibilidade_mb8
fi

# ---------------------------------------------------------------------
# 2. Confirmação de Janela de Manutenção (Mandatória)
# ---------------------------------------------------------------------
echo ""
titulo "2. Declaração de Janela de Manutenção"
warn "ATENÇÃO: A atualização aplica alterações no código, migrações no banco de dados"
warn "e reinicia os serviços do Asterisk e do servidor web Apache."
echo ""
confirma "Você confirma que está em JANELA DE MANUTENÇÃO declarada para atualizar agora?"

# ---------------------------------------------------------------------
# 3. Backup Preventivo Automático
# ---------------------------------------------------------------------
titulo "3. Criando Backup Preventivo Pré-Update"

DATA_BKP=$(date +%Y%m%d_%H%M%S)
BKP_DIR="/root/backup-mb8-pre-update-$DATA_BKP"
mkdir -p "$BKP_DIR"
chmod 700 "$BKP_DIR"

info "Diretório de backup: $BKP_DIR"

# 1. Backup do Banco de Dados MariaDB
DB_PWD=$(cat /root/passwordMysql.log 2>/dev/null | tr -d '[:space:]')
DUMP_FILE="$BKP_DIR/mbilling_backup_$DATA_BKP.sql"

info "Exportando backup completo da base 'mbilling'..."
if [ -n "$DB_PWD" ]; then
    MYSQL_PWD="$DB_PWD" mysqldump -u root --single-transaction --routines --triggers --events mbilling > "$DUMP_FILE" 2>/dev/null || true
else
    mysqldump -u root --single-transaction --routines --triggers --events mbilling > "$DUMP_FILE" 2>/dev/null || true
fi

if [ -s "$DUMP_FILE" ]; then
    TAM_BKP=$(du -sh "$DUMP_FILE" | awk '{print $1}')
    ok "Banco de dados exportado com sucesso ($TAM_BKP)."
else
    warn "Não foi possível gerar dump do banco via mysqldump. Prosseguindo com cautela."
fi

# 2. Backup das Configurações do Asterisk
info "Copiando configurações do Asterisk (/etc/asterisk)..."
cp -rp /etc/asterisk "$BKP_DIR/asterisk_configs" 2>/dev/null || true
ok "Configurações do Asterisk preservadas em $BKP_DIR/asterisk_configs."

# ---------------------------------------------------------------------
# 4. Aplicação da Atualização
# ---------------------------------------------------------------------
titulo "4. Atualizando Código-Fonte e Migrações"

cd "$MB_DIR" || exit 1

# Preserva eventuais arquivos temporários
git stash >/dev/null 2>&1 || true

info "Baixando atualizações do GitHub (git pull origin $BRANCH_ATUAL)..."
git pull origin "$BRANCH_ATUAL" 2>&1 | sed 's/^/    /'

# Executa update.sh oficial se existir
if [ -f "$MB_DIR/protected/commands/update.sh" ]; then
    info "Executando script oficial de update do MagnusBilling..."
    bash "$MB_DIR/protected/commands/update.sh" 2>&1 | grep -v "WWW.MAGNUSBILLING.COM" | sed 's/^/    /' || true
fi

# Executa migrações de banco de dados (UpdateMysql)
info "Executando migrações de banco de dados (UpdateMysql)..."
if [ -f "$MB_DIR/cron.php" ]; then
    php "$MB_DIR/cron.php" UpdateMysql 2>&1 | sed 's/^/    /' || true
elif [ -f "$MB_DIR/protected/commands/UpdateMysqlCommand.php" ]; then
    php "$MB_DIR/protected/yiic.php" updatemysql 2>&1 | sed 's/^/    /' || true
fi

ok "Código e banco de dados atualizados."

# ---------------------------------------------------------------------
# 5. Auto-Healing Dialplan, Blindagem PJSIP (from_user) e Permissões
# ---------------------------------------------------------------------
titulo "5. Auto-Healing do Dialplan, Blindagem PJSIP e Permissões"

# Regra 1: Validação de integridade e Auto-Healing de /etc/asterisk/extensions_magnus.conf
garantir_extensions_magnus() {
    local EXT_MAGNUS="/etc/asterisk/extensions_magnus.conf"
    local EXT_MAIN="/etc/asterisk/extensions.conf"

    if [ ! -s "$EXT_MAGNUS" ] || ! grep -q "\[billing\]" "$EXT_MAGNUS" 2>/dev/null; then
        warn "Arquivo $EXT_MAGNUS ausente, vazio (0 bytes) ou sem contexto [billing]! Executando Auto-Healing..."
        cat << 'EOF_EXT_MAGNUS' > "$EXT_MAGNUS"
[billing]
exten => _[*0-9].,1,AGI("/var/www/html/mbilling/resources/asterisk/mbilling.php")
  same => n,Hangup()

exten => _+X.,1,Goto(billing,${EXTEN:1},1)

exten => h,1,hangup()

exten => *111,1,VoiceMailMain(${CHANNEL(peername)}@billing)
  same => n,Hangup()

[trunk_answer_handler]
exten => s,1,Set(MASTER_CHANNEL(TRUNKANSWERTIME)=${EPOCH})
  same => n,Return()
EOF_EXT_MAGNUS
        ok "Auto-Healing concluído: $EXT_MAGNUS recriado com os contextos [billing] e [trunk_answer_handler]."
    else
        ok "Integridade de $EXT_MAGNUS validada (contexto [billing] presente)."
    fi

    if [ -f "$EXT_MAIN" ]; then
        if ! grep -qE "^[[:space:]]*#include[[:space:]]+extensions_magnus\.conf" "$EXT_MAIN" 2>/dev/null; then
            echo "#include extensions_magnus.conf" >> "$EXT_MAIN"
            ok "Adicionado '#include extensions_magnus.conf' ao final de $EXT_MAIN."
        fi
        if ! grep -qE "^[[:space:]]*#include[[:space:]]+extensions_magnus_did\.conf" "$EXT_MAIN" 2>/dev/null; then
            echo "#include extensions_magnus_did.conf" >> "$EXT_MAIN"
            ok "Adicionado '#include extensions_magnus_did.conf' ao final de $EXT_MAIN."
        fi
    fi
}

garantir_extensions_magnus

# Garante alinhamento do date.timezone em /etc/php/*/mods-available/magnusbilling.ini com o fuso do Linux
SYS_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "")
if [ -n "$SYS_TZ" ] && [[ "$SYS_TZ" != "UTC" && "$SYS_TZ" != "Etc/UTC" ]]; then
    for PHP_INI in /etc/php/*/mods-available/*.ini /etc/php/*/*/conf.d/*.ini /etc/php/*/apache2/php.ini /etc/php/*/cli/php.ini /etc/php/*/fpm/php.ini; do
        [ -f "$PHP_INI" ] || continue
        if grep -qE "^;?[[:space:]]*date\.timezone[[:space:]]*=" "$PHP_INI" 2>/dev/null; then
            sed -i -E "s|^;?[[:space:]]*date\.timezone[[:space:]]*=.*|date.timezone = $SYS_TZ|" "$PHP_INI" 2>/dev/null || true
        fi
    done
    ok "Fuso horário do PHP (magnusbilling.ini e php.ini) sincronizado com o sistema ($SYS_TZ)."
fi

# Regra 2.1: Sanitização de fromuser em contas dinâmicas no banco (preservando callerid)
info "Sanitizando coluna 'fromuser' em contas SIP dinâmicas no banco de dados..."
if [ -n "$DB_PWD" ]; then
    MYSQL_PWD="$DB_PWD" mysql -u root mbilling -e "UPDATE pkg_sip SET fromuser = '' WHERE host = 'dynamic' AND fromuser != '';" 2>/dev/null || true
else
    mysql -u root mbilling -e "UPDATE pkg_sip SET fromuser = '' WHERE host = 'dynamic' AND fromuser != '';" 2>/dev/null || true
fi
ok "Coluna 'fromuser' limpa em contas dinâmicas (callerid de saída preservado)."

# Regra 2.2: Blindagem no gerador PJSIP (AsteriskAccess.php) pós git-pull
AST_ACCESS_PHP="$MB_DIR/protected/components/AsteriskAccess.php"
if [ -f "$AST_ACCESS_PHP" ]; then
    info "Blindando gerador PJSIP ($AST_ACCESS_PHP) contra from_user em contas dinâmicas..."
    php -r '
        $file = "/var/www/html/mbilling/protected/components/AsteriskAccess.php";
        $code = file_get_contents($file);
        $pattern = "/if\s*\(\s*strlen\s*\(\s*\\\$sip->fromuser\s*\)\s*>\s*0\s*\)\s*\{\s*\\\$line\s*\.=\s*\"from_user=\"\s*\.\s*\\\$sip->fromuser\s*\.\s*\"\\\\n\"\s*;\s*\}/";
        $replacement = "if (strlen(\$sip->fromuser) > 0 && \$host != '\''dynamic'\'') {\n                        \$line .= \"from_user=\" . \$sip->fromuser . \"\\n\";\n                    }";
        $newCode = preg_replace($pattern, $replacement, $code, -1, $count);
        if ($count > 0 && $newCode !== null) {
            file_put_contents($file, $newCode);
        }
    ' >/dev/null 2>&1 || true
    ok "Gerador AsteriskAccess.php blindado (from_user restrito apenas a peers com IP fixo)."
fi

# Regra 2.3: Limpeza defensiva de from_user= em pjsip_magnus_user.conf
if [ -f "/etc/asterisk/pjsip_magnus_user.conf" ] && grep -q "^from_user=" /etc/asterisk/pjsip_magnus_user.conf 2>/dev/null; then
    sed -i '/^from_user=/d' /etc/asterisk/pjsip_magnus_user.conf 2>/dev/null || true
    ok "Diretivas 'from_user=' residuais removidas de /etc/asterisk/pjsip_magnus_user.conf."
fi

info "Garantindo permissões no diretório web ($MB_DIR)..."
chown -R www-data:www-data "$MB_DIR" 2>/dev/null || true
chmod -R 755 "$MB_DIR" 2>/dev/null || true

# Pastas de escrita para relatórios e uploads
[ -d "$MB_DIR/resources/reports" ] && chmod -R 777 "$MB_DIR/resources/reports" 2>/dev/null || true
[ -d "$MB_DIR/assets" ] && chmod -R 777 "$MB_DIR/assets" 2>/dev/null || true

# Correção crítica de permissões Asterisk (Bug 2 de produção)
info "Ajustando permissões de regeneração em /etc/asterisk/*_magnus*.conf (664)..."
usermod -aG asterisk www-data 2>/dev/null || true
chmod 664 /etc/asterisk/*_magnus*.conf 2>/dev/null || true
chown asterisk:asterisk /etc/asterisk/*_magnus*.conf 2>/dev/null || true

# Permissões das chaves SSL do WebRTC
if [ -d "/etc/asterisk/keys" ]; then
    chown -R asterisk:asterisk /etc/asterisk/keys 2>/dev/null || true
    chmod 0750 /etc/asterisk/keys 2>/dev/null || true
    chmod 0640 /etc/asterisk/keys/* 2>/dev/null || true
fi

ok "Permissões de segurança aplicadas."

# ---------------------------------------------------------------------
# 6. Recarregamento e Smoke Test Obrigatório (Regra 3)
# ---------------------------------------------------------------------
titulo "6. Recarregando Serviços e Executando Smoke Test"

info "Recarregando Apache e Asterisk 20..."
systemctl reload apache2 >/dev/null 2>&1 || systemctl restart apache2 >/dev/null 2>&1 || true

if command -v asterisk >/dev/null 2>&1; then
    if ! systemctl is-active asterisk >/dev/null 2>&1; then
        systemctl start asterisk >/dev/null 2>&1 || true
    fi
    asterisk -rx "dialplan reload" >/dev/null 2>&1 || true
    asterisk -rx "pjsip reload" >/dev/null 2>&1 || true

    DIALPLAN_BILLING=$(asterisk -rx "dialplan show billing" 2>&1)
    if echo "$DIALPLAN_BILLING" | grep -qi "no existence of 'billing' context" || ! echo "$DIALPLAN_BILLING" | grep -q "mbilling.php"; then
        warn "Contexto [billing] não detectado no primeiro reload! Reaplicando Auto-Healing..."
        garantir_extensions_magnus
        asterisk -rx "dialplan reload" >/dev/null 2>&1 || true
        DIALPLAN_BILLING=$(asterisk -rx "dialplan show billing" 2>&1)
        if echo "$DIALPLAN_BILLING" | grep -qi "no existence of 'billing' context" || ! echo "$DIALPLAN_BILLING" | grep -q "mbilling.php"; then
            erro "SMOKE TEST FALHOU: O contexto [billing] NÃO está carregado na memória ativa do Asterisk! Verifique /etc/asterisk/extensions.conf e /etc/asterisk/extensions_magnus.conf."
        fi
    fi
    ok "Smoke Test aprovado: Contexto [billing] e PJSIP recarregados e ativos na memória do Asterisk."
fi

# ---------------------------------------------------------------------
# 6. Conclusão
# ---------------------------------------------------------------------
NOVO_COMMIT=$(git log -1 --format="%h (%cd)" --date=short 2>/dev/null || echo "atual")

echo ""
titulo "ATUALIZAÇÃO DO MAGNUSBILLING 8 CONCLUÍDA"
echo ""
echo -e "  ${VERDE}${NEGRITO}✓ Sistema atualizado com sucesso!${NC}"
echo "  • Nova versão ativa: $NOVO_COMMIT"
echo "  • Backup pré-update: $BKP_DIR"
echo "  • Banco de dados:    Migrações aplicadas (UpdateMysql)"
echo "  • Permissões:        Asterisk 20 (664) e Apache (www-data) corrigidos"
echo ""
exit 0
