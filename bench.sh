#!/bin/bash
# Deterministic GPU benchmark with heat soak (see AGENTS.md §4.4).
# Phase 1 (soak): mine unhittable 6-char prefix SOAKIT on bench salt/tids
#   for SOAK_SECS to bring the chassis to thermal steady state.
# Phase 2 (measure): wipe bench checkpoints, mine fixed 4-char prefix TEST.
#   Same salt+tid+counter => same key stream => the WINNER (tid+counter,
#   decoded from the .sta2) is bit-identical every run; only wall-clock and
#   the loser's +/-1 batch tail vary, so H/s compares apples-to-apples.
# Usage: ./bench.sh [--soak SECS] [--no-soak] [--prefix P] [-l LOCAL]
set -u
cd "$(dirname "$0")"

PREFIX="TEST"
SOAK_PREFIX="SOAKIT"
BENCH_SALT="0102030405060708090a0b0c0d0e0f10"
BENCH_TID=64
BATCH=1048576
SOAK=150
LOCAL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --soak) SOAK="$2"; shift 2 ;;
        --no-soak) SOAK=0; shift ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        -l) LOCAL="$2"; shift 2 ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
done

[ -x ./gpuminer ] || make gpuminer || exit 1

INTEL_DIR="$HOME/intel-ocl"
if [ -d "$INTEL_DIR/legacy" ]; then
    export LD_LIBRARY_PATH="/usr/lib:${INTEL_DIR}/legacy/root/usr/lib/x86_64-linux-gnu:${INTEL_DIR}/legacy/root/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export OPENCL_VENDOR_PATH="$INTEL_DIR/vendors-all"
fi

CK0=".gpu_checkpoint_t${BENCH_TID}.txt"
CK1=".gpu_checkpoint_t$((BENCH_TID + 1)).txt"

if [ "$SOAK" -gt 0 ]; then
    echo "bench: soaking ${SOAK}s on '${SOAK_PREFIX}' (6-char, never hits) ..."
    timeout "$SOAK" ./gpuminer "$SOAK_PREFIX" --salt "$BENCH_SALT" -t "$BENCH_TID" -b "$BATCH" ${LOCAL:+-l "$LOCAL"} --cpu 0 --quiet >>/tmp/opencode/bench-soak.log 2>&1
    echo "bench: soak done (rc=$?; 124 = timed out as intended)"
    rm -f "${SOAK_PREFIX}.sta2"
fi

# Fresh keyspace every run; bench tids never collide with real mining (0,1...).
rm -f "$CK0" "$CK1" ".cpu_checkpoint_t${BENCH_TID}.txt" ".cpu_checkpoint_t$((BENCH_TID + 1)).txt" "${PREFIX}.sta2"

T1=$(date +%s%N)
# GPU-only: canonical kernel gauge, CPU would only add thermal noise.
./gpuminer "$PREFIX" --salt "$BENCH_SALT" -t "$BENCH_TID" -b "$BATCH" ${LOCAL:+-l "$LOCAL"} --cpu 0 --quiet
RC=$?
T2=$(date +%s%N)
EL=$(awk -v a="$T1" -v b="$T2" 'BEGIN{e=(b-a)/1e9; if (e<0.1) e=0.1; printf "%.1f", e}')
C0=$(cat "$CK0" 2>/dev/null || echo 0)
C1=$(cat "$CK1" 2>/dev/null || echo 0)
case "$C0$C1" in ''|*[!0-9]*) echo "bench: bad checkpoint read"; exit 1;; esac
HASHES=$((C0 + C1))
HS=$(awk -v h="$HASHES" -v e="$EL" 'BEGIN{printf "%.0f", h/e}')
# Winner identity (deterministic part): tid + counter decoded from the key.
# Totals can vary +/-1 batch run-to-run (loser-device finish race); the
# winner must not.
WIN=$(python3 -c "
import base64,sys
sk = base64.b64decode(open('${PREFIX}.sta2').read().splitlines()[2])
print(int.from_bytes(sk[16:20], 'little'), int.from_bytes(sk[20:28], 'little'))
" 2>/dev/null || echo "? ?")
echo "bench: hashes=$HASHES elapsed=${EL}s H/s=$HS winner(tid counter)=$WIN (rc=$RC)"
