#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
trap cleanup_test_storage EXIT
setup_test_storage

make_image localhost/prune-base:latest base
make_child_image localhost/prune-base:latest localhost/prune-active-child:latest active-child
make_child_image localhost/prune-base:latest localhost/prune-unused-child:latest unused-child
"${podman_test[@]}" create --name keep-me localhost/prune-active-child:latest >/dev/null

base_layer="$(image_layer localhost/prune-base:latest)"
active_child_layer="$(image_layer localhost/prune-active-child:latest)"
unused_child_layer="$(image_layer localhost/prune-unused-child:latest)"
writable_layer="$(container_layer keep-me)"

run_pruner --no-final-cleanup >/dev/null

assert_exists "$storage_root/overlay/$base_layer"
assert_exists "$storage_root/overlay/$active_child_layer"
assert_exists "$storage_root/overlay/$writable_layer"
assert_not_exists "$storage_root/overlay/$unused_child_layer"
