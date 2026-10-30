# Contributing

Issues and pull requests are welcome in English or Portuguese.

The most useful contribution is a [headphone report](https://github.com/raphaeltorquat0/Quietbar/issues/new?template=relatorio-de-fone.yml). It's what moves a model from experimental to tested.

## Setup

You need macOS 14 or later and Xcode 26 or later. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) if you change `project.yml`.

```sh
make test   # all tests
make dev    # run the app in Debug
```

You can develop without headphones: see [`docs/SIMULATOR.md`](docs/SIMULATOR.md).

## Add a headphone model

Follow the flow in [`docs/SIMULATOR.md`](docs/SIMULATOR.md#adicionar-um-modelo-a-partir-de-um-mdr-cli-dump): keep the raw capture in `captures/`, run `scripts/sanitize-capture.sh`, update the profile and add it to the fidelity table. Raw captures never go into Git, and only sanitized fixtures are committed.

## Pull requests

- Keep each PR to one change.
- Add a test for new protocol behavior. Real captured traffic is better than hand-written bytes.
- Record ambiguous choices in `DECISIONS.md`.
- Write commit messages in Portuguese or English, in the imperative.
- Don't add third-party images, Sony logos or code from GPL/AGPL projects.
- Never commit a raw capture. Run it through `scripts/sanitize-capture.sh`.

## For contributors and agents

These rules apply to people and to AI coding agents alike.

- **Never capture the whole screen.** Capture only the app's own windows, by ID (`screencapture -l <id>`). If a capture picks up content from other apps, delete the file right away and mention it when you report the work.
- **Never trigger a permission prompt in a test.** Tests must not request audio capture, the microphone or any other permission, by a direct request or as a side effect such as starting a process tap without the permission. While the audio prompt is open, `coreaudiod` stops serving new clients and other apps can't start playing sound. Only a person triggers it, with the onboarding button.
- Use fakes instead. `SystemPermissionTests` injects missing symbols and fake functions, and `--no-tcc-symbols` and `--demo-curve-import` show those states in a Debug build without touching the button.
- `CoreAudioTests` starts real taps. Unless your terminal already has the permission, skip it: `swift test --skip CoreAudioTests`.
