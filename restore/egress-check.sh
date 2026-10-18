#!/usr/bin/env bash
# Proves a running drill container has no network egress, using a controlled endpoint
# instead of the internet: a labeled token server on a temporary bridge network must be
# reachable from a fresh container on that bridge (positive control) and unreachable from
# the drill container. Prints EGRESS BLOCKED and exits 0 only if both hold.
#   bash restore/egress-check.sh --context CONTEXT IMAGE DRILL_CONTAINER
set -euo pipefail
shopt -s inherit_errexit
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/jh-common.sh
source "$ROOT/scripts/lib/jh-common.sh"

CTX=""; args=()
while (( $# )); do case "$1" in --context) CTX="${2:?}"; shift 2 ;; *) args+=("$1"); shift ;; esac; done
[[ -n "$CTX" && ${#args[@]} -eq 2 ]] || jh_die "usage: egress-check.sh --context CONTEXT IMAGE DRILL_CONTAINER"
IMAGE="${args[0]}"; DRILL="${args[1]}"
[[ -z "${DOCKER_HOST:-}" && -z "${DOCKER_CONTEXT:-}" ]] || jh_die "unset DOCKER_HOST and DOCKER_CONTEXT"
[[ "$(command docker context show)" == "$CTX" ]] || jh_die "current Docker context is not $CTX"
docker() { command docker --context "$CTX" "$@"; }

RAND="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"; [[ ${#RAND} -eq 12 ]] || jh_die "no run id"
LKEY="job-hunter.egress"; LABEL="$LKEY=$RAND"
NET="jh_egress_${RAND}"; EP="jh_egress_${RAND}_ep"
CREATED=()

cleanup() {
  local rc=$? i kind name v problems=0
  set +e; trap - EXIT HUP INT TERM
  for (( i=${#CREATED[@]}-1; i>=0; i-- )); do
    read -r kind name <<<"${CREATED[$i]}"
    [[ "$(jh_docker_state "$kind" "$name")" == exists ]] || continue
    if [[ "$kind" == container ]]; then
      v="$(docker container inspect --format "{{index .Config.Labels \"$LKEY\"}}" "$name")"
      [[ "$v" == "$RAND" ]] && docker rm -f "$name" >/dev/null
    else
      v="$(docker network inspect --format "{{index .Labels \"$LKEY\"}}" "$name")"
      [[ "$v" == "$RAND" ]] && docker network rm "$name" >/dev/null
    fi
    [[ "$(jh_docker_state "$kind" "$name")" == absent ]] || { echo "CLEANUP: $kind $name remains"; problems=1; }
  done
  (( problems == 0 )) || exit 3
  exit "$rc"
}
trap cleanup EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

[[ "$(jh_docker_state container "$DRILL")" == exists ]] || jh_die "drill container $DRILL not found"
[[ "$(docker container inspect --format '{{.State.Running}}' "$DRILL")" == true ]] || jh_die "$DRILL is not running"

docker network create --label "$LABEL" "$NET" >/dev/null; CREATED+=("network $NET")
docker run -d --name "$EP" --label "$LABEL" --network "$NET" --user 1000:1000 \
  --entrypoint node "$IMAGE" -e "$JH_ENDPOINT_JS" >/dev/null; CREATED+=("container $EP")
ip="$(docker container inspect --format "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$EP")"
[[ -n "$ip" ]] || jh_die "no endpoint address"
url="http://$ip:8080/"

positive="blocked"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  positive="$(timeout 60 docker run --rm --label "$LABEL" --network "$NET" --entrypoint node "$IMAGE" -e "$JH_PROBE_JS" "$url" || echo probe-failed)"
  [[ "$positive" == open ]] && break; sleep 1
done
echo "positive control (fresh container on the endpoint's network): $positive"
[[ "$positive" == open ]] || jh_die "positive control failed; egress result would be meaningless"

negative="$(timeout 30 docker exec "$DRILL" node -e "$JH_PROBE_JS" "$url" || echo probe-failed)"
echo "drill container $DRILL -> endpoint: $negative"
[[ "$negative" == blocked ]] || jh_die "EGRESS OPEN or probe failed ($negative)"
echo "EGRESS BLOCKED"
