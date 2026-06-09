# AGENTS.md — Voxcorp Setup

> Regras de comportamento para agentes AI (Antigravity, Cursor, Claude Code, Windsurf, Copilot) trabalhando no projeto `voxcorp-setup`. **Leia este arquivo antes de gerar ou modificar qualquer script.**
>
> Para detalhes técnicos sobre MagnusBilling (bugs, schema, comandos), consulte **`MAGNUS_BUGS.md`** e **`MAGNUS_REFERENCE.md`** no mesmo diretório.

**Owner:** Edgar — Voxcorp Telecom (EMB Serviços em Telecomunicações)
**Stack alvo:** MagnusBilling 7.x sobre Debian 10/11
**Linguagem do código:** Bash + SQL + Markdown, comentários em **pt-BR**

---

## 1. Propósito do projeto

Coleção versionada de scripts e procedimentos que padronizam a instalação, customização, troubleshooting e manutenção de servidores MagnusBilling em produção VoIP. Consolida o conhecimento operacional acumulado em servidores reais Voxcorp.

---

## 2. Inventário de servidores Voxcorp

| Servidor | IP | Papel |
|---|---|---|
| 136 | 186.194.49.136 | TESTE/dev (Proxmox Edgar) — será descomissionado |
| 119 | 190.89.250.119 | TESTE oficial novo (Magnus 7.8.5.6 limpo) |
| 120 | 190.89.250.120 | **PRODUÇÃO OSS Voxcorp** — criticidade alta |
| 142 | 186.194.49.142 | **PRODUÇÃO TSF** — recebe chamadas do 120 |

**Blocos IP autorizados:** `190.89.250.0/24` e `186.194.49.0/24`

---

## 3. Padrões obrigatórios Voxcorp

Todo script deve respeitar estes padrões (não negociáveis):

### SSH
- Porta **22022** (NUNCA 22)
- Restrito aos blocos Voxcorp via firewalld rich-rules

### Firewall — firewalld (DEFINITIVO)
**Verificado em 08/06/2026 no servidor 119 pós-`install.sh` oficial:**
- O `install.sh` oficial do Magnus em Debian 10/11 **instala e habilita firewalld**, não iptables-persistent
- Não criar `/etc/iptables/`, não usar `iptables-persistent`
- **Sempre usar `firewall-cmd`**, nunca regras iptables raw (exceto via `firewall-cmd --direct` quando absolutamente necessário)
- A wiki/iptables.rst do GitHub Magnus é documentação educacional/histórica — não reflete o instalador real em Debian

**Padrões para a zona public:**
- Default-deny (REJECT icmp-host-prohibited no final)
- Portas vindas do install.sh: `ssh service` + `22/tcp`, `22022/tcp`, `80/tcp`, `443/tcp`, `5060/udp`, `10000-60000/udp`
- Customizar: **remover porta 22** (manter só 22022), restringir SSH 22022 e MySQL 3306 aos blocos Voxcorp via rich-rules, adicionar IAX 4569/udp se usar
- Anti-scanner SIP via `firewall-cmd --direct` (DROP `friendly-scanner` e `VaxSIPUserAgent` em 5060/5080 TCP+UDP)
- Fail2ban integrado com `banaction = firewallcmd-multiport` (padrão Magnus)

**⚠️ Cuidado crítico ao modificar firewall:**
- Nunca remover regra que libera SSH antes da nova rich-rule estar ativa
- Usar `firewall-cmd --runtime-to-permanent` só após validar em runtime
- Recomendado: console KVM/Proxmox aberto antes de qualquer `--reload`

### MySQL/MariaDB
- `mbillingUser@localhost` + `mbillingUser@127.0.0.1` para PHP do Magnus
- `voxcorp@<IP_VPN_ADMIN>` com `ALL ON *.* WITH GRANT OPTION` (DBeaver)
- `apiuser@<IP_N8N>` com `ALL ON *.* WITH GRANT OPTION` (N8N)
- Senha sempre com plugin `mysql_native_password` (ver Bug 5 em MAGNUS_BUGS.md)
- `dbhost = 127.0.0.1` em `res_config_mysql.conf` (PADRÃO Magnus, NÃO trocar)

### Permissões dos arquivos `*_magnus*.conf`
**Todo arquivo `/etc/asterisk/*_magnus*.conf` deve ter `chmod 664` e dono `asterisk:asterisk`**, com `www-data` no grupo `asterisk`. Permissão errada quebra regeneração silenciosamente. Detalhes em MAGNUS_BUGS.md (Bug 2).

### Customizações de dialplan
Vão em `extensions_custom.conf` separado (incluído via `#include` no `extensions.conf`). **NUNCA editar `extensions_magnus.conf`** — Magnus sobrescreve.

### Tabelas customizadas Voxcorp (preservar em migrações)
- `pkg_password_reset`, `pkg_tickets`, `pkg_ticket_messages` (SaaS clientes)
- `pkg_vox_clientes_config` (exclusivo do OSS 120)
- `pkg_banned_ips`, `pkg_tables_changes`

---

## 4. Convenções de código

### Cabeçalho obrigatório (todo script bash)

```bash
#!/bin/bash
# =====================================================================
# Voxcorp Setup — <nome>.sh
# Versão: X.Y (data)
# Função: <uma linha do que faz>
# Autor: Voxcorp Telecom
#
# Pré-requisitos: <lista>
# Uso: bash <nome>.sh [--dry-run] [--help]
#
# Idempotência: SIM/NÃO (e por quê)
# Modifica estado: SIM/NÃO (se SIM, listar)
# Requer janela de manutenção: SIM/NÃO
# =====================================================================
```

### Funções padronizadas (cores e logs)

```bash
VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'

ok()    { echo -e "  ${VERDE}✓${NC} $1"; }
info()  { echo -e "  ${AZUL}➜${NC} $1"; }
warn()  { echo -e "  ${AMARELO}⚠${NC} $1"; }
erro()  { echo -e "  ${VERMELHO}✗ ERRO:${NC} $1"; exit 1; }
titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }

confirma() {
  read -p "  $1 [s/N]: " RESP
  [[ "$RESP" =~ ^[Ss]$ ]] || { erro "Cancelado"; }
}
```

### MySQL sem expor senha (regra crítica)

**SEMPRE** usar `MYSQL_PWD` via env, **NUNCA** `--password=` na linha (vaza em `ps aux`):

```bash
mysql_run() {
  MYSQL_PWD="$DB_PASS" mysql --user="$DB_USER" -h "$DB_HOST" -D "$DB_NAME" "$@"
}
```

### Logs

- Diretório: `/var/log/voxcorp-setup/` (chmod 750)
- Arquivos: `<script>-YYYYMMDD_HHMMSS.log` (chmod 640)

### Regras gerais

- Read-only por padrão; flag `--apply` ou `--dry-run` para modificar
- Confirmação obrigatória antes de operação destrutiva (`confirma()`)
- Validar pré-requisitos antes de modificar (`set -o pipefail`)
- Senhas via `read -s` ou ler de `/root/passwordMysql.log`
- Senhas geradas: **evitar `$ ! ' " \ ` e espaço** (quebram bash/SQL)
- Idempotência sempre que possível

---

## 5. O que o agente NUNCA deve fazer

1. ❌ **Rodar `update.sh` em produção** sem janela de manutenção declarada
2. ❌ **`chmod -R 555` em `/var/www/html/mbilling/`** — bloqueia regeneração
3. ❌ **`TRUNCATE pkg_firewall`** sem confirmar — pode ter regras válidas
4. ❌ **Embutir senha em script versionado** — usar `<SENHA_AQUI>` ou prompt
5. ❌ **Mudar `dbhost` de `127.0.0.1` para `localhost`** — manter padrão Magnus
6. ❌ **`DROP DATABASE mbilling`** sem backup prévio confirmado
7. ❌ **Trocar firewalld por iptables puro** — firewalld é padrão Magnus em Debian 10/11
8. ❌ **Quebrar `chmod 664` dos `*_magnus*.conf`** — quebra regeneração
9. ❌ **Editar `extensions_magnus.conf`** — Magnus sobrescreve; usar `extensions_custom.conf`
10. ❌ **`mysql --password=`** na linha de comando — usar `MYSQL_PWD` env
11. ❌ **Modificar regras firewalld em produção sem console KVM aberto** — risco de auto-bloqueio
12. ❌ **Misturar configuração de firewall em scripts de migração** — separar responsabilidades

---

## 6. Lições operacionais (vindas de produção)

- **Direto ao ponto:** preferir SQL no `mysql>` (heredoc ou interativo) em vez de scripts bash com `read -s`. Scripts longos têm bugs sutis com caracteres especiais em senha.
- **Senha sem caracteres especiais:** `$ ! ' " \ ` + espaço quebram heredocs bash e SQL.
- **Backup antes de migrar:** sempre `mysqldump --routines --triggers --events --single-transaction` antes de `DROP DATABASE`.
- **Console KVM/Proxmox aberto** ao mexer em firewall ou SSH em produção.
- **Janela de manutenção é exigida** para: `update.sh`, restart Asterisk, troca de senha mbillingUser, mudança de porta SSH em produção.
- **chan_sip não é PJSIP:** Magnus 7.x usa chan_sip. Comandos `pjsip show` e configs `pjsip.conf` não aplicam.
- **Migração CentOS→Debian** muda dono/permissões (Apache vira `www-data`). Revisar sempre.
- **firewalld pós-instalador Magnus** vem com porta 22 aberta — remover quando padronizar para 22022.
- **firewall-cmd --reload** pode derrubar conexões TCP existentes durante o flush das regras — usar com console alternativo aberto.

---

## 7. Estrutura do repositório

```
voxcorp-setup/
├── AGENTS.md                          # Este arquivo (regras do agente)
├── MAGNUS_BUGS.md                     # Catálogo de bugs Magnus
├── MAGNUS_REFERENCE.md                # Schema + comandos + padrões
├── README.md                          # Visão geral + quickstart
├── CHANGELOG.md                       # Versões dos scripts
├── .gitignore                         # *.log, senhas, .bak.*
├── scripts/
│   ├── lib/common.sh                  # Funções compartilhadas (futuro)
│   ├── diagnostico/
│   │   └── magnus-health-check.sh     # v3 — verificação read-only
│   ├── manutencao/
│   │   ├── alterar_bloco_did.sh       # v4 — reatribuir DIDs
│   │   ├── deletar_cdr_oferta.sh      # limpeza CDR
│   │   └── corrigir-permissoes.sh     # chmod 664 nos *_magnus*.conf
│   ├── migracao/
│   │   └── migrar_magnus.sh           # v5.1 — só dados (sem firewall/SSL)
│   └── configuracao/
│       ├── configurar_firewalld_voxcorp.sh  # futuro — firewall blindado
│       ├── configurar_ssl_voxcorp.sh        # futuro — Apache + Let's Encrypt
│       └── configurar_seguranca_diaria.sh   # futuro — cron + logrotate
├── docs/
│   ├── bugs-magnus-conhecidos.md
│   ├── customizacoes-pos-install.md
│   └── runbooks/
└── configs/
    └── asterisk/
        └── inbound-cid-normalize.conf # Contexto de normalização CID Brasil
```

---

## 8. Comportamento esperado do agente

Ao trabalhar neste repositório, o agente deve:

1. **Ler AGENTS.md + MAGNUS_BUGS.md + MAGNUS_REFERENCE.md primeiro** antes de qualquer modificação
2. **Manter idempotência** sempre que possível (`CREATE TABLE IF NOT EXISTS`, `chmod` repetível)
3. **Nunca commitar senhas reais** — usar `<SENHA_AQUI>`, `<IP_VPN>` como placeholders
4. **Sempre incluir cabeçalho padrão** (seção 4) ao criar scripts novos
5. **Read-only por padrão** — operações destrutivas exigem flag `--apply` + confirmação
6. **Documentar bugs novos** em `MAGNUS_BUGS.md` quando aparecerem
7. **Linguagem pt-BR** em código, comentários e documentação
8. **Commits semânticos:** `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`
9. **Antes de modificar arquivo existente:** ler `CHANGELOG.md` para histórico
10. **Em dúvida sobre Magnus:** consultar `MAGNUS_BUGS.md` ou `MAGNUS_REFERENCE.md` antes de pesquisar fora
11. **Em scripts que mexem em firewall:** sempre apresentar plano em `--check` antes de `--apply`, e exigir confirmação explícita

---

**Última atualização:** 8 de junho de 2026 (firewalld confirmado como padrão definitivo)
**Mantenedor:** Edgar — Voxcorp Telecom
