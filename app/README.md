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

## Local Builds

Local Build runs install configured missing dependencies before starting the
build. Dry Run only previews the build command path.

## GitHub Dispatch

GitHub mode runs the same shared CLI as the terminal. Product repo/workflow
defaults come from `products/*.toml`; runner profile labels come from
`build.toml`.

## Store Deploys

The Store deploy section reads `[stores.*]` lanes from the selected product
config and runs `bin/cepheus-build deploy`. Preview Deploy adds `--dry-run`;
Deploy requires the lane's configured environment variables.
