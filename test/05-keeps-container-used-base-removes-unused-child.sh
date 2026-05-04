#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
trap cleanup_test_storage EXIT
setup_test_storage

make_image localhost/prune-base:latest base
"${podman_test[@]}" create --name keep-base localhost/prune-base:latest >/dev/null
make_child_image localhost/prune-base:latest localhost/prune-unused-child:latest unused-child

base_layer="$(image_layer localhost/prune-base:latest)"
unused_child_layer="$(image_layer localhost/prune-unused-child:latest)"
writable_layer="$(container_layer keep-base)"

run_pruner --no-final-cleanup >/dev/null

assert_exists "$storage_root/overlay/$base_layer"
assert_exists "$storage_root/overlay/$writable_layer"
assert_not_exists "$storage_root/overlay/$unused_child_layer"
assert_image_exists localhost/prune-base:latest
