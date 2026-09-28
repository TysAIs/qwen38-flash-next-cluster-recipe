# docker/spinfix — the CPU spin-fix image, built from source, no registry needed

`v6-spinfix` is the image this fleet runs: the public `myllmbox/qwen38-flash-next-cluster-vllm:v6`
base plus **one sed** (`busy_loop_s: float = 1,` → `0.002` in vLLM's `shm_broadcast.py`) that stops
an idle CPU core spin-waiting and heating the GB10 SoC. Zero throughput cost; background and
measurements in [TysAIs/gb10-vllm-ops](https://github.com/TysAIs/gb10-vllm-ops).

You normally never touch this directory: `./start.sh` (via `run.sh` → `ensure_image`) detects the
tag is missing, builds it here, and ships it to the worker over `docker save | ssh docker load`.
That is the whole first-run experience — clone, set three variables, `./start.sh`.

Manual path, if you want it explicitly:

```bash
docker build -t myllmbox/qwen38-flash-next-cluster-vllm:v6-spinfix docker/spinfix/
docker save myllmbox/qwen38-flash-next-cluster-vllm:v6-spinfix | ssh <worker> docker load   # ~22 GB
```

The base image pulls from Docker Hub under `myllmbox` — the upstream recipe author's account, not
this repo's. That is the only registry dependency left, and it is the same one plain `:v6` has.
