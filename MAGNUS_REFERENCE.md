# MAGNUS_REFERENCE.md

> Referência técnica do MagnusBilling 7.x: schema do banco, arquitetura de arquivos, comandos úteis e padrões SIP. Complementa `AGENTS.md` e `MAGNUS_BUGS.md`.

---

## 1. Arquitetura

MagnusBilling 7.x combina:

- **Backend PHP (Yii Framework)** em `/var/www/html/mbilling/`
- **Asterisk 13** como PBX usando **chan_sip** (**NÃO PJSIP**) em `/etc/asterisk/`
- **MariaDB 10.3** com banco `mbilling` (~94 tabelas + customizações Voxcorp)
- **Magnus regenera arquivos `.conf` do Asterisk** a partir das tabelas quando dados mudam na interface web
- **firewalld** instalado pelo `install.sh` oficial em Debian 10/11

**Característica central:** Magnus 7.x **NÃO usa SIP realtime**. O Asterisk lê de arquivos via `#include` no `sip.conf`. Isso explica:

- Por que mudar trunk pela interface não aparece imediato (precisa regenerar arquivo)
- Por que permissões dos arquivos `*_magnus*.conf` são críticas (Bug 2)
- Por que reload do Asterisk é necessário após mudanças

---

## 2. Arquivos regenerados pelo Magnus

Estes 11 arquivos em `/etc/asterisk/` são regenerados pelo Magnus a partir do banco:

| Arquivo | Tabela do banco | Gera |
|---|---|---|
| `sip_magnus.conf` | `pkg_trunk` (providertech=sip) | Troncos SIP |
| `sip_magnus_user.conf` | `pkg_sip` + `pkg_user` | Ramais SIP |
| `sip_magnus_register.conf` | `pkg_trunk` (register=1) | Registros outbound SIP |
| `iax_magnus.conf` | `pkg_trunk` (providertech=iax) | Troncos IAX |
| `iax_magnus_user.conf` | `pkg_iax` | Ramais IAX |
| `iax_magnus_register.conf` | `pkg_iax` (register) | Registros outbound IAX |
| `queues_magnus.conf` | `pkg_queue` + `pkg_queue_member` | Filas e agentes |
| `extensions_magnus.conf` | `pkg_ivr` + outros | URAs, contextos, ramais didactic |
| `extensions_magnus_did.conf` | `pkg_did` | DIDs entrantes |
| `musiconhold_magnus.conf` | configurações | Música de espera |
| `voicemail_magnus.conf` | configurações | Voicemail |

Todos devem ter `chmod 664`, dono `asterisk:asterisk`, com `www-data` no grupo `asterisk`.

Includes no `sip.conf` principal:
```
#include sip_magnus_register.conf
#include sip_magnus_user.conf
#include sip_magnus.conf
```

---

## 3. Schema das tabelas principais

### `pkg_trunk`
Troncos SIP/IAX para roteamento de chamadas.

| Coluna | Tipo | Notas |
|---|---|---|
| `id` | int (PK) | |
| `trunkcode` | varchar(50) | Nome único do trunk |
| `host` | varchar(100) | IP do peer |
| `context` | **char(20)** | ⚠️ TRUNCA SILENCIOSAMENTE (ver Bug 1) |
| `providertech` | char(20) | `sip` ou `iax` |
| `status` | int | 1=ativo, 4=bloqueado |
| `type` | varchar | `peer` ou `friend` |
| `insecure`, `nat`, `qualify` | | Parâmetros chan_sip |

### `pkg_sip`
Ramais SIP (clientes/agentes).

| Coluna | Tipo | Notas |
|---|---|---|
| `id` | int (PK) | |
| `name` | varchar | ID do ramal |
| `accountcode` | varchar | |
| `id_user` | int (FK) | Referência a `pkg_user.id` |
| `host` | varchar | Geralmente `dynamic` |
| `status` | smallint | 1=ativo, 4=bloqueado |
| `regseconds`, `ipaddr`, `port`, `useragent` | | Preenchidos por cron — podem zerar se sincronia quebra |

### `pkg_queue_member`
Membros das filas.

| Coluna | Tipo | Notas |
|---|---|---|
| `id`, `uniqueid` | int | |
| `id_user`, `membername` | | |
| `queue_name` | varchar(128) | FK textual para `pkg_queue.name` |
| `interface` | varchar(128) | Formato `SIP/<ramal>` |
| `penalty` | int | |
| `paused` | tinyint | 0=ativo, 1=pausado (ver Bug 4) |

### `pkg_user`
Clientes/usuários do billing.

| Coluna | Tipo | Notas |
|---|---|---|
| `id` | int (PK) | |
| `username`, `email` | varchar | |
| `active` | tinyint | 1=ativo, 4=inadimplente, 0/NULL=cancelado |
| `id_plan` | int | Plano de billing |

### `pkg_did` / `pkg_did_destination`
Catálogo de DIDs entrantes e suas rotas.

- `pkg_did`: lista de números entrantes
- `pkg_did_destination`: rotas de cada DID
  - `voip_call=9` para SIP custom (destino tipo `SIP/<num>@<ip>:<porta>`)

### `pkg_cdr` / `pkg_cdr_failed`
Registros de chamadas.

| Coluna | Tipo | Notas |
|---|---|---|
| `starttime` | timestamp | |
| `callerid`, `calledstation` | varchar | |
| `sessiontime` | int | Duração em segundos |
| `disposition` | varchar | ANSWERED, BUSY, NOANSWER, FAILED |
| `hangupcause` | int | Código Q.850 |

---

## 4. Comandos de referência

### Diagnóstico geral

```bash
# Versão Magnus
mysql mbilling -e "SELECT config_value FROM pkg_configuration WHERE config_key='version';"

# Health check completo (script Voxcorp, read-only)
bash /root/magnus-health-check.sh

# Erros recentes do Magnus
tail -200 /var/www/html/mbilling/protected/runtime/application.log | grep -iE "error|exception"

# Versão Asterisk
asterisk -rx "core show version"

# Uptime Asterisk
asterisk -rx "core show uptime"
```

### Trunks e ramais

```bash
# Trunks ativos no banco
mysql mbilling -e "SELECT id, trunkcode, host, context, status FROM pkg_trunk WHERE status=1;"

# Trunks no arquivo (entradas [nome])
grep "^\[" /etc/asterisk/sip_magnus.conf | wc -l

# Ramais ATIVOS esperados (lógica correta — IMPORTANTE)
mysql mbilling -e "
  SELECT COUNT(*) FROM pkg_sip s
  INNER JOIN pkg_user u ON s.id_user=u.id
  WHERE u.active IN (1,4);
"

# Estado de um peer específico
asterisk -rx "sip show peer <ramal>"

# Listar todos peers
asterisk -rx "sip show peers"

# Histórico Reachable/Unreachable
grep "<ramal>" /var/log/asterisk/messages* | grep -iE "reachable|unreachable"
```

### Filas

```bash
# Membros visíveis (não pausados)
asterisk -rx "queue show <NOME_FILA>"

# Membros no banco (todos, incluindo pausados)
mysql mbilling -e "SELECT * FROM pkg_queue_member WHERE queue_name='<NOME_FILA>';"

# Reload de filas no Asterisk
asterisk -rx "queue reload all"
```

### SIP debug

```bash
# Ligar debug em peer específico
asterisk -rx "sip set debug peer <ramal>"

# Ligar debug em IP específico
asterisk -rx "sip set debug ip <IP>"

# Desligar
asterisk -rx "sip set debug off"

# Forçar qualify imediato
asterisk -rx "sip qualify peer <ramal>"
```

### Recargas no Asterisk (não derruba chamadas em curso)

```bash
asterisk -rx "sip reload"
asterisk -rx "dialplan reload"
asterisk -rx "queue reload all"
```

### MySQL (sempre com MYSQL_PWD em scripts)

```bash
# Listar usuários e plugins
mysql -e "SELECT User, Host, plugin FROM mysql.user ORDER BY User, Host;"

# Grants de um usuário
mysql -e "SHOW GRANTS FOR 'voxcorp'@'190.89.250.123';"

# bind-address (deve ser 0.0.0.0 — padrão Voxcorp)
grep bind-address /etc/mysql/mariadb.conf.d/50-server.cnf
```

### Backup manual

```bash
# Backup completo com routines/triggers/events
mysqldump --routines --triggers --events --single-transaction --quick mbilling \
  | gzip > /root/mbilling-$(date +%Y%m%d_%H%M%S).sql.gz

# Apenas as 3 tabelas customizadas Voxcorp
mysqldump mbilling pkg_password_reset pkg_tickets pkg_ticket_messages \
  > /root/voxcorp-tables-$(date +%Y%m%d).sql
```

### firewalld (padrão Magnus em Debian 10/11)

```bash
# Estado atual
firewall-cmd --state
systemctl is-active firewalld
systemctl is-enabled firewalld

# Listar tudo na zona padrão
firewall-cmd --get-default-zone
firewall-cmd --list-all

# Rich rules (regras com origem específica)
firewall-cmd --list-rich-rules

# Direct rules (anti-scanner SIP, regras raw)
firewall-cmd --direct --get-all-rules

# Adicionar rich rule (exemplo: SSH 22022 só do bloco Voxcorp)
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="190.89.250.0/24" port port="22022" protocol="tcp" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="186.194.49.0/24" port port="22022" protocol="tcp" accept'

# Adicionar anti-scanner SIP via direct rules
for STRING in "friendly-scanner" "VaxSIPUserAgent"; do
  for PROTO in tcp udp; do
    for PORT in 5060 5080; do
      firewall-cmd --permanent --direct --add-rule ipv4 filter INPUT 0 \
        -p $PROTO --dport $PORT -m string --string "$STRING" --algo bm -j DROP
    done
  done
done

# Remover porta 22 (manter só 22022)
firewall-cmd --permanent --remove-port=22/tcp
firewall-cmd --permanent --remove-service=ssh

# Aplicar mudanças (CUIDADO em produção — pode derrubar SSH)
firewall-cmd --reload

# Ver regras iptables geradas pelo firewalld (read-only, não modificar diretamente)
iptables -L INPUT -n -v --line-numbers
```

**⚠️ Cuidado crítico ao modificar firewalld em produção remota:**
- Sempre ter console KVM/Proxmox aberto antes de `--reload`
- Adicionar nova rich-rule ANTES de remover a regra antiga que liberava SSH
- Usar `firewall-cmd --runtime-to-permanent` só após validar em runtime
- O `--reload` faz flush das regras iptables geradas, conexões TCP em trânsito podem cair

### Fail2ban (integrado com firewalld via firewallcmd-multiport)

```bash
# Estado e jails ativos
fail2ban-client status

# Status de um jail específico
fail2ban-client status sshd
fail2ban-client status asterisk

# Desbanir IP
fail2ban-client set sshd unbanip <IP>

# Ver configuração do banaction (deve ser firewallcmd-multiport)
grep -E "banaction|backend" /etc/fail2ban/jail.local
```

---

## 5. Padrões SIP nos arquivos gerados

### Estrutura típica de trunk em `sip_magnus.conf`

```ini
[NOME_TRUNK]
disallow=all
allow=g729,alaw
directmedia=no
context=billing                     ; ou contexto custom ≤20 chars
dtmfmode=RFC2833
insecure=port,invite
nat=force_rport,comedia
qualify=yes
type=peer
host=190.89.250.47
sendrpid=no
```

### Estrutura típica de ramal em `sip_magnus_user.conf`

```ini
[<numero_ramal>]
accountcode=<accountcode>
defaultuser=<numero_ramal>
fromuser=<numero_ramal>
secret=<senha>
host=dynamic
fromdomain=dynamic
disallow=all
allow=g729
allow=alaw
directmedia=no
context=billing
dtmfmode=rfc2833
```

### Codecs comuns: `g729` (licenciado), `alaw` (Brasil), `ulaw` (EUA), `gsm`

---

## 6. extensions_custom.conf (dialplan custom)

**NUNCA editar `extensions_magnus.conf`** — Magnus sobrescreve. Customizações vão em `/etc/asterisk/extensions_custom.conf` (chmod 664, dono asterisk:asterisk), incluído via `#include` no `extensions.conf` principal. Após criar: `asterisk -rx "dialplan reload"`.

**Exemplo: contexto `cid-normalize-in`** (remove prefixo 55, nome ≤20 chars para não esbarrar no Bug 1):

```ini
[cid-normalize-in]
exten => _X.,1,NoOp(CID: ${CALLERID(num)})
 same => n,GotoIf($["${CALLERID(num):0:2}" = "55"]?strip:keep)
 same => n(strip),Set(CALLERID(num)=${CALLERID(num):2})
 same => n(keep),Goto(billing,${EXTEN},1)
```

---

## 7. Estado inicial do firewalld pós-instalador oficial

Verificado no 119 em 08/06/2026 após `install.sh` oficial em Debian 10. Zona `public` vem com: service `ssh`, service `dhcpv6-client`, portas `22/tcp`, `22022/tcp`, `80/tcp`, `443/tcp`, `5060/udp`, `10000-60000/udp`.

**Ajustes Voxcorp recomendados:**
1. Remover porta 22 (manter só 22022)
2. Restringir 22022 e MySQL 3306 ao bloco Voxcorp via rich-rule
3. Adicionar IAX 4569/udp se usar
4. Adicionar direct rules anti-scanner SIP (`friendly-scanner` + `VaxSIPUserAgent`)

---

## 8. Pontos de atenção em produção

- **120 (OSS Voxcorp) e 142 (TSF):** clientes finais. Mexer no 120 afeta 142. Janela + console KVM sempre.
- **Tabelas customizadas Voxcorp:** sempre incluir em dumps/migrações.
- **`extensions_magnus.conf` é regenerado** — customizações em `extensions_custom.conf` separado.
- **Migração CentOS→Debian:** revisar permissões em `/etc/asterisk/`, `/var/lib/asterisk/`, `/var/www/html/mbilling/` (Apache muda para `www-data`).
- **chan_sip vs PJSIP:** Magnus 7.x usa chan_sip. Comandos `pjsip show` e `pjsip.conf` não aplicam.
- **`firewall-cmd --reload` em SSH remoto** pode derrubar conexões TCP — usar com console KVM aberto.

---

**Última atualização:** 8 de junho de 2026 (firewalld confirmado como padrão definitivo)
**Mantenedor:** Edgar — Voxcorp Telecom
