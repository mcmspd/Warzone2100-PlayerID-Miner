# AGENTS.md — Warzone 2100 Player ID Miner

Spec + verified-findings handoff for a full rewrite. Provenance of every claim
below:

- **Verified** — checked empirically on this machine against the current
  implementation (compiled all 5 C binaries, ran them, and cryptographically
  validated their output). Treat as ground truth.
- **Confirmed by owner** — domain knowledge from the project owner, not
  derivable from the code.
- **Open** — genuinely unresolved; see §7.

There are no remaining guesses in the format section. The pipeline is
understood end to end.

## 1. What this tool does

One job: find an Ed25519 seed whose **base64-encoded public key starts with a
target prefix**. The prefix becomes the player's vanity Player ID in
Warzone 2100.

```
seed (32B) -> SHA-512 -> clamp -> scalar-mult base -> public key (32B)
           -> base64 -> 44-char Player ID -> strncmp against prefix -> match?
```

Vanity search, brute force. There is no clever shortcut; the work is finding
one seed in 64^N.

## 2. Verified format facts

These are the load-bearing facts. Do not change them.

**Player ID** = `base64(public_key[32])` = 44 characters.
- Characters 0..42 are data; character 43 is **always `=`**.
- Characters 0..41 carry 6 bits each (64 possible values).
- **Character 42 carries only 4 bits — 16 possible values:
  `048AEIMQUYcgkosw`.** This breaks the naive `64^N` model (see §5).

**Secret key** = `base64(seed[32] || public_key[32])` = 88 characters.
This is libsodium's standard `crypto_sign_SECRETKEYBYTES` layout, and PyNaCl's
`bytes(SigningKey)` produces the identical bytes. Do not invent a new layout.

**Seed derivation** used by the `mminer*` family (`mminer4.c:116-120`,
the kept CPU reference; `gpuminer` uses the identical layout):

| bytes | contents |
|-------|----------|
| 0..15 | 16-byte machine salt (random, unless explicit DEVICE_ID given) |
| 16..19 | thread id, little-endian `uint32` |
| 20..27 | per-thread counter, little-endian `uint64` |
| 28..31 | zero padding |

With an explicit positional `DEVICE_ID`, bytes 0..7 hold the LE `uint64`
device id and the rest of the 16-byte field is zeroed.

The zero padding at 28..31 and the LE thread/counter fields are *load-bearing
identifiers* — real keys in the wild carry them. Verified: both blobs in
`hash.py` decode to `thread=2, counter=1983690` and `thread=2, counter=489236`
with zeroed padding.

**`.sta2` output** as written by `mminer4`:

```
WZ.STA.v3
10 10 454 902788 10
<88-char base64 seed||public_key>
```

The magic middle line `10 10 454 902788 10` is a literal that Warzone 2100
does **not** validate — confirmed against a live game install. The game reads
only the key on line 3; those fields carry no meaning and no load-bearing
state. Do not spend rewrite effort deriving, explaining, or validating them.
Keep them only because the file parser expects a second line.

This write path is the only one that delivers value to the user, so it must
keep working — but it is simple, and the only real defect in it is the silent
`fopen` failure in §6.

**Extraction** (`hash.py`): the in-game Player ID is `base64_decode(key)[-32:]`,
i.e. the public key half of the 88-char string. Confirmed correct.

**Base64 variant**: `sodium_bin2base64(..., VARIANT_ORIGINAL)`, byte-identical
to Python's `base64.b64encode`. Standard alphabet, padded.

## 3. Why deterministic seeds matter

Determinism is not stylistic — it is what makes the tool resumable and
distributable:

- resume skips already-checked keys
- a worker can hand its counter range to another machine
- a found key can be re-derived and verified later from `(salt, tid, counter)`
  alone, without storing it

`miner.c` uses `crypto_sign_keypair()` (fully random) and therefore has
**none** of these properties. Do not carry that forward.

## 4. Measured performance (this machine, 4 workers)

| implementation | throughput |
|---|---|
| C / OpenMP | ~172k H/s |
| Python / multiprocessing | ~133k H/s |

Python reaches **~77% of C**. That materially weakens the case for maintaining
a C implementation at all — one Python program would be far simpler for a 1.3x
throughput gap. Only worth keeping C if you need many more cores per host or
plan a GPU path (§7).

Single-machine ETA at 133k H/s:

| prefix | expected hashes | time |
|---|---|---|
| 3 chars | 262,144 | ~2 s |
| 4 chars | 16,777,216 | ~2 min |
| 5 chars | 1,073,741,824 | ~2.2 h |
| 6 chars | 68,719,476,736 | ~6 days |

6+ characters is realistically a multi-device project. The user should be told
this up front rather than discovering it at hour 6.

**The deferred-keygen optimization in `mminer3`/`mminer4` buys nothing.**
Measured 3 runs each: `mminer` 1,375k/1,375k/1,365k vs `mminer3`
1,395k/1,360k/1,365k — pure noise. libsodium's `crypto_sign_seed_keypair`
only adds a 32-byte `mempk` over the fast path; the scalar multiplication
dominates either way. `mminer3`/`mminer4` added ~200 duplicated lines and a
hand-rolled crypto path for 0% gain. **Drop it.**

### 4.1 GPU rewrite — decided, and the one constraint that decides the design

**Requirement (project owner): the whole miner runs on the GPU, via OpenCL,
not CUDA.**

Test hardware present on this machine: **NVIDIA GeForce GTX 1050 Ti Mobile**
(GP107M, 6 compute units, 4 GB, OpenCL C 1.2, 48 KB local mem / work group,
driver 580.178.04) exposed through the `nvidia.icd` ICD. This is why OpenCL
rather than CUDA is both a requirement and the right call — it keeps the port
path to AMD/Intel open.

**The decisive measurement.** Do *not* assume the field arithmetic will follow
libsodium's layout. Probed on this device:

| operation | throughput |
|---|---|
| native 64-bit integer multiply-add | **56.9 Gop/s** |
| 32-bit multiply-add | **336.2 Gop/s** |
| 32-bit multiply widened to a 64-bit accumulator | **298.6 Gop/s** |

So on Pascal, a native `ulong` multiply is **~5.9x slower** than a 32-bit
multiply, while widening a 32-bit product into a 64-bit accumulator costs only
~11%. A direct port of libsodium's 64-bit-limb field arithmetic would throw
away roughly 6x.

**Design consequence — non-negotiable:** represent field elements as
**32-bit limbs with 64-bit accumulators** (radix 2^25.5, the layout used by
fiat-crypto's 32-bit Ed25519). Do not use 64-bit limbs. Side benefit: this
needs no 64-bit *language* support, only 64-bit types for accumulators, so
the kernel stays portable to pre-1.2 OpenCL devices too.

Note that `clinfo` on this box does **not** list `cl_khr_int64` (only
`cl_khr_int64_base_atomics` / `_extended_atomics`), yet `ulong` compiles and
multiplies correctly — verified empirically. Do not gate the build on that
extension string appearing; test by compiling.

Projected throughput at ~40% of measured peak, ~2500 field mults/candidate
plus batched SHA-512: **~2 M candidates/s vs ~172k H/s on the CPU (~12x)**.
At 2 M/s a 6-character prefix (~6.9e10 expected hashes) drops from ~6 days to
~6 hours, which is what makes GPU worth doing at all. The comb method
(Hisil–Carter–Dawson / Bernstein–Lange) can cut point additions well below the
fixed-base ~250 baseline and is the main remaining optimization.

**Status (measured, this machine): `gpuminer` lands at ~345–368k H/s
per NVIDIA GPU saturated (2.0–2.1x the CPU rate), ~435k H/s combined with
the Intel iGPU (§4.3), not the projected 2 M/s.** Correctness is
fully validated (e2e seed→pubkey vs libsodium: 256/256; §8 property test
passes on GPU-mined keys). The gap to projection is register pressure
(each work-item holds SHA-512 `w[80]` + `ge_p3/p1p1/precomp`) and unturned
occupancy — optimization work, not correctness work. Even at 2x, a 5-char
prefix drops from ~2.2 h to ~50 min and 6-char from ~6 d to ~2.2 d.
Measured: `TEST` (4 chars, 16.6M hashes) in 47 s; `ZZ` (2 chars) in 0.02 s.

Files: `gpuminer.c` (host: work distribution, checkpoint/resume, `.sta2`
output) + `gpuminer.cl` (mine kernel: seed→SHA-512→clamp→`ge_scalarmult_base`→
prefix match) + `fe25519.cl` / `ge25519.cl` (generated from libsodium ref10 by
`gen_fe.py` / `gen_ge.py` — never hand-edit) + `sha512_consts.cl` (generated
by `gen_consts.py`). Build with `make`; validate with `make check`.
Seed layout is `mminer`-compatible (`salt||tid||counter||pad`), so GPU-mined
`.sta2` files are interchangeable with CPU-mined ones. Both `mminer4` §6
defects are fixed: output filename is sanitized, and write failure exits 2.

The three hard parts, in order of difficulty: (1) Ed25519 base scalar mult in
32-bit limbs, (2) multi-buffer SHA-512, (3) the OpenCL host driver for
work distribution, checkpoint/resume, and found-key reporting.

### 4.2 Reference sources — do not hand-roll crypto from memory

All GPU kernel code must be ported from these, not written from recall
(after a hand-rolled SHA-512 failed validation twice):

- **SHA-512: RFC 6234 §5.2/§6.4 + libsodium
  `crypto_hash/sha512/cp/hash_sha512_cp.c` (Colin Percival).**
  FIPS 180-4 names: `S0/S1` (rounds) = ROTR28/34/39 and ROTR14/18/41;
  `s0/s1` (schedule) = ROTR1/8/SHR7 and ROTR19/61/SHR6.
  `Ch = (x & (y ^ z)) ^ z`, `Maj = (x & y) ^ (x & z) ^ (y & z)`.
  Message = 32 bytes → single 1024-bit block, `W[15] = 256` (bits, not bytes),
  `be64dec` (big-endian) parsing. Status: **kernel validated —
  65,536 random seeds, 0 mismatches vs libsodium, ~193 M/s on GTX 1050 Ti.**
- **Ed25519 field: libsodium `ed25519_ref10_fe_25_5.h` (1044 lines).**
  `fe25519 = int32_t[10]`, radix 2^25.5, `int64_t` accumulators — exactly
  the 32-bit-mul layout the probe mandates. Port `add/sub/neg/mul/sq/sq2/
  mul32/invert/frombytes/tobytes` verbatim, then validate each against
  libsodium before building group ops on top.
- **Ed25519 group: libsodium `crypto_core/ed25519/ref10/ed25519_ref10.c`
  (2992 lines) + `ed25519_ref10.h`.** `ge25519_p3/p2/p1p1/precomp/cached`,
  `ge25519_scalarmult_base` with precomputed base table. Port, do not redesign.
- **Structure reference: Brad Conte `sha256.c` (public domain).**
  Clean single-block transform used to isolate the systematic test-harness bug
  (`x>>25` vs `ROTR(x,25)` in EP1). Keep as a style template for kernel code.
- **Spec oracles: RFC 6234 (SHA), RFC 8032 (Ed25519 test vectors).**
  Final acceptance remains §8 property test + RFC 8032 vectors.

Local clones for porting (not committed): `/tmp/opencode/ref-libsodium`,
`/tmp/opencode/ref-crypto-algs`, `/tmp/opencode/ref-fiat` (fiat-crypto, future
32-bit codegen alternative).

### 4.3 Multi-GPU: NVIDIA + Intel iGPU together (measured)

Both GPUs on this machine mine concurrently, each in its own keyspace
partition (`tid` = device index, same salt). No coordination needed;
first finder wins via host atomic, loser discards. Sustained combined
**~520k H/s (~3x single CPU)** — per-device checkpoint counters confirm
both contribute continuously: GTX 1050 Ti ~377k/s + HD 630 ~147k/s
(65.5M hashes: 47.2M NVIDIA + 18.4M Intel in one 6-char run).

Hardware present: NVIDIA GP107M (6 CUs, driver 580.178.04, `nvidia.icd`)
+ Intel HD Graphics 630 (24 EUs @1100 MHz, PCI 8086:591b, i915, OpenCL 3.0
NEO limited to OpenCL C 1.2 — fine, the kernel targets 1.2).

Three setup gotchas, all verified empirically — do not skip:

1. **NEO 26.x dropped Gen9.** It lists only Xe/Arc/UHD 7xx; the HD 630
   needs the `legacy1` branch. Working combination: `intel-opencl-icd-
   legacy1 24.35.30872.36` + `libigdgmm12 22.5.0` + IGC `1.0.17537.24`
   (core + opencl debs from Intel GitHub releases; see AUR
   `intel-compute-runtime-legacy-bin` for the exact asset list).
2. **Rootless install works.** No sudo needed: extract the debs to a user
   dir, write your own `<dir>.icd` with the absolute `libigdrcl_legacy1.so`
   path, and point the loader at it (next point).
3. **Loader shadowing.** `clinfo`/binaries resolve `libOpenCL.so.1` to
   NVIDIA's bundled Khronos loader (`/opt/cuda/lib64`), which ignores
   vendor-dir overrides — symptoms are "0 platforms" or missing Intel.
   Force the distro ocl-icd first: `LD_LIBRARY_PATH=/usr/lib:...`, then
   `OPENCL_VENDOR_PATH=<dir-with-both-.icd-files>`. (`OCL_ICD_VENDORS`
   does *not* work as a directory on ocl-icd 2.3.5; `OPENCL_VENDOR_PATH`
   does.) The `Makefile` bakes `-Wl,-rpath,/usr/lib` so `gpuminer`
   always loads ocl-icd. Direct `dlopen` + `clIcdGetPlatformIDsKHR`
   bypasses all of this and is the fastest way to isolate driver vs
   loader problems.

Intel data points: our kernel builds unmodified on IGC and the full
seed→pubkey pipeline validates 256/256 vs libsodium on the iGPU too.
`gpuminer` needs `-pthread` (one host thread per device) and per-tid
checkpoint files already keep the partitions resumable independently.

## 5. Probability model

For prefix length N:
- **N <= 42:** expected hashes = `64^N`. Correct.
- **N = 43:** expected = `64^43 / 4` (last data char is 1-of-16, not 1-of-64).
  The naive model overstates by 4x.
- **N = 44:** impossible unless the 44th char is `=`.

The 99% quantile is `4.605 * 64^N` (`ln 100`, exponential distribution).

## 6. Known defects in the current code

**Functional (can lose a result):**
- `mminer4` builds the output path from the raw prefix:
  `snprintf(output_filename, ..., "%s.sta2", target_prefix)`. `/` is a valid
  Base64 character, so `./mminer4 "/"` attempts to write `/.sta2`. Impact is
  limited (you can't mine a long path-like prefix) but it must be sanitized.
- `mminer4` **exits 0 when `fopen` fails.** It prints the error to stderr and
  the user walks away believing their key was saved. This is the worst bug in
  the repo, because it is the only code path that delivers a result to the
  game.

**Display-only (cannot stop a search from succeeding):**
- `uint64_t` overflow: `expected_avg_hashes *= 64` wraps at `64^11 = 7.4e19` >
  `UINT64_MAX`. All 5 C binaries print `Expected Avg Hashes: 0` and garbage
  ETA for prefixes of 11+ characters. Use `double`, `__uint128_t`, or warn.
- `miner.py` undercounts hashes: workers that exit because a peer won never
  flush their pending `local_attempts`, losing up to
  `5000 * (num_processes - 1)` from the reported total.
- The `64^43` edge case above.

**Missing validation:**
- `-t` / `--threads` goes through `atoi` with no range check; 0 or negative
  reaches `omp_set_num_threads`.
- No prefix validation: an empty prefix "matches" instantly, and
  non-Base64 characters can never match so the search spins forever.

**Structural (resolved by cleanup):**
- Python and C keyspaces were **incompatible** (Python:
  `SHA-256(>I node || >I proc || >Q counter)`; C: raw little-endian
  `salt||tid||counter`). The Python miner is deleted; `gpuminer` and
  `mminer4` share the C layout, so everything left in the repo
  interoperates.
- The five C variants were an experiment ladder, not five tools
  (`miner` random → `mminer` seeded → `mminer2` file logging →
  `mminer3` deferred keygen → `mminer4` `.sta2`). Only the head,
  `mminer4.c`, is kept — as the CPU reference miner and §8 oracle.
  Its two functional §6 defects are fixed (sanitized output filename;
  write failure returns 2, never 0).
- `hash.py` (last-32-bytes extractor duplicating 5 lines now covered by
  `test_property.py`, and carrying a real account blob) is deleted.

## 7. Open questions for the rewrite

1. Should `--node-id` / `--process-index` / `--counter` be the *only* keyspace
   input, so a cluster of mixed machines can hand work to each other?
   (Today they cannot; `gpuminer` takes `-t TID` + counter ranges + salt,
   which is a step toward this but not the full unification.)

The CPU-vs-GPU question is now **decided by measurement**: GPU wins at 2x
today with headroom (see §4.1). The remaining GPU work is optimization
(occupancy, register pressure, batch sizing), not feasibility. C stays as
the host language because the kernel is OpenCL C and the host links
libsodium directly for the verify oracle — Python's role is now the
`test_property.py` acceptance gate, not mining.

## 8. Correctness test to keep

Any rewrite should ship a property test asserting, for a found key:

- `base64decode(secret_key)` is 64 bytes and equals `seed || public_key`
- `public_key == base64decode(player_id)` and is 32 bytes
- `public_key` re-derives from `seed` alone (SHA-512 + clamp + base scalarmult)
- the key signs, and the signature verifies under the reported player ID
- `player_id.startswith(prefix)`

The last one catches pubkey/seed mismatches; the third catches a broken clamp.
All 45 checks pass against the current implementation, so the existing code
can serve as a reference oracle for the rewrite.

## 9. Housekeeping

- Five compiled ELF binaries (~100 KB, unstripped, x86-64) were committed;
  they are now `git rm`'d (still in history) and `.gitignore`d.
  `Makefile` builds `gpuminer` + `mminer4`; `make check` runs the §8
  property test. The deleted miners (`miner`, `mminer`–`mminer3`,
  `miner.py`) remain recoverable from history as the §8 reference oracle
  if ever needed.
- `hash.py` (hardcoded 64-byte blob that appeared to be a real account
  identity, plus a second one commented out) is deleted. Its extraction
  logic (last 32 bytes = public key) is documented in §2 and covered by
  `test_property.py`.
- No README, LICENSE, tests (beyond `test_property.py` + `make check`), or CI.
- `hash.py` hardcodes a 64-byte blob that appears to be a real account
  identity (plus a second one commented out) on a public GitHub repo. Decide
  deliberately whether that should be there.