# Changelog

## [Unreleased]
- feat(ssl): adiciona script de instalação e configuração do Certbot Let's Encrypt (configurar_ssl_magnus.sh)
- fix(setup): adiciona mecanismo de auto-reload para evitar problema de cache do GitHub no curl
- fix(migrar): v5.2.1 remove bug do ALTER USER e permite usuários dinâmicos (admin e api)
- docs: confirmar firewalld como padrão Magnus Debian 10/11
- feat(migrar): v5.2 adiciona restart de serviços e validação final
- feat(migrar): v5.1 escopo enxuto (sem firewall/SSL)
