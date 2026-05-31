# Contributing to Cepheus Build

## Repo Layout Assumption

Product configs in `products/*.toml` set `repo_root = "../../<product>"`, which
is resolved **relative to the `products/` directory**. The default expectation is
that each product repo sits as a *sibling* of this one:

```
~/Developer/git/
  cepheus-build/     ← this repo
  printdeck/
  colorwake-studio/
  anvil/
  deckhand/
  foundry/
```

There is no submodule or checkout of product repos inside this one; builds
operate on those external checkouts.

The other supported layout is vendoring this repo as a submodule at
`shared/cepheus-build` inside an app repo. In that case, always pass
`--repo-root "$PWD"` so the CLI resolves paths from the app repo's root:

```bash
shared/cepheus-build/bin/cepheus-build build \
  -p printdeck --repo-root "$PWD" desktop
```

In CI workflows and embedded use, always pass `--repo-root`.

## Working on the CLI

The CLI needs no install step for core commands. Run it directly from a
sibling-repo checkout:

```bash
./bin/cepheus-build list
./bin/cepheus-build plan -p printdeck desktop
./bin/cepheus-build doctor -p anvil all
./bin/cepheus-build build -p colorwake-studio macos --dry-run
```

Use `--dry-run` liberally while iterating. `plan` and `doctor` never mutate
anything and are safe to run at any time. `build --dry-run` shows what would
run without executing commands or syncing the product repo.

### Python checks

Install the package in editable mode with dev extras, then run the standard
checks:

```bash
pip install -e .[dev]
ruff check .
pytest
python -m py_compile cepheus_build/*.py
```

If `.[dev]` extras are not yet declared, install `ruff` and `pytest`
separately.

### Source file size limit

Source files must stay **under 600 lines**. `cli.py` is the largest permitted
exception while it remains a single-file entrypoint; new modules added under
`cepheus_build/` must individually stay under 600 lines.

## Working on the GUI App

The Flutter app in `app/` depends on the `forge` submodule. Initialize it
before the first `pub get`:

```bash
git submodule update --init --recursive
cd app
flutter pub get
flutter analyze
flutter test
flutter run -d macos    # or -d linux / -d windows
```

The app shells out to `bin/cepheus-build` at runtime, so changes to the CLI
are immediately visible without rebuilding the app.

## Security / Trust Boundary

**Product TOML `commands`, `pre`, `post`, and store lane entries are executed
via the shell** with full environment interpolation. They are treated as
*trusted input*.

- Do not run `cepheus-build` with a `--config`/`.cepheus-build.toml` from an
  untrusted repository without first reviewing its contents. A malicious config
  can execute arbitrary shell commands.
- Store-lane `required_env` values referencing service accounts must be **file
  paths** to credential files, never inlined secret content. The Google Play
  module expects `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` to be a path to a JSON
  key file, not the raw key material.
- `history/build-history.json` stores command lines from previous runs. Avoid
  inlining secrets in product lane commands; use env-var references
  (`$MY_SECRET`) instead so secrets do not appear in history.

## Sending Changes

- Keep changes focused. One logical change per commit.
- Validate CLI changes with `plan`/`doctor`/`build --dry-run` against at
  least one product before opening a pull request.
- The CI matrix is generated from product configs; if you add a new target or
  tool requirement, run `ci-matrix` and verify the output looks correct:

```bash
./bin/cepheus-build ci-matrix -p <product> --runner-profile github-hosted all --pretty
```
