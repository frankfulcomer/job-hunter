#!/usr/bin/env bash
# Docker SEMANTICS checks only: confirms, against a real Docker engine, the behaviors the
# scripts rely on and the unit-test mocks imitate. It does NOT back up or restore anything
# and is not end-to-end recovery validation (see "Synthetic end-to-end test" in
# docs/BACKUP-RESTORE.md).
#
#   bash tests/docker-integration.sh --context CONTEXT IMAGE
#     CONTEXT  Docker context to use; must be the current context and must not be production
#     IMAGE    an n8n image, e.g. job-hunter/n8n:restored
#
# Every resource it creates has a unique name and the label job-hunter.itest=<run id>, is
# tracked, and is removed only if that label matches; removal is then confirmed.
set -euo pipefail
shopt -s inherit_errexit
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/jh-common.sh
source "$ROOT/scripts/lib/jh-common.sh"

CTX=""; IMAGE=""
while (( $# )); do
  case "$1" in
    --context) CTX="${2:?}"; shift 2 ;;
    -*) jh_die "unknown option $1" ;;
    *) IMAGE="$1"; shift ;;
  esac
done
[[ -n "$CTX" && -n "$IMAGE" ]] || jh_die "usage: docker-integration.sh --context CONTEXT IMAGE"
[[ -z "${DOCKER_HOST:-}" && -z "${DOCKER_CONTEXT:-}" ]] \
  || jh_die "unset DOCKER_HOST and DOCKER_CONTEXT; the context must be given explicitly with --context"

docker() { command docker --context "$CTX" "$@"; }   # every call is pinned to CTX

current="$(command docker context show)" || jh_die "cannot read the current Docker context"
[[ "$current" == "$CTX" ]] || jh_die "current Docker context is '$current', not '$CTX'"
endpoint="$(command docker context inspect --format '{{.Endpoints.docker.Host}}' "$CTX")" \
  || jh_die "cannot inspect Docker context $CTX"
docker version --format '{{.Server.Version}}' >/dev/null || jh_die "Docker engine for context $CTX is unreachable"
for kind_name in "container n8n" "volume n8n_data"; do
  # shellcheck disable=SC2086
  state="$(jh_docker_state $kind_name)" || jh_die "cannot check for production resources"
  [[ "$state" == absent ]] || jh_die "refusing to run: production-looking resource present ($kind_name)"
done
state="$(jh_docker_state image "$IMAGE")" || jh_die "cannot inspect image $IMAGE"
[[ "$state" == exists ]] || jh_die "image $IMAGE not found"
echo "context: $CTX ($endpoint)"

RAND="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
[[ ${#RAND} -eq 12 ]] || jh_die "could not generate run id"
LKEY="job-hunter.itest"; LABEL="$LKEY=$RAND"
V1="jh_itest_${RAND}_a"; V2="jh_itest_${RAND}_b"; NET="jh_itest_${RAND}_net"; HELPER="jh_itest_${RAND}_helper"
BRIDGE="jh_itest_${RAND}_bridge"; EP_OUT="jh_itest_${RAND}_ep_out"; EP_IN="jh_itest_${RAND}_ep_in"
CREATED=()          # "kind name", appended only after successful creation
TMP=""
PASSED=0; FAILED=0

owned() {  # kind name -> 0 if it carries our label
  local v
  case "$1" in
    container) v="$(docker container inspect --format "{{index .Config.Labels \"$LKEY\"}}" "$2")" ;;
    *) v="$(docker "$1" inspect --format "{{index .Labels \"$LKEY\"}}" "$2")" ;;
  esac
  [[ "$v" == "$RAND" ]]
}

cleanup() {
  local rc=$? i kind name state problems=0
  set +e
  trap - EXIT HUP INT TERM
  # --rm probe containers are not tracked individually; sweep any left by an interruption.
  local leftover
  leftover="$(docker ps -aq --filter "label=$LABEL")" || { echo "CLEANUP: cannot list containers"; problems=1; }
  for name in $leftover; do CREATED+=("container $name"); done
  for (( i=${#CREATED[@]}-1; i>=0; i-- )); do
    read -r kind name <<<"${CREATED[$i]}"
    state="$(jh_docker_state "$kind" "$name")" || { echo "CLEANUP: cannot inspect $kind $name"; problems=1; continue; }
    [[ "$state" == absent ]] && continue
    if ! owned "$kind" "$name"; then echo "CLEANUP: $kind $name lacks our label; not removed"; problems=1; continue; fi
    case "$kind" in
      container) docker rm -f "$name" >/dev/null ;;
      *) docker "$kind" rm "$name" >/dev/null ;;
    esac
    state="$(jh_docker_state "$kind" "$name")"
    [[ "$state" == absent ]] || { echo "CLEANUP: $kind $name still present"; problems=1; }
  done
  if [[ -n "$TMP" ]]; then rm -rf -- "$TMP"; [[ ! -e "$TMP" ]] || { echo "CLEANUP: $TMP remains"; problems=1; }; fi
  if (( problems )); then echo "CLEANUP FAILED: remove the resources above manually"; exit 3; fi
  echo "cleanup verified: ${#CREATED[@]} resource(s) removed"
  if (( rc == 0 && FAILED > 0 )); then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

track() { CREATED+=("$1 $2"); }
ok() { PASSED=$((PASSED + 1)); echo "  ok   $1"; }
bad() { FAILED=$((FAILED + 1)); echo "  FAIL $1"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
run_node() {  # network js [mount] [arg]  (bounded: 60 s)
  local -a m=(); [[ -z "${3:-}" ]] || m=(--mount "$3")
  timeout 60 docker run --rm --label "$LABEL" --network "$1" --user 1000:1000 "${m[@]}" \
    --entrypoint node "$IMAGE" -e "$2" ${4:+"$4"}
}
probe() { run_node "$1" "$JH_PROBE_JS" "" "$2" || echo "probe-failed"; }   # network url
endpoint() {  # name network -> starts a labeled token server, prints its IP on that network
  docker run -d --name "$1" --label "$LABEL" --network "$2" --user 1000:1000 \
    --entrypoint node "$IMAGE" -e "$JH_ENDPOINT_JS" >/dev/null
  track container "$1"
  docker container inspect --format "{{(index .NetworkSettings.Networks \"$2\").IPAddress}}" "$1"
}
probe_until_open() {  # network url: positive control, retried while the endpoint starts
  local i r
  for i in 1 2 3 4 5 6 7 8 9 10; do r="$(probe "$1" "$2")"; [[ "$r" == open ]] && break; sleep 1; done
  echo "$r"
}

echo "Docker semantics checks (image $IMAGE)"

# 1. Re-creating a volume returns the existing one and keeps its labels.
docker volume create --label "$LABEL" --label owner=first "$V1" >/dev/null; track volume "$V1"
second_rc=0; docker volume create --label "$LABEL" --label owner=second "$V1" >/dev/null 2>&1 || second_rc=$?
owner="$(docker volume inspect --format '{{index .Labels "owner"}}' "$V1")"
echo "       re-create of existing volume: exit $second_rc, owner label '$owner'"
check "re-creating a volume does not change its labels (restore's ownership check relies on this)" test "$owner" = first

# 2. Emptiness listing format of a fresh volume.
docker volume create --label "$LABEL" "$V2" >/dev/null; track volume "$V2"
docker create --name "$HELPER" --label "$LABEL" --network none \
  --mount "type=volume,src=$V2,dst=/home/node/.n8n,volume-nocopy=true" --entrypoint node "$IMAGE" -e 0 >/dev/null
track container "$HELPER"
listing="$(docker cp "$HELPER:/home/node/.n8n" - | tar -tf -)"
check "fresh volume lists only its top directory" test -z "$(grep -vxE '[^/]+/?' <<<"$listing" || true)"

# 3. docker cp -a into a created container's volume keeps numeric owner and mode.
TMP="$(mktemp -d)"
[[ -d "$TMP" && ! -L "$TMP" && "$(stat -c %a "$TMP")" == 700 ]] || jh_die "unsafe temporary directory"
echo '{"encryptionKey":"itest"}' > "$TMP/config"; chmod 600 "$TMP/config"
tar --numeric-owner --owner=1000 --group=1000 -C "$TMP" -cf - . | docker cp -a - "$HELPER:/home/node/.n8n"
stat_out="$(run_node none 'const s=require("fs").statSync("/home/node/.n8n/config");console.log(s.uid+" "+(s.mode&0o777).toString(8))' \
  "type=volume,src=$V2,dst=/home/node/.n8n,volume-nocopy=true")"
check "docker cp -a keeps uid 1000 and mode 600 (got: $stat_out)" test "$stat_out" = "1000 600"

# 4./5. Network isolation, against controlled endpoints (no internet or DNS involved).
# Positive controls prove the probe and endpoints work; only then is "blocked" meaningful.
docker network create --label "$LABEL" "$BRIDGE" >/dev/null; track network "$BRIDGE"
docker network create --internal --label "$LABEL" "$NET" >/dev/null; track network "$NET"
ip_out="$(endpoint "$EP_OUT" "$BRIDGE")"; ip_in="$(endpoint "$EP_IN" "$NET")"
[[ -n "$ip_out" && -n "$ip_in" ]] || jh_die "could not determine endpoint addresses"
pos_bridge="$(probe_until_open "$BRIDGE" "http://$ip_out:8080/")"
pos_internal="$(probe_until_open "$NET" "http://$ip_in:8080/")"
check "positive control: endpoint reachable on its bridge network ($pos_bridge)" test "$pos_bridge" = open
check "positive control: endpoint reachable inside the internal network ($pos_internal)" test "$pos_internal" = open
if [[ "$pos_bridge" == open && "$pos_internal" == open ]]; then
  check "--network none cannot reach the endpoint" test "$(probe none "http://$ip_out:8080/")" = blocked
  check "internal network cannot reach an endpoint outside it" test "$(probe "$NET" "http://$ip_out:8080/")" = blocked
else
  bad "isolation checks inconclusive: positive controls failed"
fi

# 6. Read-only /data bind mount is visible to uid 1000.
mkdir -m 755 "$TMP/data"; echo x > "$TMP/data/f"; chmod 644 "$TMP/data/f"
seen="$(run_node none 'console.log(require("fs").readdirSync("/data").length)' "type=bind,src=$TMP/data,dst=/data,readonly")"
check "read-only /data bind mount is readable by uid 1000" test "$seen" = 1

# 7. Version detection used by the scripts.
ver="$(docker run --rm --label "$LABEL" --network none --entrypoint n8n "$IMAGE" --version | tail -n 1 | tr -d '\r')"
check "n8n --version is a semantic version (got: $ver)" bash -c '[[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]' _ "$ver"

# 8. Real missing-object messages are recognized for every kind the scripts inspect.
for kind in container volume image network; do
  missing="jh_itest_${RAND}_missing_$kind"
  err="$(docker "$kind" inspect "$missing" 2>&1 >/dev/null || true)"
  echo "       $kind missing-object message: $err"
  state="$(jh_docker_state "$kind" "$missing" 2>/dev/null || echo error)"
  check "missing $kind is classified as absent" test "$state" = absent
done

echo
echo "passed: $PASSED  failed: $FAILED"
