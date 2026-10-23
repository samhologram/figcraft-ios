# Fork notes: FigCraft for iOS and iPadOS

This repository is a fork of [storytold/figcraft](https://github.com/storytold/figcraft) maintained at
[samhologram/figcraft-ios](https://github.com/samhologram/figcraft-ios). It adds native iPadOS and iOS apps on top of
the unchanged Rust engine. `main` is our main branch.

## Remotes

| Remote | Repository | Role |
|---|---|---|
| `origin` | `git@github.com:samhologram/figcraft-ios.git` | our fork; push here |
| `upstream` | `https://github.com/storytold/figcraft` | the original app; fetch and merge only |

## The rule: only `apple/` is ours

Fork work lives only in:

- `apple/` (Rust bridge `apple/bridge`, Swift package `apple/FigCraftKit`, app `apple/FigCraft`, tests, scripts, docs)
- `.github/workflows/apple-*.yml` (manual `workflow_dispatch` only)
- `FORK.md`

Everything else is upstream's and stays byte-identical. Engine changes go upstream (see "Upstream notes" in
`apple/README.md`); the app works around gaps in the bridge or in Swift meanwhile.

## Importing upstream

```bash
apple/scripts/sync-upstream.sh
```

It fetches `upstream`, runs `git merge upstream/main` (merge, never rebase, so our history stays linear on top of
theirs), then runs the bridge gate (`cargo test` + `cargo clippy`). Then rebuild the xcframework and the app
(`apple/README.md`).

Resolving the rare conflict: a conflict outside `apple/`, `FORK.md` or `.github/workflows/apple-*.yml` means an
upstream file was edited here by mistake — take upstream's version (`git checkout --theirs <file>`) and move the change
into `apple/`. A bridge compile error after a merge means the engine API moved: fix `apple/bridge/src`, never the
engine.

## Commits

Commit messages carry `[skip ci]`; no workflow runs on push.

## Building

See `apple/README.md`. The recipe followed is `apple/docs/COOKBOOK.md`.
