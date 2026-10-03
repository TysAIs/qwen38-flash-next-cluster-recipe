# Optional vLLM patches

Off by default. Turn one on by listing its name in `recipe.yaml`:

```yaml
server:
  patches: hermes-chat          # space-separated, applied in this order
```

At launch `run.sh` copies each file a patch touches out of the image, applies the patch, copies the result to the
worker and mounts it read-only over the image's file on both boxes. The image is never changed; an empty
`patches` = the stock image. A patch that does not fit the image stops `run.sh` before anything starts.

| patch | what it does |
|---|---|
| `hermes-chat` | Hermes agent: reads its `{"reasoning": {…}}` object (thinking on/off, effort) and makes an omitted temperature greedy. Contributed by [@yume-arasaki](https://github.com/yume-arasaki) (#2) |
| `gb10-skinny-gemm` | **Active on this fleet.** Adds SM12x (GB10) plans for the Qwen4Exp skinny decode GEMM, which vLLM 0.30 ships only for SM103/SM90 (upstream [#59632](https://github.com/vllm-project/vllm/issues/59632)). Without them every decode-sized BF16 projection falls back to cuBLAS SM80 WMMA at 125–225 GB/s; with them the skinny kernel reaches 240–255 GB/s — 1.4–1.5× at M=1, which is exactly the draft passes. Contributed by [@sethforprivacy](https://github.com/sethforprivacy) (#4) |

Kill switch: `MBX_SKINNY_GEMM_SM12X=0` restores the standard linear path without
relaunching the patch. Confirm it took effect at startup — the engine logs
`Qwen4Exp low-latency GEMM: N modules on skinny plans …`.

## Adding one

A unified diff with paths relative to the `vllm` package (`--- a/entrypoints/…`, `+++ b/entrypoints/…`), made against
the image in `recipe.yaml`. Lines before the first `---` are a free-text description.
