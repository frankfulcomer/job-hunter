#!/usr/bin/env bash
# Job Hunter backup: an encrypted, verified, offline-restorable backup set written to
# the local backup disk and the JOB_HUNTER USB drive.
#
# Usage:  sudo bash scripts/backup-n8n.sh
#         sudo CAPTURE_MODE=pause bash scripts/backup-n8n.sh    # freeze n8n during capture
#         sudo CAPTURE_MODE=stopped bash scripts/backup-n8n.sh  # n8n already cleanly stopped
#                                                               # by the operator (see docs)
#
# Backup set (identical on both destinations, published only after verification):
#   job-hunter-data.tar.zst.gpg  AES256 (GPG symmetric): database snapshot, volume files,
#                                /data, workflow + encrypted credential exports, manifest
#   n8n-image.tar.zst            the exact running image (docker save; public content)
#   repo.bundle, kit/            repository and restore scripts for offline recovery
#   MANIFEST.txt, SHA256SUMS     non-sensitive summary and checksums
#
# Safety: never stops, restarts, or execs into production; never overwrites or deletes
# existing backups; plaintext exists only in a private RAM-backed work directory; any
# failure exits non-zero and prints BACKUP FAILED. See docs/BACKUP-RESTORE.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/jh-common.sh
source "$SCRIPT_DIR/lib/jh-common.sh"

load_config() {
  REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
  USB_UUID="96BD-7884"
  USB_LABEL="JOB_HUNTER"
  USB_FSTYPE="exfat"
  USB_MOUNT_OPTS="rw,nosuid,nodev,noexec,uid=0,gid=0,fmask=0177,dmask=0077"
  USB_SUBDIR="job-hunter-backups"
  MOUNT_BASE="/run"
  LOCAL_PARENT="/mnt/storage/backups"
  LOCAL_ROOT="$LOCAL_PARENT/job-hunter"
  WORK_BASE="/dev/shm"
  LOCK_FILE="/run/job-hunter-backup.lock"
  CONTAINER="n8n"
  SERVICE="n8n"
  VOLUME="n8n_data"
  VOLUME_DEST="/home/node/.n8n"
  BIND_DEST="/data"
  CAPTURE_MODE="${CAPTURE_MODE:-online}"
  export DOCKER_HOST="unix:///var/run/docker.sock"
  unset DOCKER_CONTEXT
}

# Live database files are captured by the SQLite snapshot; event logs are diagnostic
# only, append continuously, and are deliberately excluded.
VOLUME_EXCLUDES=(database.sqlite database.sqlite-wal database.sqlite-shm database.sqlite-journal 'n8nEventLog*.log')
PAYLOAD_FILES="./
./SHA256SUMS
./bind-data.tar
./credentials.encrypted.json
./database.sqlite
./manifest.json
./n8n_data-files.tar
./verify.json
./workflows.json"

backup_timestamp() { date +%Y%m%d-%H%M%S; }
require_root() { [[ $EUID -eq 0 ]] || jh_die "run with sudo"; }
read_passphrase() { jh_read_passphrase 1; }
set_sandbox_owner() { chown -R 1000:1000 -- "$1"; chmod 700 -- "$1"; }

init_state() {
  TS="$(backup_timestamp)"
  NAME="job-hunter-$TS"
  RAND="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  [[ ${#RAND} -eq 12 ]] || jh_die "could not generate random id"
  LABEL_KEY="job-hunter.backup"
  SANDBOX_NAME="jh-backup-verify-$RAND"
  PASS=""
  WORK=""; GNUPG_HOME=""
  PAUSED=0; SANDBOX_STARTED=0
  USB_DEV=""; USB_MNT=""; USB_MNT_CREATED=0; USB_MOUNTED=0
  LOCAL_SET=""; LOCAL_PARTIAL=""; LOCAL_PARTIAL_CREATED=0; LOCAL_PUBLISHED=0
  USB_SET=""; USB_PARTIAL=""; USB_PARTIAL_CREATED=0; USB_PUBLISHED=0
  SUCCESS=0
}

on_exit() {
  local rc=$? p
  local -a problems=()
  set +e
  exec 1>&7 2>&8   # traps can fire while a command's output is redirected
  trap - EXIT HUP INT TERM
  PASS=""; unset PASS
  if [[ $PAUSED -eq 1 ]]; then
    if docker unpause "$CONTAINER" >/dev/null; then PAUSED=0
    else problems+=("n8n is still PAUSED. Run: sudo docker unpause $CONTAINER"); fi
  fi
  if [[ $SANDBOX_STARTED -eq 1 ]]; then
    jh_remove_labeled_container "$SANDBOX_NAME" "$LABEL_KEY" "$RAND" \
      || problems+=("could not remove verification container $SANDBOX_NAME")
  fi
  if [[ -n "$WORK" ]]; then
    remove_workdir || problems+=("could not remove plaintext work directory $WORK; delete it manually")
  fi
  if [[ $USB_MOUNTED -eq 1 ]]; then
    sync
    if umount "$USB_MNT"; then USB_MOUNTED=0
    else problems+=("USB is still mounted at $USB_MNT. Do NOT remove it. Run: sudo umount $USB_MNT"); fi
  fi
  if [[ $USB_MOUNTED -eq 0 && $USB_MNT_CREATED -eq 1 ]]; then
    rmdir -- "$USB_MNT" && USB_MNT_CREATED=0 || problems+=("could not remove mount point $USB_MNT")
  fi
  if [[ $rc -eq 0 && $SUCCESS -eq 1 && ${#problems[@]} -eq 0 ]]; then exit 0; fi

  echo
  echo "BACKUP FAILED (exit $rc). This run did not produce a complete, verified backup."
  for p in "${problems[@]}"; do echo "WARNING: $p"; done
  if [[ $LOCAL_PUBLISHED -eq 1 ]]; then
    echo "Local set $LOCAL_SET is complete and verified; the USB copy is not."
  elif [[ $LOCAL_PARTIAL_CREATED -eq 1 ]]; then
    echo "Incomplete local item (encrypted or non-secret content only): $LOCAL_PARTIAL"
  fi
  if [[ $USB_PUBLISHED -eq 1 ]]; then
    echo "USB set was written but final device verification did not complete: $USB_SET"
  elif [[ $USB_PARTIAL_CREATED -eq 1 ]]; then
    echo "Incomplete USB item: $USB_SUBDIR/$NAME.partial on $USB_LABEL"
  fi
  echo "Existing backups were not modified."
  exit $(( rc == 0 ? 1 : rc ))
}

remove_workdir() {
  [[ -n "$WORK" ]] || return 0
  [[ "$WORK" == "$WORK_BASE"/jh-backup.* && -d "$WORK" && ! -L "$WORK" ]] || return 1
  jh_gpg_kill_agent "$GNUPG_HOME"
  rm -rf -- "$WORK" || return 1
  WORK=""
}

acquire_lock() {
  exec 9>>"$LOCK_FILE"
  flock -n 9 || jh_die "another backup is running"
}

identify_usb() {
  jh_step "Identify USB destination"
  local dev parent tran mounts
  dev="$(blkid -U "$USB_UUID")" || jh_die "USB with UUID $USB_UUID not found"
  USB_DEV="$(readlink -f -- "$dev")"
  [[ "$(blkid -s LABEL -o value "$USB_DEV")" == "$USB_LABEL" ]] || jh_die "label mismatch on $USB_DEV"
  [[ "$(blkid -s TYPE -o value "$USB_DEV")" == "$USB_FSTYPE" ]] || jh_die "filesystem is not $USB_FSTYPE on $USB_DEV"
  parent="$(lsblk -no PKNAME "$USB_DEV")"
  [[ -n "$parent" ]] || jh_die "cannot determine parent disk of $USB_DEV"
  tran="$(lsblk -dno TRAN "/dev/$parent")"
  [[ "$tran" == "usb" ]] || jh_die "$USB_DEV is not on a USB disk (transport: ${tran:-none})"
  if mounts="$(findmnt -rn -S "$USB_DEV" -o TARGET)"; then
    jh_die "USB is already mounted at: $mounts. Unmount it first so the script controls the mount."
  fi
  echo "USB: $USB_DEV label=$USB_LABEL uuid=$USB_UUID fs=$USB_FSTYPE transport=usb (not mounted)"
}

validate_deployment() {
  jh_step "Validate production deployment"
  local inspect compose_image ref_id vol_mp
  local -a facts
  COMPOSE_FILE="$REPO/compose.yaml"
  [[ -f "$COMPOSE_FILE" ]] || jh_die "missing $COMPOSE_FILE"
  BIND_SRC_EXPECTED="$REPO/data"
  compose_image="$(jh_compose_image "$COMPOSE_FILE")"
  inspect="$(docker container inspect "$CONTAINER")" || jh_die "cannot inspect container $CONTAINER"
  mapfile -t facts < <(python3 -c "$VALIDATE_PY" "$CONTAINER" "$VOLUME" "$VOLUME_DEST" \
      "$BIND_SRC_EXPECTED" "$BIND_DEST" "$REPO" "$COMPOSE_FILE" "$SERVICE" "$compose_image" "$CAPTURE_MODE" \
      <<<"$inspect"; echo "rc=$?")
  [[ "${facts[-1]}" == "rc=0" && ${#facts[@]} -eq 4 ]] || jh_die "deployment validation failed (see messages above)"
  VOL_SRC="${facts[0]}"; BIND_SRC="${facts[1]}"; IMAGE_ID="${facts[2]}"
  vol_mp="$(docker volume inspect --format '{{.Mountpoint}}' "$VOLUME")"
  [[ "$vol_mp" == "$VOL_SRC" ]] || jh_die "volume $VOLUME mountpoint differs from the container mount"
  jh_assert_no_symlinks "$VOL_SRC"
  jh_assert_no_symlinks "$BIND_SRC"
  [[ -d "$VOL_SRC" && -d "$BIND_SRC" ]] || jh_die "mount sources are not directories"
  DB="$VOL_SRC/database.sqlite"
  [[ -f "$DB" && ! -L "$DB" ]] || jh_die "database not found at $DB"
  IMAGE_REF="$compose_image"
  ref_id="$(docker image inspect --format '{{.Id}}' "$IMAGE_REF")" || jh_die "compose image $IMAGE_REF not present"
  [[ "$ref_id" == "$IMAGE_ID" ]] || jh_die "running container image differs from the compose image"
  IMAGE_SIZE="$(docker image inspect --format '{{.Size}}' "$IMAGE_ID")"
  REPO_COMMIT="$(git -c safe.directory="$REPO" -C "$REPO" rev-parse HEAD)"
  REPO_DIRTY="$(git -c safe.directory="$REPO" -C "$REPO" status --porcelain | wc -l)"
  echo "container=$CONTAINER volume=$VOLUME->$VOLUME_DEST bind=$BIND_SRC->$BIND_DEST: verified"
  echo "image matches compose.yaml; settings indicate SQLite and no external storage"
}

# Validates `docker inspect` JSON (stdin) against the expected deployment. Prints
# volume source, bind source, image id. Never prints environment values.
VALIDATE_PY='
import json, sys
name, vol, vdest, bsrc, bdest, wdir, cfile, svc, cimg, mode = sys.argv[1:11]
d = json.load(sys.stdin)
errs = []
if len(d) != 1: sys.exit("expected one container")
c = d[0]; cfg = c.get("Config") or {}; st = c.get("State") or {}
if c.get("Name", "").lstrip("/") != name: errs.append("container name mismatch")
if mode == "stopped":
    if st.get("Running") or st.get("Restarting"): errs.append("CAPTURE_MODE=stopped but the container is running")
    elif st.get("ExitCode") != 0 or st.get("OOMKilled") or st.get("Status") != "exited":
        errs.append("container did not stop cleanly (expected status exited, exit code 0)")
else:
    if not st.get("Running"): errs.append("container is not running")
    if st.get("Paused"): errs.append("container is already paused")
mounts = c.get("Mounts") or []
vm = [m for m in mounts if m.get("Type") == "volume" and m.get("Name") == vol and m.get("Destination") == vdest and m.get("RW")]
bm = [m for m in mounts if m.get("Type") == "bind" and m.get("Source") == bsrc and m.get("Destination") == bdest]
if len(vm) != 1: errs.append(f"expected volume {vol} mounted read-write at {vdest}")
if len(bm) != 1: errs.append(f"expected bind {bsrc} at {bdest}")
if len(mounts) != 2: errs.append("unexpected mounts: " + ", ".join(sorted(m.get("Destination", "?") for m in mounts)))
lab = cfg.get("Labels") or {}
for k, want in (("com.docker.compose.project.working_dir", wdir),
                ("com.docker.compose.project.config_files", cfile),
                ("com.docker.compose.service", svc)):
    if lab.get(k) != want: errs.append(f"compose label {k} does not match")
if cfg.get("Image") != cimg: errs.append("container image reference differs from compose.yaml")
env = dict(e.split("=", 1) for e in (cfg.get("Env") or []) if "=" in e)
forbid = {"N8N_ENCRYPTION_KEY", "N8N_USER_FOLDER", "DB_SQLITE_DATABASE", "DB_SQLITE_POOL_SIZE_FILE"}
prefixes = ("DB_POSTGRESDB_", "DB_MYSQLDB_", "QUEUE_BULL_", "N8N_EXTERNAL_STORAGE_", "N8N_EXTERNAL_SECRETS_")
for k in sorted(env):
    if k in forbid or k.startswith(prefixes) or k.endswith("_FILE"):
        errs.append(f"unsupported setting present: {k}")
if env.get("DB_TYPE", "sqlite") != "sqlite": errs.append("database is not SQLite")
if env.get("EXECUTIONS_MODE", "regular") != "regular": errs.append("queue mode is not supported")
if env.get("N8N_DEFAULT_BINARY_DATA_MODE", "default") not in ("default", "filesystem", "database"):
    errs.append("external binary data storage is not supported")
for e in errs: print("validation: " + e, file=sys.stderr)
if errs: sys.exit(1)
print(vm[0]["Source"]); print(bm[0]["Source"]); print(c["Image"])
'

create_workdir() {
  jh_assert_no_symlinks "$WORK_BASE"
  jh_assert_tmpfs "$WORK_BASE"
  WORK="$(mktemp -d "$WORK_BASE/jh-backup.XXXXXXXX")"
  chmod 700 -- "$WORK"
  mkdir -m 700 -- "$WORK/payload" "$WORK/sandbox" "$WORK/gnupg"
  GNUPG_HOME="$WORK/gnupg"
}

preflight_work_capacity() {
  local db_used files_bytes need avail
  db_used="$(jh_sqlite_used_bytes "$DB")"
  files_bytes="$(du -sb "${VOLUME_EXCLUDES[@]/#/--exclude=}" -- "$VOL_SRC" "$BIND_SRC" | awk '{s+=$1} END {print s+0}')"
  need=$(( 3 * db_used + 3 * files_bytes + 64 * 1024 * 1024 ))
  avail="$(jh_ram_staging_bytes "$WORK_BASE")"
  (( avail > need )) || jh_die "not enough free memory for RAM staging in $WORK_BASE (need ~$need bytes, have $avail)"
  jh_warn_if_swap
}

capture_snapshot() {
  jh_step "Capture consistent snapshot (mode: $CAPTURE_MODE)"
  local pre post p
  local -a excl=()
  for p in "${VOLUME_EXCLUDES[@]}"; do excl+=("--exclude=./$p"); done
  if [[ "$CAPTURE_MODE" == "pause" ]]; then
    docker pause "$CONTAINER" >/dev/null; PAUSED=1
  fi
  pre="$(capture_fingerprint)" || jh_die "pre-capture fingerprint failed"
  jh_sqlite_snapshot "$DB" "$WORK/payload/database.sqlite"
  tar --numeric-owner --anchored "${excl[@]}" -C "$VOL_SRC" -cf "$WORK/payload/n8n_data-files.tar" .
  tar --numeric-owner -C "$(dirname -- "$BIND_SRC")" -cf "$WORK/payload/bind-data.tar" "$(basename -- "$BIND_SRC")"
  post="$(capture_fingerprint)" || jh_die "post-capture fingerprint failed"
  if [[ $PAUSED -eq 1 ]]; then
    docker unpause "$CONTAINER" >/dev/null
    PAUSED=0
    [[ "$(docker container inspect --format '{{.State.Paused}}' "$CONTAINER")" == "false" ]] \
      || jh_die "n8n did not resume; run: sudo docker unpause $CONTAINER"
  fi
  [[ "$pre" == "$post" ]] || jh_die "n8n file metadata changed during capture; rerun, or use CAPTURE_MODE=pause"
  jh_tar_validate "$WORK/payload/n8n_data-files.tar"
  jh_tar_validate "$WORK/payload/bind-data.tar" "$(basename -- "$BIND_SRC")"
  echo "database snapshot integrity: ok; no metadata change detected in other files during capture"
}

capture_fingerprint() {
  local v b
  v="$(jh_fingerprint "$VOL_SRC" "${VOLUME_EXCLUDES[@]}")" || jh_die "cannot fingerprint $VOL_SRC"
  b="$(jh_fingerprint "$BIND_SRC")" || jh_die "cannot fingerprint $BIND_SRC"
  printf '%s %s\n' "$v" "$b"
}

sandbox_verify() {
  jh_step "Verify snapshot with n8n (isolated, no network)"
  local sb="$WORK/sandbox" res counts
  tar --numeric-owner -C "$sb" -xf "$WORK/payload/n8n_data-files.tar"
  cp -- "$WORK/payload/database.sqlite" "$sb/database.sqlite"
  [[ -f "$sb/config" ]] || jh_die "n8n config file missing from volume"
  jh_config_has_key "$sb/config" || jh_die "encryptionKey missing from n8n config"
  set_sandbox_owner "$sb"
  jh_db_manifest "$WORK/payload/database.sqlite" > "$WORK/payload/manifest.json"
  SANDBOX_STARTED=1
  res="$(jh_n8n_verify "$SANDBOX_NAME" "$LABEL_KEY=$RAND" "$IMAGE_ID" \
      "type=bind,src=$sb,dst=$VOLUME_DEST" "$VOLUME_DEST/jh-out")"
  jh_remove_labeled_container "$SANDBOX_NAME" "$LABEL_KEY" "$RAND" \
    || jh_die "verification container $SANDBOX_NAME could not be confirmed removed"
  SANDBOX_STARTED=0
  N8N_VERSION="$(jh_check_verify "$WORK/payload/manifest.json" "$res")"
  printf '%s\n' "$res" > "$WORK/payload/verify.json"
  cp -- "$sb/jh-out/workflows.json" "$WORK/payload/workflows.json"
  cp -- "$sb/jh-out/credentials.encrypted.json" "$WORK/payload/credentials.encrypted.json"
  counts="$(jh_manifest_counts "$WORK/payload/manifest.json")"
  DATA_FILES="$(python3 -c 'import sys,tarfile; print(sum(m.isfile() for m in tarfile.open(sys.argv[1]).getmembers()))' "$WORK/payload/bind-data.tar")"
  COUNTS="$(tr '\n' ' ' <<<"$counts")data_files=$DATA_FILES"
  classify_consistency
  echo "workflows exported, all credentials decrypt with the backed-up key; n8n $N8N_VERSION"
  echo "counts: $COUNTS"
}

# Descriptive classification only. No capture mode here is an authoritative recovery
# baseline: online and pause captures do not quiesce n8n; a stopped capture relies on the
# operator's clean shutdown. See "Consistency" in docs/BACKUP-RESTORE.md.
classify_consistency() {
  local unfinished
  unfinished="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["executions_unfinished"]; print("unknown" if v is None else v)' \
      "$WORK/payload/manifest.json")"
  case "$CAPTURE_MODE" in
    online)  CONSISTENCY="online capture (n8n running)" ;;
    pause)   CONSISTENCY="paused capture (n8n frozen, not shut down)" ;;
    stopped) CONSISTENCY="stopped capture (container exited cleanly before backup)" ;;
  esac
  CONSISTENCY="$CONSISTENCY; unfinished executions recorded: $unfinished"
  echo "consistency: $CONSISTENCY"
}

build_payload() {
  jh_step "Build encrypted payload"
  local listing
  jh_write_sums "$WORK/payload"
  jh_verify_sums "$WORK/payload"
  PAYLOAD_EXPANDED_BYTES="$(du -sb -- "$WORK/payload" | cut -f1)"
  tar -C "$WORK/payload" -cf - . | zstd -q -T2 -o "$WORK/payload.tar.zst"
  zstd -q -t -- "$WORK/payload.tar.zst"
  listing="$(zstd -dc -- "$WORK/payload.tar.zst" | tar -tf - | LC_ALL=C sort)"
  [[ "$listing" == "$PAYLOAD_FILES" ]] || jh_die "payload archive structure is unexpected"
  PAYLOAD_SHA="$(jh_sha256 "$WORK/payload.tar.zst")"
  PAYLOAD_BYTES="$(stat -c %s -- "$WORK/payload.tar.zst")"
  rm -rf -- "$WORK/payload" "$WORK/sandbox"   # plaintext no longer needed
}

write_set() {  # dir
  local dir="$1" kit="$1/kit"
  jh_gpg_encrypt "$GNUPG_HOME" "$WORK/payload.tar.zst" "$dir/job-hunter-data.tar.zst.gpg"
  docker save "$IMAGE_ID" | zstd -q -T2 -o "$dir/n8n-image.tar.zst"
  zstd -q -t -- "$dir/n8n-image.tar.zst"
  zstd -dc -- "$dir/n8n-image.tar.zst" | tar -tf - | grep -x 'manifest.json' >/dev/null \
    || jh_die "saved image archive has no manifest.json"
  git -c safe.directory="$REPO" -C "$REPO" bundle create "$dir/repo.bundle" --all 2>/dev/null
  git -c safe.directory="$REPO" -C "$REPO" bundle verify "$dir/repo.bundle" >/dev/null 2>&1 \
    || jh_die "repository bundle failed verification"
  # kit/ is a working-tree copy of the deployment (committed or not) in repository layout,
  # so recovery never depends on files being present in repo.bundle.
  mkdir -m 700 -- "$kit"
  cp -- "$COMPOSE_FILE" "$kit/compose.yaml"
  cp -- "$REPO/README.md" "$REPO/.gitignore" "$kit/"
  cp -r -- "$REPO/scripts" "$REPO/restore" "$REPO/docs" "$kit/"
  [[ -f "$kit/restore/compose.restore.yaml" && -x "$kit/scripts/restore-n8n.sh" ]] || jh_die "restore kit incomplete"
  write_public_manifest > "$dir/MANIFEST.txt"
  jh_write_sums "$dir"
}

write_public_manifest() {
  cat <<EOF
format: job-hunter-backup/1
backup: $NAME
created: $(date -Is)
capture_mode: $CAPTURE_MODE
consistency: $CONSISTENCY
image_ref: $IMAGE_REF
image_id: $IMAGE_ID
image_archive: n8n-image.tar.zst
n8n_version: $N8N_VERSION
repo_commit: $REPO_COMMIT
repo_uncommitted_files: $REPO_DIRTY
payload_file: job-hunter-data.tar.zst.gpg
payload_encryption: gpg symmetric AES256
payload_plaintext_sha256: $PAYLOAD_SHA
payload_plaintext_bytes: $PAYLOAD_BYTES
payload_expanded_bytes: $PAYLOAD_EXPANDED_BYTES
counts: $COUNTS
excluded: n8n event logs (diagnostic)
EOF
}

verify_set() {  # dir
  jh_verify_sums "$1"
  [[ "$(jh_gpg_decrypt_sha256 "$GNUPG_HOME" "$1/job-hunter-data.tar.zst.gpg")" == "$PAYLOAD_SHA" ]] \
    || jh_die "decrypted payload does not match in $1"
}

publish_local() {
  jh_step "Write local backup"
  local need avail
  jh_assert_no_symlinks "$LOCAL_PARENT"
  [[ -d "$LOCAL_PARENT" ]] || jh_die "missing $LOCAL_PARENT"
  if [[ ! -e "$LOCAL_ROOT" && ! -L "$LOCAL_ROOT" ]]; then mkdir -m 700 -- "$LOCAL_ROOT"; fi
  jh_assert_no_symlinks "$LOCAL_ROOT"
  [[ -d "$LOCAL_ROOT" ]] || jh_die "$LOCAL_ROOT is not a directory"
  need=$(( PAYLOAD_BYTES + IMAGE_SIZE + 256 * 1024 * 1024 ))
  avail="$(df -B1 --output=avail -- "$LOCAL_ROOT" | tail -n 1 | tr -d ' ')"
  (( avail > need )) || jh_die "not enough local space (need ~$need bytes, have $avail)"
  LOCAL_SET="$LOCAL_ROOT/$NAME"; LOCAL_PARTIAL="$LOCAL_SET.partial"
  [[ ! -e "$LOCAL_SET" && ! -L "$LOCAL_SET" ]] || jh_die "$LOCAL_SET already exists"
  mkdir -m 700 -- "$LOCAL_PARTIAL" || jh_die "$LOCAL_PARTIAL already exists"
  LOCAL_PARTIAL_CREATED=1
  write_set "$LOCAL_PARTIAL"
  verify_set "$LOCAL_PARTIAL"
  jh_sync_tree "$LOCAL_PARTIAL"
  jh_publish_dir "$LOCAL_PARTIAL" "$LOCAL_SET"
  LOCAL_PUBLISHED=1
  echo "local backup verified: $LOCAL_SET"
}

usb_mount() {
  mount -t "$USB_FSTYPE" -o "$USB_MOUNT_OPTS" "$USB_DEV" "$USB_MNT" || jh_die "USB mount failed"
  USB_MOUNTED=1
  usb_assert
}

usb_unmount() {
  sync
  umount "$USB_MNT" || jh_die "USB unmount failed at $USB_MNT. Do NOT remove the drive."
  USB_MOUNTED=0
  if findmnt -rn -M "$USB_MNT" >/dev/null; then jh_die "USB still mounted at $USB_MNT"; fi
}

# The controlled mount point must be exactly our device, filesystem root, read-write.
usb_assert() {
  local line src fst root opts
  [[ -d "$USB_MNT" && ! -L "$USB_MNT" ]] || jh_die "USB mount point invalid"
  line="$(findmnt -rn -M "$USB_MNT" -o SOURCE,FSTYPE,FSROOT,OPTIONS)" || jh_die "USB is not mounted at $USB_MNT"
  [[ "$line" != *$'\n'* ]] || jh_die "multiple mounts stacked at $USB_MNT"
  read -r src fst root opts <<<"$line"
  [[ "$(readlink -f -- "$src")" == "$USB_DEV" ]] || jh_die "unexpected device mounted at $USB_MNT"
  [[ "$fst" == "$USB_FSTYPE" && "$root" == "/" ]] || jh_die "unexpected filesystem at $USB_MNT"
  [[ ",$opts," == *,rw,* ]] || jh_die "USB is not mounted read-write"
}

publish_usb() {
  jh_step "Write USB backup"
  local usb_root need avail
  jh_assert_no_symlinks "$MOUNT_BASE"
  USB_MNT="$(mktemp -d "$MOUNT_BASE/job-hunter-usb.XXXXXXXX")"
  USB_MNT_CREATED=1
  usb_mount
  echo "USB mounted at $USB_MNT"
  usb_root="$USB_MNT/$USB_SUBDIR"
  [[ ! -L "$usb_root" ]] || jh_die "$usb_root is a symlink"
  if [[ ! -e "$usb_root" ]]; then mkdir -- "$usb_root"; fi
  [[ -d "$usb_root" ]] || jh_die "$usb_root is not a directory"
  echo "existing backup sets on USB: $(find "$usb_root" -mindepth 1 -maxdepth 1 | wc -l) (preserved)"
  need=$(( $(du -sb -- "$LOCAL_SET" | cut -f1) + 64 * 1024 * 1024 ))
  avail="$(df -B1 --output=avail -- "$USB_MNT" | tail -n 1 | tr -d ' ')"
  (( avail > need )) || jh_die "not enough USB space (need ~$need bytes, have $avail)"
  USB_SET="$usb_root/$NAME"; USB_PARTIAL="$USB_SET.partial"
  [[ ! -e "$USB_SET" && ! -L "$USB_SET" ]] || jh_die "$USB_SET already exists"
  mkdir -- "$USB_PARTIAL" || jh_die "$USB_PARTIAL already exists"
  USB_PARTIAL_CREATED=1
  cp -r --preserve=timestamps -- "$LOCAL_SET/." "$USB_PARTIAL/"
  usb_assert
  jh_verify_sums "$USB_PARTIAL"
  jh_sync_tree "$USB_PARTIAL"
  usb_assert
  jh_publish_dir "$USB_PARTIAL" "$USB_SET"
  USB_PUBLISHED=1
  # Remount so verification reads from the device rather than the page cache.
  usb_unmount
  usb_mount
  verify_set "$USB_SET"
  usb_unmount
  rmdir -- "$USB_MNT"; USB_MNT_CREATED=0
  echo "USB backup verified after remount: $USB_LABEL:/$USB_SUBDIR/$NAME (drive unmounted)"
}

report() {
  jh_step "Report"
  cat -- "$LOCAL_SET/MANIFEST.txt"
  echo
  echo "Files (local and USB copies are identical and verified):"
  (cd "$LOCAL_SET" && find . -type f -printf '%10s  %P\n' | LC_ALL=C sort -k2)
  echo
  echo "SHA256SUMS:"
  cat -- "$LOCAL_SET/SHA256SUMS"
  echo
  echo "Local: $LOCAL_SET"
  echo "USB:   $USB_LABEL ($USB_UUID):/$USB_SUBDIR/$NAME"
  echo "Consistency: $CONSISTENCY"
  echo "Verified: set checksums, decryption, database integrity, workflow export and credential"
  echo "decryption with the backed-up image. Not demonstrated: restoring and starting n8n on"
  echo "another machine (run the recovery drill in kit/docs/BACKUP-RESTORE.md)."
  echo "Recovery requires the backup passphrase."
}

main() {
  { set +x; } 2>/dev/null
  set -euo pipefail
  shopt -s inherit_errexit   # failures inside $(...) abort too
  set -o noclobber
  umask 077
  exec 7>&1 8>&2
  load_config
  init_state
  trap on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  require_root
  [[ "$CAPTURE_MODE" =~ ^(online|pause|stopped)$ ]] || jh_die "CAPTURE_MODE must be online, pause or stopped"
  jh_require_tools docker python3 zstd tar gpg gpgconf sha256sum blkid lsblk findmnt mount umount \
    flock git od mktemp readlink sync df du stat find xargs
  acquire_lock
  identify_usb
  validate_deployment
  create_workdir
  preflight_work_capacity
  read_passphrase
  capture_snapshot
  sandbox_verify
  build_payload
  publish_local
  publish_usb
  local work_was="$WORK"
  remove_workdir || jh_die "could not remove work directory $WORK"
  [[ ! -e "$work_was" ]] || jh_die "work directory still exists: $work_was"
  report
  SUCCESS=1
  echo
  echo "BACKUP COMPLETE: $NAME"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
