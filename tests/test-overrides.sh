# Sourced after scripts/backup-n8n.sh in tests: redirects every path into the fixture
# ($JH_T) and replaces root/tty-only steps. Production code is otherwise unchanged.
load_config() {
  REPO="$JH_T/repo"
  USB_UUID="96BD-7884"
  USB_LABEL="JOB_HUNTER"
  USB_FSTYPE="exfat"
  USB_MOUNT_OPTS="rw,nosuid,nodev,noexec"
  USB_SUBDIR="job-hunter-backups"
  MOUNT_BASE="$JH_T/run"
  LOCAL_PARENT="$JH_T/local-parent"
  LOCAL_ROOT="$LOCAL_PARENT/job-hunter"
  WORK_BASE="$JH_T/shm"
  LOCK_FILE="$JH_T/run/backup.lock"
  CONTAINER="n8n"
  SERVICE="n8n"
  VOLUME="n8n_data"
  VOLUME_DEST="/home/node/.n8n"
  BIND_DEST="/data"
  CAPTURE_MODE="${CAPTURE_MODE:-online}"
}
require_root() { :; }
read_passphrase() { PASS="$JH_TEST_PASS"; }
set_sandbox_owner() { chmod 700 -- "$1"; }
backup_timestamp() { echo "${JH_TEST_TS:-20260101-000000}"; }
work_base() { echo "$JH_T/shm"; }
if [[ -n "${JH_TEST_FP_CHANGE:-}" ]]; then
  jh_fingerprint() { local n; n=$(( $(cat "$JH_T/fp" 2>/dev/null || echo 0) + 1 )); echo "$n" >| "$JH_T/fp"; echo "fp-$n"; }
fi
if [[ -n "${JH_TEST_NESTED_FAIL:-}" ]]; then
  jh_sqlite_used_bytes() { false; echo 1; }   # fails mid-function inside $(...)
fi
