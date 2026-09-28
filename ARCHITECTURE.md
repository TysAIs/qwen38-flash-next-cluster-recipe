# Architecture — what is actually running

Two NVIDIA DGX Spark (GB10, 119–121 GB unified memory each) serving **one** model as **one**
tensor-parallel engine over their ConnectX RoCE link. This is the layout as verified on the live
fleet on 2026-09-28 (`docker inspect`, `sysctl`, `sha256sum` — the numbers in `VERSIONS.lock`).

```
                     LAN 10.0.0.x
                          │
   client ──HTTP──►   the-head(head, 203.0.113.4)           the-worker(worker, 203.0.113.23)
                     rank 0 · vLLM 0.30.0               rank 1 · vLLM 0.30.0 --headless
                     API 0.0.0.0:8888                   (no API, no health port)
                     weights + caches at the SAME path   weights + caches at the SAME path
                          │                                   │
                          └────── ConnectX, 203.0.113.2/1 ───┘
                              iface enp1s0f1np1 · HCA rocep1s0f1
                              NCCL over RoCE v2 (GID 3), MTU 9000, 4 channels
```

## The engine

- **Image** `myllmbox/qwen38-flash-next-cluster-vllm:v6-spinfix` = upstream vLLM 0.30.0 +
  readable patches (NVFP4 n-gram table plugin, 4-bit output head, fused MTP draft, QSA clamp,
  loader cache-drop) + the GB10 spin-wait sed. Both boxes run the byte-identical image id
  (`684bb374cd2e…`). See `docker/spinfix/` and the README's image section.
- **Weights** `myllmbox/Qwen3.8-Flash-Next-hibrid48-uncensored` (NVFP4 quantized, ~99 GB, 25
  safetensors): real directory at `<repo>/models/…` on BOTH boxes at the same absolute path
  (the container mounts `models/` at `/models` and cannot follow symlinks). HF revision
  `572e216a…` — pinned + checksummed in `VERSIONS.lock`.
- **TP=2, PP=1, mp executor, 2 nodes.** Head is rank 0 and owns the rendezvous
  (`--master-addr 203.0.113.2:25000`); worker is rank 1 `--headless`. The launch order is
  head-first, every time — that is the order every successful boot of this model has used.
- **KV**: `--kv-cache-memory 41000000000` (41 GB/box pinned, bf16, 2.45M pooled tokens),
  `--block-size 1632` (the K=5 attention ring must divide it), 12 seats, 262,144 context.
- **Speculative decoding**: MTP, K=5, sampled drafts, block verification
  (`--speculative-config`), acceptance ~4.8–5.1 on code.
- **Container shape** (both boxes): host networking, `--ipc=host`, `--cpuset-cpus 5-9,15-19`
  (the ten 3.9 GHz X925 cores), `--device /dev/infiniband --cap-add IPC_LOCK --ulimit
  memlock=-1:-1` (the three flags that make NCCL actually use RDMA instead of silently falling
  back to TCP at half speed), no restart policy.
- **Offline by design**: `HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1` in the container — after the
  one-time download nothing at boot needs Hugging Face.

## NCCL on this pair (why each env var is there)

GB10 has no GPUDirect RDMA, so every NCCL byte is copied through host memory:

| var | value | why |
|---|---|---|
| `NCCL_SOCKET_IFNAME` / `GLOO_SOCKET_IFNAME` | `enp1s0f1np1` | cluster traffic never touches the LAN |
| `VLLM_HOST_IP` | per-box interconnect IP | same |
| `NCCL_IB_HCA` / `NCCL_IB_GID_INDEX` | `rocep1s0f1` / 3 (probed) | RoCE v2; the GID index moves on flaps, `run.sh` re-probes |
| `NCCL_MAX_NCHANNELS` | 4 | 64 channels = 64 host copies per message; 4 measured +10 % at c=32 |
| `NCCL_CUMEM_ENABLE=0`, `NCCL_NVLS_ENABLE=0` | off | unsupported/broken paths on this platform |
| `TORCH_NCCL_HEARTBEAT_TIMEOUT_SEC=180` | 3 min | a stuck collective dies instead of hanging 30 min |

## Control plane (the scripts)

| file | role |
|---|---|
| `.env` (from `.env.example`) | the 3 deployer knobs: `HF_TOKEN`, `WORKER`, `PORT` |
| `recipe.yaml` | ALL model/engine config — flags map 1:1 to `vllm serve` args |
| `cluster.env` (written by `setup.sh`) | machine-specific fabric: the interconnect iface/IP/HCA pair, worker ssh |
| `start.sh` | load .env → `run.sh` → `verify.sh` (the one command) |
| `run.sh` | pull image both boxes → weights + rsync once → memory gate → page-cache evict → GID probe → head then worker → wait healthy |
| `stop.sh` / `view.sh` | stop both boxes / live stats + the RDMA proof (HCA counter moving, TCP flat) |
| `tune-host.sh` | the one root setting (~10 %): `vm.compaction_proactiveness=0` |
| `verify.sh` | endpoint proof: models list, chat completion, generated text → `PASS` line |
| `VERSIONS.lock` | today's exact image digest, HF revision, weights checksums, host settings |

## Failure domains (the two that matter)

1. **Head dies** → API down; worker idles harmlessly. `./start.sh` rebuilds the whole pair
   (it removes the stale worker container too).
2. **Worker dies** → the head hangs mid-collective (rank 1 is part of every step). `run.sh`'s
   launch loop detects the dead worker and reports its log tail. NCCL's 180 s heartbeat kills
   a stuck head rank rather than leaving it half-alive.

There is no failover and no second replica — two boxes are the whole cluster. Design intent:
one big model, honestly shared, everything scripted. See `KNOWN-ISSUES.md` for the sharp edges.
