# Magnus Utilities

> [!CAUTION]
> **⚠ SOFTWARE EM ALFA — USE POR SUA CONTA E RISCO.**
> Estes scripts podem **causar quebras no sistema** (banco de dados, Asterisk, Apache, firewall). O autor **não se responsabiliza** por perda de dados ou indisponibilidade.
> Use preferencialmente em uma **instalação NOVA ou de TESTES**. Em produção, **somente** com backup completo e janela de manutenção.

Coleção de scripts e procedimentos versionados que padronizam a instalação, customização, troubleshooting e manutenção de servidores **MagnusBilling 7.x sobre Debian 11/12** em operações de VoIP.

> **Compatibilidade:** o instalador oficial do MagnusBilling aceita apenas **Debian 11 (bullseye)** e **Debian 12 (bookworm)** — no Debian 12 o PHP instalado é o 8.2. Os utilitários deste pacote detectam a versão do PHP automaticamente e funcionam nas duas. Servidores **Debian 10** já instalados continuam atendidos pelas ferramentas de manutenção/diagnóstico, mas a instalação nova em Debian 10 não é mais suportada pelo instalador oficial.

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
