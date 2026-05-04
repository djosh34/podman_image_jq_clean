#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

chmod +x "$repo_root/podman-emergency-layer-prune.sh"

for test_script in "$repo_root"/test/[0-9][0-9]-*.sh; do
  printf '==> %s\n' "$(basename "$test_script")"
  bash "$test_script"
done

printf 'all tests passed\n'
