# Repository Guidelines

## Project Structure & Module Organization

This repository is a shell-script installer and Docker packaging project for sing-box deployments. `main` is the source branch; `release` is generated for published artifacts.

- `src/vps/` contains modules that generate `sing-box.sh`, the VPS installer, updater, menu, and service manager.
- `src/docker/` contains Docker-specific modules that generate `docker_init.sh`, the container entrypoint.
- `tools/bundle.sh` rebuilds root scripts; `tools/prepare-release.sh` creates the trimmed release tree.
- `Dockerfile` builds the Alpine image and installs `s6-overlay` plus runtime dependencies.
- `docker-compose.example.yml` is the Docker environment variable example; keep it aligned with Docker config changes.
- `config.conf` is the key-value example for non-interactive installs.
- `force_version` pins or overrides the sing-box version used by install flows.
- `CHANGELOG.md` records downstream user-facing and release-relevant changes.
- `BEHAVIOR_DIFFS.md` records intentional behavior differences from upstream.
- `UPSTREAM.md` records upstream tracking policy and the reviewed upstream commit.
- `.shellcheckrc` is the current ShellCheck baseline for upstream-derived scripts.
- `.github/workflows/` contains `bundle.yml` for bundle/syntax CI, `build.yml` for release/GHCR publishing, and `upstream-watch.yml` for upstream update issues.
- `README.md` is the user-facing install and operations reference.

Generated runtime files are not stored here. The VPS installer writes under `/etc/sing-box/`; the container writes under `/sing-box/`.
The root `sing-box.sh` and `docker_init.sh` files are generated artifacts. For normal changes, edit `src/vps/` or `src/docker/`, then run `tools/bundle.sh`; do not hand-edit generated root scripts except for temporary investigation.

## Build, Test, and Development Commands

- `bash -n sing-box.sh docker_init.sh tools/bundle.sh tools/prepare-release.sh` checks shell syntax without executing installer logic.
- `tools/bundle.sh --check` verifies generated root scripts match `src/`.
- `tools/prepare-release.sh /tmp/sing-box-release` creates a local release tree.
- Do not run ShellCheck over the generated large scripts (`sing-box.sh` or `docker_init.sh`) in this VM. It has repeatedly saturated CPU and caused machine freezes. If ShellCheck is needed, run it only on small, targeted source modules or tool scripts, for example `shellcheck src/vps/40_config.sh tools/bundle.sh`, and avoid broad globs or whole-repo scans.
- `docker build -t sing-box:local .` builds a local test image from `Dockerfile`.
- `docker run --rm --network host -e START_PORT=8800 -e SERVER_IP=127.0.0.1 sing-box:local` smoke-tests container startup. Add variables such as `-e XTLS_REALITY=true` when testing configs.

Avoid running installer paths on a workstation unless you intend to modify system services, firewall rules, and `/etc/sing-box/`.

## Documentation Sync

- When adding, removing, or renaming configuration variables, update the relevant source module, `config.conf`, `README.md`, and `docker-compose.example.yml` together.
- When changing user-visible behavior, release packaging, Docker behavior, or downstream-only behavior, update `CHANGELOG.md` and, when applicable, `BEHAVIOR_DIFFS.md`.
- When reviewing or porting upstream changes from `fscarmen/sing-box`, update `UPSTREAM.md` with the reviewed upstream commit and keep intentional downstream differences documented in `BEHAVIOR_DIFFS.md`.
- `tools/prepare-release.sh` currently publishes `sing-box.sh`, `docker_init.sh`, `Dockerfile`, `README.md`, `docker-compose.example.yml`, `CHANGELOG.md`, `BEHAVIOR_DIFFS.md`, `LICENSE`, `config.conf`, and `force_version`. `UPSTREAM.md` is maintainer-facing and is not included in the release tree.

## Coding Style & Naming Conventions

Use Bash for scripts. Follow the existing style: two-space indentation inside blocks, uppercase global configuration variables, lowercase function names, and `local` for function-scoped variables. Keep bilingual text aligned through the `E[...]` and `C[...]` arrays in `src/vps/10_i18n.sh`.

Prefer quoted expansions (`"$VAR"`) and explicit error handling for filesystem, network, and service operations.

## Testing Guidelines

There is no formal test suite. At minimum, run `bash -n` and `shellcheck` after script edits. For behavior changes, test the affected path in a disposable Linux VM or container and verify generated JSON with `jq`:

```sh
jq . /etc/sing-box/conf/00_log.json
```

## Commit & Pull Request Guidelines

Recent commits use concise prefixes such as `fix:`, `feat:`, and versioned release subjects like `v1.3.13 feat: ...`. Keep subjects scoped to one change.

Do not push commits or monitor GitHub Actions unless the user explicitly asks to push. It is acceptable to make local edits and, when requested, local commits first; wait for a clear push instruction before running `git push`.

When monitoring GitHub Actions for this project, explicitly target the repository `qqqasdwx/sing-box`, for example `gh run list --repo qqqasdwx/sing-box` or `gh run watch <run-id> --repo qqqasdwx/sing-box`. Do not rely on `gh` default repository inference, because this checkout also has an `upstream` remote and commands may otherwise query `fscarmen/sing-box`.

Pull requests should include the problem, changed install/runtime path, tested OS or architecture, commands run, and relevant logs or config snippets. Do not include real UUIDs, Argo tokens, Cloudflare API credentials, private keys, or production server IPs.

## Security & Configuration Tips

Treat `ARGO_AUTH`, `REALITY_PRIVATE`, UUIDs, tokens, and generated certificates as secrets. Keep examples sanitized. Changes touching firewall rules, Cloudflare tunnels, subscriptions, or service lifecycle should document rollback steps.
