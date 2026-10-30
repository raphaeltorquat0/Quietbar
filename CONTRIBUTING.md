# Contributing

Issues and pull requests are welcome in English or Portuguese.

The most useful contribution is a [headphone report](https://github.com/raphaeltorquat0/Quietbar/issues/new?template=relatorio-de-fone.yml). It's what moves a model from experimental to tested.

## Setup

You need macOS 14 or later and Xcode 26 or later. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) if you change `project.yml`.

```sh
make test   # all tests
make dev    # run the app in Debug
```

## Pull requests

- Keep each PR to one change.
- Add a test for new protocol behavior. Real captured traffic is better than hand-written bytes.
- Record ambiguous choices in `DECISIONS.md`.
- Write commit messages in Portuguese or English, in the imperative.
- Don't add third-party images, Sony logos or code from GPL/AGPL projects.
- Remove Bluetooth addresses from any capture you include.
