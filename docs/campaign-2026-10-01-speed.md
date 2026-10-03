# Speed campaign, 2026-10-01 — measured result: the capacity premise is false

> **⚠️ RETRACTED IN PART (commit `cbe2238`).** An earlier version of this document claimed a
> finding — "acceptance decays with draft depth" — that does not exist. It was an artifact of
> reading a **survival curve** as a per-slot acceptance rate. The section is retracted below with
> its replacement data. The capacity verdict and every throughput number here are **unaffected**.
> Do not act on the depth-acceptance claim or build the position-decaying draft scale.

Campaign card executed read-only. Engine lane: this repo's serving recipe, two GB10 boxes,
`v6-spinfix-hermes` image, 64 seats, 41G KV pin per box, K=5 MTP block/probabilistic.

## Bottom line

**No recipe change was made, and none is justified by this measurement.** Sustained long-generation
stress at the top of the documented concurrency ladder reached **19 of 64 seats and 37.9 % of the KV
pool with zero preemptions, zero queueing and zero failed requests**. The pool has roughly 2.6x
headroom, so capacity is not what limits this deployment, and the two phases the campaign was built
around — seat count and KV pool size — are demoted. KV pool size is also the only knob family here
that can wedge a unified-memory box with no BMC, so not spending boots on it is the safe outcome,
not a compromise.

`recipe.yaml` in this repo is byte-exact with tag `fleet-known-good-20261001`
(`sha256 dec940fee6df9254f65a7e3dee1af5e6933f5c9b39af0da031c02bdf7e70c3fc`). The tag's blob, `HEAD`'s
blob and the working tree all hash identically. Nothing in the serving config was touched.

## Measured cells

Throughput is decoded from engine counters and usage tokens, never from SSE chunk arrival. Gauges
were scraped at 1 Hz for the whole run.

| cell | wall | failed | tok/s | cadence Hz | yield tok/step | preempt | TTFT median | TTFT max | peak running | KV peak |
|---|---|---|---|---|---|---|---|---|---|---|
| c=1, 512 tok | 4.6 s | 0 | 78.72 | 30.97 | 3.361 | 0 | 0.201 s | 0.201 s | 2/64 | 0.050 |
| c=16, 512 tok | 38.7 s | 0 | 187.02 | 64.45 | 2.331 | 0 | 1.345 s | 3.217 s | 18/64 | 0.285 |
| c=16 **stress**, 4096 tok | 346.7 s | 0 | 187.86 | — | — | 0 | 0.465 s | 0.467 s | 19/64 | **0.379** |

Gauges over 357 samples: running min 1 / median 18 / max 19, `waiting_max` 0,
`waiting_by_capacity_max` 0, `kv_cache_usage_perc_max` 0.379, preemptions 0, request errors 0,
scrape errors 0. Live after the run: `num_preemptions_total` 0, `request_success_total{error}` 0,
`{abort}` 0, prefix cache 85.91 % hit rate.

## Comparison against the pinned baseline — and why it carries no verdict

| figure | pinned quiet baseline (09-29) | measured 10-01 | readable as |
|---|---|---|---|
| c=1 tok/s | 67.7 median (64.5–73.0, n=5) | 78.72 | **nothing** |
| c=16 aggregate tok/s | 249.3 | 187.02 | **nothing** |
| c=1 TTFT | 0.096 s | 0.201 s | **nothing** |

The engine was never quiet during this run: `engine_ever_quiet: false`, 0 of 357 gauge samples read
zero running (median 18). Across 66 h of 1-minute samples only 0.46 % of minutes have ≤1 request
running, because sibling agents call this endpoint continuously — there is no natural quiet hour to
schedule around.

So the +16 % at c=1 is not a result and the −25 % at c=16 is not a regression. Both are "loaded"
numbers and their ratio carries no information. For scale, a single stream on this same config moves
3–5x between loaded and quiet conditions, which is larger than any candidate delta this campaign
would have been able to detect against a same-config noise floor of 6.97 % at n=5.

**The capacity verdict is the only load-independent claim here**, and co-tenant load makes it
conservative: holding 37.9 % of the pool while serving other people's traffic is a floor, not a
best case.

## RETRACTED — "acceptance decays with draft depth" was an artifact of a misread gauge

**This section previously claimed a finding that does not exist. It is retracted, not softened.**

The evidence was a table of `vllm:spec_decode_num_accepted_tokens_per_pos_total` normalised
against its own position-0 entry, which appeared to decay monotonically with draft depth
(1.000 / 0.716 / 0.518 / 0.390 / 0.296) and was read as a per-slot acceptance rate.

That gauge is **not** a per-slot rate. From the pinned image's own
`vllm/v1/spec_decode/metrics.py`:

```python
for i in range(num_accepted_tokens):
    self.num_accepted_tokens_per_pos[i] += 1
```

Every position below the accepted count is incremented on each draft, so the counter is the
**survival curve** `P(accept >= i+1)`. It is **non-increasing by construction**. Dividing it by its
own position-0 entry cannot disclose depth dependence — the "decay" was the shape of the
instrument, not of the engine. The same error produced the "mean ratio 0.584" and the
"implied yield ≈2.92 tokens/step" figures; the true accepted drafts/step is
`sum(per_pos) / num_drafts` = **2.228** (reconciling exactly with the independent
`num_accepted_tokens_total / num_drafts_total`), or **3.228** tokens/step including the bonus token.

Measured properly — per-slot **conditional** acceptance `P(accept i+1 | i accepted)`, from counter
*deltas* over two windows with reversed prompt-class order, 44 trials, 0 failures:

| class | slot1 | slot2 | slot3 | slot4 | slope/slot |
|---|---|---|---|---|---|
| code | 0.845 | 0.873 | 0.870 | 0.857 | ~0 |
| btree | 0.755 | 0.764 | 0.760 | 0.775 | ~0 |
| narrative | 0.691 | 0.712 | 0.756 | 0.789 | **+0.034 (rising)** |

**No class decays with depth.** The pooled per-slot conditional rate is flat (0.729 / 0.737 / 0.760
/ 0.765). Consequently the recommendation this section made — a position-decaying draft scale — is
**dead**, and so is the depth axis in general:

- the instrument does not exist — `MBX_MTP_DRAFT_SCALE` is a single scalar applied to all
  positions, and `compute_logits` receives `spec_step_idx` and discards it, so a position-varying
  scale needs an engine edit plus an image rebuild on both Sparks (out of scope, not a tune);
- the only supported per-position schedule, `rejection_sample_method: synthetic`, accepts on
  `u < rate` instead of the probability-ratio test — it does not verify, and fails a distribution
  quality gate by construction.

What **is** real and load-robust on this axis is the **prompt-class yield spread**: code
3.10–3.23 vs btree 2.49–2.53 vs narrative 1.87–2.09 accepted drafts/step, a ~1.7x spread that is
stable across both windows and under load. That is a routing / traffic-quality question, not drafter
arithmetic. `K` (`num_speculative_tokens`) is the only config-reachable dial on the genuine depth
axis and needs no image rebuild.

The capacity verdict elsewhere in this document is **unaffected** — 37.9 % KV, 19/64 seats, zero
preemptions was measured from pool gauges, not from this counter.

Raw receipts for the retraction are kept outside this repository (measurement kit: per-position
counters at two sampling offsets; draft-scale results: 2026-10-01). The counters quoted above are
reproduced inline so this document stands on its own.

## Consequences for the recipe

- **Seat count `max-num-seqs` (currently 64): no evidence to change.** The runbook's control would
  have been two more boots to confirm a null — 19 seats were used, none waited.
- **KV pool size / `MBX_PLE_REPLICATE` (currently `0`, 41G pin): no evidence to change.** Only change
  it in a direction measured pressure points to, and pressure is at 37.9 %.
- **`async-scheduling: true` and `NCCL_MAX_NCHANNELS: "4"`: already at their measured optima**
  (+9–12 % at c=4–5, neutral at 8+; +10 % at 32 concurrent, +7 % at 64, same at 1).
- **Prefix caching at 85.91 %:** the TTFT lever is largely pulled.
- **`TF_TP_REDUCE`: a no-op for this checkpoint.** The Flash Next `qwen4_exp` CUDA path calls
  `comm.all_gather` unconditionally, so the knob cannot do anything here. Do not spend an arm on it.
- **`cudagraph_capture_sizes` must keep reaching seats × (K+1) = 384** if seats ever change; a list
  that stops short leaves every concurrency above it decoding without CUDA graphs.

## Caveats a reader should carry forward

1. **Self-correction on the stress arm.** An earlier attempt recorded clean gauges while generating
   zero tokens, because the length-forcing prompts had not been applied. It would have produced a
   false pass. Only the arm that actually generated 4096-token completions is reported here.
2. **`waiting_by_capacity{reason="capacity"}` is not pool exhaustion.** It is `num_requests_waiting`
   (`loggers.py:1059`) — ordinary scheduler queueing. `num_preemptions_total` is the authoritative
   pool signal. Both gauges were kept in the raw manifest so the earlier misreading stays auditable.
3. **Not re-run, on purpose:** the depth × confidence sweep (10 arms, 50 clean trials, no accepted
   win), `MBX_MTP_DRAFT_SCALE` 2.0 / 1.25 (redistribution, not gain), `NCCL_MAX_NCHANNELS`, and
   `TF_TP_REDUCE`.
4. **Before any future A/B, the baseline must be re-measured quiet.** A quiet gate or an explicit
   loaded-vs-quiet paired baseline is required; otherwise a 6.97 % noise floor cannot be
   distinguished from a candidate delta. This is the one real blocker to further throughput work,
   and it is a scheduling problem, not a tuning problem.
5. **Only one boot lane was used and it was read-only.** No container was restarted by this campaign.

## Rollback — unchanged and re-verified

The serving config was never modified, so rollback remains the pre-existing one-liner:

```
git checkout fleet-known-good-20261001 -- recipe.yaml && ./stop.sh && ./run.sh
```

Verify after reverting: `sha256sum recipe.yaml` equals
`dec940fee6df9254f65a7e3dee1af5e6933f5c9b39af0da031c02bdf7e70c3fc`; `/health` returns 200;
`/v1/models` lists the served name; a real chat completion returns non-empty content with
`completion_tokens > 0`; the container is Up on **both** boxes with RestartCount 0.

Do not `docker image prune` on either box. The image is built locally with no registry digest, and
pruning destroys the rollback's engine.

## Follow-ups

1. ~~Position-decaying draft scale~~ — **DEAD, do not build.** Its premise (acceptance decaying
   with draft depth) was a misread survival curve, and the instrument is unreachable by config in
   the pinned image. See the RETRACTED section above.
2. A quiet-window gate for measurement, so future arms can be compared at all.
3. Do not spend further boots on seat count or KV pool size unless new pressure evidence appears.
4. **Prompt-class yield spread** (code 3.10–3.23 vs narrative 1.87–2.09 accepted drafts/step, ~1.7x,
   stable under load) is the one real open finding on this axis. It is a routing / traffic-quality
   question, not a tuning knob — decide it on workload grounds, not as a speed lever.
5. **`K` = `num_speculative_tokens`** is the only config-reachable dial on the genuine depth axis
   and needs no image rebuild. Untested here; if it is ever armed, report conditional acceptance per
   slot, never the raw per-position counter.
