# Behavior Differences from Upstream

Baseline reviewed on 2026-05-25:

- Upstream: `fscarmen/sing-box@a683f289eabee672c6fb512292e4b255e1ab1be6`
- Downstream: `qqqasdwx/sing-box@main`

No newer upstream commit was found during this review. This document records behavior that intentionally differs from upstream, plus migration issues found during review.

## Review Result

- VPS installer behavior is intentionally kept close to upstream. The observed differences are repository ownership links, `force_version` source, and the generated `sb` shortcut URL.
- Docker behavior is intentionally different because it now reuses the VPS protocol-generation path instead of maintaining a separate hand-written implementation.
- Migration issues found and fixed in this review:
  - The rewritten README no longer had the ShadowTLS help anchor used by script output. The link now points to the restored `Nekobox 设置 ShadowTLS 方法` section.
  - Docker `init.sh -v` had lost upstream-style rollback safety. It now backs up the old binary, restarts through s6, and restores the old binary if the new process does not come back.

## Intentional Differences

| Area | Upstream behavior | This repository | Why |
| --- | --- | --- | --- |
| Source layout | `sing-box.sh` and `docker_init.sh` are maintained directly as root scripts. | Source lives in `src/vps/` and `src/docker/`; `tools/bundle.sh` generates root scripts. | Keep single-file release compatibility while making changes reviewable by module. |
| Release branch | `main` is both source and raw install target. | `main` is source; `release` is generated and contains runtime artifacts only. | Raw install stays stable while source and automation stay on the default branch. |
| Raw install URL | Uses `raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh`. | Uses `raw.githubusercontent.com/qqqasdwx/sing-box/release/sing-box.sh`. | Published script must come from our generated release branch. |
| `force_version` | Read from upstream `fscarmen/sing-box/main/force_version`. | Read from our `qqqasdwx/sing-box/release/force_version`. | Our released installer should obey the version pin published with the same release artifacts. |
| Docker registry | Action pushes to Docker Hub using Docker Hub secrets. | Action pushes to `ghcr.io/qqqasdwx/sing-box:latest` with `GITHUB_TOKEN`. | Avoid Docker Hub credentials and keep image publishing inside GitHub Packages. |
| Docker build context | Builds directly from the repository branch. | Builds from the generated release tree. | Ensures the image uses the exact same `docker_init.sh` and files that are published on `release`. |
| Docker protocol generation | Docker has separate hand-written config generation logic. | Docker reuses VPS modules for protocol JSON, subscriptions, Argo parsing, Reality keys, Hysteria2 Realm, and exports. | Prevent Docker and VPS behavior from drifting. |
| Docker protocol selection | Uses individual booleans such as `XTLS_REALITY=true`; if no boolean is enabled, no protocol is selected. | Supports `CHOOSE_PROTOCOLS` letters like VPS. Legacy booleans still work; if neither is supplied, defaults to all protocols. | Align Docker with VPS quick-install behavior while keeping old env flags usable. |
| Docker port semantics | `START_PORT` is the nginx/Argo origin port; protocol ports start after it. | `START_PORT` is the first protocol port. `PORT_NGINX` is the nginx/Argo origin port and defaults to `START_PORT + selected_protocol_count`. | Remove the hidden one-port offset and match VPS semantics. |
| Docker subscription/nginx | Nginx and subscription output are always part of the generated flow. | Nginx is created only when subscription or Argo needs it; `SUBSCRIBE=false` and `ARGO=false` can disable it. | Make non-HTTP deployments possible and avoid unnecessary services. |
| Docker Argo API | Docker has its own Cloudflare API parsing and sets tunnel origin to `START_PORT`. | Docker uses the shared VPS `input_argo_auth` / `create_argo_tunnel` path and sets tunnel origin to `PORT_NGINX`. Invalid fixed Argo input fails early. | Fix the Docker Cloudflare API Token path and keep Argo behavior consistent with VPS. |
| Docker Quick Tunnel metrics | Metrics listener is exposed on `0.0.0.0:$METRICS_PORT`. | Metrics listener is bound to `127.0.0.1:$METRICS_PORT`. | The metrics endpoint is only used inside the container to read the temporary tunnel domain. |
| Docker update | Upstream backs up the old sing-box binary and rolls back when the new process does not start. | Same safety behavior is preserved, but restart is done by killing the s6-managed process and letting s6 bring it back. | Keep rollback safety while respecting the container supervisor. |
| Docker port hopping | Upstream Docker does not manage host NAT for Hysteria2 port hopping. | Docker accepts the shared `HY2_PORT_HOPPING_RANGE` setting but only warns; host UDP forwarding must be configured outside the container. | A container should not mutate host firewall/NAT state. |
| Runtime dependencies | Alpine image installs only `wget nginx bash openssl`. | Adds `ca-certificates tar iproute2 iputils procps coreutils xxd`. | Shared VPS modules need these tools for downloads, IP detection, process checks, and Reality key handling. |
| Upstream tracking | Fork-style sync/mirror workflows are upstream-oriented. | `upstream-main` mirrors upstream only for review; `Upstream watch` opens an issue when upstream changes. | The repository is an independent downstream, not a direct fork workflow. |

