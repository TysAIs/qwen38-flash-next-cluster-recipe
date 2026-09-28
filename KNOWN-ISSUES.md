# Known issues and honest caveats

Everything here was observed on the live fleet (two DGX Sparks: the head + the worker)
or measured directly. If it is not on this page, it has not bitten us.

## 1. The worker runs rank 1 `--headless` — it has no API and no health endpoint

`--headless` on the worker's `vllm serve` means: no HTTP server, no `/health`, no `/v1/models`.
The API exists **only** on the head (`:8888`). Consequences:

- Health-check the **head** (`./verify.sh`). On the worker, "alive" = the container is running
  and its log shows the engine loop: `docker ps && docker logs --tail 20 qwen38-flash-next-cluster`.
- The worker can be wedged-but-running. If the head starts erroring mid-request, check the
  worker's log and `nvidia-smi`'s compute-apps too — a dead rank 1 looks like a hung head.
- After ANY host reboot, restart BOTH boxes: containers have `--restart` unset on purpose
  (a half-rebooted pair boot-storms and phantom-OOMs). One command from the head: `./start.sh`
  (it removes old containers, waits for memory to come back, launches head then worker).

## 2. Real-world throughput: the fleet numbers are NOT the idle-spec numbers

The upstream ladder (99 tok/s at c=1, 793 at c=64) was measured on a **quiet** engine: a bench
script hammering the endpoint while nothing else runs. The fleet endpoint is a **shared service**
— typically 5–9 concurrent requests from agents at all times — so what you measure depends on
what you measure:

- **21.9–23.9 tok/s at c=1 under fleet load** (measured 2026-09-28, three windows,
  6–11 engine requests in flight): a single client's tokens per second while the engine is
  already busy with other traffic. The engine never goes quiet; your request shares every step
  with everyone else's. At a genuinely quiet moment the SAME method measured 68.5 tok/s c=1
  (peak 94.0) on this live endpoint.
- **88–107 tok/s aggregate at c=8 under fleet load** (same 2026-09-28 windows; 233.7 when the
  engine was quiet): eight clients' combined token rate. The per-stream tax is decode sharing —
  your request shares every engine step with everyone else's.
- **TTFT stays good** (241–545 ms median at c=1, busy or quiet): prefill and decode interleave
  well; the tax is in decode sharing, not in admission. Queueing shows up as TTFT growth past
  the seat count (c=12 benches under load saw 4–23 s medians), never as failures — every request
  in every 2026-09-28 window completed.

If you benchmark a fleet endpoint, benchmark it **as a fleet endpoint** (concurrent, sustained).
An idle-engine number from a shared box is a measurement error, not a spec. The 36/36 requests
OK across the baseline runs is the other half of the card: the endpoint is healthy, just shared.

## 3. `v6-spinfix` is built from this repo, not pulled — by design, no registry dependency

`myllmbox/qwen38-flash-next-cluster-vllm:v6-spinfix` (v6 + the GB10 spin-wait fix, see
`docker/spinfix/`) is deliberately **not published to any registry**: it is a one-line sed over the
public `v6` base, and a 22 GB single-sed image does not deserve registry custody. `./start.sh`
self-heals — if the tag is missing it runs
`docker build -t myllmbox/qwen38-flash-next-cluster-vllm:v6-spinfix docker/spinfix/` on the head
(only network dependency: the public `v6` base pull from Docker Hub, the upstream author's account)
and ships the image to the worker with `docker save | ssh docker load`. A fresh clone therefore
needs **zero manual steps** and never silently regresses to plain `v6`.
If you skip the fix anyway (point `recipe.yaml` at `:v6`), everything runs at the same speed, but a
CPU core busy-spins while idle and SoC temps climb — not free to skip on a hot box.

## 4. `vm.compaction_proactiveness` is still 20 on the live fleet

`tune-host.sh` exists, is correct, and **has not been applied** on our two boxes. Expected
symptom: a 4–5 s decode slowdown every ~37 s (the kernel page-compactor's retry cycle migrating
pages the GPU is using) — ~10 % of throughput and the reason some latency windows look spiky.
`run.sh` prints the warning at every launch; we have lived with it deliberately (it changes
nothing about correctness). One root command fixes it fleet-wide: `./tune-host.sh`.

## 5. The clock cap is lost on every reboot

If you apply a GPU clock cap (`nvidia-smi -lgc`), it does not survive a reboot, and `run.sh`
does not reapply it (deliberately: the fleet runs uncapped). Reapply and verify **under load**,
not at idle. Today both boxes are uncapped with no active throttle reasons.

## 6. RoCE v2 GID index moves after reboot / link flap

`NCCL_IB_GID_INDEX=3` is correct today on both boxes, but the index of the RoCE v2 IPv4 GID
changes when the link flaps. A stale index fails NCCL init with "unhandled system error" —
`run.sh` re-probes it at every launch (that probe is why a manual `docker run` diverges from
`./start.sh`). Never hardcode it into a hand-rolled launch.

## 7. Unified memory: relaunch too fast = phantom CUDA OOM

After a container dies, the GB10 needs 30–60 s to return its GPU pages. Launching sooner gives
a "CUDA out of memory" that vanishes on retry — nothing is wrong. `run.sh` gates on ≥100 GB
available on BOTH boxes before launching (`wait_mem`); if you bypass run.sh, wait yourself.
Same family of trap: page-cache build-up stalling a load (`run.sh` evicts its own checkpoint
files with `dd iflag=nocache`, no root needed).

## 8. 12 seats is a fleet decision, not an engine limit

`max-num-seqs: 12` trades top-end throughput for per-agent latency + pool headroom on a shared
endpoint. The engine seats 64 (upstream default; 48 recommended for many-long-answer loads).
Raise it in `recipe.yaml` together with the graph-capture list logic in the tuning section of
the README; 12 is why a load spike queues a request instead of slowing everyone down.

## 9. Containers do not auto-restart

`RestartPolicy=no` on both boxes by design (see #1). A crashed engine stays down until someone
runs `./start.sh`. If you want a supervised fleet, add a systemd unit that runs
`ExecStartPre=-docker rm -f` + `./run.sh` — but keep the memory gate; do not `--restart unless-stopped`.
