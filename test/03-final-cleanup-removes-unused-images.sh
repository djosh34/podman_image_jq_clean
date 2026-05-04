#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
trap cleanup_test_storage EXIT
setup_test_storage

make_image localhost/prune-active:latest active
make_image localhost/prune-unused-a:latest unused-a
make_image localhost/prune-unused-b:latest unused-b
"${podman_test[@]}" create --name keep-me localhost/prune-active:latest >/dev/null

run_pruner >/dev/null

assert_image_exists localhost/prune-active:latest
assert_image_absent localhost/prune-unused-a:latest
assert_image_absent localhost/prune-unused-b:latest
"${podman_test[@]}" container exists keep-me
