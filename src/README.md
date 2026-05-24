# Source Layout

The root `sing-box.sh` and `docker_init.sh` files are generated release artifacts.
Edit the files under `src/` first, then run:

```sh
tools/bundle.sh
```

The bundled files stay in the repository root so existing raw GitHub install
commands continue to work. CI runs `tools/bundle.sh --check` to make sure the
generated files match the source modules.

## Layout

- `src/vps/` contains the VPS installer source chunks used to generate `sing-box.sh`.
- `src/docker/` contains the container-only wrapper used to generate `docker_init.sh`.

The Docker bundle intentionally includes the shared VPS modules and then applies
Docker-specific overrides for downloads, environment variables, s6 services, and
container lifecycle. Keep protocol generation and subscription output in the
shared VPS modules so the raw installer and Docker image stay aligned.
