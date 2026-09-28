# Qwen3.8-Flash-Next on two DGX Sparks — the fleet recipe

**This repository is the live recipe**: exactly what our two-Spark fleet serves today, verified
against the running boxes on 2026-09-28 and pinned in [`VERSIONS.lock`](VERSIONS.lock). Clone it,
set three variables, run one script, verify — and you have the same endpoint we do.

```
model   qwen3.8-flash-next  (myllmbox/Qwen3.8-Flash-Next-hibrid48-uncensored, NVFP4, ~99 GB)
engine  vLLM 0.30.0 — image myllmbox/qwen38-flash-next-cluster-vllm:v6-spinfix, TP=2 over RoCE
API     http://<head>:8888/v1        context 262,144 tokens        seats 12
boxes   2× DGX Spark (GB10) — head rank 0 (API) + worker rank 1 (--headless)
```

**Measured on this live fleet endpoint (2026-09-28 baseline card, shared load — real numbers,
not an idle spec): 47.8 tok/s at c=1, 99.3 at c=4, 218.6 tok/s aggregate at c=8, 36/36 requests
OK, TTFT 0.299 s.** Why these sit below the quiet-engine ladder further down: see
[KNOWN-ISSUES.md #2](KNOWN-ISSUES.md). The endpoint is a shared fleet service; measure it as one.

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
| `myllmbox/Qwen3.8-Flash-Next-hibrid48-uncensored` (**active — this fleet**) | OrcaRouter's abliterated body, NVFP4 output head, 99 GB | gated, no guardrails — research / private use behind your own moderation |
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

## Quiet-engine performance ladder (for reference — NOT what a shared fleet sees)

Measured by a bench script on an otherwise **quiet** engine (image v6, hibrid48, 41 GB KV pin,
`vm.compaction_proactiveness=0`, K=5, thinking off, 120 s windows, FlashInfer GDN prefill,
2026-09-27). Our fleet endpoint runs 12 seats under constant agent traffic, so live measurements
land lower (47.8 @ c=1). Both are honest — they measure different things
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
cost, build it from [docker/spinfix/](docker/spinfix/Dockerfile); background in
[TysAIs/gb10-vllm-ops](https://github.com/TysAIs/gb10-vllm-ops). The `-spinfix` tag is **not on
Docker Hub**: KNOWN-ISSUES #3.

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
~4 min). One root setting is worth ~10 % and the kit never applies it silently:
`./tune-host.sh` (`vm.compaction_proactiveness=0`) — not yet applied on our fleet, see
KNOWN-ISSUES #4.

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
