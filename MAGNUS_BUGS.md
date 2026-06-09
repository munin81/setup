# MAGNUS_BUGS.md

> Catálogo de bugs conhecidos e estados do MagnusBilling 7.x, com sintomas, diagnóstico e solução. Complementa `AGENTS.md` e `MAGNUS_REFERENCE.md`.
>
> **Fonte:** conhecimento acumulado em servidores reais Voxcorp Telecom (120, 142, 136, 119) durante operação e migrações 2025-2026.

---

## Bug 1: `pkg_trunk.context` é `char(20)` — trunca silenciosamente

**Descrição:** Nomes de contexto com 21+ caracteres são truncados no INSERT/UPDATE sem aviso.

**Caso real:** contexto `inbound-cid-normalize` (21 chars) virou `inbound-cid-normaliz` (20). Asterisk procura pelo nome truncado, não acha no dialplan, retorna 404 Not Found.

**Sintomas:**
- Trunks dão 404 Not Found em chamadas inbound
- Discrepância: nome do contexto no `extensions_*.conf` ≠ valor em `pkg_trunk.context`

**Diagnóstico:**
```sql
SELECT id, trunkcode, context, LENGTH(context) AS len
FROM pkg_trunk
WHERE LENGTH(context) >= 19;
```

**Solução:** usar nomes ≤20 chars (ex: `cid-normalize-in`, 16 chars).

---

## Bug 2: Regeneração falha silenciosa sem `g+w` (mais frequente!)

**Descrição:** Se algum arquivo `*_magnus*.conf` perde a permissão `664` (cai para `644`), Magnus tenta `touch` antes de escrever e falha silenciosamente.

**Erro no `application.log`:**
```
LinuxAccess::exec -> touch /etc/asterisk/<arquivo>.conf
```

**Sintomas (críticos):**
- Dados gravam no banco mas não aparecem no Asterisk
- Trunks novos dão 401 Unauthorized
- Agentes não entram na fila (mesmo cadastrados pela interface)
- DIDs novos não roteiam
- Falsa impressão de "Magnus quebrado"
- Comparação banco vs arquivo mostra dessincronia

**Diagnóstico:**
```bash
# Verifica se www-data escreve em todos os arquivos críticos
for ARQ in /etc/asterisk/*_magnus*.conf; do
  sudo -u www-data test -w "$ARQ" && echo "OK $ARQ" || echo "FAIL $ARQ"
done

# Erros recentes no log Yii
tail -200 /var/www/html/mbilling/protected/runtime/application.log \
  | grep "LinuxAccess::exec"
```

**Correção:**
```bash
chmod 664 /etc/asterisk/*_magnus*.conf
chown asterisk:asterisk /etc/asterisk/*_magnus*.conf
usermod -aG asterisk www-data
systemctl reload apache2 php*-fpm
```

**Causa raiz frequente:** migração CentOS→Debian e/ou scripts antigos que fazem `chmod -R 555` em `/var/www/html/mbilling/` mexem em correlatas.

**Após corrigir:** forçar regeneração editando+salvando qualquer trunk/ramal/fila/DID na interface web.

---

## Bug 3: `update.sh` sem `chmod +x` por padrão

**Descrição:** Após instalação ou restauração, `/var/www/html/mbilling/protected/commands/update.sh` vem sem bit de execução.

**Sintoma:**
```
-bash: /var/www/html/mbilling/protected/commands/update.sh: Permission denied
```

**Solução:** `chmod +x /var/www/html/mbilling/protected/commands/update.sh`

**⚠️ Cuidado:** rodar `update.sh` em produção tem riscos:
- Reinicia Asterisk (derruba chamadas)
- Reescreve `.htaccess`
- Pode resetar permissões dos `*_magnus*.conf` (gerando Bug 2)
- Atualiza schema do banco
- Sobrescreve PHP

**Exigir janela de manutenção sempre.**

---

## Bug 4: `pkg_queue_member.paused` não aparece em `queue show`

**Descrição:** O comando `asterisk -rx "queue show"` **não lista membros pausados**.

**Sintoma:** Aparenta que o agente "sumiu", mas ele continua membro da fila.

**Diagnóstico correto para health check:**
```sql
-- Ativos (visíveis em queue show)
SELECT COUNT(*) FROM pkg_queue_member WHERE paused = 0 OR paused IS NULL;

-- Pausados (não visíveis, mas existem)
SELECT COUNT(*) FROM pkg_queue_member WHERE paused = 1;

-- Total
SELECT COUNT(*) FROM pkg_queue_member;
```

**Para comparar banco↔Asterisk:**
- Banco ativos = Asterisk `queue show` (devem bater)
- Banco pausados = no arquivo `queues_magnus.conf` mas não em `queue show`

---

## Bug 5: MariaDB 10.3 — `CREATE USER` deixa plugin vazio

**Descrição:** Após `CREATE USER 'voxcorp'@'IP' IDENTIFIED BY 'senha'`, o campo `plugin` em `mysql.user` pode ficar em branco, impedindo login externo.

**Sintoma:** DBeaver retorna `Access denied for user 'voxcorp'@'IP' (using password: YES)` mesmo com senha correta.

**Diagnóstico:**
```sql
SELECT User, Host, plugin FROM mysql.user WHERE User='voxcorp';
-- mostra: plugin = '' (vazio)
```

**Solução obrigatória:**
```sql
ALTER USER 'voxcorp'@'IP' IDENTIFIED VIA mysql_native_password USING PASSWORD('senha');
FLUSH PRIVILEGES;
```

**Procedimento direto e completo:**
```sql
-- Dentro do mysql>
DROP USER IF EXISTS 'voxcorp'@'190.89.250.123';
CREATE USER 'voxcorp'@'190.89.250.123' IDENTIFIED BY 'senha-sem-especiais';
GRANT ALL PRIVILEGES ON *.* TO 'voxcorp'@'190.89.250.123' WITH GRANT OPTION;
ALTER USER 'voxcorp'@'190.89.250.123' IDENTIFIED VIA mysql_native_password USING PASSWORD('senha-sem-especiais');
FLUSH PRIVILEGES;
SELECT User, Host, plugin FROM mysql.user WHERE User='voxcorp';
```

**Importante:** senha **sem** `$ ! ' " \ ` e espaço (quebram bash e SQL).

---

## Bug 6: `update.sh` antigo apaga `/var/www/html/mbilling/script/`

**Descrição:** Versões antigas do `update.sh` removem o diretório `script/`, perdendo o `database.sql` de referência.

**Solução:** usar `update2.sh` quando disponível, ou fazer backup do `script/` antes:
```bash
cp -rp /var/www/html/mbilling/script /root/mbilling-script-bak-$(date +%Y%m%d)
```

---

## Bug 7: HTTP 500 por `res_config_mysql.conf` + iptables

**Descrição:** Se `dbhost = 127.0.0.1` (padrão Magnus) E iptables não tem `ACCEPT -i lo` antes de DROPs, PHP timeout na conexão MySQL.

**Sintoma no `application.log`:**
```
SQLSTATE[HY000] [2002] Connection timed out
```

**Sintoma no browser:** HTTP 500 ao abrir o painel Magnus.

**Solução:** garantir `iptables -A INPUT -i lo -j ACCEPT` antes de qualquer DROP, OU usar firewalld (já tem isso por padrão).

**Verificação:**
```bash
iptables -S INPUT | grep "\-i lo"
# Deve aparecer ACCEPT antes de qualquer DROP

# Ou se for firewalld:
firewall-cmd --get-default-zone
firewall-cmd --list-all
```

---

## Estados de `pkg_user.active` (lógica Magnus)

Diferente de muitos sistemas que usam apenas 0/1, o Magnus usa 3 estados:

| Valor | Significado | Comportamento no Asterisk |
|---|---|---|
| `1` | Ativo | Ramal gerado normalmente em `sip_magnus_user.conf` |
| `4` | Bloqueado por inadimplência | Ramal **continua no Asterisk**, AGI bloqueia chamadas em runtime |
| `0` ou `NULL` | Cancelado/desativado | Ramal **removido** do arquivo |

**Para health check de sincronia banco↔arquivo:**

```sql
-- Ramais que DEVEM estar no sip_magnus_user.conf
SELECT COUNT(*) FROM pkg_sip s
INNER JOIN pkg_user u ON s.id_user = u.id
WHERE u.active IN (1, 4);
```

**Importante:** a coluna `pkg_sip.status` também tem valores 1 e 4, mas **o que filtra a geração é `pkg_user.active`**, não `pkg_sip.status`. Já errei isso antes — não confundir.

---

## Tabelas customizadas Voxcorp (não são bugs, mas devem ser preservadas)

Em qualquer migração/restore, preservar:

| Tabela | Função | Onde existe |
|---|---|---|
| `pkg_password_reset` | Reset de senha clientes SaaS | Todos os Magnus Voxcorp |
| `pkg_tickets` | Sistema de tickets clientes | Todos os Magnus Voxcorp |
| `pkg_ticket_messages` | Mensagens dos tickets | Todos os Magnus Voxcorp |
| `pkg_vox_clientes_config` | Configs específicas | **Apenas no OSS 120** |
| `pkg_banned_ips` | IPs banidos custom | Sugestão técnica |
| `pkg_tables_changes` | Audit log mudanças | Sugestão técnica |

---

## Como adicionar bug novo aqui

1. Numerar sequencialmente (Bug 8, Bug 9, ...)
2. Incluir: **Descrição**, **Sintomas**, **Diagnóstico** (com comandos), **Solução**, **Causa raiz** se conhecida
3. Atualizar a data abaixo
4. Commit semântico: `docs: catalogar Bug <N> - <descrição curta>`

---

**Última atualização:** 8 de junho de 2026
**Mantenedor:** Edgar — Voxcorp Telecom
