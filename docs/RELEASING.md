# Como publicar uma release

Os alvos `make release` e `make notarize` funcionam sem credenciais: sem as variáveis abaixo, eles geram o build ad-hoc e avisam o que pularam.

| Variável | Valor |
|---|---|
| `QUIETBAR_SIGN_IDENTITY` | Nome completo do certificado, como `Developer ID Application: Seu Nome (TEAMID)` |
| `QUIETBAR_NOTARY_PROFILE` | Nome do perfil salvo pelo `notarytool`, como `quietbar` |

Nenhum dos dois é segredo por si só, mas não os versione. A senha fica no Keychain.

## Configurar o Developer ID (uma vez)

1. Entre no [Apple Developer Program](https://developer.apple.com/programs/). Ele é pago, e o certificado Developer ID exige a inscrição.
2. Em [Certificates](https://developer.apple.com/account/resources/certificates/list), crie um certificado **Developer ID Application**. O site pede um CSR: gere-o no Acesso às Chaves, em **Assistente de Certificado › Solicitar um Certificado de uma Autoridade de Certificação**, e salve em disco.
3. Baixe o `.cer` e abra-o para instalar no Keychain.
4. Copie o nome exato:
   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
5. Crie uma senha de app em [account.apple.com](https://account.apple.com), em **Entrar e Segurança**.
6. Salve o perfil do `notarytool`. O comando pede a senha de app e a guarda no Keychain:
   ```sh
   xcrun notarytool store-credentials quietbar --apple-id "voce@exemplo.com" --team-id "TEAMID"
   ```
7. Exporte as variáveis no seu shell:
   ```sh
   export QUIETBAR_SIGN_IDENTITY="Developer ID Application: Seu Nome (TEAMID)"
   export QUIETBAR_NOTARY_PROFILE="quietbar"
   ```

## Publicar

Checklist, nesta ordem:

- [ ] Suba `MARKETING_VERSION` e `CURRENT_PROJECT_VERSION` no `project.yml`, a única fonte da versão
- [ ] `make test`
- [ ] `make release`
- [ ] `make notarize`
- [ ] `scripts/update-cask.sh`
- [ ] Commit da versão e push do `main`, sem `docs/appcast.xml` nem `Casks/quietbar.rb`
- [ ] Crie a tag e a release com o `.dmg` de `dist/`, que é o arquivo assinado no appcast e no cask:
  ```sh
  VERSION=1.3.0
  gh release create "v$VERSION" "dist/Quietbar-$VERSION.dmg" --title "Quietbar $VERSION" --notes-file notas.md
  ```
- [ ] Baixe o `.dmg` da release e confira o sha256 com `shasum -a 256`
- [ ] Só agora faça commit e push de `docs/appcast.xml` e `Casks/quietbar.rb`: publicar o appcast antes do arquivo oferece um download que ainda não existe
- [ ] Copie `Casks/quietbar.rb` para o tap e faça push
- [ ] Instale pelo cask em outra conta ou máquina e abra o app

Se você recompilar depois de `scripts/update-cask.sh`, o sha256 e a assinatura mudam: o `.dmg` não é reproduzível. `make release` e `make notarize` refazem a entrada do appcast. Rode `scripts/update-cask.sh` de novo.

## Atualizações pelo Sparkle

O app lê `https://raphaeltorquat0.github.io/Quietbar/appcast.xml`, que é o `docs/appcast.xml` deste repositório.

**Ativar o GitHub Pages (uma vez):** em **Settings › Pages**, escolha **Deploy from a branch**, `main` e a pasta `/docs`. A partir daí, tudo em `docs/` fica público nesse endereço.

**Chave de assinatura:** a chave privada EdDSA fica só no Keychain do seu login, na conta `quietbar`. A chave pública está em `App/Support/Info.plist`. `scripts/appcast.sh` assina o `.dmg` com ela e grava a entrada no appcast; sem a chave, a etapa é pulada com um aviso.

**Faça um backup da chave agora.** Sem ela, nenhuma atualização nova é aceita pelos apps já instalados, e não há como recuperá-la. Guarde o arquivo no seu gerenciador de senhas e apague a cópia, sem nunca colocá-la no repositório:

```sh
.build/release-app/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account quietbar -x ~/quietbar-sparkle.key
```

**Build ad-hoc:** a atualização funciona, porque o Sparkle valida a assinatura EdDSA. Mas cada build ad-hoc tem uma identidade diferente, então o macOS pode pedir de novo o acesso ao Bluetooth depois de atualizar. Com Developer ID, isso não acontece.

**Build number:** o Sparkle compara `CURRENT_PROJECT_VERSION`. Suba esse número em toda release, ou a atualização não é oferecida.

## Tap do Homebrew

O cask fica em `Casks/quietbar.rb` e é publicado por um tap próprio.

1. Crie o repositório público `raphaeltorquat0/homebrew-tap`.
2. Coloque o arquivo em `Casks/quietbar.rb` nesse repositório.
3. Quem for instalar roda:
   ```sh
   brew install --cask raphaeltorquat0/tap/quietbar
   ```

O envio ao `homebrew-cask` oficial fica para depois da notarização: o repositório oficial não aceita apps que não passam pelo Gatekeeper.

Sem notarização, o cask instala o app com a quarentena normal do macOS, e a pessoa precisa liberá-lo como no README. O cask não remove a quarentena de propósito (`DECISIONS.md` #68).
