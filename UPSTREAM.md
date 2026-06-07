# Upstream Tracking

This repository is maintained as an independent downstream of:

- Upstream: https://github.com/fscarmen/sing-box
- Upstream branch: `main`
- Tracking branch: `upstream-main`
- Current tracked commit: `2ca9504654e0bfc2fd6270d386a919e8f14800ab`
- Last reviewed: 2026-06-07

Policy:

- `main` is the default source branch and contains the modular implementation.
- `release` is generated from `main` and contains only published runtime artifacts.
- `upstream-main` mirrors `fscarmen/main` for review only.
- Do not edit or merge directly into `release`; review upstream changes and port useful changes into `main`.
