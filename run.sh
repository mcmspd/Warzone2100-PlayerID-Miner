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

    # 3. AMD OpenCL missing? (best effort, untested here — no AMD hardware)
    if [ "$need_amd" = "1" ]; then
        log "AMD GPU present but no AMD OpenCL platform."
        if pkg_install "opencl-rusticl-mesa" "mesa-opencl-icd" "mesa-libOpenCL"; then
            log "AMD runtime installed."
        else
            print_install_cmds "AMD runtime (untested)" \
                "opencl-rusticl-mesa" "mesa-opencl-icd" "mesa-libOpenCL"
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

exec ./gpuminer "$@"
