#!/usr/bin/env bash
# Two-host TCP e2e: a remote requester reads an object from a standalone
# store's DRAM segment, then from its offload tier (offset-allocator arena).
# The store runs with local_hostname=localhost and the master's HTTP metadata
# server, the setup in which remote offload-tier reads used to dial the
# reader's own loopback and return 0 bytes. Each role runs in its own container
# on a private Docker network, so "localhost" means a different host to each.
#
#   IMAGE=<image> mooncake-store/tests/e2e/run_remote_offload_get_e2e.sh
#
# IMAGE needs python3 with the mooncake package and mooncake_master on PATH
# (MASTER_BIN overrides it). CLIENT_IMAGE (default IMAGE) runs the requester,
# e.g. a released wheel against a store built from this tree.
# STORE_DOCKER_ARGS / CLIENT_DOCKER_ARGS add `docker run` arguments (mounts,
# env) to each role.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
IMAGE=${IMAGE:?set IMAGE to an image with mooncake installed}
CLIENT_IMAGE=${CLIENT_IMAGE:-$IMAGE}
MASTER_BIN=${MASTER_BIN:-mooncake_master}
STORE_HOSTNAME=${STORE_HOSTNAME:-localhost}
NET=mooncake-remote-get-e2e
STORE=$NET-store
CLIENT=$NET-client

cleanup() {
  docker rm -f "$STORE" "$CLIENT" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null

common=(--network "$NET" -v "$SCRIPT_DIR":/e2e:ro -e GLOG_minloglevel=1
  -e MASTER_SERVER="$STORE:50051"
  -e MC_METADATA_SERVER="http://$STORE:8080/metadata")

# shellcheck disable=SC2086  # *_DOCKER_ARGS are word-split on purpose.
docker run -d --name "$STORE" --shm-size=1g "${common[@]}" ${STORE_DOCKER_ARGS:-} \
  -e LOCAL_HOSTNAME="$STORE_HOSTNAME" \
  -e MOONCAKE_OFFLOAD_STORAGE_BACKEND_DESCRIPTOR=offset_allocator_storage_backend \
  -e MOONCAKE_OFFLOAD_FILE_STORAGE_PATH=/tmp/offload \
  -e MOONCAKE_OFFSET_DAX_DEVICE_PATH=/tmp/offload.arena \
  -e MOONCAKE_OFFSET_PERSIST_MODE=strict \
  -e MOONCAKE_OFFLOAD_TOTAL_SIZE_LIMIT_BYTES=1073741824 \
  -e MOONCAKE_OFFLOAD_LOCAL_BUFFER_SIZE_BYTES=268435456 \
  "$IMAGE" bash -c "mkdir -p /tmp/offload && truncate -s 1G /tmp/offload.arena &&
    { $MASTER_BIN --enable_offload=true --default_kv_lease_ttl=500 \
        --enable_http_metadata_server=true & } &&
    sleep 2 && exec python3 /e2e/remote_offload_get_e2e.py store" >/dev/null

for _ in $(seq 60); do
  docker logs "$STORE" 2>&1 | grep -q "store setup rc=" && break
  sleep 1
done
if ! docker logs "$STORE" 2>&1 | grep -q "store setup rc=0"; then
  echo "store failed to start:" >&2
  docker logs "$STORE" 2>&1 | tail -n 40 >&2
  exit 2
fi

set +e
# shellcheck disable=SC2086
docker run --rm --name "$CLIENT" "${common[@]}" ${CLIENT_DOCKER_ARGS:-} \
  -e LOCAL_HOSTNAME="$CLIENT" \
  "$CLIENT_IMAGE" python3 /e2e/remote_offload_get_e2e.py client
RC=$?
set -e

if [[ "$RC" -eq 0 ]]; then
  echo "PASSED: remote offload GET e2e"
else
  echo "FAILED: remote offload GET e2e rc=$RC; store log tail:" >&2
  docker logs "$STORE" 2>&1 | tail -n 40 >&2
fi
exit "$RC"
