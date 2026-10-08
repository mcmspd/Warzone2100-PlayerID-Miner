#!/bin/bash
# Run gpuminer with both GPUs enabled. Usage: ./run.sh <PREFIX> [args...]
# All arguments are passed through to ./gpuminer (see README.md).
#
# Preflight: verifies the OpenCL driver stack and installs what's missing.
# Needs root for repo packages (uses passwordless sudo when available,
# otherwise prints the exact commands). The Intel Gen9 runtime can be
# installed rootless and is done automatically.
set -u
cd "$(dirname "$0")"

INTEL_DIR="$HOME/intel-ocl"
INTEL_LIB="$INTEL_DIR/legacy/root/usr/lib/x86_64-linux-gnu:$INTEL_DIR/legacy/root/usr/local/lib"
INTEL_VENDORS="$INTEL_DIR/vendors-all"

# Pinned working combination for Intel Gen9 (see AGENTS.md §4.3).
LEGACY_NEO_VER="24.35.30872.36"
LEGACY_GMM_VER="22.5.0"
LEGACY_IGC_VER="1.0.17537.24"
LEGACY_BASE_CR="https://github.com/intel/compute-runtime/releases/download/${LEGACY_NEO_VER}"
LEGACY_BASE_IGC="https://github.com/intel/intel-graphics-compiler/releases/download/igc-${LEGACY_IGC_VER}"

log()  { echo "[run.sh] $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

can_sudo() { sudo -n true 2>/dev/null; }
is_root()  { [ "$(id -u)" = "0" ]; }
can_install() { is_root || can_sudo; }
SUDO=""; is_root || { can_sudo && SUDO="sudo"; }

distro() { # echoes arch | debian | fedora | unknown
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-} ${ID_LIKE:-}" in
            *arch*|*cachyos*|*endeavour*|*manjaro*) echo arch ;;
            *debian*|*ubuntu*|*pop*|*mint*)         echo debian ;;
            *fedora*|*rhel*|*centos*)               echo fedora ;;
            *)                                     echo unknown ;;
        esac
    else
        echo unknown
    fi
}

pkg_install() { # pkg_install <arch-pkgs...>;<debian-pkgs...>;<fedora-pkgs...>
    local d; d=$(distro)
    local pkgs=""
    case "$d" in
        arch)   pkgs="$1" ;;
        debian) pkgs="$2" ;;
        fedora) pkgs="$3" ;;
    esac
    if [ -z "$pkgs" ] || [ "$pkgs" = "-" ]; then return 1; fi
    if ! can_install; then return 1; fi
    case "$d" in
        arch)   $SUDO pacman -S --needed --noconfirm $pkgs ;;
        debian) $SUDO apt-get update && $SUDO apt-get install -y $pkgs ;;
        fedora) $SUDO dnf install -y $pkgs ;;
    esac
}

print_install_cmds() { # print_install_cmds <desc> <arch>;<debian>;<fedora>
    echo "  manual install ($1):"
    echo "    Arch:   sudo pacman -S $2"
    echo "    Debian: sudo apt-get install -y $3"
    echo "    Fedora: sudo dnf install -y $4"
}

setup_intel_env() {
    if [ -d "$INTEL_DIR/legacy" ] && [ -d "$INTEL_VENDORS" ]; then
        export LD_LIBRARY_PATH="/usr/lib:${INTEL_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export OPENCL_VENDOR_PATH="$INTEL_VENDORS"
    fi
}

check_gpus() { # echoes "gpus: N" lines to stdout; returns 0 if >=1 GPU
    ./gpuminer --check 2>/dev/null
}

install_intel_legacy() {
    # Rootless fetch of the pinned Gen9 stack into $INTEL_DIR.
    log "installing Intel Gen9 OpenCL runtime (rootless) into $INTEL_DIR ..."
    have curl || { log "need curl for download"; return 1; }
    if ! have bsdtar && ! have ar; then log "need bsdtar or ar to unpack .debs"; return 1; fi
    mkdir -p "$INTEL_DIR/legacy/root" "$INTEL_VENDORS" "$INTEL_DIR/dl" || return 1
    local deb
    deb() { # deb <file.deb> <rootdir>: unpack payload, never cd's
        local t; t=$(mktemp -d) || return 1
        if have bsdtar; then
            bsdtar -xf "$1" -C "$t" || { rm -rf "$t"; return 1; }
        else
            (cd "$t" && ar x "$1") || { rm -rf "$t"; return 1; }
        fi
        local data; data=$(ls "$t"/data.tar.* 2>/dev/null | head -1)
        [ -n "$data" ] || { rm -rf "$t"; return 1; }
        case "$data" in
            *.zst) tar --use-compress-program=unzstd -xf "$data" -C "$2" ;;
            *)     tar -xzf "$data" -C "$2" ;;
        esac
        local rc=$?; rm -rf "$t"; return $rc
    }
    local url f dest
    for url in \
        "${LEGACY_BASE_CR}/intel-opencl-icd-legacy1_${LEGACY_NEO_VER}_amd64.deb" \
        "${LEGACY_BASE_CR}/libigdgmm12_${LEGACY_GMM_VER}_amd64.deb" \
        "${LEGACY_BASE_IGC}/intel-igc-core_${LEGACY_IGC_VER}_amd64.deb" \
        "${LEGACY_BASE_IGC}/intel-igc-opencl_${LEGACY_IGC_VER}_amd64.deb"; do
        f="$(basename "$url")"; dest="$INTEL_DIR/dl/$f"
        [ -f "$dest" ] || curl -sSL -o "$dest" "$url" || { log "download failed: $url"; return 1; }
        deb "$dest" "$INTEL_DIR/legacy/root" || { log "unpack failed: $f"; return 1; }
    done
    echo "$INTEL_DIR/legacy/root/usr/lib/x86_64-linux-gnu/intel-opencl/libigdrcl_legacy1.so" \
        > "$INTEL_VENDORS/intel_legacy.icd"
    if [ -r /etc/OpenCL/vendors/nvidia.icd ]; then
        cp /etc/OpenCL/vendors/nvidia.icd "$INTEL_VENDORS/nvidia.icd"
    fi
    log "Intel runtime installed."
    return 0
}

preflight() {
    # 0. OpenCL loader present?
    if ! ldconfig -p 2>/dev/null | grep -q libOpenCL.so.1; then
        log "OpenCL loader (libOpenCL.so.1) not found."
        if pkg_install "ocl-icd" "ocl-icd-libopencl1" "ocl-icd"; then
            log "loader installed."
        else
            print_install_cmds "OpenCL loader" "ocl-icd" "ocl-icd-libopencl1" "ocl-icd"
            return 1
        fi
    fi

    local info; info=$(check_gpus); local rc=$?
    local have_nv=0 have_intel=0 have_amd=0
    echo "$info" | grep -qi "nvidia" && have_nv=1
    echo "$info" | grep -qi "intel" && have_intel=1
    echo "$info" | grep -qi -E "amd|radeon" && have_amd=1

    local need_nv=0 need_intel=0 need_amd=0
    if have lspci; then
        lspci -n 2>/dev/null | grep -q "0300:.*10de\|0302:.*10de" && [ "$have_nv" = "0" ] && need_nv=1
        lspci -n 2>/dev/null | grep -q "0300:.*8086" && [ "$have_intel" = "0" ] && need_intel=1
        lspci -n 2>/dev/null | grep -q "0300:.*1002\|0302:.*1002" && [ "$have_amd" = "0" ] && need_amd=1
    fi

    # 1. NVIDIA driver missing?
    if [ "$need_nv" = "1" ]; then
        log "NVIDIA GPU present but no NVIDIA OpenCL platform."
        if pkg_install "nvidia-dkms nvidia-utils linux-headers" "nvidia-driver" "-"; then
            log "NVIDIA driver installed — REBOOT, then re-run."
            return 3
        else
            print_install_cmds "NVIDIA driver (then REBOOT)" \
                "nvidia-dkms nvidia-utils linux-headers" "nvidia-driver" "(via RPMFusion, then reboot)"
            return 1
        fi
    fi

    # 2. Intel OpenCL missing?
    if [ "$need_intel" = "1" ]; then
        log "Intel GPU present but no Intel OpenCL platform."
        local fixed=0
        # repo package first (covers Gen11+)
        if pkg_install "intel-compute-runtime" "intel-opencl-icd" "-"; then
            setup_intel_env
            if check_gpus | grep -qi "intel"; then fixed=1; fi
        fi
        # Gen9 fallback: AUR helper, else pinned rootless fetch
        if [ "$fixed" = "0" ]; then
            if have yay && can_install && yay -S --needed --noconfirm intel-compute-runtime-legacy-bin 2>/dev/null; then
                fixed=1
            elif have paru && can_install && paru -S --needed --noconfirm intel-compute-runtime-legacy-bin 2>/dev/null; then
                fixed=1
            elif install_intel_legacy; then
                setup_intel_env
                if check_gpus | grep -qi "intel"; then fixed=1; fi
            fi
        fi
        if [ "$fixed" = "0" ]; then
            echo "  could not set up Intel OpenCL automatically."
            print_install_cmds "Intel runtime (Gen11+)" \
                "intel-compute-runtime" "intel-opencl-icd" "(not in stock repos)"
            echo "  Gen9 (HD/UHD 5xx-6xx): AUR intel-compute-runtime-legacy-bin,"
            echo "  or rootless fetch, see AGENTS.md §4.3."
            return 1
        fi
        log "Intel OpenCL ready."
    fi

    # 3. AMD OpenCL missing?
    if [ "$need_amd" = "1" ]; then
        log "AMD GPU present but no AMD OpenCL platform."
        if pkg_install "opencl-mesa" "mesa-opencl-icd" "mesa-libOpenCL"; then
            # Rusticl hides devices unless opted in (see Mesa docs).
            export RUSTICL_ENABLE="${RUSTICL_ENABLE:-radeonsi}"
            log "AMD runtime installed."
        else
            print_install_cmds "AMD runtime (untested)" \
                "opencl-mesa" "mesa-opencl-icd" "mesa-libOpenCL"
            return 1
        fi
    fi
    return 0
}

if [ ! -x ./gpuminer ]; then
    echo "building gpuminer first..."
    make || exit 1
fi

setup_intel_env
if ! preflight; then
    rc=$?
    [ "$rc" = "3" ] && exit 3
    echo "[run.sh] continuing with available GPUs (some hardware has no OpenCL)."
fi
setup_intel_env

if [ ! -x ./gpuminer ]; then
    echo "building gpuminer first..."
    make gpuminer || exit 1
fi

setup_intel_env
if ! preflight; then
    rc=$?
    [ "$rc" = "3" ] && exit 3
    echo "[run.sh] continuing with available GPUs (some hardware has no OpenCL)."
fi
setup_intel_env

# --- orchestration: all workers share one salt, disjoint tids ---
# Usage: run.sh PREFIX [-b BATCH] [--cpu N|--no-cpu] [--no-gpu] [--salt HEX]
PREFIX=""
BATCH=1048576
CPU_THREADS=""
USE_CPU=1
USE_GPU=1
SALT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cpu)      USE_CPU=1; CPU_THREADS="$2"; shift 2 ;;
        --no-cpu)   USE_CPU=0; shift ;;
        --no-gpu)   USE_GPU=0; shift ;;
        -b)         BATCH="$2"; shift 2 ;;
        --salt)     SALT="$2"; shift 2 ;;
        -h|--help)  echo "Usage: $0 PREFIX [-b BATCH] [--cpu N|--no-cpu] [--no-gpu] [--salt HEX32]"; exit 0 ;;
        -*)         echo "unknown option: $1"; exit 1 ;;
        *)          [ -z "$PREFIX" ] && PREFIX="$1" || { echo "extra arg: $1"; exit 1; }; shift ;;
    esac
done
[ -n "$PREFIX" ] || { echo "Usage: $0 PREFIX [-b BATCH] [--cpu N|--no-cpu] [--no-gpu] [--salt HEX32]"; exit 1; }

if [ "$USE_GPU" = "0" ] && [ "$USE_CPU" = "0" ]; then
    echo "nothing to run (both --no-gpu and --no-cpu)"; exit 1
fi

# GPU-only: keep gpuminer's own foreground HUD.
if [ "$USE_CPU" = "0" ]; then
    if [ -n "$SALT" ]; then exec ./gpuminer "$PREFIX" --salt "$SALT" -b "$BATCH" --quiet;
    else exec ./gpuminer "$PREFIX" -b "$BATCH"; fi
fi
# CPU-only: keep mminer4's own foreground HUD.
if [ "$USE_GPU" = "0" ]; then
    [ -x ./mminer4 ] || make mminer4 || exit 1
    if [ -z "$CPU_THREADS" ]; then CPU_THREADS=$(nproc 2>/dev/null || echo 4); fi
    if [ -n "$SALT" ]; then exec ./mminer4 "$PREFIX" -t "$CPU_THREADS" --salt "$SALT";
    else exec ./mminer4 "$PREFIX" -t "$CPU_THREADS"; fi
fi

# Combined: GPUs (tids 0..ndev-1) + CPU (tids ndev..) under one salt.
# Default CPU to 25% of cores: iGPU shares package power/thermals with the
# CPU, and CPU H/J is worse, so full CPU starves the iGPU. Explicit --cpu N wins.
[ -x ./mminer4 ] || make mminer4 || exit 1
if [ -z "$CPU_THREADS" ]; then
    _n=$(nproc 2>/dev/null || echo 4)
    CPU_THREADS=$(( (_n + 3) / 4 ))
    [ "$CPU_THREADS" -lt 1 ] && CPU_THREADS=1
fi
if [ -z "$SALT" ]; then SALT=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n'); fi
GPU_TIDS=$(./gpuminer --check 2>/dev/null | grep -c "^  gpu " || true)
STA="$(printf '%s' "$PREFIX" | tr -c 'A-Za-z0-9+=' '_').sta2"
rm -f "$STA"
GPU_LOG=.run_gpuminer.log; CPU_LOG=.run_mminer4.log
: > "$GPU_LOG"; : > "$CPU_LOG"

# snapshot resume points so the HUD counts this run only
INIT_SUM=0
for f in .gpu_checkpoint_t*.txt .cpu_checkpoint_t*.txt; do
    [ -f "$f" ] || continue
    v=$(cat "$f" 2>/dev/null); case "$v" in ''|*[!0-9]*) v=0 ;; esac
    INIT_SUM=$((INIT_SUM + v))
done
PLEN=${#PREFIX}; [ "$PLEN" -gt 43 ] && PLEN=43
EXPECTED=$(awk -v n="$PLEN" 'BEGIN{e=1; for(i=0;i<n;i++) e*=64; if (n==43) e/=4; printf "%.0f", e}')

./gpuminer "$PREFIX" --salt "$SALT" -b "$BATCH" --quiet >>"$GPU_LOG" 2>&1 &
GPU_PID=$!
./mminer4 "$PREFIX" -t "$CPU_THREADS" --salt "$SALT" --tid-base "$GPU_TIDS" --quiet >>"$CPU_LOG" 2>&1 &
CPU_PID=$!
START=$(date +%s)
INTERRUPTED=0
# cleanup must be airtight: workers blocked in clFinish/OpenMP loops have
# survived a bare TERM before, orphaning GPU-burning processes.
cleanup() {
    kill "$GPU_PID" "$CPU_PID" 2>/dev/null
    for _ in $(seq 1 50); do
        kill -0 "$GPU_PID" 2>/dev/null || kill -0 "$CPU_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -9 "$GPU_PID" "$CPU_PID" 2>/dev/null
    wait 2>/dev/null
}
onint() { INTERRUPTED=1; cleanup; }
trap onint INT TERM
echo "[run.sh] mining '$PREFIX' with $GPU_TIDS GPU(s) + $CPU_THREADS CPU threads (salt ${SALT:0:8}...) — Ctrl-C stops"
while kill -0 "$GPU_PID" 2>/dev/null && kill -0 "$CPU_PID" 2>/dev/null && [ ! -f "$STA" ]; do
    sleep 0.5
    SUM=0
    for f in .gpu_checkpoint_t*.txt .cpu_checkpoint_t*.txt; do
        [ -f "$f" ] || continue
        v=$(cat "$f" 2>/dev/null); case "$v" in ''|*[!0-9]*) v=0 ;; esac
        SUM=$((SUM + v))
    done
    MINED=$((SUM - INIT_SUM)); [ "$MINED" -lt 0 ] && MINED=0
    NOW=$(date +%s); EL=$((NOW - START)); [ "$EL" -lt 1 ] && EL=1
    SPD=$((MINED / EL))
    if [ "$SPD" -gt 0 ] && [ "$EXPECTED" -gt "$MINED" ] 2>/dev/null; then
        ETA_S=$(awk -v e="$EXPECTED" -v m="$MINED" -v s="$SPD" 'BEGIN{printf "%d", (e-m)/s}')
        if [ "$ETA_S" -lt 60 ]; then ETA="${ETA_S}s";
        elif [ "$ETA_S" -lt 3600 ]; then ETA="$((ETA_S/60))m $((ETA_S%60))s";
        elif [ "$ETA_S" -lt 86400 ]; then ETA="$((ETA_S/3600))h $(((ETA_S%3600)/60))m";
        else ETA="$((ETA_S/86400))d $(((ETA_S%86400)/3600))h"; fi
    else ETA="--"; fi
    printf "\r[*] Hashes: %s | Speed: %s H/s | ETA: %s   " "$(printf "%'d" "$MINED" 2>/dev/null || echo "$MINED")" "$(printf "%'d" "$SPD" 2>/dev/null || echo "$SPD")" "$ETA"
done
echo
cleanup
trap - INT TERM
if [ ! -f "$STA" ]; then
    if [ "$INTERRUPTED" = "1" ]; then echo "[run.sh] interrupted; progress kept in checkpoint files."; exit 130; fi
    echo "[run.sh] workers exited without a result; see $GPU_LOG $CPU_LOG"; exit 1
fi

# verify + identify winner
if have python3 && python3 -c "import nacl" 2>/dev/null; then
    if python3 test_property.py "$STA" "$PREFIX"; then
        echo "[run.sh] key verified."
    else
        echo "[run.sh] WARNING: property test FAILED — key kept for inspection."
        exit 2
    fi
else
    echo "[run.sh] (PyNaCl absent — skipping verification)"
fi
WTID=$(python3 -c "
import base64,sys
sk = base64.b64decode(open(sys.argv[1]).read().splitlines()[2])
print(int.from_bytes(sk[16:20], 'little'))
" "$STA" 2>/dev/null || echo "?")
if [ "$WTID" != "?" ] && [ "$WTID" -lt "$GPU_TIDS" ] 2>/dev/null; then
    echo "[run.sh] winner: GPU tid $WTID"
else
    echo "[run.sh] winner: CPU tid $WTID"
fi
exit 0
