# Deployment notes: remote offload GET, GB10 RDMA, ARM64/CUDA 13 wheel

Placeholders: `<store-ip>` is the store host's data-plane IP, `<rnic>` an RDMA
device name (`ibv_devices`), `<client-host>` a GB10 client's hostname or IP.

## 1. Remote GET returned 0 bytes (fixed, store side)

**Symptom.** A remote client's `get()` of a key that had been evicted from the
store's DRAM into the offload arena returned 0 bytes with rc=0. The same GET
on the store host returned the full value, and keys still in DRAM read fine
remotely.

**Cause.** An offload-tier read is a two-step exchange. The reader first sends
an RPC to the address published in the key's LOCAL_DISK replica
(`transport_endpoint`); the store stages the bytes and the reader pulls them
with a transfer-engine READ. The store built that RPC address from the raw
`local_hostname`. With any metadata server other than `P2PHANDSHAKE`, the
transfer engine ignores `local_hostname` and advertises a real LAN IP, which
is why DRAM reads worked. The offload endpoint, however, became
`localhost:<port>` (or `0.0.0.0:<port>`).

A remote reader therefore sent the RPC to itself, got `RPC_FAIL`, and the
Python `get()` turned the failure into empty bytes. On the store host the
loopback happened to reach the store, so GETs there worked.

**Fix.** `mooncake-store/src/real_client.cpp`: the offload RPC address now uses
the host the transfer engine advertises, on both paths: the separate offload
RPC server, and `mooncake_client --start_offload_rpc_server=false`. The wire
protocol is unchanged. Only the store needs the new build; existing clients,
including the 0.3.13.post1 GB10 wheel, work once the store is rebuilt.

On a multi-homed store, the engine picks the first LAN IP. Set
`MC_TCP_BIND_ADDRESS=<store-ip>` on the store to choose the data-plane
interface. The offload RPC server listens on an ephemeral port on all
interfaces, so clients must be able to reach that port.

Workaround for a store you can't rebuild yet: set its `local_hostname` to
`<store-ip>`.

**Tests.**

- Unit test (CI), which fails without the fix with endpoint `localhost:<port>`:
  `pybind_client_test --gtest_filter=RealClientTest.LocalDiskEndpointUsesTransferEngineHost`
- Two-host e2e covering the DRAM tier and the offset-allocator arena. Each role
  runs in its own container:

  ```bash
  IMAGE=<image with mooncake installed> mooncake-store/tests/e2e/run_remote_offload_get_e2e.sh
  ```

  Results:

  | Store build | Clients | DRAM | Offload arena |
  |---|---|---|---|
  | 0.3.13.post1 | 0.3.13.post1 | MATCH | 0 bytes (client dials `localhost:<port>`, RPC_FAIL) |
  | main | main and 0.3.13.post1 | MATCH | MATCH |

## 2. GB10 RDMA (commit 3fe3f433, reworked)

3fe3f433 registered GB10 `cudaMalloc` memory with plain `ibv_reg_mr()`.
NVIDIA's DGX Spark documentation says GPUDirect RDMA is unsupported and that
GPU memory is not coherent for PCIe devices such as the NIC. That registration
would therefore succeed and serve stale data. The reworked version:

- **Init:** keeps the RNIC open when the GPU supports neither nvidia-peermem
  nor dma-buf, with a warning that it is enabled for host memory only. This is
  3fe3f433's behavior.
- **Registration:** GPU memory without peermem and without dma-buf fails with
  an explicit error ("Cannot register GPU memory … Use host memory or the TCP
  transport"). Host memory, including `cudaHostAlloc`, registers normally.
- **Branch order:** the nvidia-peermem branch comes first and is unchanged. No
  path that used to fail now registers silently.
- **Build guards:** the helper and the new branch compile only under
  `USE_CUDA`/`USE_SUPA`. This fixes the non-CUDA build break 3fe3f433
  introduced (`'CUdeviceptr' was not declared`), which affected MACA, MLU,
  HIP and plain builds.
- **cuInit:** the dma-buf query runs only after `cuPointerGetAttribute`
  classified the pointer as device memory, so the driver is already
  initialized.
- **Unit test:** none. The path needs a CUDA device and an RNIC, so it is
  covered by on-cluster step (a).

## 3. Settings

**GB10 clients**

| Variable | Value | Why |
|---|---|---|
| `WITH_NVIDIA_PEERMEM` | `0` | GB10 has no nvidia-peermem. With the default (`1`), GPU buffers take the plain `ibv_reg_mr()` path. |
| `MC_GID_INDEX` | `3` | RoCEv2/IPv4 GID. The legacy engine otherwise auto-selects. |
| `MC_MTU` | `4096` | Path MTU, capped at the port's active MTU. |
| `MC_TE_FILTERS` | `<rnic>[,<rnic>]` | Use only NICs that can reach the store. |

**Store:** the same `MC_GID_INDEX`, `MC_MTU` and `MC_TE_FILTERS` when using
RDMA, plus `MC_TCP_BIND_ADDRESS=<store-ip>` if the host has several
interfaces.

**Protocol.** The store and all clients must use the same protocol. A mismatch
shows up as `NotSupportedTransport`, or as TCP `no transfer progress` and
`readBody` errors.

- `rdma`: correct when everything the GB10 clients register with the transfer
  engine is host memory, such as the client's `local_buffer_size` staging
  buffer.
- `tcp`: required if the connector registers GPU KV tensors for zero-copy.
  The TCP transport stages device memory through `cudaMemcpy` and works on
  GB10.

The offload fix applies to both protocols. If after step (b) the engine logs
"Cannot register GPU memory … for RDMA", switch the store and all clients to
`tcp`.

## 4. ARM64 / CUDA 13 / cp312 wheel

**GitHub Actions (preferred).** The workflow
`.github/workflows/build-wheel-cuda13-arm64.yaml` runs the same reusable job as
the release workflows: an arm64 runner, the manylinux CUDA 13 builder, and
`mooncake-transfer-engine-cuda13`. It needs no on-cluster compile.

```bash
gh workflow run build-wheel-cuda13-arm64.yaml --repo SpaceshipCreative/Mooncake-Optane --ref main
```

```bash
gh run list --workflow build-wheel-cuda13-arm64.yaml --repo SpaceshipCreative/Mooncake-Optane --limit 1
```

```bash
gh run download <run-id> --repo SpaceshipCreative/Mooncake-Optane -n mooncake-wheel-cuda13-arm64-py312 -D mooncake-wheel
```

```bash
pip uninstall -y mooncake-transfer-engine-cuda13 mooncake-transfer-engine && pip install mooncake-wheel/*.whl
```

The version is `0.3.13.post1+optane.<run number>`.

**On-cluster Docker fallback.** The final image installs the wheel and deletes
it, so build the `builder` stage and copy `dist/` out of it. Keep
`BUILD_JOBS` low:

```bash
docker build -f docker/mooncake.Dockerfile --target builder --build-arg CUDA_VERSION=13.0.1 --build-arg UBUNTU_VERSION=24.04 --build-arg PYTHON_VERSION=3.12 --build-arg BUILD_JOBS=3 -t mooncake-wheel-builder:gb10 .
```

```bash
id=$(docker create mooncake-wheel-builder:gb10) && docker cp "$id":/workspace/mooncake-wheel/dist ./mooncake-wheel && docker rm "$id"
```

This path builds the package as `mooncake-transfer-engine`, without the
`-cuda13` suffix, so uninstall the `-cuda13` wheel before installing it.

## 5. On-cluster test sequence (after pulling main)

**(a) Transfer engine plus one RDMA put/get.**

1. On one GB10 client, install the wheel from section 4. Alternatively, compile
   only the transfer engine to validate it against CUDA 13 cheaply:

   ```bash
   cmake --build build --target transfer_engine -j3
   ```

2. Run a single 1 MiB put/get (host memory) against the running store, with
   the store on `rdma`:

   ```bash
   WITH_NVIDIA_PEERMEM=0 MC_GID_INDEX=3 MC_MTU=4096 MC_TE_FILTERS=<rnic> PROTOCOL=rdma DEVICE_NAME=<rnic> LOCAL_HOSTNAME=<client-host> MC_METADATA_SERVER=http://<store-ip>:8080/metadata MASTER_SERVER=<store-ip>:50051 python3 mooncake-store/tests/e2e/remote_offload_get_e2e.py probe
   ```

   Expect `dram: MATCH (got 1048576 of 1048576 bytes)` and exit code 0.

**(b) Full stack restart.**

1. Rebuild the store host from main with `BUILD_JOBS` low.
2. Restart the master, then the store, with the chosen protocol and the store
   settings above.
3. Restart the vLLM engines on the GB10 clients with the new wheel and the
   client settings.
4. Rerun the probe from (a).

**(c) Cross-restart cache hit.**

1. Send the same prompt of more than 2304 tokens twice, restarting the engine
   between the two requests. The engine's own prefix cache is empty after the
   restart, so any hit on the second request must come from the store. Keep
   the prompt under `max_model_len`:

   ```bash
   P=$(python3 -c 'print("The quick brown fox jumps over the lazy dog. " * 300)')
   ```

   ```bash
   curl -s http://<client-host>:8000/v1/completions -H 'Content-Type: application/json' -d "$(jq -n --arg p "$P" '{model: "<model>", prompt: $p, max_tokens: 1}')"
   ```

2. After the second request, the engine's external prefix-cache hit counter
   must be above 0:

   ```bash
   curl -s http://<client-host>:8000/metrics | grep -i external_prefix_cache
   ```

   A zero count together with `SSD read failed` or `RPC_FAIL` in the engine
   log means the store is still on the old build.
