# Magnus Utilities

> [!CAUTION]
> **⚠ SOFTWARE EM ALFA — USE POR SUA CONTA E RISCO.**
> Estes scripts podem **causar quebras no sistema** (banco de dados, Asterisk, Apache, firewall). O autor **não se responsabiliza** por perda de dados ou indisponibilidade.
> Use preferencialmente em uma **instalação NOVA ou de TESTES**. Em produção, **somente** com backup completo e janela de manutenção.

Coleção de scripts e procedimentos versionados que padronizam a instalação, customização, troubleshooting e manutenção de servidores **MagnusBilling 8 (Asterisk 20 + PJSIP) e 7.x** sobre Debian e Ubuntu em operações de VoIP.

> **Compatibilidade:** O pacote suporta a instalação e manutenção tanto do **MagnusBilling 8** (oficial: Debian 11, 12, 13 e Ubuntu LTS com Asterisk 20 e PJSIP) quanto do **MagnusBilling 7** (Debian 11/12 com Asterisk 13 e chan_sip). Inclui ferramenta automatizada para migração segura side-by-side de MagnusBilling 7 para MagnusBilling 8 com conversão de banco e PJSIP via `UpdateMysql`.

## Instalação Rápida (Interativa)

Você pode iniciar o menu interativo com todas as ferramentas de diagnóstico e manutenção através de um único comando em qualquer servidor com curl:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/munin81/setup/main/setup.sh)
```

## Estrutura de Diretórios

- `scripts/lib/`: Funções globais e helpers comuns a todos os scripts (`common.sh`).
- `scripts/diagnostico/`: Scripts read-only para health-check e auditoria.
- `scripts/instalacao/`: Ajustes pós-instalação, firewall e customizações padrão.
- `scripts/manutencao/`: Rotinas de operação (remoção de logs, recarga de DID, backups).
- `scripts/migracao/`: Scripts de backup e migração de dados de servidor Magnus. (Nota: Configurações de firewall, SSL e cron são feitas através de scripts separados pós-migração).
- `docs/`: Manuais operacionais, tutoriais de runbooks e registro de bugs conhecidos.
- `configs/`: Templates de arquivos de configuração (Asterisk, Fail2ban, Firewalld).

## Convenções

Ao contribuir com scripts, certifique-se de:
1. Usar o cabeçalho padronizado.
2. Fazer `source scripts/lib/common.sh` para usar os outputs de console padronizados (`ok`, `erro`, `warn`, `titulo`, `info`).
3. Manter os scripts focados na idempotência (poder rodar várias vezes com segurança).
