#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
trap cleanup_test_storage EXIT
setup_test_storage

make_image localhost/prune-active-only:latest active-only
"${podman_test[@]}" create --name keep-me localhost/prune-active-only:latest >/dev/null

active_layer="$(image_layer localhost/prune-active-only:latest)"
writable_layer="$(container_layer keep-me)"

output="$(run_pruner --no-final-cleanup 2>&1)"

grep -q "No container-unused layer payloads found." <<<"$output"
assert_exists "$storage_root/overlay/$active_layer"
assert_exists "$storage_root/overlay/$writable_layer"
assert_image_exists localhost/prune-active-only:latest
