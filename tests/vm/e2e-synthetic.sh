#!/usr/bin/env bash
# Genuine synthetic backup/restore validation inside the DISPOSABLE VM (after
# vm-prepare.sh). Real Docker Engine, real n8n (pinned image), real GPG, real exFAT USB
# disk, synthetic data only. Steps run in a fixed order; each records its log and exit
# status under the evidence directory, and the run exits 0 only if every step passes.
#   sudo bash tests/vm/e2e-synthetic.sh
# Re-running requires reverting the VM to its 'prepared' snapshot.
set -uo pipefail
shopt -s inherit_errexit
die() { echo "ABORT: $*" >&2; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIX="$SRC/tests/vm/fixtures"
OVR="$SRC/tests/vm/vm-overrides.sh"
DEPLOY=/opt/jh-e2e/job-hunter
TS="$(date +%Y%m%d-%H%M%S)"
EVID="/var/tmp/jh-e2e-evidence/$TS"
LOCAL_SETS=/mnt/storage/backups/job-hunter
EXPECT_COUNTS="counts: workflows=2 credentials=1 data_tables=0 data_table_rows=0 executions=0 data_files=2"

[[ $EUID -eq 0 ]] || die "run with sudo"
systemd-detect-virt --vm >/dev/null || die "not running in a virtual machine"
[[ "$(hostname)" == jh-e2e* && -f /etc/jh-e2e-vm ]] || die "not a prepared jh-e2e VM (run vm-prepare.sh)"
[[ ! -e "$DEPLOY" ]] || die "$DEPLOY exists; revert the VM to its 'prepared' snapshot"
# shellcheck disable=SC1091
source /etc/jh-e2e-vm
mkdir -p "$EVID"; chmod 700 "$EVID"
PASSFILE="$EVID/passphrase.synthetic"; WRONGPASS="$EVID/wrong-passphrase.synthetic"
od -An -N24 -tx1 /dev/urandom | tr -d ' \n' > "$PASSFILE"; echo "wrong-passphrase-0000" > "$WRONGPASS"
RESULTS="$EVID/results.tsv"; : > "$RESULTS"
FAILS=0

record() {  # step expected-description pass(0/1)
  local verdict=PASS; [[ "$3" == 0 ]] || { verdict=FAIL; FAILS=$((FAILS + 1)); }
  printf '%s\t%s\t%s\n' "$1" "$verdict" "$2" | tee -a "$RESULTS"
}
step() { echo; echo "######## $1"; }
backup() {  # log mode -> exit status
  ( set -o pipefail; JH_E2E_PASSFILE="$PASSFILE" CAPTURE_MODE="$2" bash -c \
      'source "$1"; source "$2"; main' _ "$DEPLOY/scripts/backup-n8n.sh" "$OVR" 2>&1 | tee "$EVID/$1.log" )
}
restore() {  # log passfile args... -> exit status
  local log="$1" pf="$2"; shift 2
  ( set -o pipefail; JH_E2E_PASSFILE="$pf" HOME=/var/tmp bash -c \
      'source "$1"; source "$2"; main "${@:3}"' _ "$DEPLOY/scripts/restore-n8n.sh" "$OVR" "$@" 2>&1 | tee "$EVID/$log.log" )
}
newest_set() { find "$LOCAL_SETS" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' -newer "$1" | sort | tail -n 1; }
healthy() { local i; for i in $(seq 60); do [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5678/healthz)" == 200 ]] && return 0; sleep 2; done; return 1; }
no_leftovers() {
  [[ -z "$(ls /dev/shm | grep -E '^jh-(backup|restore)\.' || true)" ]] \
    && [[ -z "$(docker ps -aq --filter label=job-hunter.backup)$(docker ps -aq --filter label=job-hunter.restore)" ]] \
    && ! findmnt -rn -S "$JH_E2E_USB_PART" >/dev/null
}

{
  echo "date: $(date -Is)"; uname -a; docker version --format 'docker {{.Server.Version}}'; docker compose version
  echo "usb: $JH_E2E_USB_PART $JH_E2E_USB_UUID"
  echo "-- sha256 of code under test"
  (cd "$SRC" && find scripts restore tests compose.yaml -type f -print0 | sort -z | xargs -0 sha256sum)
} > "$EVID/environment.txt"

IMAGE_REF="$(python3 -c 'import re,sys; print(re.search(r"^\s*image:\s*(\S+)", open(sys.argv[1]).read(), re.M).group(1))' "$SRC/compose.yaml")"

step "S0 pull pinned image"
docker pull -q "$IMAGE_REF" > "$EVID/S0-pull.log" 2>&1; record S0 "pinned n8n image pulled" $?

step "S1 Docker semantics (before any n8n_data volume exists)"
( set -o pipefail; bash "$SRC/tests/docker-integration.sh" --context "$(docker context show)" "$IMAGE_REF" 2>&1 | tee "$EVID/S1-docker-semantics.log" )
record S1 "docker-integration.sh exits 0, all checks ok, cleanup verified" $?

step "S2 synthetic deployment"
(
  set -e
  mkdir -p "$DEPLOY"
  cp -r "$SRC"/{compose.yaml,README.md,.gitignore,scripts,restore,docs} "$DEPLOY/"
  git -C "$DEPLOY" init -q
  git -C "$DEPLOY" add -A
  git -C "$DEPLOY" -c user.name=e2e -c user.email=e2e@example.invalid commit -qm "synthetic deployment"
  mkdir -p "$DEPLOY/data"; cp -r "$FIX/synthetic-data/." "$DEPLOY/data/"; chown -R 1000:1000 "$DEPLOY/data"
  docker volume create n8n_data >/dev/null
  cd "$DEPLOY"
  docker compose run --rm --no-deps -v "$FIX:/fixtures:ro" --entrypoint n8n n8n import:workflow --input=/fixtures/workflows.json
  docker compose run --rm --no-deps -v "$FIX:/fixtures:ro" --entrypoint n8n n8n import:credentials --input=/fixtures/synthetic-credentials.json
  docker compose up -d
  healthy
) > "$EVID/S2-deploy.log" 2>&1
record S2 "synthetic n8n seeded (2 workflows, 1 credential, 2 data files) and healthy" $?

step "S3 backup, online"
touch "$EVID/.t3"; backup S3-backup-online online; rc=$?
SET_ONLINE="$(newest_set "$EVID/.t3")"
[[ $rc -eq 0 && "$(tail -n 1 "$EVID/S3-backup-online.log")" == "BACKUP COMPLETE: "* && -n "$SET_ONLINE" ]] \
  && grep -qx "$EXPECT_COUNTS" "$SET_ONLINE/MANIFEST.txt" \
  && grep -q '^consistency: online capture' "$SET_ONLINE/MANIFEST.txt"
record S3 "exit 0, BACKUP COMPLETE, manifest '$EXPECT_COUNTS', online capture" $?

step "S4 refuses an already-mounted USB"
mkdir -p /mnt/jh-premount; mount "$JH_E2E_USB_PART" /mnt/jh-premount
touch "$EVID/.t4"; backup S4-backup-premounted online; rc=$?
umount /mnt/jh-premount
[[ $rc -ne 0 ]] && grep -q 'already mounted' "$EVID/S4-backup-premounted.log" && [[ -z "$(newest_set "$EVID/.t4")" ]]
record S4 "non-zero exit, 'already mounted', no new set" $?

step "S5 backup, pause"
touch "$EVID/.t5"; backup S5-backup-pause pause; rc=$?
SET_PAUSE="$(newest_set "$EVID/.t5")"
[[ $rc -eq 0 && -n "$SET_PAUSE" && "$(docker container inspect --format '{{.State.Paused}}' n8n)" == false ]] \
  && grep -q '^consistency: paused capture' "$SET_PAUSE/MANIFEST.txt"
record S5 "exit 0, paused capture, n8n unpaused afterwards" $?

step "S6 backup, stopped (operator clean shutdown)"
(cd "$DEPLOY" && docker compose stop n8n) > "$EVID/S6-stop.log" 2>&1
[[ "$(docker container inspect --format '{{.State.Status}} {{.State.ExitCode}}' n8n)" == "exited 0" ]]; stopped_ok=$?
touch "$EVID/.t6"; backup S6-backup-stopped stopped; rc=$?
SET_STOPPED="$(newest_set "$EVID/.t6")"
(cd "$DEPLOY" && docker compose start n8n) >> "$EVID/S6-stop.log" 2>&1; healthy; healthy_rc=$?
[[ $stopped_ok -eq 0 && $rc -eq 0 && -n "$SET_STOPPED" && $healthy_rc -eq 0 ]] \
  && grep -q '^consistency: stopped capture' "$SET_STOPPED/MANIFEST.txt"
record S6 "clean stop (exited 0), exit 0, stopped capture, n8n healthy after start" $?

step "S7 SIGTERM during backup"
touch "$EVID/.t7"
JH_E2E_PASSFILE="$PASSFILE" CAPTURE_MODE=online bash -c 'source "$1"; source "$2"; main' _ \
  "$DEPLOY/scripts/backup-n8n.sh" "$OVR" > "$EVID/S7-sigterm.log" 2>&1 &
bpid=$!   # the backup's own bash process
for _ in $(seq 300); do grep -q 'Verify snapshot' "$EVID/S7-sigterm.log" 2>/dev/null && break; sleep 0.2; done
kill -TERM "$bpid"
wait "$bpid"; rc=$?
sleep 2
[[ $rc -ne 0 ]] && grep -q 'BACKUP FAILED' "$EVID/S7-sigterm.log" && [[ -z "$(newest_set "$EVID/.t7")" ]] && no_leftovers
record S7 "non-zero exit, BACKUP FAILED, no set, no plaintext/containers/mount left" $?

step "S8 restore each set into a new volume"
i=0
for set in "$SET_ONLINE" "$SET_PAUSE" "$SET_STOPPED"; do
  i=$((i + 1)); vol="jh_e2e_restore_$i"
  restore "S8-restore-$i" "$PASSFILE" "$set" --volume "$vol" --data-dir "/var/tmp/$vol-data" --report "$EVID/S8-report-$i.txt"; rc=$?
  [[ $rc -eq 0 ]] && grep -qx 'ARTIFACT VERIFICATION: PASS' "$EVID/S8-report-$i.txt" \
    && grep -q '/data restored to .*: 2 files, contents match' "$EVID/S8-report-$i.txt" \
    && (cd "$set" && sha256sum -c --quiet SHA256SUMS)
  record "S8.$i" "restore of $(basename "${set:-missing}") exits 0, PASS, 2 data files, set unchanged" $?
done

step "S9 smoke test of the stopped-capture restore (isolated)"
(
  set -e
  cp -r "$SET_STOPPED/kit" /var/tmp/jh-drill; cd /var/tmp/jh-drill
  export JH_DRTEST_VOLUME=jh_e2e_restore_3 JH_DRTEST_DATA=/var/tmp/jh_e2e_restore_3-data
  docker compose -f restore/compose.drtest.yaml up -d
  cid="$(docker compose -f restore/compose.drtest.yaml ps -q n8n)"
  for _ in $(seq 60); do
    [[ "$(docker exec "$cid" node -e "fetch('http://localhost:5678/healthz').then(r=>console.log(r.status),()=>console.log(0))")" == 200 ]] && break
    sleep 2
  done
  [[ "$(docker exec "$cid" node -e "fetch('http://localhost:5678/healthz').then(r=>console.log(r.status),()=>console.log(0))")" == 200 ]]
  bash restore/egress-check.sh --context "$(docker context show)" job-hunter/n8n:restored "$cid"
  [[ "$(docker exec "$cid" node -e "console.log(require('fs').readdirSync('/data').length)")" == 2 ]]
  docker compose -f restore/compose.drtest.yaml logs --tail 100 n8n
  docker compose -f restore/compose.drtest.yaml down
) > "$EVID/S9-smoke.log" 2>&1
record S9 "drill n8n healthy (200), EGRESS BLOCKED with positive control, /data has 2 entries" $?

step "S10 negative restores"
restore S10-wrong-pass "$WRONGPASS" "$SET_ONLINE" --volume jh_e2e_wrongpass --report "$EVID/S10-report-wrongpass.txt"; rc=$?
[[ $rc -ne 0 ]] && [[ "$(docker volume ls -q --filter name=^jh_e2e_wrongpass$)" == "" ]]
record S10.1 "wrong passphrase: non-zero exit, no volume created" $?
cp -r "$SET_ONLINE" /var/tmp/jh-tampered; printf 'x' >> /var/tmp/jh-tampered/job-hunter-data.tar.zst.gpg
restore S10-tampered "$PASSFILE" /var/tmp/jh-tampered --volume jh_e2e_tampered --report "$EVID/S10-report-tampered.txt"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'checksum' "$EVID/S10-tampered.log"
record S10.2 "tampered set: non-zero exit at checksum verification" $?

step "S11 final state"
ok=0
for set in "$SET_ONLINE" "$SET_PAUSE" "$SET_STOPPED"; do (cd "$set" && sha256sum -c --quiet SHA256SUMS) || ok=1; done
no_leftovers || ok=1
[[ "$(docker container inspect --format '{{.State.Running}}' n8n)" == true ]] || ok=1
record S11 "all sets verify, no plaintext/containers/mounts left, synthetic n8n running" $ok

echo
echo "Evidence: $EVID"
column -t -s $'\t' "$RESULTS"
if (( FAILS == 0 )); then echo "E2E SYNTHETIC: PASS"; exit 0; fi
echo "E2E SYNTHETIC: FAIL ($FAILS step(s))"; exit 1
