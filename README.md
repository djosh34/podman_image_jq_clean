# Podman Emergency Layer Prune

Emergency cleanup for rootless Podman stores that are too full for
`podman image rm --all` to make progress.

Podman normally updates `images.json` and `layers.json` with atomic writes,
which create temporary files next to the metadata. If the filesystem is full,
those temp files can fail before Podman frees any image data.

This script avoids that first write. It reads Podman storage metadata with
`jq`, finds every layer reachable from existing containers, then removes only
overlay layer payload directories that are not reachable from any container.
After freeing space, it runs `podman image rm --all` by default so Podman can
clean up image and layer metadata normally.

## Requirements

- `bash`
- `podman`
- `jq`
- Podman `overlay` storage driver

## Usage

Dry run:

```bash
./podman-emergency-layer-prune.sh --dry-run
```

Free unused layer payloads, then run `podman image rm --all`:

```bash
./podman-emergency-layer-prune.sh
```

Only run the no-tempfile payload cleanup pass:

```bash
./podman-emergency-layer-prune.sh --no-final-cleanup
```

For an alternate Podman store:

```bash
PODMAN_ARGS="--root /path/to/root --runroot /path/to/runroot --storage-driver overlay" \
  ./podman-emergency-layer-prune.sh --dry-run
```

## Safety Model

The script protects:

- each container writable layer
- the image layer for each container image
- all parent layers of those protected layers

It removes only layer payload directories outside that protected set. It does
not rewrite Podman JSON metadata and does not create temp files itself.

## Tests

The tests use isolated Podman storage roots under `/tmp`.

```bash
test/run-all.sh
```

## License

MIT. See [LICENSE](LICENSE).
