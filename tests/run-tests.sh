#!/usr/bin/env bash
# Tests for scripts/backup-n8n.sh, scripts/restore-n8n.sh and scripts/lib/jh-common.sh.
# Uses fixtures under a temp dir and mocks for docker and device commands; needs no root,
# Docker or USB drive. Real gpg, zstd, tar, git and python3 are used.
#   bash tests/run-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCKS="$ROOT/tests/mocks"
LIB="$ROOT/scripts/lib/jh-common.sh"
PASSED=0; FAILED=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jh-tests.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

export JH_TEST_PASS="correct horse battery staple"
SECRET_KEY="SECRETKEY-7f3a"
SECRET_WF="SECRETWF-Alpha"
SECRET_CRED="SECRETCRED-Gmail"
IMAGE_REF="docker.n8n.io/n8nio/n8n@sha256:cda6bafc7bb4873533e7affb82d1bd47282a7614bdf83242c2293f8ff281261a"

ok() { PASSED=$((PASSED + 1)); echo "  ok   $1"; }
bad() { FAILED=$((FAILED + 1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && sed 's/^/       | /' <<<"$2" | tail -n 25; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d" "${OUT:-}"; fi; }

# Run a snippet with the shared library loaded under production shell options.
lib() { bash -c 'set -euo pipefail; shopt -s inherit_errexit; set -o noclobber; umask 077; source "$1"; eval "$2"' _ "$LIB" "$1" 2>&1; }

# ---------------------------------------------------------------------------- fixture
new_fixture() {
  JH_T="$(mktemp -d "$TMP_ROOT/fx.XXXXXX")"; export JH_T
  export MOCK_STATE="$JH_T/state"
  mkdir -p "$MOCK_STATE/volumes" "$MOCK_STATE/volume-labels" "$MOCK_STATE/containers" "$MOCK_STATE/usb-store" \
           "$JH_T/local-parent" "$JH_T/run" "$JH_T/shm"
  local vol="$JH_T/docker/volumes/n8n_data/_data" repo="$JH_T/repo"
  mkdir -p "$vol/nodes" "$repo"
  printf '{"encryptionKey":"%s"}\n' "$SECRET_KEY" > "$vol/config"; chmod 600 "$vol/config"
  echo '{"name":"installed-nodes","dependencies":{}}' > "$vol/nodes/package.json"
  echo 'event log line' > "$vol/n8nEventLog.log"
  make_db "$vol/database.sqlite"
  cp "$ROOT/compose.yaml" "$ROOT/.gitignore" "$ROOT/README.md" "$repo/"
  mkdir -p "$repo/data"; echo 'bind data' > "$repo/data/keep.txt"
  git -C "$repo" init -q
  git -C "$repo" add compose.yaml .gitignore README.md
  # scripts/, restore/ and docs/ stay uncommitted, as in the real working tree.
  cp -r "$ROOT/scripts" "$ROOT/restore" "$ROOT/docs" "$repo/"
  git -C "$repo" -c user.name=t -c user.email=t@example.com commit -qm fixture
  python3 - "$MOCK_STATE/container.json" "$vol" "$repo" "$IMAGE_REF" "${FIXTURE_VARIANT:-}" <<'PY'
import json, sys
out, vol, repo, ref, variant = sys.argv[1:6]
c = {"Name": "/n8n", "Image": "sha256:" + "ab" * 32,
     "State": {"Running": True, "Paused": False},
     "Mounts": [{"Type": "volume", "Name": "n8n_data", "Source": vol, "Destination": "/home/node/.n8n", "RW": True},
                {"Type": "bind", "Source": repo + "/data", "Destination": "/data", "RW": True}],
     "Config": {"Image": ref, "Env": ["TZ=America/New_York", "N8N_RUNNERS_ENABLED=true", "PATH=/usr/bin"],
                "Labels": {"com.docker.compose.project.working_dir": repo,
                           "com.docker.compose.project.config_files": repo + "/compose.yaml",
                           "com.docker.compose.service": "n8n"}}}
if variant == "extra-mount":
    c["Mounts"].append({"Type": "bind", "Source": "/etc", "Destination": "/host-etc", "RW": False})
if variant == "env-key":
    c["Config"]["Env"].append("N8N_ENCRYPTION_KEY=x")
if variant == "postgres":
    c["Config"]["Env"].append("DB_TYPE=postgresdb")
if variant == "wrong-label":
    c["Config"]["Labels"]["com.docker.compose.project.working_dir"] = "/elsewhere"
if variant == "paused":
    c["State"]["Paused"] = True
if variant in ("stopped-clean", "stopped-dirty"):
    c["State"] = {"Running": False, "Paused": False, "Status": "exited", "OOMKilled": False,
                  "ExitCode": 0 if variant == "stopped-clean" else 137}
json.dump([c], open(out, "w"))
PY
  export MOCK_PROD_VOLDIR="$vol" MOCK_IMAGE_ID="sha256:$(printf 'ab%.0s' {1..32})" MOCK_IMAGE_REF="$IMAGE_REF"
  export MOCK_UUID="96BD-7884" MOCK_DEV="/dev/mock-usb1" MOCK_KEY="$SECRET_KEY"
  touch "$MOCK_STATE/image_present"
  printf 'MemTotal: 8000000 kB\nMemAvailable: %s kB\n' "${FIXTURE_MEM_KB:-4000000}" > "$JH_T/meminfo"
  printf 'Filename Type Size Used Priority\n' > "$JH_T/swaps"
  export JH_MEMINFO="$JH_T/meminfo" JH_SWAPS="$JH_T/swaps"
}

make_db() {
  python3 - "$1" "$SECRET_WF" "$SECRET_CRED" <<'PY'
import sqlite3, sys
db, wf, cred = sys.argv[1:4]
c = sqlite3.connect(db)
c.executescript("""
create table migrations(id integer primary key, name text);
create table workflow_entity(id text, name text, active integer, updatedAt text);
create table credentials_entity(name text, type text, data text);
create table data_table(id text, name text);
create table data_table_user_T1(v text);
create table data_table_user_T2(v text);
create table execution_entity(id integer, status text);
create table execution_data(id integer, data text);
""")
c.execute("insert into migrations values (1, 'Init1'), (2, 'Latest2')")
c.execute("insert into workflow_entity values ('w1', ?, 1, 'x'), ('w2', 'Other', 0, 'y')", (wf,))
c.execute("insert into credentials_entity values (?, 'gmailOAuth2', 'enc'), ('Sheets', 'googleApi', 'enc')", (cred,))
c.execute("insert into data_table values ('T1', 'jobs'), ('T2', 'job_titles')")
c.executemany("insert into data_table_user_T1 values (?)", [("r%d" % i,) for i in range(5)])
c.executemany("insert into data_table_user_T2 values (?)", [("t%d" % i,) for i in range(3)])
c.executemany("insert into execution_entity values (?, 'success')", [(i,) for i in range(4)])
if __import__("os").environ.get("FIXTURE_RUNNING_EXEC"):
    c.execute("update execution_entity set status = 'running' where id = 3")
c.commit()
PY
}

run_backup() {
  OUT="$(PATH="$MOCKS:$PATH" bash -c 'source "$1"; source "$2"; main' _ \
        "$JH_T/repo/scripts/backup-n8n.sh" "$ROOT/tests/test-overrides.sh" 2>&1)"
  RC=$?
}

run_restore() {
  OUT="$(cd "$SET" && HOME="$JH_T" PATH="$MOCKS:$PATH" bash -c 'source "$1"; source "$2"; main "${@:3}"' _ \
        "$SET/kit/scripts/restore-n8n.sh" "$ROOT/tests/test-overrides.sh" "$@" 2>&1)"
  RC=$?
}

# Copy a set, apply a Python edit to its decrypted payload dir, then re-encrypt and
# re-checksum so only the injected content is "wrong".
tamper_set() {  # src dst python_code
  local w="$JH_T/tamper" sha
  rm -rf "$w"; mkdir -p "$w/p"; cp -r "$1" "$2"
  lib "mkdir -m 700 '$w/gh'; PASS='$JH_TEST_PASS'; jh_gpg '$w/gh' --decrypt '$2/job-hunter-data.tar.zst.gpg'" > "$w/p.tar.zst"
  zstd -q -dc "$w/p.tar.zst" | tar -C "$w/p" -xf -
  python3 -c "$3" "$w/p"
  rm "$w/p/SHA256SUMS" "$w/p.tar.zst" "$2/job-hunter-data.tar.zst.gpg" "$2/SHA256SUMS"
  lib "jh_write_sums '$w/p'" >/dev/null
  tar -C "$w/p" -cf - . | zstd -q -o "$w/p.tar.zst"
  lib "PASS='$JH_TEST_PASS'; jh_gpg_encrypt '$w/gh' '$w/p.tar.zst' '$2/job-hunter-data.tar.zst.gpg'" >/dev/null
  sha="$(sha256sum "$w/p.tar.zst" | cut -d' ' -f1)"
  sed -i "s/^payload_plaintext_sha256: .*/payload_plaintext_sha256: $sha/" "$2/MANIFEST.txt"
  lib "jh_write_sums '$2'; jh_gpg_kill_agent '$w/gh'" >/dev/null
}
set_state() { (cd "$1" && find . -printf '%P %s %T@ %m\n' | LC_ALL=C sort && sha256sum SHA256SUMS); }

usb_sets() { find "$MOCK_STATE/usb-store" -mindepth 2 -maxdepth 2 -printf '%f\n' 2>/dev/null | sort; }
local_sets() { find "$JH_T/local-parent/job-hunter" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort; }
no_mounts() { [[ ! -s "$MOCK_STATE/mounts" ]]; }
shm_empty() { [[ -z "$(ls -A "$JH_T/shm")" ]]; }
failed_cleanly() { [[ $RC -ne 0 ]] && grep -q 'BACKUP FAILED' <<<"$OUT" && ! grep -q 'BACKUP COMPLETE' <<<"$OUT"; }

# ---------------------------------------------------------------------------- unit tests
echo "unit: shared library"
d="$(mktemp -d "$TMP_ROOT/u.XXXXXX")"
mkdir -p "$d/real/sub"; ln -s "$d/real" "$d/link"
OUT="$(lib "jh_assert_no_symlinks '$d/real/sub'")"; check "accepts path without symlinks" test $? -eq 0
OUT="$(lib "jh_assert_no_symlinks '$d/link/sub'")"; check "rejects symlinked path component" test $? -ne 0
OUT="$(lib "jh_assert_no_symlinks 'relative/path'")"; check "rejects relative path" test $? -ne 0

mkdir "$d/src1"; echo a > "$d/src1/f"
OUT="$(lib "jh_publish_dir '$d/src1' '$d/dst1'")"
check "publish_dir renames staging to final" test $? -eq 0 -a -f "$d/dst1/f" -a ! -e "$d/src1"
mkdir "$d/src2" "$d/dst2"; echo keep > "$d/dst2/sentinel"
OUT="$(lib "jh_publish_dir '$d/src2' '$d/dst2'")"
check "publish_dir refuses existing destination" test $? -ne 0 -a -d "$d/src2" -a "$(cat "$d/dst2/sentinel")" = keep
mkdir "$d/src3"; ln -s "$d/nowhere" "$d/dst3"
OUT="$(lib "jh_publish_dir '$d/src3' '$d/dst3'")"
check "publish_dir refuses broken-symlink destination" test $? -ne 0 -a -d "$d/src3"

mkdir "$d/sums"; echo one > "$d/sums/a"; mkdir "$d/sums/k"; echo two > "$d/sums/k/b"
OUT="$(lib "jh_write_sums '$d/sums' && jh_verify_sums '$d/sums'")"; check "checksums verify" test $? -eq 0
OUT="$(lib "jh_write_sums '$d/sums'")"; check "SHA256SUMS is never overwritten" test $? -ne 0
echo extra > "$d/sums/extra"
OUT="$(lib "jh_verify_sums '$d/sums'")"; check "unlisted extra file is detected" test $? -ne 0
rm "$d/sums/extra"; echo changed > "$d/sums/a"
OUT="$(lib "jh_verify_sums '$d/sums'")"; check "modified file is detected" test $? -ne 0
rm "$d/sums/a"
OUT="$(lib "jh_verify_sums '$d/sums'")"; check "missing file is detected" test $? -ne 0

mkdir "$d/fp"; echo x > "$d/fp/a"; echo l > "$d/fp/n8nEventLog.log"
f1="$(lib "jh_fingerprint '$d/fp' 'n8nEventLog*.log'")"
echo more >> "$d/fp/n8nEventLog.log"
f2="$(lib "jh_fingerprint '$d/fp' 'n8nEventLog*.log'")"
check "fingerprint ignores excluded files" test "$f1" = "$f2"
echo y >> "$d/fp/a"; f3="$(lib "jh_fingerprint '$d/fp' 'n8nEventLog*.log'")"
check "fingerprint detects modified file" test "$f1" != "$f3"
touch "$d/fp/new"; f4="$(lib "jh_fingerprint '$d/fp' 'n8nEventLog*.log'")"
check "fingerprint detects added file" test "$f3" != "$f4"

mkdir -p "$d/fpu/locked"; chmod 000 "$d/fpu/locked"
OUT="$(lib "jh_fingerprint '$d/fpu'")"; check "fingerprint fails on an unreadable directory" test $? -ne 0
chmod 755 "$d/fpu/locked"
OUT="$(lib "jh_fingerprint '$d/does-not-exist'")"; check "fingerprint fails on a missing directory" test $? -ne 0
OUT="$(lib 'f() { local v; v="$(false)"; echo after; }; x="$(f)"; echo "got $x"')"
check "library test harness propagates nested failures" bash -c '! grep -q "got after" <<<"$1"' _ "$OUT"

mkdir -p "$d/tt/data/sub"; echo a > "$d/tt/data/a"; echo b > "$d/tt/data/sub/b"
tar -C "$d/tt" -cf "$d/tt.tar" data
mkdir "$d/tt-ok"; tar -C "$d/tt-ok" --strip-components=1 -xf "$d/tt.tar"
OUT="$(lib "jh_tree_matches_tar '$d/tt.tar' '$d/tt-ok' 1")"; check "restored tree matches its archive" test "$OUT" = 2
echo changed > "$d/tt-ok/a"
OUT="$(lib "jh_tree_matches_tar '$d/tt.tar' '$d/tt-ok' 1")"; check "changed restored file is detected" test $? -ne 0
echo a > "$d/tt-ok/a"; echo extra > "$d/tt-ok/extra"
OUT="$(lib "jh_tree_matches_tar '$d/tt.tar' '$d/tt-ok' 1")"; check "extra restored file is detected" test $? -ne 0

export MOCK_STATE="$d/ms"; mkdir -p "$MOCK_STATE/volumes" "$MOCK_STATE/volume-labels" "$MOCK_STATE/containers"
mkdir "$MOCK_STATE/volumes/present"
OUT="$(PATH="$MOCKS:$PATH" lib "jh_docker_state volume present")"; check "docker state: exists" test "$OUT" = exists
OUT="$(PATH="$MOCKS:$PATH" lib "jh_docker_state volume missing")"; check "docker state: absent" test "$OUT" = absent
OUT="$(MOCK_INSPECT_ERROR=present PATH="$MOCKS:$PATH" lib "jh_docker_state volume present")"
check "docker state: daemon error is an error, not absence" test $? -ne 0
echo other > "$MOCK_STATE/containers/c1"
OUT="$(PATH="$MOCKS:$PATH" lib "jh_remove_labeled_container c1 k mine")"
check "container with another label is not removed" test $? -ne 0 -a -f "$MOCK_STATE/containers/c1"
echo mine > "$MOCK_STATE/containers/c2"
OUT="$(MOCK_RM_NOOP=1 PATH="$MOCKS:$PATH" lib "jh_remove_labeled_container c2 k mine")"
check "removal is confirmed, not assumed" test $? -ne 0
unset MOCK_STATE

miss() { lib "jh_is_missing_object_error '$1' '$2'" <<<"$3" >/dev/null; }
not_miss() { ! miss "$@"; }
check "real 'No such container' message is absence" miss container c1 "Error: No such container: c1"
check "real 'No such object' message is absence" miss container c1 "Error: No such object: c1"
check "real volume message is absence" miss volume v1 "Error response from daemon: get v1: no such volume"
check "real image message is absence" miss image sha256:ab "Error response from daemon: No such image: sha256:ab"
check "real network message is absence" miss network n1 "Error response from daemon: network n1 not found"
check "message naming another object is not absence" not_miss container c1 "Error: No such container: c10"
check "lookalike 'not found' text is not absence" not_miss network n1 "Error response from daemon: context n1 not found"
check "daemon error is not absence" not_miss volume v1 "Cannot connect to the Docker daemon at unix:///var/run/docker.sock"
check "extra stderr lines are not absence" not_miss volume v1 $'WARNING: x\nError response from daemon: get v1: no such volume'
check "wrong-kind message is not absence" not_miss volume v1 "Error: No such container: v1"
check "regex characters in names are literal" not_miss container a.c "Error: No such container: abc"

make_db "$d/m.sqlite"
OUT="$(lib "jh_db_manifest '$d/m.sqlite' > '$d/m.json' && jh_manifest_counts '$d/m.json'")"
check "db manifest counts are correct" grep -qx 'data_table_rows=8' <<<"$OUT"
python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"insert into data_table values ('x\\\" or 1--', 'evil')\"); c.commit()" "$d/m.sqlite"
OUT="$(lib "jh_db_manifest '$d/m.sqlite'")"; check "unsafe data table identifier is rejected" test $? -ne 0
head -c 4096 /dev/urandom > "$d/garbage.sqlite"
OUT="$(lib "jh_db_manifest '$d/garbage.sqlite'")"; check "corrupt database is rejected" test $? -ne 0

make_db "$d/live.sqlite"
OUT="$(lib "jh_sqlite_snapshot '$d/live.sqlite' '$d/snap.sqlite'")"
check "sqlite snapshot is created and integrity-checked" test $? -eq 0 -a -s "$d/snap.sqlite"
OUT="$(lib "jh_sqlite_snapshot '$d/live.sqlite' '$d/snap.sqlite'")"; check "snapshot refuses existing output" test $? -ne 0

printf 'services:\n  n8n:\n    image: a/b@sha256:1\n' > "$d/c1.yaml"
printf 'services:\n  a:\n    image: x\n  b:\n    image: y\n' > "$d/c2.yaml"
OUT="$(lib "jh_compose_image '$d/c1.yaml'")"; check "compose image is parsed" test "$OUT" = "a/b@sha256:1"
OUT="$(lib "jh_compose_image '$d/c2.yaml'")"; check "multiple compose images are rejected" test $? -ne 0

echo 'payload' > "$d/plain"
OUT="$(lib "mkdir -m 700 '$d/gh'; PASS='$JH_TEST_PASS'; jh_gpg_encrypt '$d/gh' '$d/plain' '$d/enc.gpg'; jh_gpg_decrypt_sha256 '$d/gh' '$d/enc.gpg'")"
check "encryption round-trip hash matches" test "$(tail -n1 <<<"$OUT")" = "$(sha256sum "$d/plain" | cut -d' ' -f1)"
OUT="$(lib "PASS='wrong passphrase here'; jh_gpg_decrypt_sha256 '$d/gh' '$d/enc.gpg'")"
check "wrong passphrase fails decryption" test $? -ne 0
OUT="$(lib "PASS='$JH_TEST_PASS'; jh_gpg_encrypt '$d/gh' '$d/plain' '$d/enc.gpg'")"
check "encryption refuses to overwrite output" test $? -ne 0
lib "jh_gpg_kill_agent '$d/gh'" >/dev/null

# ---------------------------------------------------------------------------- backup e2e
echo "backup: success path"
new_fixture
run_backup
check "exits 0 and ends with BACKUP COMPLETE" test $RC -eq 0 -a "$(tail -n1 <<<"$OUT")" = "BACKUP COMPLETE: job-hunter-20260101-000000"
check "local set published, no .partial" test "$(local_sets)" = "job-hunter-20260101-000000"
check "USB set published, no .partial" test "$(usb_sets)" = "job-hunter-20260101-000000"
SET="$JH_T/local-parent/job-hunter/job-hunter-20260101-000000"
check "local set checksums verify" lib "jh_verify_sums '$SET'"
check "USB set checksums verify" lib "jh_verify_sums '$MOCK_STATE/usb-store/job-hunter-backups/job-hunter-20260101-000000'"
check "USB unmounted at end" no_mounts
check "USB was unmounted and remounted for verification" test "$(cat "$MOCK_STATE/umount_count")" = 2
check "plaintext work directory removed" shm_empty
check "no secrets in local set" bash -c '! grep -rqaF -e "$1" -e "$2" -e "$3" "$4"' _ "$SECRET_KEY" "$SECRET_WF" "$SECRET_CRED" "$SET"
check "no secrets on USB" bash -c '! grep -rqaF -e "$1" -e "$2" -e "$3" "$4"' _ "$SECRET_KEY" "$SECRET_WF" "$SECRET_CRED" "$MOCK_STATE/usb-store"
check "no secret names in console output" bash -c '! grep -qF -e "$1" -e "$2" -e "$3" <<<"$4"' _ "$SECRET_KEY" "$SECRET_WF" "$SECRET_CRED" "$OUT"
check "production container never exec'd, paused or removed" bash -c '! grep -qE "^docker (exec|pause|unpause|rm) .*n8n$|^docker exec" "$1"' _ "$MOCK_STATE/docker.log"
check "verification ran with --network none" grep -q -- '--network none' "$MOCK_STATE/docker.log"
check "no verification container left behind" test -z "$(ls -A "$MOCK_STATE/containers")"
dec="$JH_T/dec"; mkdir "$dec"
lib "mkdir -m 700 '$JH_T/gh'; PASS='$JH_TEST_PASS'; jh_gpg '$JH_T/gh' --decrypt '$SET/job-hunter-data.tar.zst.gpg'" > "$JH_T/p.tar.zst"
zstd -dc "$JH_T/p.tar.zst" | tar -C "$dec" -xf - 2>/dev/null
check "payload decrypts to a verified database snapshot" lib "jh_verify_sums '$dec' && jh_db_manifest '$dec/database.sqlite' >/dev/null"
check "payload contains the encryption key config" bash -c 'tar -xOf "$1" ./config | grep -qF "$2"' _ "$dec/n8n_data-files.tar" "$SECRET_KEY"
check "payload excludes live database and event logs from file archive" bash -c '! tar -tf "$1" | grep -qE "database.sqlite|n8nEventLog"' _ "$dec/n8n_data-files.tar"
check "payload includes /data" bash -c 'tar -tf "$1" | grep -qx "data/keep.txt"' _ "$dec/bind-data.tar"
check "repository bundle clones" git clone -q "$SET/repo.bundle" "$JH_T/clone"
check "restore kit included" test -x "$SET/kit/scripts/restore-n8n.sh" -a -f "$SET/kit/restore/compose.restore.yaml"
check "kit mirrors repository layout (docs paths work)" test -f "$SET/kit/docs/BACKUP-RESTORE.md" -a -f "$SET/kit/compose.yaml" -a -f "$SET/kit/README.md"
check "bundle lacks uncommitted restore files (why recovery uses kit/)" test ! -e "$JH_T/clone/restore/compose.restore.yaml"
check "manifest describes the capture, not a baseline" grep -qx 'consistency: online capture (n8n running); unfinished executions recorded: 0' "$SET/MANIFEST.txt"
check "manifest counts /data files" grep -q 'data_files=1$' "$SET/MANIFEST.txt"
check "console makes no content-unchanged claim" bash -c '! grep -q "files unchanged" <<<"$1"' _ "$OUT"
check "manifest records a real n8n version" grep -qx 'n8n_version: 1.123.4' "$SET/MANIFEST.txt"
check "console states what was not demonstrated" grep -q 'Not demonstrated' <<<"$OUT"
check "manifest has counts, not names" grep -q '^counts: workflows=2 credentials=2 data_tables=2 data_table_rows=8 executions=4' "$SET/MANIFEST.txt"
lib "jh_gpg_kill_agent '$JH_T/gh'" >/dev/null

echo "backup: second run keeps the first"
JH_TEST_TS=20260101-000100 run_backup
check "second run succeeds" test $RC -eq 0
check "both sets present locally" test "$(local_sets | wc -l)" = 2
check "both sets present on USB" test "$(usb_sets | wc -l)" = 2
check "first set unchanged" lib "jh_verify_sums '$SET'"

echo "restore: drill"
rm -f "$MOCK_STATE/image_present"; touch "$MOCK_STATE/no-prod"
before="$(set_state "$SET")"
run_restore . --volume jh_drtest_n8n_data --data-dir "$JH_T/restored-data" --report "$JH_T/report.txt"
check "restore passes" test $RC -eq 0 -a -f "$JH_T/report.txt"
check "report: artifact verification PASS" grep -qx 'ARTIFACT VERIFICATION: PASS' "$JH_T/report.txt"
check "report: application recovery not demonstrated" grep -q '^APPLICATION RECOVERY: NOT DEMONSTRATED' "$JH_T/report.txt"
check "report carries backup consistency" grep -q '^backup consistency: online capture' "$JH_T/report.txt"
check "report: /data contents verified separately" grep -q '/data restored to .*: 1 files, contents match' "$JH_T/report.txt"
check "report: /data visible inside the container" grep -q '/data visible read-only inside the container (1 files)' "$JH_T/report.txt"
check "backup set byte-for-byte unchanged by restore" test "$before" = "$(set_state "$SET")"
check "restored volume is labeled as owned by the run" test -s "$MOCK_STATE/volume-labels/jh_drtest_n8n_data"
check "report contains no secrets" bash -c '! grep -qF -e "$1" -e "$2" -e "$3" "$4"' _ "$SECRET_KEY" "$SECRET_WF" "$SECRET_CRED" "$JH_T/report.txt"
check "image loaded and tagged" grep -q 'job-hunter/n8n:restored' "$MOCK_STATE/tags"
check "volume holds database and config" test -f "$MOCK_STATE/volumes/jh_drtest_n8n_data/database.sqlite" -a -f "$MOCK_STATE/volumes/jh_drtest_n8n_data/config"
check "/data restored" test "$(cat "$JH_T/restored-data/keep.txt")" = "bind data"
check "restore work directory removed" shm_empty
check "no restore containers left" test -z "$(ls -A "$MOCK_STATE/containers")"

run_restore . --volume jh_drtest_n8n_data --report "$JH_T/report2.txt"
check "restore refuses an existing volume" test $RC -ne 0
check "failed restore writes FAIL report" grep -qx 'ARTIFACT VERIFICATION: FAIL' "$JH_T/report2.txt"

MOCK_VOLUME_RACE=1 run_restore . --volume jh_race --report "$JH_T/report-race.txt"
check "volume created by someone else after the check is not touched" \
  test $RC -ne 0 -a "$(cat "$MOCK_STATE/volumes/jh_race/foreign.txt")" = foreign -a ! -e "$MOCK_STATE/volumes/jh_race/database.sqlite"
check "race abort names the cause" grep -q 'already existed' <<<"$OUT"

run_restore . --volume jh_in1 --report "$SET/report.txt"
check "report path inside the set is refused" test $RC -ne 0 -a ! -e "$SET/report.txt"
run_restore . --volume jh_in2 --data-dir "$SET/data" --report "$JH_T/report-in2.txt"
check "--data-dir inside the set is refused" test $RC -ne 0 -a ! -e "$SET/data"
check "set still unchanged after refused restores" test "$before" = "$(set_state "$SET")"

MOCK_N8N_VERSION=9.9.9 run_restore . --volume jh_ver --report "$JH_T/report-ver.txt"
check "n8n version differing from the backup fails restore" test $RC -ne 0
MOCK_N8N_VERSION="" run_restore . --volume jh_ver2 --report "$JH_T/report-ver2.txt"
check "undeterminable n8n version fails restore" test $RC -ne 0

MOCK_SHM_FSTYPE=ext4 run_restore . --volume jh_disk --report "$JH_T/report-disk.txt"
check "restore refuses non-tmpfs staging" test $RC -ne 0 -a ! -d "$MOCK_STATE/volumes/jh_disk"
MOCK_SHM_FSTYPE=ext4 run_restore . --volume jh_disk2 --allow-disk-staging --report "$JH_T/report-disk2.txt"
check "--allow-disk-staging permits it explicitly" test $RC -eq 0
check "disk staging is warned about" grep -q 'allow-disk-staging' <<<"$OUT"

MOCK_RM_FAIL=1 run_restore . --volume jh_rm --report "$JH_T/report-rm.txt"
check "helper container removal failure fails restore" test $RC -ne 0
check "removal failure is reported" grep -q 'could not remove' <<<"$OUT"
rm -f "$MOCK_STATE/containers/"jh-restore-*

tamper_set "$SET" "$JH_T/evil1" 'import io,os,sys,tarfile
t=tarfile.open(os.path.join(sys.argv[1],"n8n_data-files.tar"),"a"); i=tarfile.TarInfo("../escape.txt"); i.size=1; t.addfile(i,io.BytesIO(b"x")); t.close()'
SET_SAVE="$SET"; SET="$JH_T/evil1"
run_restore . --volume jh_evil1 --report "$JH_T/report-evil1.txt"
check "path traversal in volume archive is rejected" test $RC -ne 0 -a ! -d "$MOCK_STATE/volumes/jh_evil1"
check "no file escaped the work directory" bash -c '! find "$1" -name escape.txt | grep -q .' _ "$JH_T"
SET="$SET_SAVE"
tamper_set "$SET" "$JH_T/evil2" 'import os,sys,tarfile
t=tarfile.open(os.path.join(sys.argv[1],"bind-data.tar"),"a"); i=tarfile.TarInfo("data/link"); i.type=tarfile.SYMTYPE; i.linkname="/etc/passwd"; t.addfile(i); t.close()'
SET="$JH_T/evil2"
run_restore . --volume jh_evil2 --data-dir "$JH_T/evil-data" --report "$JH_T/report-evil2.txt"
check "symlink in /data archive is rejected" test $RC -ne 0 -a ! -e "$JH_T/evil-data"
SET="$SET_SAVE"
check "tampered-set tests left no plaintext" shm_empty

MOCK_INSPECT_ERROR=jh_ierr run_restore . --volume jh_ierr --report "$JH_T/report-ierr.txt"
check "volume inspection error is not read as absence" test $RC -ne 0 -a ! -d "$MOCK_STATE/volumes/jh_ierr"
check "inspection error is named" grep -q 'cannot determine whether volume' <<<"$OUT"
MOCK_INSPECT_ERROR=n8n run_restore . --volume n8n_data --report "$JH_T/report-ierr2.txt"
check "production container inspection error refuses n8n_data" test $RC -ne 0 -a ! -d "$MOCK_STATE/volumes/n8n_data"
MOCK_DATA_HIDDEN=1 run_restore . --volume jh_hidden --report "$JH_T/report-hidden.txt"
check "/data not visible in the container fails restore" test $RC -ne 0
MOCK_RM_NOOP=1 run_restore . --volume jh_noop --report "$JH_T/report-noop.txt"
check "container that survives 'docker rm' fails restore" test $RC -ne 0
check "unconfirmed removal is reported" grep -q 'could not' <<<"$OUT"
rm -f "$MOCK_STATE/containers/"jh-restore-*

rm -f "$MOCK_STATE/no-prod"
run_restore . --volume n8n_data --report "$JH_T/report3.txt"
check "restore refuses n8n_data where production exists" test $RC -ne 0 -a ! -d "$MOCK_STATE/volumes/n8n_data"
touch "$MOCK_STATE/no-prod"

JH_TEST_PASS="wrong passphrase here" run_restore . --volume jh_v2 --report "$JH_T/report4.txt"
check "wrong passphrase fails restore before creating a volume" test $RC -ne 0 -a ! -d "$MOCK_STATE/volumes/jh_v2"
check "wrong passphrase leaves no plaintext" shm_empty

cp -r "$SET" "$JH_T/tampered"; printf 'x' >> "$JH_T/tampered/job-hunter-data.tar.zst.gpg"
SET_SAVE="$SET"; SET="$JH_T/tampered"
run_restore . --volume jh_v3 --report "$JH_T/report5.txt"
check "tampered set is rejected" test $RC -ne 0 -a ! -d "$MOCK_STATE/volumes/jh_v3"
SET="$SET_SAVE"

mkdir -p "$JH_T/busy"; echo x > "$JH_T/busy/f"
run_restore . --volume jh_v4 --data-dir "$JH_T/busy" --report "$JH_T/report6.txt"
check "existing --data-dir is refused" test $RC -ne 0 -a "$(cat "$JH_T/busy/f")" = x

MOCK_KEY="different" run_restore . --volume jh_v5 --report "$JH_T/report7.txt"
check "credentials that do not decrypt fail the restore" test $RC -ne 0
rm -f "$MOCK_STATE/no-prod"

echo "backup: failure handling"
new_fixture
mkdir -p "$JH_T/local-parent/job-hunter/job-hunter-20260101-000000"; echo keep > "$JH_T/local-parent/job-hunter/job-hunter-20260101-000000/sentinel"
run_backup
check "name collision fails cleanly" failed_cleanly
check "existing set untouched" test "$(cat "$JH_T/local-parent/job-hunter/job-hunter-20260101-000000/sentinel")" = keep
check "nothing written to USB on collision" test -z "$(usb_sets)"
check "no plaintext left after collision" shm_empty

new_fixture
MOCK_UMOUNT_FAIL_AT=2 run_backup
check "final unmount failure is not reported as success" failed_cleanly
check "unmount failure tells user not to remove drive" grep -q 'Do NOT remove' <<<"$OUT"
check "unmount failure reports local set as complete" grep -q 'Local set .* is complete and verified' <<<"$OUT"

new_fixture
MOCK_UMOUNT_FAIL_AT=1 run_backup
check "unmount failure before remount fails cleanly" failed_cleanly

new_fixture
MOCK_RUN_FAIL=1 run_backup
check "verification container failure fails cleanly" failed_cleanly
check "no local set after verification failure" test -z "$(local_sets)"
check "no plaintext after verification failure" shm_empty

new_fixture
MOCK_KEY="different" run_backup
check "credentials that do not decrypt abort the backup" failed_cleanly
check "no set published when credentials fail" test -z "$(local_sets)"

new_fixture
JH_TEST_FP_CHANGE=1 run_backup
check "files changing during capture aborts" failed_cleanly
check "abort message names the cause" grep -q 'changed during capture' <<<"$OUT"

new_fixture
CAPTURE_MODE=pause JH_TEST_FP_CHANGE=1 run_backup
check "pause mode failure still unpauses n8n" test ! -f "$MOCK_STATE/paused"
check "pause mode called docker unpause" grep -qx 'docker unpause n8n' "$MOCK_STATE/docker.log"

new_fixture
CAPTURE_MODE=pause MOCK_UNPAUSE_FAIL=1 run_backup
check "unpause failure is reported loudly" bash -c 'grep -q "still PAUSED" <<<"$1"' _ "$OUT"
check "unpause failure is not success" failed_cleanly

new_fixture
CAPTURE_MODE=pause run_backup
check "pause mode success path" test $RC -eq 0 -a ! -f "$MOCK_STATE/paused"
check "pause mode is described as paused, not a baseline" \
  grep -qx 'consistency: paused capture (n8n frozen, not shut down); unfinished executions recorded: 0' "$JH_T/local-parent/job-hunter/job-hunter-20260101-000000/MANIFEST.txt"

FIXTURE_RUNNING_EXEC=1 new_fixture
CAPTURE_MODE=pause run_backup
check "unfinished executions are recorded" \
  grep -qx 'consistency: paused capture (n8n frozen, not shut down); unfinished executions recorded: 1' "$JH_T/local-parent/job-hunter/job-hunter-20260101-000000/MANIFEST.txt"

FIXTURE_VARIANT=stopped-clean new_fixture
CAPTURE_MODE=stopped run_backup
check "stopped mode backs up a cleanly exited container" test $RC -eq 0
check "stopped mode is described as such" \
  grep -q '^consistency: stopped capture (container exited cleanly before backup)' "$JH_T/local-parent/job-hunter/job-hunter-20260101-000000/MANIFEST.txt"
check "stopped mode never pauses, starts or stops n8n" bash -c '! grep -qE "^docker (pause|unpause|start|stop|restart)" "$1"' _ "$MOCK_STATE/docker.log"
FIXTURE_VARIANT=stopped-clean new_fixture
run_backup
check "online mode refuses a stopped container" failed_cleanly
FIXTURE_VARIANT=stopped-dirty new_fixture
CAPTURE_MODE=stopped run_backup
check "stopped mode refuses an unclean exit" failed_cleanly
check "unclean exit is named" grep -q 'did not stop cleanly' <<<"$OUT"
new_fixture
CAPTURE_MODE=stopped run_backup
check "stopped mode refuses a running container" failed_cleanly

new_fixture
JH_TEST_NESTED_FAIL=1 run_backup
check "failure inside a command substitution aborts (inherit_errexit)" failed_cleanly
new_fixture
mkdir -m 000 "$MOCK_PROD_VOLDIR/unreadable"
run_backup
chmod 755 "$MOCK_PROD_VOLDIR/unreadable"
check "unreadable directory in the volume aborts the backup" failed_cleanly
check "no set published after traversal failure" test -z "$(local_sets)"
new_fixture
MOCK_INSPECT_ERROR='jh-backup-verify-*' run_backup
check "inspection error on the verification container is not read as removed" failed_cleanly

new_fixture
MOCK_N8N_VERSION="" run_backup
check "undeterminable n8n version aborts the backup" failed_cleanly
check "no set published without a version" test -z "$(local_sets)"

new_fixture
MOCK_SHM_FSTYPE=ext4 run_backup
check "non-tmpfs staging aborts the backup" failed_cleanly
check "nothing written with non-tmpfs staging" test -z "$(local_sets)" -a -z "$(ls -A "$JH_T/shm")"

FIXTURE_MEM_KB=540000 new_fixture
run_backup
check "insufficient free memory aborts the backup" failed_cleanly
check "memory abort names the cause" grep -q 'not enough free memory' <<<"$OUT"

new_fixture
echo '/swap.img file 4194300 0 -2' >> "$JH_SWAPS"
run_backup
check "active swap is disclosed" grep -q 'swap is active' <<<"$OUT"

new_fixture
ln -s /etc/passwd "$MOCK_PROD_VOLDIR/link"
run_backup
check "symlink in the volume aborts the backup (restore would refuse it)" failed_cleanly

new_fixture
CAPTURE_MODE=bogus run_backup
check "invalid capture mode rejected" failed_cleanly

new_fixture
MOCK_TRAN=sata run_backup
check "non-USB device is rejected" failed_cleanly
check "nothing mounted for non-USB device" no_mounts

new_fixture
MOCK_LABEL=OTHER run_backup
check "wrong label is rejected" failed_cleanly

new_fixture
echo "$MOCK_DEV /media/someone/JOB_HUNTER rw" > "$MOCK_STATE/mounts"
run_backup
check "already-mounted USB is refused" failed_cleanly
check "external mount left alone" grep -q '/media/someone/JOB_HUNTER' "$MOCK_STATE/mounts"

new_fixture
MOCK_FINDMNT_FSTYPE=vfat run_backup
check "unexpected filesystem at mount point aborts" failed_cleanly
check "USB unmounted after mount check failure" no_mounts
check "no USB set after mount check failure" test -z "$(usb_sets)"

for v in extra-mount env-key postgres wrong-label paused; do
  FIXTURE_VARIANT="$v" new_fixture
  run_backup
  check "deployment check rejects: $v" failed_cleanly
  check "nothing written for: $v" test -z "$(local_sets)" -a -z "$(usb_sets)"
done

new_fixture
MOCK_REF_ID="sha256:$(printf 'cd%.0s' {1..32})" run_backup
check "image differing from compose.yaml is rejected" failed_cleanly

new_fixture
( MOCK_RUN_SLEEP=3 PATH="$MOCKS:$PATH" bash -c 'source "$1"; source "$2"; main' _ \
    "$JH_T/repo/scripts/backup-n8n.sh" "$ROOT/tests/test-overrides.sh" > "$JH_T/term.log" 2>&1 ) &
pid=$!
for _ in $(seq 50); do grep -q 'Verify snapshot' "$JH_T/term.log" 2>/dev/null && break; sleep 0.1; done
pkill -TERM -P "$pid" -f 'backup-n8n.sh' 2>/dev/null || kill -TERM "$pid"
wait "$pid"; RC=$?; OUT="$(cat "$JH_T/term.log")"
check "SIGTERM during capture fails cleanly" failed_cleanly
check "SIGTERM leaves no plaintext" shm_empty
check "SIGTERM leaves no partial set" test -z "$(local_sets)"

echo "docs"
check "documented logged backups return the backup's exit status (pipefail, no trailing echo)" \
  bash -c 'l="$(grep -hE "backup-n8n.sh.*\| tee" "$@")"; [[ -n "$l" ]] && ! grep -v "set -o pipefail" <<<"$l" | grep -q . && ! grep -q "| tee[^)]*; *echo" <<<"$l"' \
  _ "$ROOT/docs/BACKUP-RESTORE.md" "$ROOT/docs/VM-VALIDATION.md"
check "README integration command passes --context" grep -q 'docker-integration.sh --context' "$ROOT/README.md"
check "no internet-dependent egress probe remains" bash -c '! grep -rqE "example\.com|api\.resend\.com" "$@"' _ \
  "$ROOT/tests/docker-integration.sh" "$ROOT/restore" "$ROOT/docs"
check "docs make no authoritative-baseline claim for online/pause" \
  bash -c '! grep -iE "baseline" "$1" | grep -qiE "online|pause"' _ "$ROOT/docs/BACKUP-RESTORE.md"
check "scripts never label a capture as a baseline" \
  bash -c '! grep -n "CONSISTENCY=.*baseline" "$@"' _ "$ROOT/scripts/backup-n8n.sh"

echo "docker-integration.sh guards (no resources may be created)"
new_fixture
itest() { OUT="$(PATH="$MOCKS:$PATH" bash "$ROOT/tests/docker-integration.sh" "$@" 2>&1)"; RC=$?; }
DOCKER_HOST=tcp://x itest --context default img
check "refuses when DOCKER_HOST is set" test $RC -ne 0
MOCK_CONTEXT=other itest --context default img
check "refuses when the current context differs" test $RC -ne 0
itest --context default img
check "refuses where production n8n exists" test $RC -ne 0 -a "$(cat "$MOCK_STATE/last-context")" = default
touch "$MOCK_STATE/no-prod"; MOCK_INSPECT_ERROR=n8n itest --context default img
check "refuses when production presence cannot be determined" test $RC -ne 0
check "guards created no Docker resources" bash -c '! grep -qE "^docker (volume create|create|run|network create)" "$1"' _ "$MOCK_STATE/docker.log"

echo "VM scripts refuse to run on this host"
OUT="$(bash "$ROOT/tests/vm/vm-prepare.sh" --usb-disk /dev/null 2>&1)"; check "vm-prepare.sh refuses outside a prepared VM / without root" test $? -ne 0
OUT="$(bash "$ROOT/tests/vm/e2e-synthetic.sh" 2>&1)"; check "e2e-synthetic.sh refuses outside a prepared VM / without root" test $? -ne 0
check "VM fixtures are valid JSON with the expected counts" python3 -c '
import json, os, sys; f = sys.argv[1]
assert len(json.load(open(f + "/workflows.json"))) == 2 and len(json.load(open(f + "/synthetic-credentials.json"))) == 1
assert sum(len(x[2]) for x in os.walk(f + "/synthetic-data")) == 2' "$ROOT/tests/vm/fixtures"

echo
echo "passed: $PASSED  failed: $FAILED"
[[ $FAILED -eq 0 ]]
