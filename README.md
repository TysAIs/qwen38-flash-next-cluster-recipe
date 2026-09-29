# Qwen3.8-Flash-Next on two DGX Sparks — the fleet recipe

**Two standards here, plainly:** (1) **the uncensored lane** — we serve
`myllmbox/Qwen3.8-Flash-Next-hibrid48-uncensored`; no censored variant is offered as the
standard. (2) **the CPU spin-fix image, built from this repo** — `./start.sh` builds
`v6-spinfix` itself from `docker/spinfix/` over the public `v6` base when the tag is missing, so a
fresh clone needs **zero extra steps** and no registry hosts our fork (the one-line sed lives
here; background in [KNOWN-ISSUES.md #3](KNOWN-ISSUES.md)).

**This repository is the live recipe**: exactly what our two-Spark fleet serves today, verified
against the running boxes on 2026-09-28 and pinned in [`VERSIONS.lock`](VERSIONS.lock). Clone it,
set three variables, run one script, verify — and you have the same endpoint we do.

```
model   qwen3.8-flash-next  (myllmbox/Qwen3.8-Flash-Next-hibrid48-uncensored, NVFP4, ~99 GB)
engine  vLLM 0.30.0 — image myllmbox/qwen38-flash-next-cluster-vllm:v6-spinfix, TP=2 over RoCE
API     http://<head>:8888/v1        context 262,144 tokens        seats 12
boxes   2× DGX Spark (GB10) — head rank 0 (API) + worker rank 1 (--headless)
```

**Measured on this live fleet endpoint (see [Real-world performance](#real-world-performance)
for the dated, load-labeled table): 21.9–23.9 tok/s at c=1 under fleet load, 85.4 at c=1 when
the engine is quiet (post-compaction-fix, 2026-09-28 evening), 233.7 tok/s aggregate at c=8
quiet.** Why shared-load numbers sit below the
quiet-engine ladder further down: see [KNOWN-ISSUES.md #2](KNOWN-ISSUES.md). The endpoint is a
shared fleet service; measure it as one.

## Quick start

Requirements: two DGX Sparks cabled together over their ConnectX ports, docker + NVIDIA runtime
on both, passwordless ssh from the head to the worker, ~100 GB free on both.

```bash
git clone https://github.com/TysAIs/qwen38-flash-next-cluster-recipe.git
cd qwen38-flash-next-cluster-recipe
cp .env.example .env      # set 3 variables: HF_TOKEN, WORKER=user@<worker-ip>, PORT=8888
./start.sh                # first run: setup, ~99G download + sync, serve, verify. ~4 min once weights exist
```

`./start.sh` ends by running `./verify.sh` against the endpoint:

```
PASS  GET http://127.0.0.1:8888/v1/models answers
PASS  served name present (qwen3.8-flash-next)
PASS  chat completion returns content
PASS  engine generates fresh text (completions endpoint)
PASS  endpoint healthy — http://127.0.0.1:8888 serves qwen3.8-flash-next (2026-09-28T09:00:00Z)
```

Smoke test by hand:

```bash
curl http://<head>:8888/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "qwen3.8-flash-next",
  "messages": [{"role": "user", "content": "hello"}]
}'
```

`./stop.sh` stops both boxes. `./view.sh` shows live status plus the **RDMA proof** (HCA counters
moving while the TCP path stays flat). `./run.sh` is the engine of `start.sh` if you want it
without the `.env`/verify wrapper. First run without `cluster.env` triggers `./setup.sh`: it asks
for the worker (`$WORKER` from `.env` seeds it), probes both boxes, discovers the interconnect by
bound pings (never the LAN), firewall-checks without root, and writes `cluster.env`.

**Hugging Face token.** The serving checkpoint is gated: accept its
[agreement](https://huggingface.co/myllmbox/Qwen3.8-Flash-Next-hibrid48-uncensored), then put a
read token in `.env` (`HF_TOKEN=*** or use `hf auth login`. The kit checks access before
downloading anything.

## What is where

| file | what it is |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | the layout, the engine, every NCCL var, control plane, failure domains |
| [`KNOWN-ISSUES.md`](KNOWN-ISSUES.md) | headless rank 1, fleet vs idle tok/s, spinfix image, compaction, GID drift, phantom OOM |
| [`VERSIONS.lock`](VERSIONS.lock) | today's image id + digest, HF revision, weights sha256, kernel/driver/cpuset |
| [`recipe.yaml`](recipe.yaml) | all engine config (image, weights, KV, spec-decode, every flag, all NCCL env) |
| `docker/spinfix/Dockerfile` | the v6 → v6-spinfix one-line build the fleet runs (see KNOWN-ISSUES #3) |
| `start.sh` `run.sh` `stop.sh` `view.sh` `verify.sh` `setup.sh` `tune-host.sh` `lib.sh` | the control plane |

## The checkpoints

| `model:` in recipe.yaml | what it is | notes |
|---|---|---|
| `myllmbox/Qwen3.8-Flash-Next-hibrid48-uncensored` (**standard — this recipe ships it active**) | OrcaRouter's abliterated body, NVFP4 output head, 99 GB | gated, no guardrails — research / private use behind your own moderation |
| `myllmbox/Qwen3.8-Flash-Next-hibrid48` | the calibrated base body, same head | one comment-flip away in `recipe.yaml`, same speed |

Switching = comment one `model:` line, uncomment the other, `./start.sh`. Both load on the same
image with the same flags; hibrid47 variants load too, at v2.1 speed. The first download of the
second checkpoint is a full download (different body; the 8 table shards are shared bytes).

**Quality** (lm-eval-harness against this serve, thinking on, temp 0.6/top-p 0.95/top-k 20,
763 questions per checkpoint, 2026-09-13):

| task | questions | hibrid48 | hibrid48-uncensored |
|---|---|---|---|
| HumanEval pass@1 | 164 | **95.7** | **94.5** |
| GSM8K exact match | 200 | **98.0** | 97.5 (v4-image rerun, 400 q: 97.75 / 97.25, no truncation) |
| IFEval prompt-level strict | 200 | 91.5 | **94.5** |
| MMLU-Pro | 200 | **84.9** | 82.9 |

Subsets of 200 carry ~±3 points of sampling noise; treat external leaderboard rows as a sanity
band, not a column.

## Real-world performance (measured on the live fleet endpoint, 2026-09-28)

Method: streaming decode rate = `(usage.completion_tokens − 1) / (end − first_token)` from the
server's own usage report — never SSE-chunk counting, which undercounts spec-decode ~4.7×. Forced
length (`min_tokens = max_tokens = 256`, `ignore_eos`), thinking off. Every window is
**load-labeled** with the engine's own `vllm:num_requests_running` (other clients' requests
in-flight; sampled before/during/after). Client: a laptop on the LAN — the inference nodes never
run the bench.

| window (2026-09-28) | fleet load during | c=1 decode | c=1 TTFT | c=4 agg | c=8 agg |
|---|---|---|---|---|---|
| 11:19–11:28 (busy) | 8–11 running | **21.9** tok/s (17.6–27.8) | 545 ms | 46.8–75.3 | 88.0–91.5 |
| 11:52 (quiet) | 0–1 running | **68.5** tok/s (50.2–94.0) | 241 ms | 185.1 | 233.7 |
| 13:00–13:07 (busy) | 6–9 running | **23.9** tok/s (21.0–30.6) | 475 ms | 42.8–70.3 | 96.6–107.1 |
| 15:10–15:18 (medium) | 2–7 running | **40.1** tok/s (35.4–47.4) | 358 ms | 46.3–117.3 | 119.5–185.0 |
| **19:07–19:25, post-compaction-fix, quiet (gated 0 running)** | 0 running | **85.4** tok/s (54.8–89.2) | 96 ms | — | — |
| **19:07–19:25, post-fix, medium** | 1–3 running | **49.6** tok/s (28.4–63.6) | 227 ms | 73.0–110.8 | 156.4 |
| **19:07–19:25, post-fix, busy** | 3–5 running | **38.0** tok/s (21.5–44.6) | 259 ms | — | — |

The 19:07–19:25 windows re-run the SAME method after `vm.compaction_proactiveness=0` was applied
live (KNOWN-ISSUES #4, closed): quiet-gated c=1 went **68.5 → 85.4 tok/s median (+25 %)** and
medium-load c=1 went **40.1 → 49.6 (+24 %)**; every trial kept healthy spec-decode acceptance
(3.2–4.2 tok/step). Busy-window comparison is load-mismatched (the fleet idled at 3–5 in flight
that evening vs 6–11 earlier), so no busy-band claim is made.

**Stall check (the point of the fix):** a 2,048-token forced c=1 decode (48.5 s, fleet 4 in
flight) was streamed with per-chunk inter-arrival gaps sampled — 432 gaps spanning more than one
former compaction cycle: p50 95 ms, p95 107 ms, **max 1.13 s, ZERO gaps >2 s**. The previously
documented signature — a 4–5 s slowdown every ~37 s — is gone. The five residual gaps >1 s
(≤1.13 s) are ordinary fleet-load jitter.

Long generations at a genuinely quiet engine sustain 70.7 tok/s c=1 (2,048-token forced output,
acceptance 3.81 tok/step). The honest read: **~100 tok/s at c=1 is a quiet-engine number.** On a
fleet that runs 6–12 requests in flight, per-stream decode is bandwidth-shared and lands
21–31 tok/s at any bench concurrency from 2 to 24; the fleet's aggregate is what scales
(233.7 tok/s measured at c=8 quiet, 107.1 under load, 141.3 peak under load at c=24). See
[KNOWN-ISSUES.md #2](KNOWN-ISSUES.md).

### Concurrency ladder + the degradation knee (same method, full c=1→24 sweep)

Per-stream decode median / aggregate, per window (fleet load = engine requests in flight,
`vllm:num_requests_running`):

| bench c | quiet window (0–1 load) | medium (2–7) | busy (6–11) | TTFT median, busy |
|---|---|---|---|---|
| 1 | 68.5 / — | 40.1 | 21.9–23.9 | 475–545 ms |
| 2 | 77.3 / 117.7 | 32.4–38.8 | 22.3–26.2 | 417–518 ms |
| 4 | 59.6 / 185.1 | 29.0–35.3 | 12.9–23.9 | 443–5549 ms |
| 8 | 36.9 / 233.7 | 18.9–30.6 | 24.7–28.0 | 424–1394 ms |
| 12 | — | 27.2–29.8 / 161–163 | 20.8–23.2 | 3.9–13.7 s |
| 16 | — | 22.9–29.4 / 170–176 | 25.7–27.1 | 9–17 s |
| 24 | — | 25.5–27.9 / 196–198 | 25.2–25.3 | 12–23 s |

Every one of 436 bench requests across four windows completed — the 12-seat cap never shed a
request, it just queued it (TTFT growth past ~12 in-flight is the queue).

**The knee (per-stream < 50 % of the quiet c=1 baseline of 68.5 → 34 tok/s):** on a quiet
engine it sits between c=8 (36.9, 54 %) and c=12; under a normal 6–9-request fleet background
the engine is already past it at bench c=2. Decode is bandwidth-bound: per-stream collapses,
aggregate saturates at ~200–235 tok/s and TTFT absorbs the rest.

**Seat-count recommendation (measured, not yet applied — engine restart needs approval):**
keep `max-num-seqs: 12`. The 50 %-per-stream knee lands at bench c≈12 on a quiet engine
anyway, so 64 seats would only convert interactive streams into a batch lane: per-stream at
c=16–24 is 22–29 tok/s at ANY setting. What the data does support: (a) a per-client admission
limit of ~4 concurrent per agent profile, so one chatty profile cannot turn everyone else's
TTFT into 10–20 s queues; (b) ~~`./tune-host.sh` at the next maintenance reboot~~ — **applied
live 2026-09-28** (`vm.compaction_proactiveness=0`, persisted; KNOWN-ISSUES #4 closed, post-fix
numbers below).

## Quiet-engine performance ladder (for reference — NOT what a shared fleet sees)

Measured by a bench script on an otherwise **quiet** engine (image v6, hibrid48, 41 GB KV pin,
`vm.compaction_proactiveness=0`, K=5, thinking off, 120 s windows, FlashInfer GDN prefill,
2026-09-27). Our fleet endpoint runs 12 seats under constant agent traffic, so live measurements
land lower (21.9–23.9 @ c=1 under load, 68.5 @ c=1 at a quiet moment — the gap to 99 is the
background agents; the compaction stall was unapplied then and is now closed on this fleet —
KNOWN-ISSUES #4). Both are honest — they measure different things
([KNOWN-ISSUES.md #2](KNOWN-ISSUES.md)).

| concurrent requests | tok/s | peak | per-stream | acceptance |
|---|---|---|---|---|
| 1 | **99** | 109 | 99 | 4.73 |
| 2 | **159** | 173 | 79 | 4.87 |
| 4 | **233** | 248 | 58 | 4.93 |
| 8 | **342** | 367 | 43 | 4.93 |
| 16 | **458** | 495 | 29 | 4.90 |
| 32 | **627** | 662 | 20 | 4.91 |
| 48 | **721** | 752 | 15 | 4.81 |
| 64 | **793** | 834 | 12 | 4.80 |

Thinking on, one request: 80 tok/s average, 118 peak. Long context, one request: prefill
3,100–3,300 tok/s from 8k to 256k prompt tokens; cold TTFT 84 s on a full 256k prompt, **hot
(prefix-cached) TTFT 1.5 s**; decode 81–99 tok/s at every depth. Earlier ladders (v4 0.30 /
v3 0.29 / v2) ride with the [tagged releases](/tags) of this README — each tag is a complete,
bootable kit.

## The image

`myllmbox/qwen38-flash-next-cluster-vllm:v6` — upstream `vllm/vllm-openai:v0.30.0` plus readable,
sha256-anchored patches (each refuses to apply twice): the NVFP4 n-gram (PLE) table as a GPU
parameter (`18-ple-nvfp4-v030`; stock 0.30 refuses these checkpoints without it), the 4-bit output
head (`11-lm-head-quant-config`), fused multi-step MTP draft (`05-qsa-fused-draft-v2`, proposed
upstream as [vllm-project/vllm#58449](https://github.com/vllm-project/vllm/pull/58449), +1–3 %
engine steps), QSA pre-indexer rope clamp (`03`), loader page-cache drop (`13`), two inert knobs
(`16`, `17`). Registry digest
`sha256:861ac752164e0d723c5eff3f876586c6678c26ad4a516112c48745f6a101ff4d`.

This fleet pins **`v6-spinfix`**: that image + a one-line sed (`busy_loop_s 1 → 0.002` in vLLM's
shm broadcast) that stops an idle CPU core spin-waiting and heating the SoC — zero throughput
cost. It is deliberately **not on any registry**: `./start.sh` builds it from
[docker/spinfix/](docker/spinfix/Dockerfile) over the public `v6` base on first run and ships it
to the worker (`docker save | ssh docker load`); background in
[TysAIs/gb10-vllm-ops](https://github.com/TysAIs/gb10-vllm-ops) and
[KNOWN-ISSUES.md #3](KNOWN-ISSUES.md).

## RDMA or it is lying to you

NCCL runs over TCP on the same ConnectX cable and never mentions it — same flags, it boots, every
step is ~2× slower. Three container flags make it real: `--device /dev/infiniband`,
`--cap-add IPC_LOCK`, `--ulimit memlock=-1:-1` (`run.sh` passes them; `view.sh` proves RDMA is
carrying traffic by sampling HCA port counters against the interface's TCP counters while
decoding). The RoCE v2 GID index is re-probed at every launch — it moves after reboots.

## Memory on a Spark

Unified memory: the GPU driver wants **free** pages, not reclaimable ones. The kit never asks for
a password: it waits for both boxes to report ≥100 GB available before launching (a relaunch
inside ~60 s of a teardown gives a phantom CUDA OOM), evicts its own checkpoint files from the
page cache (`dd iflag=nocache`), and loads with `fastsafetensors` (weights in ~97 s, whole boot
~4 min. One root setting is worth ~10 % and the kit never applies it silently:
`./tune-host.sh` (`vm.compaction_proactiveness=0`) — applied + persisted on our fleet since
2026-09-28 (KNOWN-ISSUES #4, closed).

## Tuning pointers

Everything lives in [`recipe.yaml`](recipe.yaml) with an inline comment; the ones that bite:

- **`max-num-seqs: 12`** — this fleet's latency-first seat count (upstream ships 64; 48 for many
  long answers). Each admitted request also pins pool regardless of length (GDN recurrent state,
  36 layers × (2+K) blocks). The graph-capture list must reach seats×(K+1).
- **`kv-cache-memory: 41G/box`** — 2,450,356 pooled tokens, paid for by half the n-gram table per
  box (`MBX_PLE_REPLICATE: "0"`; set `"1"` and drop the pin to 28G). Do not take vLLM's
  "fully utilize" suggestion on a unified-memory box — over-commit has needed a power cycle.
- **`block-size: 1632`** — required by K=5: the attention ring (12 slots) must divide the block;
  vLLM's automatic 1616 does not.
- **`NCCL_MAX_NCHANNELS: "4"`** — no GPUDirect on GB10, so more channels = more host copies
  (4 measured +10 % at c=32; 2 and 8 the same, 1 slower).
- **`host: 0.0.0.0` + port 8888** — this fleet exposes the API on the LAN; flip `host` to
  `127.0.0.1` for a private box.
- **fp8 KV** is not in the v6 image (upstream PR #54846 not yet re-ported); `git checkout v3` for it.
- Thinking is ON by default (model native); per-request `"chat_template_kwargs":
  {"enable_thinking": false}` for max speed on structured output.

## License

Kit (scripts, configs, docs): MIT — see [LICENSE](LICENSE). Weights: Qwen Community License 1.0
(permissive incl. commercial; >100M MAU / $20M revenue products must display the model name;
MaaS needs a separate Qwen license) — see the checkpoint card. Fork base:
[myllmbox/qwen38-flash-next-cluster-recipe](https://github.com/myllmbox/qwen38-flash-next-cluster-recipe).
