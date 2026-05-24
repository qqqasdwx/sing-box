# Repository Guidelines

## Project Structure & Module Organization

This repository is a shell-script installer and Docker packaging project for sing-box deployments.

- `sing-box.sh` is the primary VPS installer, updater, menu, and service-management script.
- `docker_init.sh` is the container entrypoint used by the Docker image.
- `Dockerfile` builds the Alpine image and installs `s6-overlay` plus runtime dependencies.
- `config.conf` is the key-value example for non-interactive installs.
- `force_version` pins or overrides the sing-box version used by install flows.
- `.github/workflows/` contains manual image build/push and repository mirror workflows.
- `README.md` is the user-facing install and operations reference.

Generated runtime files are not stored here. The VPS installer writes under `/etc/sing-box/`; the container writes under `/sing-box/`.

## Build, Test, and Development Commands

- `bash -n sing-box.sh docker_init.sh` checks shell syntax without executing installer logic.
- `shellcheck sing-box.sh docker_init.sh` runs static analysis; use it before larger script changes when available.
- `docker build -t sing-box:local .` builds a local test image from `Dockerfile`.
- `docker run --rm --network host -e START_PORT=8800 -e SERVER_IP=127.0.0.1 sing-box:local` smoke-tests container startup. Add variables such as `-e XTLS_REALITY=true` when testing configs.

Avoid running installer paths on a workstation unless you intend to modify system services, firewall rules, and `/etc/sing-box/`.

## Coding Style & Naming Conventions

Use Bash for scripts. Follow the existing style: two-space indentation inside blocks, uppercase global configuration variables, lowercase function names, and `local` for function-scoped variables. Keep bilingual text aligned through the `E[...]` and `C[...]` arrays in `sing-box.sh`.

Prefer quoted expansions (`"$VAR"`) and explicit error handling for filesystem, network, and service operations.

## Testing Guidelines

There is no formal test suite. At minimum, run `bash -n` and `shellcheck` after script edits. For behavior changes, test the affected path in a disposable Linux VM or container and verify generated JSON with `jq`:

```sh
jq . /etc/sing-box/conf/00_log.json
```

## Commit & Pull Request Guidelines

Recent commits use concise prefixes such as `fix:`, `feat:`, and versioned release subjects like `v1.3.13 feat: ...`. Keep subjects scoped to one change.

Pull requests should include the problem, changed install/runtime path, tested OS or architecture, commands run, and relevant logs or config snippets. Do not include real UUIDs, Argo tokens, Cloudflare API credentials, private keys, or production server IPs.

## Security & Configuration Tips

Treat `ARGO_AUTH`, `REALITY_PRIVATE`, UUIDs, tokens, and generated certificates as secrets. Keep examples sanitized. Changes touching firewall rules, Cloudflare tunnels, subscriptions, or service lifecycle should document rollback steps.
