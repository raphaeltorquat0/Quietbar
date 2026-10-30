# Roteiro: primeira abertura a partir de um download real

Este roteiro confere se as instruções de instalação do README valem para quem baixa o app pela primeira vez. Rode com o `.dmg` ad-hoc e repita depois da notarização, quando o aviso não deve mais aparecer.

Uma simulação local com o atributo de quarentena no macOS 27 mostrou o aviso **O Item Quietbar Não Foi Aberto**, com os botões **Mover para o Lixo** e **OK**. Ela não substitui este roteiro, porque não passa pelo Safari nem pelo `.dmg`.

## Preparar

1. Gere o `.dmg`:
   ```sh
   make release
   ```
2. Publique uma pre-release, que não vira a "última versão" do link do README:
   ```sh
   gh release create v1.3.0-rc.1 dist/Quietbar-1.3.0.dmg --prerelease --title "Quietbar 1.3.0 RC 1" --notes "Teste de instalação"
   ```
   O nome do arquivo não muda, então a URL do `docs/appcast.xml` não aponta para esta pre-release.
3. Em **Ajustes do Sistema › Usuários e Grupos**, crie um usuário padrão, sem privilégios de administrador. Um usuário novo não tem aprovações anteriores do Gatekeeper nem permissões do Quietbar.
4. Encerre a sessão atual e entre com o usuário novo.

## Executar

Anote o resultado de cada passo. No Safari do usuário novo:

| # | Passo | Esperado | Resultado |
|---|---|---|---|
| 1 | Abra `https://github.com/raphaeltorquat0/Quietbar/releases/tag/v1.3.0-rc.1` e baixe o `.dmg` | Arquivo em Downloads | |
| 2 | No Terminal, rode `xattr -p com.apple.quarantine ~/Downloads/Quietbar-1.3.0.dmg` | Mostra um valor com `Safari` | |
| 3 | Abra o `.dmg` e arraste o Quietbar para **Aplicativos** | Pede a senha de administrador, porque o usuário é padrão | |
| 4 | Abra o Quietbar em Aplicativos | Aviso **O Item Quietbar Não Foi Aberto**, com **Mover para o Lixo** e **OK** | |
| 5 | Clique em **OK** | O aviso fecha e o app continua em Aplicativos | |
| 6 | Vá em **Ajustes do Sistema › Privacidade e Segurança** e role até **Segurança** | Aparece a linha do Quietbar com **Abrir Mesmo Assim** | |
| 7 | Clique em **Abrir Mesmo Assim** | Novo aviso, que pede confirmação e senha | |
| 8 | Confirme | O app abre e o ícone aparece na barra de menus | |
| 9 | Clique no ícone com o fone pareado | O macOS pede acesso ao Bluetooth | |
| 10 | Permita e abra o painel | O app conecta ao fone | |
| 11 | Feche o app e abra de novo | Abre sem aviso | |
| 12 | Clique com o botão direito no ícone › **Procurar atualizações…** | Janela do Sparkle, sem erro de permissão | |
| 13 | Veja **Configurações › Geral › Procurar atualizações automaticamente** | Vem ligado | |

Depois, repita os passos 4 a 8 com uma variação: abra o app direto da janela do `.dmg`, sem arrastar. O macOS executa o app de um local temporário, e o Sparkle não consegue atualizá-lo. Anote se o app avisa alguma coisa.

### macOS 14

No macOS 14 não há usuário de teste obrigatório, mas repita os passos 4 a 8. Confira também o atalho do README: Control-clique no app › **Abrir** › **Abrir**.

### Homebrew

Depois de criar o tap, teste num usuário novo:

```sh
brew install --cask raphaeltorquat0/tap/quietbar
```

Confira se a primeira abertura segue os passos 4 a 8. O cask não remove a quarentena (`DECISIONS.md` #68).

## Se algo divergir

Atualize a seção **Instalar** de `README.md` e `README.en.md`, nos mesmos termos que o macOS mostrou, e `docs/launch/` se o número de passos mudar. Anote aqui a versão do macOS em que você testou.

## Limpar

```sh
gh release delete v1.3.0-rc.1 --cleanup-tag --yes
```

Remova o usuário de teste em **Usuários e Grupos**.
