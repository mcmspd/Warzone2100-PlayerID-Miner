# Warzone 2100 Player ID Miner (GPU)

Brute-force vanity Ed25519 Player ID miner for Warzone 2100. Finds a seed
whose base64-encoded public key starts with your target prefix, then writes
a `.sta2` file the game loads directly. See `AGENTS.md` for the full spec,
measured numbers, and design notes.

## Requirements

- `gcc`, OpenCL headers + loader (`ocl-icd`), `libsodium`
  (`pacman -S base-devel ocl-icd opencl-headers libsodium`)
- An OpenCL GPU. NVIDIA works out of the box with its driver installed.
- Python + PyNaCl only for the integerity check (`make check`).

## Build

```sh
make          # builds ./gpuminer
```

## Run

```sh
./run.sh <PREFIX>           # builds if needed, enables both GPUs, runs
```

`run.sh` builds `./gpuminer` if missing, sets the GPU environment, and
passes all arguments through to it (flags below). It starts with a
preflight: if a GPU has no working OpenCL driver, `run.sh` installs it
automatically — repo packages via passwordless sudo when available
(password prompt never hangs: without it you get the exact command to run
yourself), Intel Gen9 via a rootless fetch. NVIDIA driver installs stop
with a reboot notice, since the new driver won't load until then.
First launch compiles the kernels once (~10–30 s, mostly the iGPU);
binaries cache to `.gpuminer_cache_*` so later runs start mining
immediately. Or step by step (`make`, exports, `./gpuminer`) — see below.

```sh
./gpuminer <PREFIX> [DEVICE_ID] [-t TID] [-b BATCH]
```

- `PREFIX`: wanted leading characters of the Player ID (Base64 alphabet).
  Budget for the 99% worst case (4.6x the mean — lucky draw, plan unlucky):
  2 chars seconds, 3 chars seconds, 4 chars ~2.5 min, 5 chars ~2.6 h,
  6 chars ~7 days — at ~520k H/s dual-GPU (GTX 1050 Ti + HD 630).
- `DEVICE_ID`: optional number mixed into the seed salt so clustered
  machines never overlap. Default is a random salt.
- `-t TID`: thread-id tag in the seed layout (default 0). Each GPU gets
  `TID + device_index`, so partitions stay disjoint and resumable.
- `-b BATCH`: candidates per device per launch (default 1048576).
  Smaller = fresher HUD, less overshoot on short finds.

Examples:

```sh
./gpuminer AB            # seconds, writes AB.sta2
./gpuminer TEST          # under a minute on dual GPU, writes TEST.sta2
./gpuminer TEST 7 -t 4  # cluster device 7, tids 4+5
```

All GPUs found on the system mine together; the first finder wins and the
result is verified on the CPU (via libsodium) before saving. Progress,
 checkpoints (`.gpu_checkpoint_t*.txt`, per tid), and ETA print live;
 re-running resumes where it stopped. A failed `.sta2` write exits non-zero.

## All workers at once (CPU + GPU)

```sh
./run.sh <PREFIX> [--cpu N|--no-cpu] [--no-gpu] [--salt HEX32]
# or directly: ./gpuminer <PREFIX> [--cpu N] [--no-cpu] [--no-gpu]
```

One binary runs every GPU plus CPU workers under one shared salt, with
disjoint `tid` partitions (GPUs `0..n-1`, CPU from `n`), so nothing is
searched twice and a mixed cluster can split by tid ranges. CPU defaults
to 25% of cores (package budget is shared with the iGPU); `--cpu N`
overrides, `--cpu 0`/`--no-cpu` disables. Checkpoints are per-tid
(`.gpu/cpu_checkpoint_t*.txt`); Ctrl-C stops and re-running resumes.
`mminer4` remains as the standalone CPU reference miner.

## Both GPUs (NVIDIA + Intel iGPU on this machine)

The Intel HD 630 needs the legacy NEO runtime (`intel-opencl-icd-legacy1
24.35.30872.36` + `libigdgmm12 22.5.0` + IGC `1.0.17537.24`; NEO 26.x
dropped Gen9) and the distro `ocl-icd` loader must win over NVIDIA's
bundled one (baked into the binary via rpath; see `AGENTS.md` §4.3).
With the runtime at `~/intel-ocl`:

```sh
export LD_LIBRARY_PATH=/usr/lib:$HOME/intel-ocl/legacy/root/usr/lib/x86_64-linux-gnu:$HOME/intel-ocl/legacy/root/usr/local/lib
export OPENCL_VENDOR_PATH=$HOME/intel-ocl/vendors-all
./gpuminer <PREFIX>
```

Without those exports, `gpuminer` simply uses whatever GPUs the default
loader sees (here: NVIDIA only). Verify visibility any time with
`clinfo -l` under the same exports.

## Check a result

```sh
make check              # mines ZZ, then runs test_property.py on ZZ.sta2
python3 test_property.py <file.sta2> <PREFIX>   # any key, any time
```

The property test re-derives the public key from the seed, checks the
signature verifies, and asserts the prefix — the acceptance gate for any
change to the kernel.

## Portability (Linux x86-64 little-endian)

The kernels are pure OpenCL C 1.2 — no vendor extensions, no inline asm —
and should compile on any full-profile OpenCL 1.2+ GPU (NVIDIA, Intel,
AMD). Tested only on GTX 1050 Ti + HD 630; everything else is reasoned,
not measured.

- **NVIDIA-only box**: works out of the box with the proprietary driver.
- **Intel iGPU**: Gen11+ via distro `intel-compute-runtime`; Gen9
  (HD/UHD 5xx-6xx) needs the legacy branch — `run.sh` fetches it
  rootlessly when it detects the gap.
- **AMD**: kernel should build (RadeonSI/Rusticl/ROCm all take 1.2).
  Runtimes, in order of preference: Mesa Rusticl (all GCN/RDNA APUs
  including old Vega — needs `RUSTICL_ENABLE=radeonsi`, set by `run.sh`;
  ships with Mesa, nothing to install on most distros) →
  AMDGPU-PRO PAL OpenCL (broader APU coverage, proprietary) →
  ROCm `rocm-opencl` (only Ryzen AI 300/Max APUs on Ubuntu, ML-focused;
  older APUs unsupported). All untested here — validate with `make check`.
- **NVIDIA RTX 50 (Blackwell)**: no action needed — OpenCL 3.0 ships in
  R570+ drivers (conformant since R465). Estimates only: ~30–50x a
  GTX 1050 Ti (~10–18M H/s on a 5090), 6-char prefix in ~1–2 h.
  Our kernel is occupancy-bound, so measure, don't trust the estimate.
- **No GPU at all**: `./run.sh <PREFIX> --no-gpu` (or `gpuminer --no-gpu`)
  runs the built-in CPU workers instead.
- **`make dist` binaries**: need glibc >= the build machine's (2.44 here)
  plus the target's own GPU driver stack. Little-endian x86-64 assumed
  (seed `tid`/`counter` are raw `memcpy` little-endian on the host).
- **Not supported**: Windows/macOS (`run.sh` needs `lspci`, os-release
  package names, and Unix ICD paths), big-endian CPUs, 32-bit (untested).

## Renting a farm (7–8 char prefixes)

Local hardware tops out around 6 chars. For more, rent NVIDIA pods —
`make dist` binaries deploy as-is (CUDA images ship OpenCL; only
`libOpenCL` + libc needed). Farm recipe: same `--salt` on every box,
disjoint `-t` tid ranges per box/GPU — no other coordination needed,
and per-tid checkpoints make preemption nearly free, so use
interruptible/spot instances.

| target | setup (est. rates) | cost basis (2026 prices) |
|---|---|---|
| 7 chars (~3 d mean) | 1× RTX 5090 (~15 MH/s) | ~$56 on RunPod community ($0.69/h) |
| 8 chars (~1 mo mean) | 10× RTX 4090 (~100 MH/s) | ~$2.4k/mo RunPod community ($0.34/h) |
| 8 chars, budget | 14× RTX 3090 (~100 MH/s) | ~$2.2k/mo, or ~$1.3k interruptible on Vast.ai |

Cheapest $/MH is usually previous-gen (3090) on community/interruptible
tiers. Validate one box first (`make check` + one timed prefix) before
scaling — per-GPU rates here are estimates until measured.

## Portable build (fresh PC without dev packages)

```sh
make dist               # downloads libsodium, builds static, embeds kernels
```

`dist/` holds single-file `gpuminer` + `mminer4` with static libsodium and
embedded kernels — nothing to install except the GPU driver stack. Dynamic
deps left (`ldd`): `gpuminer` → `libOpenCL` + libc; `mminer4` → `libgomp` +
libc. Two caveats, both unavoidable:

- The target still needs a working OpenCL driver + ICD loader for its own
  GPU (copying our NVIDIA/Intel runtime won't help another machine).
- Binaries need a glibc >= the build machine's (2.44 here); older distros
  won't run them.
