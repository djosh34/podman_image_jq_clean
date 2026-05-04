#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_base_dir="${TEST_BASE_DIR:-/tmp/podman-emergency-layer-prune-tests}"
test_root="$test_base_dir/$(basename "$0" .sh)"
storage_root="$test_root/root"
run_root="$test_root/run"

podman_test=(
  podman
  --root "$storage_root"
  --runroot "$run_root"
  --storage-driver overlay
  --events-backend file
)

cleanup_test_storage() {
  "${podman_test[@]}" rm -af >/dev/null 2>&1 || true
  "${podman_test[@]}" image rm -af >/dev/null 2>&1 || true
  rm -rf -- "$test_root" 2>/dev/null || "${podman_test[@]}" unshare rm -rf -- "$test_root" 2>/dev/null || true
}

setup_test_storage() {
  rm -rf -- "$test_root" 2>/dev/null || podman unshare rm -rf -- "$test_root" 2>/dev/null || true
  mkdir -p "$test_root"
}

run_pruner() {
  PODMAN_ARGS="--root $storage_root --runroot $run_root --storage-driver overlay --events-backend file" \
    "$repo_root/podman-emergency-layer-prune.sh" "$@"
}

make_image() {
  local tag="$1"
  local payload="${2:-$tag}"
  local ctx="$test_root/context-${tag//[^A-Za-z0-9_.-]/_}"

  mkdir -p "$ctx"
  printf '%s\n' "$payload" > "$ctx/payload.txt"
  printf 'FROM scratch\nCOPY payload.txt /payload.txt\nCMD ["/payload.txt"]\n' > "$ctx/Containerfile"
  "${podman_test[@]}" build -q -t "$tag" "$ctx" >/dev/null
}

make_child_image() {
  local base="$1"
  local tag="$2"
  local payload="${3:-$tag}"
  local ctx="$test_root/context-${tag//[^A-Za-z0-9_.-]/_}"

  mkdir -p "$ctx"
  printf '%s\n' "$payload" > "$ctx/child.txt"
  printf 'FROM %s\nCOPY child.txt /child.txt\n' "$base" > "$ctx/Containerfile"
  "${podman_test[@]}" build -q -t "$tag" "$ctx" >/dev/null
}

image_layer() {
  local tag="$1"
  jq -r --arg tag "$tag" '
    .[]
    | select((.names // []) | index($tag))
    | .layer
  ' "$storage_root/overlay-images/images.json"
}

container_layer() {
  local name="$1"
  jq -r --arg name "$name" '
    .[]
    | select((.names // []) | index($name))
    | .layer
  ' "$storage_root/overlay-containers/containers.json"
}

assert_exists() {
  [[ -e "$1" ]] || {
    printf 'assertion failed: expected path to exist: %s\n' "$1" >&2
    exit 1
  }
}

assert_not_exists() {
  [[ ! -e "$1" ]] || {
    printf 'assertion failed: expected path to be absent: %s\n' "$1" >&2
    exit 1
  }
}

assert_image_exists() {
  "${podman_test[@]}" image exists "$1" || {
    printf 'assertion failed: expected image to exist: %s\n' "$1" >&2
    exit 1
  }
}

assert_image_absent() {
  if "${podman_test[@]}" image exists "$1"; then
    printf 'assertion failed: expected image to be absent: %s\n' "$1" >&2
    exit 1
  fi
}
