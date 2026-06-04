# First-Party Dependency Workflow

Cepheus product repos should not embed recursive first-party submodule copies as
the normal development model. Product manifests should move toward pinned
package refs, tags, or registry releases. Local development uses ignored
override files generated from one shared manifest.

## Local Sibling Checkout Model

Keep first-party repos as siblings:

```text
Developer/git/
  printdeck/
  anvil/
  colorwake-studio/
  forge/
  helm/
  stockpile/
  ...
```

Then generate local overrides for the product you are working in:

```bash
cepheus-build deps -p printdeck --write
cepheus-build deps -p anvil --write
cepheus-build deps -p colorwake-studio --write
```

By default the workspace root is the product repo's parent directory. Override it
for nonstandard layouts:

```bash
cepheus-build deps -p printdeck --workspace-root "$HOME/src/cepheus" --write
```

## Generated Files

For Flutter apps, the command writes `pubspec_overrides.yaml` beside each app
`pubspec.yaml`, mapping first-party packages to sibling checkouts.

Running `flutter pub get` with local overrides can update `pubspec.lock` to the
local path source. Treat that lockfile churn as local-only until the committed
manifest cutover lands; do not include it in product commits unless the commit is
intentionally changing dependency pins.

For Go hosts, the command writes `go.work` beside the host `go.mod`, mapping
first-party modules to sibling checkouts.

These files are local-only and must be ignored:

```text
pubspec_overrides.yaml
go.work
go.work.sum
```

## Committed Manifests

The target committed state is:

- Flutter `pubspec.yaml` dependencies use `git:` refs or registry releases for
  first-party packages.
- Go `go.mod` files use real versions or pseudo-versions, not local `replace`
  directives for first-party modules.
- CI config authenticates once for private `github.com/CepheusLabs/*` fetches.
- Local path overrides live only in generated ignored files.
- Submodules remain only for exceptional pinned external forks or source drops.

## CI Authentication

Private first-party git refs need one Git credential setup step before Flutter or
Go dependency resolution. The reusable `app-build` workflow configures this for
callers:

```bash
git config --global \
  url."https://x-access-token:${CEPHEUS_READ_TOKEN}@github.com/".insteadOf \
  "https://github.com/"
go env -w GOPRIVATE=github.com/cepheuslabs/*,github.com/CepheusLabs/*
```

Set a product secret named `CEPHEUS_READ_TOKEN` with read access to the sibling
private repos. The workflow falls back to `github.token`, but that token is only
enough when org policy grants it cross-repo read access.

## Checks

Preview status without writing:

```bash
cepheus-build deps -p printdeck
```

Machine-readable status:

```bash
cepheus-build deps -p printdeck --json
```

The command exits nonzero if local package paths are missing, or if generated
files are stale when run without `--write`.
