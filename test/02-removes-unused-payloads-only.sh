#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
trap cleanup_test_storage EXIT
setup_test_storage

make_image localhost/prune-active:latest active
make_image localhost/prune-unused:latest unused
"${podman_test[@]}" create --name keep-me localhost/prune-active:latest >/dev/null

unused_layer="$(image_layer localhost/prune-unused:latest)"
active_layer="$(image_layer localhost/prune-active:latest)"
writable_layer="$(container_layer keep-me)"

run_pruner --no-final-cleanup >/dev/null

assert_not_exists "$storage_root/overlay/$unused_layer"
assert_exists "$storage_root/overlay/$active_layer"
assert_exists "$storage_root/overlay/$writable_layer"
assert_image_exists localhost/prune-active:latest
