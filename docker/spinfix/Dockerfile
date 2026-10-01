# The v6 -> v6-spinfix delta the fleet actually runs: the GB10 CPU spin-wait fix.
# vLLM's shared-memory broadcast busy-loop sleeps 1 s per poll cycle when idle; on the GB10's
# Cortex-X925 that pins a core at 100 % and heats the SoC (which then shares memory bandwidth
# with the GPU). One sed, no behavior change for throughput. Provenance + measurements:
# https://github.com/TysAIs/gb10-vllm-ops  (patch-vllm-spinwait.sh).
#
#   docker build -t myllmbox/qwen38-flash-next-cluster-vllm:v6-spinfix docker/spinfix/
#
# Then ship it to the worker: docker save | ssh worker docker load   (image is ~22 GB).
#
# Or publish it to ghcr with no PAT at all -- the automatic GITHUB_TOKEN carries
# packages:write (this repo is public):
#
#   gh workflow run publish-spinfix-ghcr -f source=rebuild
#
# MBX_BASE lets CI pin the base explicitly (e.g. by digest) without editing this file.
# The default is unchanged, so every existing build command keeps working.
ARG MBX_BASE=myllmbox/qwen38-flash-next-cluster-vllm:v6
FROM ${MBX_BASE}

RUN sed -i "s/busy_loop_s: float = 1,/busy_loop_s: float = 0.002,/" \
      /usr/local/lib/python3.12/dist-packages/vllm/distributed/device_communicators/shm_broadcast.py \
 && grep -n "busy_loop_s: float = 0.002," \
      /usr/local/lib/python3.12/dist-packages/vllm/distributed/device_communicators/shm_broadcast.py

LABEL mbx.spinfix="shm_broadcast busy_loop_s 1 -> 0.002 (GB10 spin-wait thermal fix)"
