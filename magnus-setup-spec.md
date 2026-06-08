# Projeto: Magnus Utilities

**Owner:** Edgar (Comunidade MagnusBilling — EMB Serviços em Telecomunicações)
**Tipo:** Repositório Git privado (preparado para futura abertura)
**Estado:** Especificação inicial — junho 2026

---

## 1. Visão e propósito

Coleção de scripts e procedimentos versionados que padronizam a instalação, customização, troubleshooting e manutenção de servidores **MagnusBilling 7.x sobre Debian 10/11** em operações de VoIP.

O projeto consolida o conhecimento operacional acumulado pela equipe Admin em produção, transformando-o em scripts auditáveis, reutilizáveis e idempotentes, que substituem procedimentos manuais propensos a erro.

**Objetivos:**

- Reduzir o tempo de provisionamento de um Magnus novo ou restaurado de horas para minutos.
- Documentar e padronizar customizações Admin em qualquer ambiente Magnus.
- Detectar e corrigir desvios de configuração ("drift") em servidores existentes.
- Servir de referência operacional auditável para outros administradores.
- Preservar conhecimento histórico sobre bugs do Magnus 7.x e workarounds aplicados.

**Fora de escopo (por enquanto):**

- Instalação do Magnus do zero a partir de ISO (assume Magnus já instalado pelo script oficial do Adilson Magnus).
- Versões anteriores do Magnus (6.x, 5.x).
- CentOS, Ubuntu, RHEL ou outros SOs além de Debian 10/11.
- Asterisk PJSIP (foco em chan_sip, que é o que o Magnus 7.x usa).

---

## 2. Ambiente alvo

| Item | Versão / detalhe |
|---|---|
| SO | Debian 10 (Buster) ou 11 (Bullseye) |
| Magnus | 7.8.5.6 (cobrir 7.x em geral) |
| Asterisk | 13.x (vem com Magnus) |
| Banco | MariaDB 10.3 |
| PHP | 7.3-fpm |
| Firewall | firewalld (instalação oficial Magnus) |

**Convenções de rede e SSH adotadas pela Admin:**

- SSH apenas na porta **22022** (nunca 22).
- Blocos IP autorizados: `1.2.3.0/24` e `5.6.7.0/24` (referência — devem ser parametrizáveis por servidor).
- IP de administração (VPN do operador): variável por instalação.

---

## 3. Inventário inicial de scripts

Estes são os scripts que existem hoje no desktop do Edgar (`C:\Users\edgar\OneDrive\Admin - Geral\DEVOPS\setup\`) e que entram no commit inicial:

| Script | Função | Estado atual |
|---|---|---|
| `magnus-health-check.sh` | Verificação read-only de saúde Magnus + Asterisk | **v3** (criada em 08/06/2026, pronta para incluir) |
| `restaurar_magnus.sh` | Migração/restauração de Magnus entre servidores via SSH + rsync + mysqldump | **v4.0** (script de 350 linhas, precisa revisão para escopo) |
| `alterar_bloco_did.sh` | Alteração em lote de bloco de DIDs | Não revisado ainda |
| `deletar_cdr_oferta.sh` | Limpeza de CDR e ofertas | Não revisado ainda |

**Ação para a IDE:** ler cada script, identificar duplicações, padronizar cabeçalho, comentários, funções comuns (`ok/warn/erro/titulo`).

**Scripts a serem criados** (já mapeados como necessidade pela operação Admin):

| Script | Função | Prioridade |
|---|---|---|
| `magnus-pos-restauracao.sh` | Aplica as 17 customizações pós-restauração Admin | Alta |
| `corrigir-permissoes-magnus.sh` | `chmod 664` em todos os `*_magnus*.conf` | Alta |
| `liberar-dbeaver.sh` | Cria usuário MySQL externo (`admin_user@IP`) + abre firewall | Alta |
| `backup-magnus-diario.sh` | Backup `mysqldump` automatizado via cron | Média |
| `migrar-banco-magnus.sh` | Versão enxuta para migração só de tabelas customizadas | Média |

---

## 4. Estrutura proposta do repositório

```
magnus-utils/
├── README.md                          # Visão geral + quickstart
├── LICENSE                            # Decidir: MIT/Apache 2.0/proprietária
├── CHANGELOG.md                       # Versão e mudanças
├── .gitignore                         # node_modules, *.log, senhas, etc
│
├── docs/
│   ├── arquitetura-admin_user.md         # Inventário 120/142/119, padrões SSH/firewall
│   ├── customizacoes-pos-install.md   # As 17 customizações documentadas
│   ├── bugs-magnus-conhecidos.md      # Catálogo de bugs + workarounds
│   │                                  #   (truncamento char(20), permissão 644,
│   │                                  #    plugin vazio MariaDB 10.3, etc)
│   └── runbooks/
│       ├── restaurar-magnus.md
│       ├── liberar-dbeaver.md
│       ├── corrigir-permissoes.md
│       └── ...
│
├── scripts/
│   ├── lib/
│   │   └── common.sh                  # Funções compartilhadas: ok, warn, erro,
│   │                                  #   titulo, confirma, backup_iptables, etc
│   │
│   ├── diagnostico/
│   │   └── magnus-health-check.sh     # v3
│   │
│   ├── instalacao/
│   │   └── magnus-pos-restauracao.sh # Customizações Admin
│   │
│   ├── manutencao/
│   │   ├── corrigir-permissoes-magnus.sh
│   │   ├── liberar-dbeaver.sh
│   │   ├── backup-magnus-diario.sh
│   │   ├── alterar-bloco-did.sh       # Migrado do desktop
│   │   └── deletar-cdr-oferta.sh      # Migrado do desktop
│   │
│   └── migracao/
│       └── restaurar-magnus.sh        # Migrado do desktop, v4.0
│
├── configs/
│   ├── firewalld/                     # Rich rules e direct rules padrão Admin
│   ├── iptables/                      # Regras anti-scanner SIP
│   ├── apache/                        # VirtualHosts modelo (com SSL Let's Encrypt)
│   ├── asterisk/
│   │   ├── extensions_custom.conf.tpl # Para feature codes Admin
│   │   └── inbound-cid-normalize.conf # Contexto de normalização CID Brasil
│   └── cron/
│       └── magnus-backup-diario.cron
│
└── tests/
    └── README.md                      # Como rodar smoke tests num lab
```

---

## 5. Convenções de código (Bash)

**Cabeçalho obrigatório em todo script:**

```bash
#!/bin/bash
# =====================================================================
# Magnus Utilities — <nome do script>
# Versão: X.Y (data)
# Função: <uma linha do que faz>
# Autor: Comunidade MagnusBilling
#
# Pré-requisitos:
#   - <lista>
#
# Uso: bash <nome>.sh [opções]
#
# Idempotência: SIM/NÃO
# Modifica estado do servidor: SIM/NÃO  (se SIM, listar o que modifica)
# Requer janela de manutenção: SIM/NÃO
# =====================================================================
```

**Funções compartilhadas (em `scripts/lib/common.sh`):**

```bash
# Cores e logs padronizados
VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;34m'; NEGRITO='\033[1m'; NC='\033[0m'

ok()     { echo -e "  ${VERDE}✓${NC} $1"; }
warn()   { echo -e "  ${AMARELO}⚠${NC} $1"; }
erro()   { echo -e "  ${VERMELHO}✗${NC} $1"; }
info()   { echo -e "  ${AZUL}ℹ${NC} $1"; }
titulo() { echo ""; echo -e "${NEGRITO}${AZUL}═══ $1 ═══${NC}"; }

# Confirmação obrigatória antes de operação destrutiva
confirma() {
  read -p "  $1 [s/N]: " RESP
  [[ "$RESP" =~ ^[Ss]$ ]] || { erro "Cancelado pelo usuário"; exit 1; }
}

# Backup antes de modificar arquivo de sistema
backup_arquivo() {
  local ARQ="$1"
  cp -p "$ARQ" "${ARQ}.bak.$(date +%Y%m%d_%H%M%S)"
}
```

**Regras gerais:**

- **Idempotência:** rodar duas vezes deve dar o mesmo resultado sem erro. Usar `CREATE TABLE IF NOT EXISTS`, `chmod` que aceita estado atual, `iptables -C` antes de `-A`, etc.
- **Sem senhas embutidas:** sempre `read -s` ou ler de arquivo seguro tipo `/root/passwordMysql.log`.
- **Sem caracteres especiais em senhas geradas:** evitar `$ ! ' " \` (lição aprendida em 29/05).
- **Read-only por padrão, com flag `--apply` para modificar:** scripts de diagnóstico mostram problemas mas não corrigem sem `--apply`.
- **Validar pré-requisitos antes de modificar:** se algo falhar, sair sem efeitos colaterais (`set -e` ou checagem explícita).
- **Log de execução:** scripts que modificam estado devem escrever em `/var/log/magnus-utils/<script>-<timestamp>.log`.

---

## 6. Padrões Admin documentados

Estes padrões devem ser respeitados por todos os scripts (vêm das memórias persistentes acumuladas):

**Banco de dados:**

- Manter `dbhost = 127.0.0.1` em `res_config_mysql.conf` (padrão Magnus).
- Garantir regra `iptables -A INPUT -i lo -j ACCEPT` antes de qualquer DROP.
- Usuário PHP do Magnus: `mbillingUser@localhost` + `mbillingUser@127.0.0.1` (socket Unix e TCP loopback).
- Usuários externos: `admin_user@<IP_VPN>` (DBeaver, admin total), `apiuser@<IP_N8N>` (API, admin total).
- Bug MariaDB 10.3: após `CREATE USER`, plugin pode ficar vazio. Sempre aplicar `ALTER USER ... IDENTIFIED VIA mysql_native_password USING PASSWORD('senha')` na sequência.

**Firewall:**

- firewalld é padrão (vem com o instalador oficial Magnus). Não migrar para iptables puro.
- Zona public default-deny (`REJECT icmp-host-prohibited` no final).
- Portas liberadas: SSH 22022 (só blocos Admin), MySQL 3306 (só blocos Admin), HTTP 80, HTTPS 443, SIP UDP 5060, RTP UDP 10000-60000, IAX UDP 4569 (opcional).
- Anti-scanner SIP via direct rules: DROP `friendly-scanner` e `VaxSIPUserAgent` em 5060/5080 TCP+UDP.
- Fail2ban integrado (jails `sshd` e `asterisk-iptables`).

**Asterisk / Magnus:**

- Magnus 120 (e similares) NÃO usa SIP realtime. Lê de arquivos `sip_magnus*.conf` via `#include` no `sip.conf`.
- Permissões obrigatórias dos arquivos regenerados pelo Magnus: `chmod 664`, dono `asterisk:asterisk`, com `www-data` no grupo `asterisk`.
- Arquivos regenerados pelo Magnus (lista completa em `magnus-health-check.sh`):
  `sip_magnus.conf`, `sip_magnus_user.conf`, `sip_magnus_register.conf`,
  `iax_magnus*.conf` (3 arquivos), `queues_magnus.conf`,
  `extensions_magnus.conf`, `extensions_magnus_did.conf`,
  `musiconhold_magnus.conf`, `voicemail_magnus.conf`.
- Customizações de dialplan devem ir em `extensions_custom.conf` separado (criado pela Admin e incluído via `#include` no `extensions.conf`), nunca em `extensions_magnus.conf` (que o Magnus sobrescreve).

**Estados do Magnus (`pkg_user.active`):**

- `1` = ativo
- `4` = bloqueado por inadimplência (ramal ainda gerado no Asterisk; chamadas bloqueadas via AGI)
- `0` ou `NULL` = cancelado (ramal removido do arquivo)

**Bugs conhecidos do Magnus 7.x a documentar:**

1. `pkg_trunk.context` é `char(20)` — nomes maiores são truncados silenciosamente.
2. Regeneração de arquivos `*_magnus*.conf` falha silenciosa se `www-data` não tiver `g+w`. Log: `LinuxAccess::exec -> touch` em `application.log`.
3. `update.sh` sem `chmod +x` por padrão.
4. `pkg_queue_member.paused` não aparece em `queue show` do Asterisk (precisa filtrar separado).

---

## 7. Roadmap em milestones

**Milestone 1 — Fundação (semana 1)**

- Criar repositório `magnus-utils` no GitHub (privado).
- Commit inicial com README, LICENSE, estrutura de pastas.
- Migrar os 4 scripts atuais do desktop para `scripts/`.
- Criar `scripts/lib/common.sh` com funções padronizadas.
- Adaptar `magnus-health-check.sh` v3 para usar `common.sh`.

**Milestone 2 — Documentação base (semana 2)**

- `docs/arquitetura-admin_user.md` com inventário e padrões.
- `docs/bugs-magnus-conhecidos.md` com os 4 bugs catalogados.
- `docs/customizacoes-pos-install.md` (lista das 17 customizações).
- Runbook do `magnus-health-check.sh` (interpretação dos outputs).

**Milestone 3 — Scripts novos críticos (semana 3-4)**

- `corrigir-permissoes-magnus.sh` (com `--check` e `--apply`).
- `liberar-dbeaver.sh` (parametrizado por IP do operador).
- `magnus-pos-restauracao.sh` (aplica padrões em servidor recém instalado).

**Milestone 4 — Refinamentos (futuro)**

- Backup automatizado diário.
- Scripts de migração enxutos.
- Testes em ambiente de lab.
- Considerar publicar como open-source.

---

## 8. Instruções para a IDE / agente AI

Quando trabalhar neste projeto, o agente deve:

1. **Antes de modificar qualquer script existente**, ler o conteúdo completo dele e o `CHANGELOG.md` para entender o histórico.
2. **Nunca embutir senhas, IPs reais de produção, ou hashes** em arquivos versionados. Usar placeholders `<SENHA_AQUI>`, `<IP_VPN>`, etc.
3. **Manter idempotência:** se for adicionar lógica nova, garantir que rodar duas vezes não quebre nada.
4. **Sempre incluir o cabeçalho padrão** (seção 5) com versão e data atualizada.
5. **Operações destrutivas exigem confirmação explícita** via função `confirma()` da `common.sh`.
6. **Diagnóstico antes de correção:** seguir o padrão do `magnus-health-check.sh` (read-only por padrão, flag `--apply` para corrigir).
7. **Documentar bugs descobertos no Magnus** em `docs/bugs-magnus-conhecidos.md` quando aparecerem.
8. **Não rodar scripts em servidores reais sem explicitamente perguntar** se há janela de manutenção e backup feito.
9. **Linguagem do código e comentários: português (pt-BR)** — alinhado com a equipe Admin e a comunidade Magnus brasileira.
10. **Commits semânticos:** `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`.

---

## 9. Definição de "pronto" para o Milestone 1

Considera-se Milestone 1 concluído quando:

- [ ] Repositório criado no GitHub do Edgar/Admin (privado).
- [ ] README.md explica o projeto e quickstart.
- [ ] 4 scripts originais migrados para a estrutura, com cabeçalho padronizado.
- [ ] `scripts/lib/common.sh` criado e funcional.
- [ ] `magnus-health-check.sh` v3 rodando idêntico ao atual mas usando `common.sh`.
- [ ] `.gitignore` cobrindo arquivos sensíveis (`*.log`, senhas, `.bak.*`).
- [ ] LICENSE escolhida.
- [ ] Edgar consegue clonar em qualquer servidor Admin e rodar `bash scripts/diagnostico/magnus-health-check.sh` sem ajustes.

---

**Próximos passos imediatos para o Edgar:**

1. Criar o repositório no GitHub com nome `magnus-utils` (privado).
2. Clonar localmente.
3. Anexar os 3 scripts não revistos no chat (`alterar_bloco_did.sh`, `deletar_cdr_oferta.sh`, `restaurar_magnus.sh`) para análise individual e padronização.
4. Decidir licença (sugestão inicial: proprietária com nota "uso interno Admin" até decidir abrir).
