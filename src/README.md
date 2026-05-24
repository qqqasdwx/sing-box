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
- `src/docker/` contains the container entrypoint source chunks used to generate `docker_init.sh`.

This first split is intentionally behavior-preserving. Future refactors should
move duplicated VPS and Docker behavior into shared source modules before
changing generated runtime behavior.
