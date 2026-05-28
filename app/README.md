# Cepheus Build GUI

Lightweight Flutter desktop console for Cepheus Build.

## Run

```bash
cd app
flutter run -d macos
```

## History

Local run history is stored in the toolkit repo at:

```text
history/build-history.json
```

Commit that file when the team should share run history across machines.

## GitHub Dispatch

GitHub mode runs the same shared CLI as the terminal. Product repo/workflow
defaults come from `products/*.toml`; runner profile labels come from
`build.toml`.
