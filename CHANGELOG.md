# Changelog

## [Unreleased]
- feat(debian12): suporte a Debian 12 (bookworm) — migrar detecta a versão do php-fpm automaticamente (7.3/7.4/8.2), instalar_magnus confere a versão do SO antes de baixar o instalador oficial (que aceita só Debian 11/12), README e cabeçalhos atualizados
- feat(banco): criar_usuario_db.sh — cria/atualiza usuário MySQL por IP de origem com senha oculta (read -s, via stdin, fora do ps aux), escopo full ou só mbilling, nada gravado em log
- feat(seguranca): blindar_web_magnus.sh v2 — restrição global via <Location />, padroniza/limpa blindagens antigas (acesso_negado.html), torna o redirect :80 incondicional e libera /.well-known/acme-challenge (não quebra renovação SSL)
- feat(seguranca): blindar_web_magnus.sh — restringe o painel web a IPs/blocos autorizados, cobrindo o acesso pelo domínio E pelo IP direto, com página "Acesso Não Autorizado"
- fix(seguranca): correções críticas — deletar_cdr_oferta atômico com backup; senha fora do ps aux em auditoria/migrar; iptables com persistência no reboot e RTP 10000-60000
- feat(setup): nova interface do menu dividida em categorias com descritivos explicativos
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
