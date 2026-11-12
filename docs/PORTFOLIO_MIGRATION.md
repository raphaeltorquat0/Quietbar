# Migração para o portfólio: Quietbar

Levantamento de 30/10/2026. Nenhum código foi alterado. O portfólio usa o nome Quietbar, não SonyCtl (decisão 53 de `DECISIONS.md`).

## Decisões pendentes

Nenhuma. As três decisões estão em `DECISIONS.md`:

- **Licença (#76):** o Quietbar continua MIT.
- **Sparkle (#74):** integrado, com o serviço de download do próprio Sparkle. O app não tem `network.client`, e o cask usa `auto_updates true`. Falta atualizar o texto de privacidade em `apps.json` no site.
- **Dono do repositório (#77):** continua em `raphaeltorquat0/Quietbar`.

## Adotar o MacKit

| Hoje | Trocar por | Observação |
|---|---|---|
| Sem About padrão | `SupportKit.AboutWindow` | Adicionar ao menu do ícone |
| Sem lembrete | `SupportKit.SupportPrompt.run(links:)` | App de barra de menus |
| Pedido de Bluetooth próprio | `PermissionsKit` com `.bluetooth` | Localização não existe no kit e continua local |
| Diagnóstico na aba Desenvolvedor | Avaliar `DiagnosticsKit` | O sanitizador remove MAC, IP e caminhos. Compare antes de trocar: o diagnóstico atual alimenta a issue de novo modelo |

## Adotar o workflow de release

O build usa entitlements de sandbox e tem uma extensão de Controles, então não cabe no `xcodebuild archive` padrão. Crie `scripts/ci-build.sh`:

```sh
#!/bin/sh
set -eu
scripts/build-app.sh
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" \
  -c "Set :CFBundleVersion $APP_BUILD" dist/Quietbar.app/Contents/Info.plist
ditto dist/Quietbar.app "$OUT_DIR/Quietbar.app"
```

- [ ] Workflow com `app-name: Quietbar`, `cask: quietbar`, `build-script: scripts/ci-build.sh` e `run-tests: false`.
- [ ] O build personalizado não roda testes. Adicione `swift test` ao `ci-build.sh`.
- [ ] `build-app.sh` passa entitlements pelo build, e `sign.sh` os preserva. Confira com `codesign -d --entitlements -` no app e na extensão.
- [ ] A extensão exige macOS 26. Confirme que o runner tem SDK compatível: o `macos-latest` usa Xcode 26.
- [ ] `App/Support/Info.plist` precisa aceitar a troca de versão feita pelo script.
- [ ] Os DMGs atuais não são notarizados. O README explica a abertura manual. Ajuste esse texto no primeiro release notarizado.
- [ ] O `make install` não muda.

## Arquivos padrão

| Arquivo | Estado |
|---|---|
| `LICENSE` | Existe (MIT) |
| `README.md` | Existe em português. O padrão público é inglês com `README.pt-BR.md` |
| `DECISIONS.md` | Mover para `docs/DECISIONS.md` |
| `docs/QA_CHECKLIST.md` | Falta. `docs/HARDWARE_TEST.md` é uma boa base |
| `PRIVACY.md` | Falta. Inclua Bluetooth e o uso de Localização só nos perfis por Wi-Fi |
| `CLAUDE.md`, `Scripts/measure_idle_cpu.sh` | Faltam |
| `FUNDING.yml`, PR template | Herdados |
| Issue template | **Não herda**: `novo-modelo.md` local desativa os padrões. Copie `bug_report.yml` e `feature_request.yml` |

Bundle ID `io.github.raphaeltorquat0.Quietbar` fica como está.

A pasta local se chama `sonyctl_macos`, mas o remote já é `Quietbar`. Não há impacto no build.
