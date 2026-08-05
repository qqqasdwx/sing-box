# Upstream Tracking

This repository is maintained as an independent downstream of:

- Upstream: https://github.com/fscarmen/sing-box
- Upstream branch: `main`
- Tracking branch: `upstream-main`
- Current tracked commit: `4c9f6fbf06b5083fe3c8acc26568228c6f0f866e`
- Latest reviewed commit: `4c9f6fbf06b5083fe3c8acc26568228c6f0f866e`
- Last reviewed: 2026-08-05

Policy:

- `main` is the default source branch and contains the modular implementation.
- `release` is generated from `main` and contains only published runtime artifacts.
- `upstream-main` mirrors `fscarmen/main` for review only.
- Do not edit or merge directly into `release`; review upstream changes and port useful changes into `main`.
