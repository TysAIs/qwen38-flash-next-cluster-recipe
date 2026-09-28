#!/usr/bin/env bash
# start.sh — the fleet's one command: load .env, start the cluster (run.sh does the rest), verify it answers.
# First run boot ≈ 4 min (weights already on disk); a fresh install additionally downloads ~99G once.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "no .env — cp .env.example .env and set the 3 variables (HF_TOKEN, WORKER, PORT)"; exit 1; }
./run.sh
./verify.sh
