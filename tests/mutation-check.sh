#!/usr/bin/env bash
# Reproducible mutation check: re-introduces each previously fixed defect into a scratch
# copy of the repository, runs tests/run-tests.sh there, and requires the named tests to
# fail. Also runs the unmutated copy, which must pass. Writes an evidence file.
#   bash tests/mutation-check.sh [EVIDENCE_FILE]   (default: docs/evidence/mutation-check.txt)
set -euo pipefail
shopt -s inherit_errexit

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE="${1:-$ROOT/docs/evidence/mutation-check.txt}"
mkdir -p "$(dirname "$EVIDENCE")"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/jh-mutation.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# Each mutation: name, file, exact old text, replacement, expected failing test (substring).
NAMES=(); FILES=(); OLDS=(); NEWS=(); EXPECTS=()
mutation() { NAMES+=("$1"); FILES+=("$2"); OLDS+=("$3"); NEWS+=("$4"); EXPECTS+=("$5"); }
mutation errexit scripts/backup-n8n.sh \
  $'  shopt -s inherit_errexit   # failures inside $(...) abort too\n' '' \
  'failure inside a command substitution aborts (inherit_errexit)'
mutation walk-onerror scripts/lib/jh-common.sh \
  $'h, n = hashlib.sha256(), 0\nfor dp, dns, fns in os.walk(root, onerror=fail):' \
  $'h, n = hashlib.sha256(), 0\nfor dp, dns, fns in os.walk(root):' \
  'fingerprint fails on an unreadable directory'
mutation volume-ownership scripts/restore-n8n.sh \
  '[[ "$owner" == "$RAND" ]] || jh_die' 'true || jh_die' \
  'race abort names the cause'
mutation loose-missing-object scripts/lib/jh-common.sh \
  'sys.exit(0 if pats and len(lines) == 1 and any(re.fullmatch(p, lines[0]) for p in pats) else 1)' 'sys.exit(0)' \
  'daemon error is not absence'
mutation logged-status docs/BACKUP-RESTORE.md \
  '( set -o pipefail; sudo bash scripts/backup-n8n.sh 2>&1 | tee ~/jh-backup.log )' \
  'sudo bash scripts/backup-n8n.sh 2>&1 | tee ~/jh-backup.log; echo done' \
  "documented logged backups return the backup's exit status"

copy_repo() {  # dest
  mkdir -p "$1"
  (cd "$ROOT" && tar -cf - compose.yaml README.md .gitignore scripts restore docs tests) | tar -C "$1" -xf -
}
run_suite() {  # dir -> prints summary + FAIL lines, returns suite status
  local out rc=0
  out="$(bash "$1/tests/run-tests.sh" 2>&1)" || rc=$?
  grep -E '^  FAIL |^passed:' <<<"$out" || true
  return $rc
}

{
  echo "Job Hunter mutation check"
  echo "date: $(date -Is)"
  echo "host: $(uname -srm); bash ${BASH_VERSION}; $(python3 --version)"
  echo "code under test (sha256):"
  (cd "$ROOT" && find scripts restore tests -type f ! -path 'tests/vm/fixtures/*' -print0 | sort -z | xargs -0 sha256sum | sed 's/^/  /')
  echo
} > "$EVIDENCE.tmp"

overall=0
copy_repo "$SCRATCH/baseline"
{
  echo "== unmutated copy (must pass)"
  if summary="$(run_suite "$SCRATCH/baseline")"; then echo "$summary"; echo "RESULT: PASS"
  else echo "$summary"; echo "RESULT: FAIL (unmutated suite failed)"; overall=1; fi
  echo
} >> "$EVIDENCE.tmp"

for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; file="${FILES[$i]}"; expect="${EXPECTS[$i]}"
  dir="$SCRATCH/$name"; copy_repo "$dir"
  python3 - "$dir/$file" "${OLDS[$i]}" "${NEWS[$i]}" <<'PY'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
if s.count(old) != 1:
    sys.exit(f"mutation target found {s.count(old)} times in {path}")
open(path, "w").write(s.replace(old, new))
PY
  {
    echo "== mutation: $name ($file)"
    echo "-- diff"
    diff -u "$ROOT/$file" "$dir/$file" | sed -n '3,$p' || true
    summary="$(run_suite "$dir")" && rc=0 || rc=$?
    echo "-- suite"
    echo "$summary"
    if [[ $rc -ne 0 ]] && grep -qF "FAIL $expect" <<<"$summary"; then
      echo "RESULT: DETECTED (expected failing test: $expect)"
    else
      echo "RESULT: NOT DETECTED (expected failing test: $expect)"; overall=1
    fi
    echo
  } >> "$EVIDENCE.tmp"
done

echo "OVERALL: $([[ $overall -eq 0 ]] && echo PASS || echo FAIL)" >> "$EVIDENCE.tmp"
mv -f "$EVIDENCE.tmp" "$EVIDENCE"
cat "$EVIDENCE" | sed -n '/^== /,$p'
exit $overall
