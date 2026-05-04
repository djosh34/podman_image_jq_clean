#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
trap cleanup_test_storage EXIT
setup_test_storage

output="$(run_pruner --no-final-cleanup 2>&1)"

grep -q "No container-unused layer payloads found." <<<"$output"
image_count="$("${podman_test[@]}" image ls -q | wc -l)"
[[ "$image_count" == "0" ]] || {
  printf 'assertion failed: expected no images in empty store\n' >&2
  exit 1
}
