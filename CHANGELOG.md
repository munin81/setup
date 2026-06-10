# Changelog

## [Unreleased]
- security(auditoria): remove IPs restritos e domínio hardcoded para evitar vazamentos
- security(manutencao): remove senha exposta em texto plano e corrige vulnerabilidade na linha de comando mysql (ps aux)
- security(iptables): adiciona interatividade na coleta de IP e proteção contra lock-out (deadman switch dinâmico)
- feat(apache): adiciona script para limpar URL do painel (remover /mbilling)
- feat(ssl): adiciona script de instalação e configuração do Certbot Let's Encrypt (configurar_ssl_magnus.sh)
- fix(setup): adiciona mecanismo de auto-reload para evitar problema de cache do GitHub no curl
- fix(migrar): v5.2.1 remove bug do ALTER USER e permite usuários dinâmicos (admin e api)
- docs: confirmar firewalld como padrão Magnus Debian 10/11
- feat(migrar): v5.2 adiciona restart de serviços e validação final
- feat(migrar): v5.1 escopo enxuto (sem firewall/SSL)
