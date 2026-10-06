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
  2 chars takes seconds, 3 chars seconds, 4 chars ~1 min, 5 chars ~35 min,
  6 chars ~1.5 days — at ~520k H/s dual-GPU (GTX 1050 Ti + HD 630).
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
