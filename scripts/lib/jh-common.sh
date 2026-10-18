# Shared helpers for backup-n8n.sh and restore-n8n.sh. Source only; do not execute.
# Callers run with: set -euo pipefail; set -o noclobber; umask 077.

jh_die() { echo "ABORT: $*" >&2; exit 1; }
jh_step() { printf '\n== %s\n' "$*"; }

jh_require_tools() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null || jh_die "missing tool: $t"; done
}

# Reject a path if it is relative or if it or any parent component is a symlink.
jh_assert_no_symlinks() {
  local p="$1" cur="" part
  local -a parts
  [[ "$p" == /* ]] || jh_die "path must be absolute: $p"
  IFS=/ read -ra parts <<<"${p#/}"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    cur="$cur/$part"
    [[ ! -L "$cur" ]] || jh_die "symlink not allowed in path: $cur"
  done
}

# Read a hidden passphrase from the terminal. $1 = 1 to require confirmation.
jh_read_passphrase() {
  local confirm="$1" again=""
  [[ -r /dev/tty ]] || jh_die "a terminal is required for the passphrase prompt"
  IFS= read -rsp "Backup encryption passphrase: " PASS </dev/tty; echo >/dev/tty
  (( ${#PASS} >= 12 )) || jh_die "passphrase must be at least 12 characters"
  if [[ "$confirm" == "1" ]]; then
    IFS= read -rsp "Repeat passphrase: " again </dev/tty; echo >/dev/tty
    [[ "$PASS" == "$again" ]] || jh_die "passphrases do not match"
  fi
}

# gpg wrappers: passphrase via fd 3 (never in argv), isolated homedir, no caching.
jh_gpg() {
  local home="$1"; shift
  gpg --homedir "$home" --batch --quiet --pinentry-mode loopback --no-symkey-cache \
      --passphrase-fd 3 "$@" 3<<<"$PASS"
}
jh_gpg_encrypt() {  # home in out
  jh_gpg "$1" --symmetric --cipher-algo AES256 --s2k-mode 3 --s2k-digest-algo SHA512 \
      --s2k-count 65011712 --compress-algo none -o "$3" "$2"
}
jh_gpg_decrypt_sha256() {  # home file -> sha256 of decrypted stream (no plaintext written)
  local sum
  sum="$(jh_gpg "$1" --decrypt "$2" | sha256sum)" || jh_die "decryption failed: $2"
  echo "${sum%% *}"
}
jh_gpg_kill_agent() { gpgconf --homedir "$1" --kill gpg-agent >/dev/null 2>&1 || true; }

jh_sha256() { local s; s="$(sha256sum -- "$1")"; echo "${s%% *}"; }

# Write SHA256SUMS for every file under $1 (created exclusively; noclobber).
jh_write_sums() {
  local dir="$1" list
  list="$(cd "$dir" && find . -type f ! -path ./SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum --)"
  [[ -n "$list" ]] || jh_die "no files to checksum in $dir"
  printf '%s\n' "$list" > "$dir/SHA256SUMS"
}

# Verify SHA256SUMS and that the directory holds exactly the listed files.
jh_verify_sums() {
  local dir="$1" listed actual
  [[ -f "$dir/SHA256SUMS" ]] || jh_die "missing $dir/SHA256SUMS"
  (cd "$dir" && sha256sum -c --quiet --strict SHA256SUMS) || jh_die "checksum verification failed in $dir"
  listed="$(sed -E 's/^[0-9a-f]{64} [ *]//' "$dir/SHA256SUMS" | LC_ALL=C sort)"
  actual="$(cd "$dir" && find . \( -type f -o -type l \) ! -path ./SHA256SUMS | LC_ALL=C sort)"
  [[ "$listed" == "$actual" ]] || jh_die "file set in $dir does not match SHA256SUMS"
}

# fsync every file and directory under $1.
jh_sync_tree() {
  find "$1" -type f -exec sync -- {} +
  find "$1" -type d -exec sync -- {} +
}

# Atomically publish a fully verified staging directory; never replaces anything.
jh_publish_dir() {
  local src="$1" dst="$2"
  [[ -d "$src" && ! -L "$src" ]] || jh_die "staging directory missing: $src"
  [[ ! -e "$dst" && ! -L "$dst" ]] || jh_die "destination already exists: $dst"
  mv -T --no-clobber -- "$src" "$dst" || jh_die "rename failed: $src -> $dst"
  [[ -d "$dst" && ! -L "$dst" && ! -e "$src" ]] || jh_die "rename did not complete: $dst"
  sync -- "$(dirname -- "$dst")"
}

# Metadata fingerprint of a tree (paths, types, modes, sizes, mtimes, inodes, link
# targets). Detects ordinary modifications; it does NOT prove contents are unchanged
# (a rewrite that preserves size and mtime is not detected). Unreadable entries are fatal.
# Usage: jh_fingerprint DIR [EXCLUDE_GLOB...]  (globs match paths relative to DIR)
jh_fingerprint() {
  python3 -c '
import fnmatch, hashlib, os, sys
root, excl = sys.argv[1], sys.argv[2:]
def fail(err): raise err
if not os.path.isdir(root): sys.exit("not a directory: " + root)
h, n = hashlib.sha256(), 0
for dp, dns, fns in os.walk(root, onerror=fail):
    dns.sort()
    for name in sorted(dns + fns):
        p = os.path.join(dp, name)
        rel = os.path.relpath(p, root)
        if any(fnmatch.fnmatchcase(rel, g) for g in excl):
            if name in dns: dns.remove(name)
            continue
        st = os.lstat(p)
        tgt = os.readlink(p) if os.path.islink(p) else ""
        h.update(f"{rel}\0{st.st_mode}\0{st.st_size}\0{st.st_mtime_ns}\0{st.st_ino}\0{tgt}\n".encode())
        n += 1
print(f"{h.hexdigest()}:{n}")
' "$@"
}

# Consistent SQLite snapshot (transactional VACUUM INTO from a read-only connection).
jh_sqlite_snapshot() {  # src dst
  python3 -c '
import sqlite3, sys, urllib.parse
src, dst = sys.argv[1], sys.argv[2]
con = sqlite3.connect("file:" + urllib.parse.quote(src) + "?mode=ro", uri=True, timeout=60)
con.execute("VACUUM INTO ?", (dst,))
con.close()
chk = sqlite3.connect(dst).execute("PRAGMA integrity_check").fetchone()[0]
sys.exit(0 if chk == "ok" else "integrity_check failed on snapshot")
' "$1" "$2"
}

# Bytes of live data in an SQLite database (pages in use).
jh_sqlite_used_bytes() {
  python3 -c '
import sqlite3, sys, urllib.parse
con = sqlite3.connect("file:" + urllib.parse.quote(sys.argv[1]) + "?mode=ro", uri=True, timeout=60)
pc, fl, ps = (con.execute(f"PRAGMA {p}").fetchone()[0] for p in ("page_count", "freelist_count", "page_size"))
print((pc - fl) * ps)
' "$1"
}

# Full (sensitive) manifest of an n8n SQLite database as JSON. Fails on integrity errors,
# unexpected schema, or unsafe identifiers.
jh_db_manifest() {
  python3 -c '
import json, re, sqlite3, sys, urllib.parse
con = sqlite3.connect("file:" + urllib.parse.quote(sys.argv[1]) + "?mode=ro", uri=True)
one = lambda q: con.execute(q).fetchone()[0]
if one("PRAGMA integrity_check") != "ok":
    sys.exit("integrity_check failed")
tables = {r[0] for r in con.execute("select name from sqlite_master where type = ?", ("table",))}
def count(t):
    if not re.fullmatch(r"[A-Za-z0-9_]+", t) or t not in tables:
        sys.exit("unsafe or missing table")
    return one(f"select count(*) from \"{t}\"")
m = {
    "last_migration": one("select name from migrations order by id desc limit 1"),
    "workflows": [{"id": i, "name": n, "active": bool(a)} for i, n, a in
                  con.execute("select id, name, active from workflow_entity order by id")],
    "credentials": [{"name": n, "type": t} for n, t in
                    con.execute("select name, type from credentials_entity order by name, type")],
    "data_tables": [],
    "executions": count("execution_entity"),
}
if "data_table" in tables:
    for tid, name in con.execute("select id, name from data_table order by name, id"):
        m["data_tables"].append({"name": name, "rows": count("data_table_user_" + str(tid))})
cols = {r[1] for r in con.execute("PRAGMA table_info(execution_entity)")}
m["executions_unfinished"] = (con.execute("select count(*) from execution_entity where status in (?, ?, ?)",
                                         ("new", "running", "waiting")).fetchone()[0] if "status" in cols else None)
for t in ("execution_data", "binary_data"):
    if t in tables:
        m[t + "_rows"] = count(t)
print(json.dumps(m, indent=1, sort_keys=True))
' "$1"
}

# Non-sensitive counts from a db manifest: one "key=value" per line.
jh_manifest_counts() {
  python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
tables = m["data_tables"]
print("workflows=%d" % len(m["workflows"]))
print("credentials=%d" % len(m["credentials"]))
print("data_tables=%d" % len(tables))
print("data_table_rows=%d" % sum(t["rows"] for t in tables))
print("executions=%d" % m["executions"])
' "$1"
}

# Check n8n CLI verification JSON against a db manifest. Prints n8n version on success.
jh_check_verify() {  # manifest.json verify_json_string
  python3 -c '
import json, re, sys
m = json.load(open(sys.argv[1])); v = json.loads(sys.argv[2])
errs = []
if v.get("workflows") != len(m["workflows"]): errs.append("workflow export count mismatch")
if v.get("credentials") != len(m["credentials"]): errs.append("credential export count mismatch")
if v.get("credentials_decrypted") != len(m["credentials"]): errs.append("credentials did not all decrypt")
ver = v.get("n8n_version") or ""
if not re.fullmatch(r"\d+\.\d+\.\d+([-+.][0-9A-Za-z.-]+)?", ver): errs.append("n8n version could not be determined")
if errs: sys.exit("; ".join(errs))
print(ver)
' "$1" "$2"
}

# Runs inside the n8n image (node). Exports workflows and encrypted credentials to
# $JH_OUT (if set) and proves every credential decrypts, without the plaintext ever
# leaving the container tmpfs. Prints one JSON line of counts.
JH_VERIFY_JS='
const {execFileSync} = require("child_process"), fs = require("fs");
const tmp = "/tmp/jh-verify", out = process.env.JH_OUT || "";
fs.mkdirSync(tmp, {recursive: true});
const dir = out || tmp;
if (out) fs.mkdirSync(out, {recursive: true});
const n8n = (a) => execFileSync("n8n", a, {stdio: ["ignore", "ignore", "inherit"]});
n8n(["export:workflow", "--all", "--output=" + dir + "/workflows.json"]);
n8n(["export:credentials", "--all", "--output=" + dir + "/credentials.encrypted.json"]);
n8n(["export:credentials", "--all", "--decrypted", "--output=" + tmp + "/decrypted.json"]);
const rd = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
const w = rd(dir + "/workflows.json"), e = rd(dir + "/credentials.encrypted.json");
const d = rd(tmp + "/decrypted.json");
fs.rmSync(tmp + "/decrypted.json");
const ver = execFileSync("n8n", ["--version"], {encoding: "utf8", stdio: ["ignore", "pipe", "inherit"]})
  .trim().split("\n").pop().trim();
let dataFiles = null;
if (process.env.JH_DATA_CHECK) {
  const walk = (p) => fs.readdirSync(p, {withFileTypes: true})
    .reduce((n, e) => n + (e.isDirectory() ? walk(p + "/" + e.name) : e.isFile() ? 1 : 0), 0);
  dataFiles = walk("/data");
}
const ok = d.filter((c) => c && c.data && typeof c.data === "object" && Object.keys(c.data).length > 0).length;
console.log(JSON.stringify({workflows: w.length, credentials: e.length, credentials_decrypted: ok,
  n8n_version: ver, data_files: dataFiles}));
'

# Run the verification in a throwaway, network-less container. Prints the JSON line.
jh_n8n_verify() {  # name label image mount_spec out_dir_in_container [data_dir_to_mount_ro]
  local name="$1" label="$2" image="$3" mount="$4" out="$5" data="${6:-}" res
  local -a extra=()
  [[ -z "$data" ]] || extra=(--mount "type=bind,src=$data,dst=/data,readonly" --env JH_DATA_CHECK=1)
  res="$(docker run --rm --name "$name" --label "$label" --network none --user 1000:1000 "${extra[@]}" \
      --tmpfs /tmp:rw,nosuid,nodev,size=256m \
      --env N8N_DIAGNOSTICS_ENABLED=false --env N8N_VERSION_NOTIFICATIONS_ENABLED=false \
      --env N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true --env "JH_OUT=$out" \
      --mount "$mount" --entrypoint node "$image" -e "$JH_VERIFY_JS")" \
    || jh_die "n8n verification container failed"
  printf '%s\n' "$res" | tail -n 1
}

# Print "exists" or "absent" for a Docker object. "absent" requires a non-zero exit AND
# stderr consisting of exactly one Docker missing-object message naming this object;
# anything else (daemon unreachable, permission denied, lookalike text) is an error and
# must never be read as absence.
jh_docker_state() {  # container|volume|image|network name
  local err rc=0
  err="$(docker "$1" inspect "$2" 2>&1 >/dev/null)" || rc=$?
  if (( rc == 0 )); then echo exists; return 0; fi
  if jh_is_missing_object_error "$1" "$2" <<<"$err"; then echo absent; return 0; fi
  echo "docker $1 inspect $2 failed (exit $rc): $err" >&2
  return 1
}

# stdin: docker inspect stderr. Exit 0 only for a recognized missing-object message.
jh_is_missing_object_error() {  # kind name
  python3 -c '
import re, sys
kind, name = sys.argv[1], re.escape(sys.argv[2])
d = r"Error(?: response from daemon)?: "
pats = {
    "container": [d + r"No such (?:container|object): " + name],
    "volume":    [d + r"get " + name + r": no such volume", d + r"No such volume: " + name],
    "image":     [d + r"No such image: " + name + r"(?::latest)?"],
    "network":   [d + r"network " + name + r" not found", d + r"No such network: " + name],
}.get(kind)
lines = [l.strip() for l in sys.stdin.read().splitlines() if l.strip()]
sys.exit(0 if pats and len(lines) == 1 and any(re.fullmatch(p, lines[0]) for p in pats) else 1)
' "$1" "$2"
}

# Controlled network probe (runs in the n8n image with node). JH_ENDPOINT_JS serves a
# known token on :8080; JH_PROBE_JS fetches argv[1] with a 3 s timeout and prints "open"
# only if the token comes back, otherwise "blocked".
JH_ENDPOINT_JS='require("http").createServer((q, r) => r.end("jh-probe-ok")).listen(8080)'
JH_PROBE_JS='
fetch(process.argv[1], {signal: AbortSignal.timeout(3000)})
  .then((r) => r.text()).then((t) => console.log(t === "jh-probe-ok" ? "open" : "unexpected"),
                              () => console.log("blocked"));
'

# Remove a container only if it carries our exact label value, then confirm it is gone.
# Returns 0 if absent afterwards, non-zero on label mismatch or any failure.
jh_remove_labeled_container() {  # name label_key label_value
  local state v
  state="$(jh_docker_state container "$1")" || return 1
  [[ "$state" == absent ]] && return 0
  v="$(docker container inspect --format "{{index .Config.Labels \"$2\"}}" "$1")" || return 1
  [[ "$v" == "$3" ]] || { echo "container $1 is not ours (label mismatch); not removing" >&2; return 1; }
  docker rm -f "$1" >/dev/null || return 1
  state="$(jh_docker_state container "$1")" || return 1
  [[ "$state" == absent ]]
}

# Compare a directory with a tar of the same tree (after stripping N leading path
# components): same regular files, same SHA-256 contents. Prints the file count.
jh_tree_matches_tar() {  # tar dir strip
  python3 -c '
import hashlib, os, sys, tarfile
tar, root, strip = sys.argv[1], sys.argv[2], int(sys.argv[3])
want = {}
with tarfile.open(tar, "r:") as t:
    for m in t.getmembers():
        if m.isfile():
            parts = os.path.normpath(m.name).split("/")[strip:]
            want["/".join(parts)] = hashlib.sha256(t.extractfile(m).read()).hexdigest()
def fail(err): raise err
have = {}
for dp, dns, fns in os.walk(root, onerror=fail):
    for f in fns:
        p = os.path.join(dp, f)
        if os.path.islink(p) or not os.path.isfile(p): sys.exit("unexpected non-regular file: " + p)
        with open(p, "rb") as fh:
            have[os.path.relpath(p, root)] = hashlib.sha256(fh.read()).hexdigest()
if want != have:
    sys.exit("restored tree differs from archive (%d archived, %d restored)" % (len(want), len(have)))
print(len(want))
' "$@"
}

# The single image reference in a compose file.
jh_compose_image() {
  python3 -c '
import re, sys
imgs = re.findall(r"^\s*image:\s*[\"\x27]?([^\s\"\x27#]+)", open(sys.argv[1]).read(), re.M)
if len(imgs) != 1: sys.exit("expected exactly one image in compose file")
print(imgs[0])
' "$1"
}

# Does an n8n config file contain a non-empty encryptionKey?
jh_config_has_key() {
  python3 -c '
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])).get("encryptionKey") else 1)
' "$1"
}

# Read "key: value" from a public MANIFEST.txt.
jh_manifest_field() {  # file key
  local v
  v="$(sed -n "s/^$2: //p" "$1")"
  [[ -n "$v" && "$v" != *$'\n'* ]] || jh_die "manifest field missing or duplicated: $2"
  printf '%s\n' "$v"
}

# Validate a tar before extraction: only regular files and directories, relative paths,
# no "..", optionally all under PREFIX. Usage: jh_tar_validate TAR [PREFIX]
jh_tar_validate() {
  python3 -c '
import os, sys, tarfile
path, prefix = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
with tarfile.open(path, "r:") as t:
    for m in t.getmembers():
        n = os.path.normpath(m.name)
        if m.name.startswith("/") or n == ".." or n.startswith("../"):
            sys.exit("unsafe path in archive: " + m.name)
        if not (m.isfile() or m.isdir()):
            sys.exit("unsupported member type in archive: " + m.name)
        if prefix and n != "." and n != prefix and not n.startswith(prefix + "/"):
            sys.exit("unexpected path in archive: " + m.name)
' "$@" || jh_die "archive failed validation: $1"
}

# Plaintext staging must be RAM-backed (tmpfs).
jh_assert_tmpfs() {
  local fst
  fst="$(findmnt -no FSTYPE -T "$1")" || jh_die "cannot determine filesystem of $1"
  [[ "$fst" == "tmpfs" ]] || jh_die "$1 is not tmpfs (got $fst); refusing to stage plaintext on disk"
}

# Free bytes usable for RAM staging: the smaller of tmpfs free space and MemAvailable
# minus a 512 MiB reserve (tmpfs pages beyond available memory would be swapped).
jh_ram_staging_bytes() {
  local avail mem
  avail="$(df -B1 --output=avail -- "$1" | tail -n 1 | tr -d ' ')"
  mem="$(awk '/^MemAvailable:/ {print $2 * 1024}' "${JH_MEMINFO:-/proc/meminfo}")"
  [[ "$avail" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] || jh_die "cannot determine free memory"
  mem=$(( mem - 512 * 1024 * 1024 ))
  echo $(( avail < mem ? avail : mem ))
}

jh_warn_if_swap() {
  if [[ "$(wc -l < "${JH_SWAPS:-/proc/swaps}")" -gt 1 ]]; then
    echo "NOTE: swap is active; RAM-staged plaintext could be written to swap under memory pressure."
  fi
}

# Directory is (or is inside) another directory, after resolving symlinks.
jh_path_within() {  # path dir
  local p d
  p="$(readlink -m -- "$1")"; d="$(readlink -m -- "$2")"
  [[ "$p" == "$d" || "$p" == "$d"/* ]]
}
