# Magnus Utilities (`setup`)

> [!CAUTION]
> **⚠ SOFTWARE EM ALFA — USE POR SUA CONTA E RISCO.**
> Estes scripts realizam alterações profundas no sistema (banco de dados MariaDB/MySQL, Asterisk, Apache, SSH, rede e firewall). O autor **não se responsabiliza** por perda de dados ou indisponibilidade.
> Utilize preferencialmente em **ambientes de homologação/testes**. Em produção, execute **somente** com backup prévio validado, console KVM/Proxmox aberto e janela de manutenção.

---

## Sobre (About)

**Magnus Utilities** é uma suíte interativa de scripts para instalação, migração side-by-side (`MB7 ➔ MB8`), blindagem de segurança, ativação de WebRTC/WSS, cutover de IP e manutenção operacional de servidores **MagnusBilling 8** (Asterisk 20 + PJSIP) e **MagnusBilling 7** (Asterisk 13 + `chan_sip`) em Debian 10/11/12/13 e Ubuntu LTS.

---

## Execução Rápida (Menu Interativo)

Execute diretamente em qualquer servidor como `root`:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/munin81/setup/main/setup.sh)
```

> Na primeira execução, o utilitário clona o repositório em `/root/magnus-utils` e mantém-se sincronizado automaticamente a cada inicialização.

---

## Catálogo de Ferramentas

### Página 1 — MagnusBilling 8 (Principal / Asterisk 20 + PJSIP)

#### Segurança e Firewall
| Opção | Script | Descrição |
| :---: | :--- | :--- |
| **1** | `verificar_seguranca_magnus.sh` | Auditoria completa (read-only) de versão MB7/MB8, porta SSH, restrição por IP no SSH/Web, certificado SSL, WebRTC e firewall. |
| **2** | `blindar_ssh_magnus.sh` | Altera a porta SSH (padrão recomendado `22022`), restringe o acesso apenas aos IPs/blocos autorizados no `firewalld`/`iptables` e inclui *Deadman Switch* de 300s contra auto-bloqueio. |
| **3** | `blindar_web_magnus.sh` | Restringe o painel web no Apache apenas aos IPs/blocos administrativos autorizados (com página customizada ou `403 Forbidden` discreto para visitantes externos). |
| **4** | `liberar_ip_firewall.sh` | Libera rapidamente o IP de outro servidor no `firewalld`, `iptables` e `fail2ban` (ideal antes de migrações via SSH/Rsync). |
| **5** | `desfazer_bloqueios_magnus.sh` | Reverte restrições de IP no painel Web e no SSH (com opção de restaurar a porta 22 ou manter a porta customizada). |

#### Servidor Web, SSL e WebRTC (WSS)
| Opção | Script | Descrição |
| :---: | :--- | :--- |
| **6** | `configurar_ssl_mb8.sh` | Emite certificado SSL Let's Encrypt no Apache, bloqueia acesso direto por IP puro (anti-scanner), configura renovação automática e integra TLS/WSS ao Asterisk 20. |
| **7** | `limpar_url_magnus.sh` | Remove o sufixo `/mbilling` da URL, fazendo o painel responder diretamente na raiz (`https://dominio/`) mantendo compatibilidade com APIs e callbacks. |
| **8** | `ativar_webrtc_mb8.sh` | Ativa o servidor HTTPS/WSS interno do Asterisk 20 na porta `8089` (`/etc/asterisk/http.conf`), configura `[transport-wss]` no `pjsip.conf`, exporta certificados SSL e libera `8089/tcp`. |

#### Instalação, Migração e Cutover
| Opção | Script | Descrição |
| :---: | :--- | :--- |
| **9** | `instalar_magnus.sh --mb8` | Instalação limpa oficial do MagnusBilling 8 (Asterisk 20 + PJSIP nativo). |
| **10** | `migrar_mb7_para_mb8.sh` | Migração automatizada `MB7 ➔ MB8` via SSH: modo não-invasivo na origem, dump e importação do banco, preservação de tabelas novas do MB8, execução do `UpdateMysql.php`, sanitização de `fromuser` em contas SIP dinâmicas, auto-healing de `extensions_magnus.conf`, sincronização de fuso horário e transferência de áudios/gravações via `rsync`. |
| **11** | `atualizar_mb8.sh` | Atualização segura do MagnusBilling 8 com backup prévio completo, `update.sh`, `UpdateMysql.php`, proteção de `extensions_magnus.conf`, ajuste de timezone do PHP e smoke test pós-update. |
| **12** | `trocar_ip_servidor.sh` | Cutover de produção: transfere o IP público do servidor antigo para o servidor novo (atualizando `/etc/network/interfaces` ou Netplan, `pjsip.conf`/`sip.conf`, MariaDB e firewall) com **rollback automático em 5 minutos** caso o acesso SSH não seja confirmado. |

#### Manutenção de Banco, CDR e Sistema
| Opção | Script | Descrição |
| :---: | :--- | :--- |
| **13** | `alterar_bloco_did.sh` | Repasse em massa de faixas de DIDs entre clientes com atualização automática das rotas em `pkg_did` e `pkg_did_destination`. |
| **14** | `deletar_cdr_oferta.sh` | Limpeza seletiva de histórico de CDRs (`pkg_cdr`, `pkg_cdr_failed`) e consumo de pacotes (`pkg_offer_cdr`) de usuários inativos/cancelados. |
| **15** | `criar_usuario_db.sh` | Criação segura de usuário MySQL/MariaDB remoto restrito por IP (para DBeaver, BI ou automações) com `mysql_native_password` e liberação no firewall. |
| **16** | `gerar_csv_cdr.sh` | Exportação rápida de relatórios CSV de CDR filtrados por cliente e período. |
| **17** | `alterar_senha_web.sh` | Alteração direta e segura da senha de qualquer usuário do painel web (`pkg_user`) via banco de dados. |
| **18** | `configurar_horario_brasil.sh` | Verifica e sincroniza o fuso horário do Brasil (Brasília, Cuiabá, Manaus, Rio Branco, Noronha) em 4 camadas: Linux (`timedatectl`), PHP (`php.ini` + override `/etc/php/*/mods-available/magnusbilling.ini`), MariaDB e Asterisk, com opção de corrigir CDRs gravados com `+3h` (UTC). |

---

### Página 2 — MagnusBilling 7 (Legado / Asterisk 13 + `chan_sip`)

Acessível digitando `L` no menu principal:

- **21.** Instalação Oficial do MagnusBilling 7 Legado (`instalar_magnus.sh --mb7`)
- **22.** Migração de Dados entre Servidores MagnusBilling 7 (`MB7 ➔ MB7` — `migrar_magnus.sh`)
- **23.** Configurar Certificado SSL — MagnusBilling 7 Legado (`configurar_ssl_mb7_legado.sh`)
- **24.** Auditoria de Saúde e Segurança Legada (`magnus-health-check.sh`)
- **25.** Blindagem de Firewall IPtables Clássico (`iptables-magnus.sh`)
- **26.** Trocar IP do Servidor / Cutover de Produção (`trocar_ip_servidor.sh`)
- **27.** Liberar IP no Firewall para Migração (`liberar_ip_firewall.sh`)
- **28.** Verificar e Ajustar Fuso Horário do Brasil (`configurar_horario_brasil.sh`)

---

## Estrutura do Repositório

```text
setup/
├── README.md                          # Documentação principal
├── CHANGELOG.md                       # Histórico de versões e melhorias
├── LICENSE                            # Licença MIT
├── setup.sh                           # Painel interativo principal (Paginado MB8 / MB7)
└── scripts/
    ├── lib/common.sh                  # Funções compartilhadas de log, cores e validação
    ├── diagnostico/                   # Health check e auditoria de segurança
    ├── instalacao/                    # Instalação, SSL, WebRTC (WSS :8089), blindagem SSH/Web
    ├── manutencao/                    # Atualização MB8, fuso horário, DIDs, CDR, senhas e DB
    ├── migracao/                      # Migração MB7->MB8, MB7->MB7 e Cutover de IP
    └── relatorios/                    # Exportação CSV de CDR
```

---

## Diretrizes de Segurança e Arquitetura

1. **Zero Senhas Expostas em Processos (`ps aux`):** Todas as conexões MySQL/MariaDB e SSH utilizam variáveis de ambiente (`MYSQL_PWD` e `SSHPASS`) ou autenticação socket local.
2. **Idempotência:** Todos os scripts verificam o estado atual antes de aplicar mudanças, podendo ser reexecutados com segurança.
3. **Proteção contra Auto-Bloqueio (*Deadman Switch*):** Alterações críticas de firewall, SSH e troca de IP contam com reversão automática programada caso a sessão não seja confirmada pelo operador.
4. **Auto-Healing para MagnusBilling 8:** Os scripts de migração e atualização protegem o arquivo estático `/etc/asterisk/extensions_magnus.conf` (contexto `[billing]`), higienizam `fromuser` em contas SIP dinâmicas para preservar o CallerID no PJSIP e garantem permissões `asterisk:asterisk` (`chmod 664`) nos arquivos `*_magnus*.conf`.
