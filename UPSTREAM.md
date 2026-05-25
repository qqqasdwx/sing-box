# Upstream Tracking

This repository is maintained as an independent downstream of:

- Upstream: https://github.com/fscarmen/sing-box
- Upstream branch: `main`
- Tracking branch: `upstream-main`
- Current tracked commit: `a683f289eabee672c6fb512292e4b255e1ab1be6`
- Last reviewed: 2026-05-25

Policy:

- `main` is the default source branch and contains the modular implementation.
- `release` is generated from `main` and contains only published runtime artifacts.
- `upstream-main` mirrors `fscarmen/main` for review only.
- Do not edit or merge directly into `release`; review upstream changes and port useful changes into `main`.
