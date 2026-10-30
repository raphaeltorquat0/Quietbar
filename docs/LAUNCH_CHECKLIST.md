# Checklist de lançamento

O que depende de você, nesta ordem. Os comandos da release estão em `docs/RELEASING.md`.

- [ ] **Rodar o roteiro no fone:** siga `docs/HARDWARE_TEST.md` com o fone conectado. Confira também o painel novo com o fone real e os alertas do fone, que ainda não foram vistos nele.
- [ ] **Ver o painel no macOS 14 e 15:** rode `/Applications/Quietbar.app/Contents/MacOS/Quietbar --demo-panel nc` e teste clique no ícone, Esc e clique fora. Essas versões só foram compiladas.
- [ ] **Configurar Developer ID e notarização:** siga `docs/RELEASING.md`. Sem isso, o lançamento sai com o aviso do Gatekeeper, e os textos já dizem isso.
- [ ] **Criar o tap:** crie o repositório `raphaeltorquat0/homebrew-tap` e publique `Casks/quietbar.rb` depois da release.
- [ ] **Publicar a release:** gere a 1.3.0, confira o sha256 do arquivo publicado e confirme que o CI passou no GitHub. O workflow ainda não rodou lá.
- [ ] **Ativar relatórios privados de vulnerabilidade:** ligue **Private vulnerability reporting** nas configurações de segurança do repositório. O `SECURITY.md` depende disso.
- [ ] **Revisar os rascunhos:** preencha os colchetes em `docs/launch/` e atualize o que mudou nos itens acima.
- [ ] **Postar:** comece pelo Show HN, que pede mais atenção aos comentários no primeiro dia, e use os outros canais depois.
