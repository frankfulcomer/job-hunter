#!/usr/bin/env bash
# Job Hunter restore / recovery drill. Works offline on Linux or Windows (WSL2 + Docker
# Desktop). Never starts the n8n server: verification runs n8n's CLI in a network-less
# container. Starting n8n is the separate smoke test in docs/BACKUP-RESTORE.md.
#
# Usage: bash restore-n8n.sh BACKUP_SET_DIR [--volume NAME] [--data-dir DIR] [--report FILE]
#   --volume    New Docker volume to create and fill (default: jh_drtest_<timestamp>).
#               Use n8n_data only for a real recovery on a machine without n8n.
#   --data-dir  Where to restore the /data bind mount (must not exist yet; default:
#               ~/<volume>-data). Verified separately and mounted read-only for checks.
#   --report    Report path (default: ~/job-hunter-restore-report-<timestamp>.txt).
#   --allow-disk-staging  Permit plaintext staging outside tmpfs (not recommended).
#
# The backup set is only read, and is re-verified at the end to prove it is unchanged.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/jh-common.sh
source "$SCRIPT_DIR/lib/jh-common.sh"

RESTORED_TAG="job-hunter/n8n:restored"
PROD_CONTAINER="n8n"
VOLUME_DEST="/home/node/.n8n"
LABEL_KEY="job-hunter.restore"

read_passphrase() { jh_read_passphrase 0; }
work_base() { echo /dev/shm; }

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

init_state() {
  TS="$(date +%Y%m%d-%H%M%S)"
  RAND="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  [[ ${#RAND} -eq 12 ]] || jh_die "could not generate random id"
  HELPER="jh-restore-copy-$RAND"; VERIFIER="jh-restore-verify-$RAND"
  HELPER_CREATED=0; VERIFIER_STARTED=0; VOLUME_CREATED=0
  WORK=""; GNUPG_HOME=""; PASS=""
  RESULTS=(); SUCCESS=0; CONSISTENCY="unknown"
}

result() { RESULTS+=("$1  $2"); echo "$1  $2"; }

write_report() {  # overall
  {
    echo "Job Hunter recovery report"
    echo "date: $(date -Is)"
    echo "host: $(hostname)"
    echo "backup: ${BACKUP_NAME:-unknown}"
    echo "backup consistency: $CONSISTENCY"
    echo "image_id: ${IMAGE_ID:-unknown}"
    echo "volume: $TARGET_VOLUME"
    echo
    printf '%s\n' "${RESULTS[@]}"
    echo
    echo "ARTIFACT VERIFICATION: $1"
    echo "APPLICATION RECOVERY: NOT DEMONSTRATED by this script (n8n server not started;"
    echo "  integrations not exercised). Complete the smoke test in docs/BACKUP-RESTORE.md."
  } > "$REPORT"
  echo "report: $REPORT"
}

# Remove our containers and confirm each is gone. Flags are cleared per container only
# once that container is confirmed absent; returns non-zero if any removal is unconfirmed.
cleanup_containers() {
  local rc=0
  if [[ $HELPER_CREATED -eq 1 ]]; then
    if jh_remove_labeled_container "$HELPER" "$LABEL_KEY" "$RAND"; then HELPER_CREATED=0; else rc=1; fi
  fi
  if [[ $VERIFIER_STARTED -eq 1 ]]; then
    if jh_remove_labeled_container "$VERIFIER" "$LABEL_KEY" "$RAND"; then VERIFIER_STARTED=0; else rc=1; fi
  fi
  return $rc
}

remove_workdir() {
  [[ -n "$WORK" ]] || return 0
  [[ "$WORK" == "$WORK_BASE"/jh-restore.* && -d "$WORK" && ! -L "$WORK" ]] || return 1
  jh_gpg_kill_agent "$GNUPG_HOME"
  rm -rf -- "$WORK" || return 1
  [[ ! -e "$WORK" ]] || return 1
  WORK=""
}

on_exit() {
  local rc=$?
  set +e
  exec 1>&7 2>&8   # traps can fire while a command's output is redirected
  trap - EXIT HUP INT TERM
  PASS=""; unset PASS
  local cleanup_ok=1
  if ! cleanup_containers; then
    cleanup_ok=0; echo "WARNING: could not confirm removal of restore container(s) $HELPER / $VERIFIER"
  fi
  if ! remove_workdir; then
    cleanup_ok=0; echo "WARNING: could not remove plaintext work directory $WORK; delete it manually"
  fi
  if [[ $rc -eq 0 && $SUCCESS -eq 1 && $cleanup_ok -eq 1 ]]; then exit 0; fi
  result FAIL "aborted (exit $rc); see messages above"
  [[ -n "${REPORT:-}" && ! -e "$REPORT" ]] && write_report FAIL
  [[ $VOLUME_CREATED -eq 1 ]] && echo "Volume $TARGET_VOLUME was created by this run and left for inspection (docker volume rm $TARGET_VOLUME)."
  echo "RESTORE FAILED"
  exit $(( rc == 0 ? 1 : rc ))
}

parse_args() {
  SET_DIR=""; TARGET_VOLUME="jh_drtest_$TS"; DATA_DIR=""; REPORT=""; ALLOW_DISK=0
  while (( $# )); do
    case "$1" in
      --volume) TARGET_VOLUME="${2:?}"; shift 2 ;;
      --data-dir) DATA_DIR="${2:?}"; shift 2 ;;
      --report) REPORT="${2:?}"; shift 2 ;;
      --allow-disk-staging) ALLOW_DISK=1; shift ;;
      -h|--help) usage ;;
      -*) jh_die "unknown option $1" ;;
      *) [[ -z "$SET_DIR" ]] || usage; SET_DIR="$1"; shift ;;
    esac
  done
  [[ -n "$SET_DIR" && -d "$SET_DIR" ]] || usage
  SET_DIR="$(cd "$SET_DIR" && pwd -P)"
  [[ "$TARGET_VOLUME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || jh_die "invalid volume name"
  REPORT="$(readlink -m -- "${REPORT:-$HOME/job-hunter-restore-report-$TS.txt}")"
  ! jh_path_within "$REPORT" "$SET_DIR" || jh_die "report must be outside the backup set"
  [[ ! -e "$REPORT" && ! -L "$REPORT" ]] || jh_die "report file already exists: $REPORT"
  [[ -d "$(dirname -- "$REPORT")" ]] || jh_die "report directory does not exist"
  DATA_DIR="${DATA_DIR:-$HOME/$TARGET_VOLUME-data}"
  if [[ -n "$DATA_DIR" ]]; then
    DATA_DIR="$(readlink -m -- "$DATA_DIR")"
    ! jh_path_within "$DATA_DIR" "$SET_DIR" || jh_die "--data-dir must be outside the backup set"
    [[ ! -e "$DATA_DIR" && ! -L "$DATA_DIR" ]] || jh_die "--data-dir must not exist yet: $DATA_DIR"
    jh_assert_no_symlinks "$(dirname -- "$DATA_DIR")"
    [[ -d "$(dirname -- "$DATA_DIR")" ]] || jh_die "parent of --data-dir does not exist"
  fi
}

# Create the target volume and prove this run owns it and it is empty. `docker volume
# create` silently returns an existing volume, so ownership is checked by label.
create_owned_volume() {
  local owner listing
  docker volume create --label "$LABEL_KEY=$RAND" "$TARGET_VOLUME" >/dev/null
  owner="$(docker volume inspect --format "{{index .Labels \"$LABEL_KEY\"}}" "$TARGET_VOLUME")" \
    || jh_die "cannot inspect volume $TARGET_VOLUME"
  [[ "$owner" == "$RAND" ]] || jh_die "volume $TARGET_VOLUME already existed (created by someone else); not touching it"
  VOLUME_CREATED=1
  HELPER_CREATED=1
  docker create --name "$HELPER" --label "$LABEL_KEY=$RAND" --network none \
    --mount "type=volume,src=$TARGET_VOLUME,dst=$VOLUME_DEST,volume-nocopy=true" \
    --entrypoint node "$IMAGE_ID" -e 0 >/dev/null
  listing="$(docker cp "$HELPER:$VOLUME_DEST" - | tar -tf -)" || jh_die "cannot list volume $TARGET_VOLUME"
  [[ -z "$(grep -vxE '[^/]+/?' <<<"$listing" || true)" ]] || jh_die "volume $TARGET_VOLUME is not empty; not touching it"
}

main() {
  { set +x; } 2>/dev/null
  set -euo pipefail
  shopt -s inherit_errexit   # failures inside $(...) abort too
  set -o noclobber
  umask 077
  exec 7>&1 8>&2
  init_state
  parse_args "$@"
  trap on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  jh_require_tools docker python3 zstd tar gpg gpgconf sha256sum od mktemp find xargs findmnt readlink

  jh_step "Verify backup set (read-only)"
  local f want_sha want_version need avail
  for f in MANIFEST.txt SHA256SUMS job-hunter-data.tar.zst.gpg n8n-image.tar.zst; do
    [[ -f "$SET_DIR/$f" ]] || jh_die "backup set is missing $f"
  done
  jh_verify_sums "$SET_DIR"
  BACKUP_NAME="$(jh_manifest_field "$SET_DIR/MANIFEST.txt" backup)"
  IMAGE_ID="$(jh_manifest_field "$SET_DIR/MANIFEST.txt" image_id)"
  CONSISTENCY="$(jh_manifest_field "$SET_DIR/MANIFEST.txt" consistency)"
  want_sha="$(jh_manifest_field "$SET_DIR/MANIFEST.txt" payload_plaintext_sha256)"
  want_version="$(jh_manifest_field "$SET_DIR/MANIFEST.txt" n8n_version)"
  need="$(jh_manifest_field "$SET_DIR/MANIFEST.txt" payload_expanded_bytes)"
  result PASS "backup set checksums ($BACKUP_NAME; consistency: $CONSISTENCY)"

  jh_step "Check target"
  local state
  if [[ "$TARGET_VOLUME" == "n8n_data" ]]; then
    state="$(jh_docker_state container "$PROD_CONTAINER")" || jh_die "cannot determine whether container $PROD_CONTAINER exists"
    [[ "$state" == absent ]] || jh_die "a container named $PROD_CONTAINER exists here; refusing to restore into n8n_data"
  fi
  state="$(jh_docker_state volume "$TARGET_VOLUME")" || jh_die "cannot determine whether volume $TARGET_VOLUME exists"
  [[ "$state" == absent ]] || jh_die "volume $TARGET_VOLUME already exists; refusing to touch it"
  WORK_BASE="$(work_base)"
  jh_assert_no_symlinks "$WORK_BASE"
  if [[ $ALLOW_DISK -eq 0 ]]; then
    jh_assert_tmpfs "$WORK_BASE"
    avail="$(jh_ram_staging_bytes "$WORK_BASE")"
  else
    echo "WARNING: --allow-disk-staging: plaintext may be written to disk under $WORK_BASE"
    avail="$(df -B1 --output=avail -- "$WORK_BASE" | tail -n 1 | tr -d ' ')"
  fi
  (( avail > 3 * need + 64 * 1024 * 1024 )) || jh_die "not enough staging space in $WORK_BASE (need ~$((3 * need)) bytes, have $avail)"
  jh_warn_if_swap
  result PASS "target volume name is free; staging capacity ok"

  read_passphrase
  WORK="$(mktemp -d "$WORK_BASE/jh-restore.XXXXXXXX")"
  chmod 700 -- "$WORK"
  mkdir -m 700 -- "$WORK/gnupg" "$WORK/payload" "$WORK/vol"
  GNUPG_HOME="$WORK/gnupg"

  jh_step "Decrypt and verify payload"
  jh_gpg "$GNUPG_HOME" --decrypt -o "$WORK/payload.tar.zst" "$SET_DIR/job-hunter-data.tar.zst.gpg" \
    || jh_die "decryption failed (wrong passphrase or damaged file)"
  [[ "$(jh_sha256 "$WORK/payload.tar.zst")" == "$want_sha" ]] || jh_die "decrypted payload checksum mismatch"
  result PASS "decryption and payload checksum"
  zstd -q -dc -- "$WORK/payload.tar.zst" > "$WORK/payload.tar"
  rm -f -- "$WORK/payload.tar.zst"
  jh_tar_validate "$WORK/payload.tar"
  tar -C "$WORK/payload" -xf "$WORK/payload.tar"
  rm -f -- "$WORK/payload.tar"
  jh_verify_sums "$WORK/payload"
  jh_tar_validate "$WORK/payload/n8n_data-files.tar"
  jh_tar_validate "$WORK/payload/bind-data.tar" data
  result PASS "payload file checksums; archives contain only safe relative paths"
  jh_db_manifest "$WORK/payload/database.sqlite" > "$WORK/manifest.check.json"
  python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))' \
    "$WORK/manifest.check.json" "$WORK/payload/manifest.json" || jh_die "database contents differ from the backup manifest"
  result PASS "database integrity_check and contents match manifest ($(jh_manifest_counts "$WORK/payload/manifest.json" | tr '\n' ' '))"

  jh_step "Load n8n image"
  state="$(jh_docker_state image "$IMAGE_ID")" || jh_die "cannot inspect image $IMAGE_ID"
  if [[ "$state" == absent ]]; then
    zstd -q -dc -- "$SET_DIR/n8n-image.tar.zst" | docker load >/dev/null
  fi
  state="$(jh_docker_state image "$IMAGE_ID")" || jh_die "cannot inspect image $IMAGE_ID"
  [[ "$state" == exists ]] || jh_die "image $IMAGE_ID not available after docker load (image ID differs on this Docker engine?)"
  docker tag "$IMAGE_ID" "$RESTORED_TAG"
  result PASS "image $IMAGE_ID loaded and tagged $RESTORED_TAG"

  jh_step "Restore volume $TARGET_VOLUME"
  tar -C "$WORK/vol" -xf "$WORK/payload/n8n_data-files.tar"
  cp -- "$WORK/payload/database.sqlite" "$WORK/vol/database.sqlite"
  [[ -f "$WORK/vol/config" ]] && jh_config_has_key "$WORK/vol/config" || jh_die "n8n config with encryptionKey missing"
  chmod 600 -- "$WORK/vol/config"
  create_owned_volume
  tar --numeric-owner --owner=1000 --group=1000 -C "$WORK/vol" -cf - . | docker cp -a - "$HELPER:$VOLUME_DEST"
  cleanup_containers || jh_die "could not remove helper container $HELPER"
  result PASS "volume created by this run, was empty, now filled (owner 1000:1000, config 0600)"

  jh_step "Restore and verify /data"
  local data_files res version
  mkdir -m 700 -- "$DATA_DIR" || jh_die "could not create $DATA_DIR (already exists?)"
  tar -C "$DATA_DIR" --numeric-owner --strip-components=1 -xf "$WORK/payload/bind-data.tar"
  if [[ $EUID -eq 0 ]]; then chown 1000:1000 -- "$DATA_DIR"; fi   # n8n runs as uid 1000
  data_files="$(jh_tree_matches_tar "$WORK/payload/bind-data.tar" "$DATA_DIR" 1)" \
    || jh_die "restored /data does not match the backup"
  result PASS "/data restored to $DATA_DIR: $data_files files, contents match the archive"

  jh_step "Verify restored volume and /data with n8n CLI (no network)"
  VERIFIER_STARTED=1
  res="$(jh_n8n_verify "$VERIFIER" "$LABEL_KEY=$RAND" "$IMAGE_ID" \
      "type=volume,src=$TARGET_VOLUME,dst=$VOLUME_DEST,volume-nocopy=true" "" "$DATA_DIR")"
  cleanup_containers || jh_die "could not remove verification container $VERIFIER"
  version="$(jh_check_verify "$WORK/payload/manifest.json" "$res")"
  [[ "$version" == "$want_version" ]] || jh_die "n8n version $version differs from backup ($want_version)"
  result PASS "n8n $version: all workflows export, all credentials decrypt"
  [[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("data_files"))' "$res")" == "$data_files" ]] \
    || jh_die "restored /data is not fully visible inside the container"
  result PASS "/data visible read-only inside the container ($data_files files)"

  remove_workdir || jh_die "could not remove work directory"
  result PASS "plaintext work directory removed"
  jh_verify_sums "$SET_DIR"
  result PASS "backup set unchanged after restore"
  write_report PASS
  SUCCESS=1
  echo "ARTIFACT VERIFICATION PASSED. Application recovery is not yet demonstrated:"
  echo "run the smoke test in docs/BACKUP-RESTORE.md with"
  echo "  JH_DRTEST_VOLUME=$TARGET_VOLUME JH_DRTEST_DATA=$DATA_DIR"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
