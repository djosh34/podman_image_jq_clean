#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: podman-emergency-layer-prune.sh [--dry-run] [--no-final-cleanup] [--final=rm-all]

Removes Podman overlay layer payload directories that are not reachable from
any container, without writing Podman metadata or creating temp files.

Options:
  --dry-run             Print what would be removed; do not delete anything.
  --no-final-cleanup    Do not run the final Podman metadata/image cleanup.
  --final=rm-all        Run "podman image rm --all" after deleting payloads.
  -h, --help            Show this help.

Environment:
  PODMAN_BIN            Podman executable. Default: podman
  PODMAN_ARGS           Extra Podman arguments, e.g. "--root X --runroot Y".
  JQ_BIN                jq executable. Default: jq
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*" >&2
}

dry_run=0
run_final_cleanup=1
final_cleanup="rm-all"

while (($#)); do
  case "$1" in
    --dry-run)
      dry_run=1
      run_final_cleanup=0
      ;;
    --no-final-cleanup)
      run_final_cleanup=0
      ;;
    --final=rm-all)
      final_cleanup="rm-all"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

podman_bin="${PODMAN_BIN:-podman}"
jq_bin="${JQ_BIN:-jq}"

command -v "$podman_bin" >/dev/null 2>&1 || die "podman executable not found: $podman_bin"
command -v "$jq_bin" >/dev/null 2>&1 || die "jq executable not found: $jq_bin"

podman_args=()
if [[ -n "${PODMAN_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  podman_args=(${PODMAN_ARGS})
fi
podman_cmd=("$podman_bin" "${podman_args[@]}")

store_json="$("${podman_cmd[@]}" info --format '{{json .Store}}')"
driver="$("$jq_bin" -r '.graphDriverName // empty' <<<"$store_json")"
graph_root="$("$jq_bin" -r '.graphRoot // empty' <<<"$store_json")"
run_root="$("$jq_bin" -r '.runRoot // empty' <<<"$store_json")"
transient_store="$("$jq_bin" -r '.transientStore // false' <<<"$store_json")"

[[ -n "$driver" ]] || die "could not determine Podman graph driver"
[[ -n "$graph_root" ]] || die "could not determine Podman graph root"
[[ "$driver" == "overlay" ]] || die "only the overlay storage driver is supported; found: $driver"
[[ "$graph_root" != "/" ]] || die "refusing to operate on graph root /"

driver_root="$graph_root/$driver"
layers_dir="$graph_root/${driver}-layers"
images_dir="$graph_root/${driver}-images"
containers_dir="$graph_root/${driver}-containers"

volatile_layers_dir="$layers_dir"
volatile_containers_dir="$containers_dir"
if [[ "$transient_store" == "true" ]]; then
  [[ -n "$run_root" ]] || die "transient store is enabled but runRoot is empty"
  volatile_layers_dir="$run_root/${driver}-layers"
  volatile_containers_dir="$run_root/${driver}-containers"
fi

[[ -d "$driver_root" ]] || die "driver root does not exist: $driver_root"

emit_merged_json_array() {
  local first=1 path item
  printf '['
  for path in "$@"; do
    [[ -r "$path" ]] || continue
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      if ((first)); then
        first=0
      else
        printf ','
      fi
      printf '%s' "$item"
    done < <("$jq_bin" -c 'if type == "array" then .[] else empty end' "$path")
  done
  printf ']'
}

emit_store_snapshot() {
  printf '{"layers":'
  emit_merged_json_array \
    "$layers_dir/layers.json" \
    "$images_dir/layers.json" \
    "$volatile_layers_dir/volatile-layers.json"
  printf ',"images":'
  emit_merged_json_array "$images_dir/images.json"
  printf ',"containers":'
  emit_merged_json_array \
    "$containers_dir/containers.json" \
    "$volatile_containers_dir/volatile-containers.json"
  printf '}\n'
}

remove_tree() {
  local path="$1"
  rm -rf --one-file-system -- "$path" 2>/dev/null && return 0
  "${podman_cmd[@]}" unshare rm -rf --one-file-system -- "$path"
}

deletable_layer_filter='
  def clean_ids:
    map(select(type == "string" and length > 0)) | unique;

  def ancestors($parents; $roots):
    def walk($seen; $front):
      ($front | clean_ids | map(select(($seen[.] // false) | not))) as $new
      | if ($new | length) == 0 then
          $seen
        else
          walk(
            reduce $new[] as $id ($seen; .[$id] = true);
            $new | map($parents[.] // empty)
          )
        end;
    walk({}; $roots);

  (.layers // []) as $layers
  | (.images // []) as $images
  | (.containers // []) as $containers
  | ($layers
      | map(select(.id? and (.id | type == "string")))
      | map({key: .id, value: (.parent // "")})
      | from_entries) as $parents
  | ($images
      | map(select(.id? and (.id | type == "string")))
      | map({key: .id, value: (.layer // "")})
      | from_entries) as $image_top_by_id
  | (($containers | map(.layer? // empty))
      + ($containers | map($image_top_by_id[.image?] // empty))) as $container_roots
  | ancestors($parents; $container_roots) as $protected
  | $layers
  | map(.id? // empty)
  | clean_ids
  | map(select(($protected[.] // false) | not))
  | .[]
'

mapfile -t deletable_layers < <(emit_store_snapshot | "$jq_bin" -r "$deletable_layer_filter")

if ((${#deletable_layers[@]} == 0)); then
  note "No container-unused layer payloads found."
else
  note "Container-unused layer payloads found: ${#deletable_layers[@]}"
fi

removed_count=0
skipped_count=0
freed_bytes=0

for layer_id in "${deletable_layers[@]}"; do
  if [[ ! "$layer_id" =~ ^[a-f0-9]{64}$ ]]; then
    note "skip suspicious layer id: $layer_id"
    ((skipped_count+=1))
    continue
  fi

  layer_dir="$driver_root/$layer_id"
  if [[ ! -e "$layer_dir" ]]; then
    note "already absent: $layer_id"
    continue
  fi

  size_bytes="$(du -sb -- "$layer_dir" 2>/dev/null | awk '{print $1}')"
  size_bytes="${size_bytes:-0}"
  freed_bytes=$((freed_bytes + size_bytes))

  if ((dry_run)); then
    printf 'would remove %s (%s bytes)\n' "$layer_dir" "$size_bytes"
    continue
  fi

  link_id=""
  if [[ -r "$layer_dir/link" ]]; then
    IFS= read -r link_id < "$layer_dir/link" || true
  fi

  if [[ -n "$link_id" && "$link_id" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    remove_tree "$driver_root/l/$link_id"
  fi
  remove_tree "$layer_dir"
  printf 'removed %s (%s bytes)\n' "$layer_dir" "$size_bytes"
  ((removed_count+=1))
done

if ((dry_run)); then
  note "Dry run complete. Estimated reclaimable bytes: $freed_bytes"
  exit 0
fi

note "Removed layer payload directories: $removed_count; skipped: $skipped_count; estimated bytes removed: $freed_bytes"

if ((run_final_cleanup)); then
  case "$final_cleanup" in
    rm-all)
      note "Running final Podman cleanup: podman image rm --all"
      if ! "${podman_cmd[@]}" image rm --all; then
        note "podman image rm --all returned non-zero; this is expected when containers still use images."
      fi
      ;;
    *)
      die "unsupported final cleanup mode: $final_cleanup"
      ;;
  esac
fi
