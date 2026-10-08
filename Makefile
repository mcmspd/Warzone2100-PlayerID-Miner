# GPU vanity miner (OpenCL) — see AGENTS.md §4.1/§4.2.
CC      = gcc
CFLAGS  = -O2 -Wall -Wextra
LDLIBS  = -lOpenCL -lsodium
LDFLAGS = -pthread
# NOTE: link order matters on multi-loader systems (see AGENTS.md §4.3):
# force the distro ocl-icd (/usr/lib) ahead of vendor-bundled loaders.
LDFLAGS += -Wl,-rpath,/usr/lib

# Runtime kernel sources (loaded by gpuminer at startup, must sit next to the binary)
CL_SRCS = sha512_consts.cl fe25519.cl ge25519.cl gpuminer.cl

all: gpuminer mminer4

gpuminer: gpuminer.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LDLIBS)

# Kept CPU reference miner (OpenMP + libsodium). Serves as the §8 oracle
# and the fallback when no OpenCL GPU is present.
mminer4: mminer4.c
	$(CC) $(CFLAGS) -O2 -fopenmp -o $@ $< -lsodium

# Regenerate OpenCL sources from reference clones (developers only;
# requires /tmp/opencode/ref-libsodium — see AGENTS.md §4.2).
regen:
	python3 gen_consts.py
	python3 gen_fe.py
	python3 gen_ge.py

# Property test from AGENTS.md §8 against a freshly mined key
check: gpuminer
	./gpuminer ZZ -b 1048576
	python3 test_property.py ZZ.sta2 ZZ

# Deterministic benchmark from AGENTS.md §4.4 (fixed salt/tids/prefix)
bench: gpuminer
	./bench.sh

# Portable build: single binary + static libsodium, kernels embedded.
# Dynamic deps left: libc + libOpenCL + libdl (the GPU driver stack, which
# cannot be static — OpenCL finds drivers via dlopen by design).
# The target PC still needs a working OpenCL driver + ICD loader.
SODIUM_VERSION = 1.0.22
SODIUM_TGZ = build/libsodium-$(SODIUM_VERSION).tar.gz
SODIUM_URL = https://download.libsodium.org/libsodium/releases/libsodium-$(SODIUM_VERSION).tar.gz
SODIUM_A = build/sodium-static/lib/libsodium.a

$(SODIUM_TGZ):
	mkdir -p build
	curl -sSL -o $@ $(SODIUM_URL)

$(SODIUM_A): $(SODIUM_TGZ)
	cd build && tar xzf $(notdir $(SODIUM_TGZ))
	cd build/libsodium-$(SODIUM_VERSION) && ./configure --disable-shared --enable-static --prefix=$(CURDIR)/build/sodium-static >/dev/null && make -j$$(nproc) >/dev/null && make install >/dev/null
	touch $@

kernels_embed.c: $(CL_SRCS) gen_embed.py
	python3 gen_embed.py

dist: $(SODIUM_A) kernels_embed.c
	mkdir -p dist
	$(CC) $(CFLAGS) $(LDFLAGS) -DKERNELS_EMBEDDED -I$(CURDIR)/build/sodium-static/include -o dist/gpuminer gpuminer.c kernels_embed.c $(CURDIR)/build/sodium-static/lib/libsodium.a -lOpenCL -static-libgcc
	$(CC) $(CFLAGS) -O2 -fopenmp -static-libgcc -I$(CURDIR)/build/sodium-static/include -o dist/mminer4 mminer4.c $(CURDIR)/build/sodium-static/lib/libsodium.a
	@echo "--- dist contents ---"
	@ls -la dist/
	@echo "--- dynamic deps (must exist on target) ---"
	@ldd dist/gpuminer
	@ldd dist/mminer4

clean:
	rm -f gpuminer mminer4 *.sta2 .gpu_checkpoint_*.txt kernels_embed.c
	rm -rf dist build

.PHONY: all regen check clean
