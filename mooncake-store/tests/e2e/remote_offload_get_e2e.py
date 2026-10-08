#!/usr/bin/env python3
"""Remote GET from a standalone store, DRAM tier and offload tier.

Run through run_remote_offload_get_e2e.sh, which starts the "store" role
(master + store with SSD offload) and the "client" role (pure requester) on
separate hosts. Env: LOCAL_HOSTNAME, MC_METADATA_SERVER, MASTER_SERVER, and
optionally PROTOCOL (default tcp) and DEVICE_NAME (RDMA NICs).

The client checks a 1 MiB object read back while it is in the store's DRAM
segment, then another read back after it was evicted to the offload tier, so
only its LOCAL_DISK replica remains. Exit code 0 when both match. The "probe"
role stops after the DRAM check, for a quick put/get against a live store.
"""

import os
import sys
import time

from mooncake.store import MooncakeDistributedStore

MiB = 1 << 20
SEGMENT_SIZE = 64 * MiB


def kind(replica):
    if replica.is_local_disk_replica():
        return "LOCAL_DISK"
    return "MEMORY" if replica.is_memory_replica() else "OTHER"


def kinds(store, key):
    return sorted(kind(r) for r in store.get_replica_desc(key) or [])


def check(store, label, key, want):
    got = store.get(key)
    ok = got == want
    print(
        f"{label}: {'MATCH' if ok else 'MISMATCH'} "
        f"(got {len(got)} of {len(want)} bytes)",
        flush=True,
    )
    return ok


def main():
    role = sys.argv[1]
    host = os.environ["LOCAL_HOSTNAME"]
    meta = os.environ["MC_METADATA_SERVER"]
    master = os.environ["MASTER_SERVER"]
    protocol = os.environ.get("PROTOCOL", "tcp")
    device = os.environ.get("DEVICE_NAME", "")
    store = MooncakeDistributedStore()

    if role == "store":
        rc = store.setup(
            host, meta, SEGMENT_SIZE, SEGMENT_SIZE, protocol, device, master, None, True
        )
        print(f"store setup rc={rc}", flush=True)
        if rc:
            return 1
        while True:
            time.sleep(3600)

    rc = store.setup(host, meta, 0, SEGMENT_SIZE, protocol, device, master)
    if rc:
        print(f"client setup rc={rc}", flush=True)
        return 1
    run = time.time_ns()

    dram_key, dram_value = f"dram-{run}", os.urandom(MiB)
    assert store.put(dram_key, dram_value) == 0
    dram_ok = check(store, "dram", dram_key, dram_value)
    if role == "probe":
        return 0 if dram_ok else 1

    disk_key, disk_value = f"disk-{run}", os.urandom(MiB)
    assert store.put(disk_key, disk_value) == 0
    deadline = time.time() + 30
    while "LOCAL_DISK" not in kinds(store, disk_key):
        if time.time() > deadline:
            print("offload: no LOCAL_DISK replica within 30s", flush=True)
            return 1
        time.sleep(0.2)
    # Overflow the DRAM segment so the key is evicted. Don't touch the key
    # meanwhile: every read renews its lease, which blocks eviction.
    for i in range(5 * SEGMENT_SIZE // MiB):
        store.put(f"fill-{run}-{i}", os.urandom(MiB))
        time.sleep(0.02)
    replicas = kinds(store, disk_key)
    if replicas != ["LOCAL_DISK"]:
        print(
            f"offload: expected only a LOCAL_DISK replica, got {replicas}", flush=True
        )
        return 1
    disk_ok = check(store, "offload", disk_key, disk_value)
    return 0 if dram_ok and disk_ok else 1


if __name__ == "__main__":
    sys.exit(main())
