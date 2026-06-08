# Voxcorp Setup

Coleção de scripts e procedimentos versionados que padronizam a instalação, customização, troubleshooting e manutenção de servidores **MagnusBilling 7.x sobre Debian 10/11** em operações de VoIP da Voxcorp.

## Instalação Rápida (Interativa)

Você pode iniciar o menu interativo com todas as ferramentas de diagnóstico e manutenção através de um único comando em qualquer servidor com curl:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/Voxcorp/voxcorp-setup/main/setup.sh)
```

*(Nota: a URL real dependerá de onde este repositório for hospedado)*

## Estrutura de Diretórios

- `scripts/lib/`: Funções globais e helpers comuns a todos os scripts (`common.sh`).
- `scripts/diagnostico/`: Scripts read-only para health-check e auditoria.
- `scripts/instalacao/`: Ajustes pós-instalação, firewall e customizações padrão.
- `scripts/manutencao/`: Rotinas de operação (remoção de logs, recarga de DID, backups).
- `scripts/migracao/`: Scripts de backup e restore de servidor Magnus inteiro ou tabelas.
- `docs/`: Manuais operacionais, tutoriais de runbooks e registro de bugs conhecidos.
- `configs/`: Templates de arquivos de configuração (Asterisk, Fail2ban, Firewalld).

## Convenções

Ao contribuir com scripts, certifique-se de:
1. Usar o cabeçalho padronizado.
2. Fazer `source scripts/lib/common.sh` para usar os outputs de console padronizados (`ok`, `erro`, `warn`, `titulo`, `info`).
3. Manter os scripts focados na idempotência (poder rodar várias vezes com segurança).
