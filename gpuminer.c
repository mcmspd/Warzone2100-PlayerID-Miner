// GPU vanity miner host (multi-device OpenCL): work distribution across all
// GPUs, prefix match on device, .sta2 output on host.
// Usage: ./gpuminer <PREFIX> [DEVICE_ID] [-t TID] [-b BATCH]
// Seed layout matches mminer.c (salt||tid||counter||pad); each GPU device
// gets its own tid, so keyspaces are disjoint with no coordination needed.
#define CL_TARGET_OPENCL_VERSION 120
#include <CL/cl.h>
#include <sodium.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <pthread.h>

static void chk(cl_int e, const char *w) {
    if (e != CL_SUCCESS) { fprintf(stderr, "OpenCL FAIL %s: %d\n", w, e); exit(1); }
}
static char *slurp(const char *p) {
#ifdef KERNELS_EMBEDDED
    extern const char *kernels_get(const char *name);
    const char *emb = kernels_get(p);
    if (emb) {
        size_t n = strlen(emb);
        char *b = malloc(n + 1);
        if (!b) { fprintf(stderr, "out of memory\n"); exit(1); }
        memcpy(b, emb, n + 1);
        return b;
    }
    // fall through to disk (lets a dist binary pick up local edits)
#endif
    FILE *f = fopen(p, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p); exit(1); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char *b = malloc(n + 1);
    if (fread(b, 1, n, f) != (size_t)n) { fprintf(stderr, "short read %s\n", p); exit(1); }
    b[n] = 0; fclose(f); return b;
}

static const char *B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void prefix_to_target(const char *prefix, unsigned char *target,
                             unsigned *full_bytes, unsigned char *mask,
                             unsigned char *top) {
    size_t L = strlen(prefix);
    if (L == 0) { fprintf(stderr, "empty prefix matches instantly; refusing\n"); exit(1); }
    if (L > 43) { fprintf(stderr, "prefix too long (max 43)\n"); exit(1); }
    int vals[44];
    for (size_t i = 0; i < L; i++) {
        const char *p = strchr(B64, prefix[i]);
        if (!p) { fprintf(stderr, "non-base64 char %c; will never match\n", prefix[i]); exit(1); }
        vals[i] = (int)(p - B64);
    }
    size_t bits;
    if (L == 43) {
        if (!strchr("048AEIMQUYcgkosw", prefix[42])) {
            fprintf(stderr, "char 42 must be one of 048AEIMQUYcgkosw\n"); exit(1);
        }
        // GPU matches on first 42 chars; host verifies char 42 + full prefix.
        L = 42;
    }
    bits = L * 6;
    unsigned cur = 0, curbits = 0;
    size_t out = 0;
    for (size_t i = 0; i < L; i++) {
        cur = (cur << 6) | (unsigned)vals[i];
        curbits += 6;
        while (curbits >= 8) {
            curbits -= 8;
            target[out++] = (unsigned char)(cur >> curbits);
            cur &= (curbits ? ((1u << curbits) - 1) : 0);
        }
    }
    *full_bytes = out;
    if (curbits) {
        *mask = (unsigned char)((0xFF << (8 - curbits)) & 0xFF);
        *top = (unsigned char)(cur << (8 - curbits));
    } else {
        *mask = 0; *top = 0;
    }
    (void)bits;
}


// On-disk program binary cache: avoids multi-second IGC/NVVM rebuilds.
// Keyed by sha256(driver version + device name + all sources).
static void cache_key(cl_device_id dev, char *const src[4], char *out, size_t n) {
    char ver[256] = {0}, name[256] = {0};
    clGetDeviceInfo(dev, CL_DRIVER_VERSION, sizeof ver, ver, NULL);
    clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof name, name, NULL);
    crypto_hash_sha256_state st;
    crypto_hash_sha256_init(&st);
    crypto_hash_sha256_update(&st, (unsigned char *)ver, strlen(ver));
    crypto_hash_sha256_update(&st, (unsigned char *)name, strlen(name));
    for (int i = 0; i < 4; i++)
        crypto_hash_sha256_update(&st, (unsigned char *)src[i], strlen(src[i]));
    unsigned char h[32];
    crypto_hash_sha256_final(&st, h);
    snprintf(out, n, ".gpuminer_cache_");
    for (int i = 0; i < 8 && strlen(out) + 3 < n; i++) {
        char b[4]; snprintf(b, sizeof b, "%02x", h[i]);
        strcat(out, b);
    }
    strcat(out, ".bin");
}

static cl_program build_cached(cl_context ctx, cl_device_id dev, const char *srcs[4],
                               const char *opts, const char *dev_name) {
    cl_int err;
    char key[64];
    char *src[4];
    for (int i = 0; i < 4; i++) src[i] = (char *)srcs[i];
    cache_key(dev, src, key, sizeof key);
    // Try binary first
    FILE *f = fopen(key, "rb");
    if (f) {
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        unsigned char *bin = malloc(n);
        if (bin && fread(bin, 1, n, f) == (size_t)n) {
            size_t len = n; cl_int st = 0;
            cl_program p = clCreateProgramWithBinary(ctx, 1, &dev, &len,
                                                     (const unsigned char **)&bin,
                                                     &st, &err);
            if (p && err == CL_SUCCESS && st == CL_SUCCESS) {
                err = clBuildProgram(p, 1, &dev, opts, NULL, NULL);
                if (err == CL_SUCCESS) {
                    cl_build_status s = 0;
                    clGetProgramBuildInfo(p, dev, CL_PROGRAM_BUILD_STATUS, sizeof s, &s, NULL);
                    if (s == CL_BUILD_SUCCESS) {
                        printf("[*] %s: kernel loaded from cache\n", dev_name);
                        free(bin); fclose(f);
                        return p;
                    }
                }
                clReleaseProgram(p);
            }
            free(bin);
        }
        fclose(f);
    }
    // Source build + save
    cl_program prog = clCreateProgramWithSource(ctx, 4, srcs, NULL, &err); chk(err, "prog");
    err = clBuildProgram(prog, 1, &dev, opts, NULL, NULL);
    if (err != CL_SUCCESS) {
        size_t len; clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, 0, NULL, &len);
        char *log = malloc(len + 1);
        clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, len, log, NULL); log[len] = 0;
        fprintf(stderr, "BUILD FAILED on %s:\n%s\n", dev_name, log);
        exit(1);
    }
    {
        size_t len = 0;
        clGetProgramInfo(prog, CL_PROGRAM_BINARY_SIZES, sizeof len, &len, NULL);
        if (len > 0) {
            unsigned char *bin = malloc(len);
            unsigned char *bins[1] = { bin };
            if (bin && clGetProgramInfo(prog, CL_PROGRAM_BINARIES, sizeof bins, bins, NULL) == CL_SUCCESS) {
                FILE *o = fopen(key, "wb");
                if (o) { fwrite(bin, 1, len, o); fclose(o); }
            }
            free(bin);
        }
    }
    return prog;
}

static void format_time(double s, char *buf, size_t n) {
    if (s < 0) s = 0;
    if (s < 60) snprintf(buf, n, "%ds", (int)s);
    else if (s < 3600) snprintf(buf, n, "%dm %ds", (int)(s/60), (int)s%60);
    else if (s < 86400) snprintf(buf, n, "%dh %dm", (int)(s/3600), (int)(s-(int)(s/3600)*3600)/60);
    else snprintf(buf, n, "%dd %dh", (int)(s/86400), (int)(s-(int)(s/86400)*86400)/3600);
}

typedef struct {
    cl_platform_id plat;
    cl_device_id dev;
    char plat_name[128];
    char dev_name[128];
    uint32_t tid;
    // shared (read-only after init except atomics)
    unsigned char salt[16];
    unsigned char target[33];
    unsigned full_bytes;
    unsigned char mask, top;
    const char *prefix;
    size_t plen;
    size_t batch;
    char *src[4];
    volatile int *found;          // host-side shared flag (atomic ops)
    pthread_mutex_t *win_lock;
    int *winner_tid;
    unsigned char *win_seed;
    unsigned char *win_pk;
    volatile unsigned long long *total;
    int quiet;
    uint64_t initial_base;        // per-thread resume point (for exact count)
    uint64_t final_base;          // counter_base at thread exit
    uint64_t win_counter;         // winner's absolute counter (winner only)
    int dev_matched;              // this device's batch contained a match
    uint64_t dev_fctr;            // its counter (even if host race lost)
} worker_arg;

static void *worker(void *arg_) {
    worker_arg *a = (worker_arg *)arg_;
    cl_int err;
    cl_context ctx = clCreateContext(NULL, 1, &a->dev, NULL, NULL, &err); chk(err, "ctx");
    cl_command_queue q = clCreateCommandQueue(ctx, a->dev, 0, &err); chk(err, "queue");
    const char *srcs[4] = { (const char *)a->src[0], (const char *)a->src[1],
                            (const char *)a->src[2], (const char *)a->src[3] };
    cl_program prog = build_cached(ctx, a->dev, srcs, "-cl-std=CL1.2", a->dev_name);
    cl_kernel k = clCreateKernel(prog, "mine", &err); chk(err, "kernel");

    cl_mem b_salt = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, 16, a->salt, &err); chk(err, "salt");
    cl_mem b_target = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, 33, a->target, &err); chk(err, "target");
    cl_mem b_flag = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof(cl_uint), NULL, &err); chk(err, "flag");
    cl_mem b_ctr = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof(cl_ulong), NULL, &err); chk(err, "ctr");
    cl_mem b_pk = clCreateBuffer(ctx, CL_MEM_READ_WRITE, 32, NULL, &err); chk(err, "pk");

    uint32_t count = (uint32_t)a->batch;
    unsigned full_bytes = a->full_bytes;
    chk(clSetKernelArg(k, 0, sizeof b_salt, &b_salt), "s0");
    chk(clSetKernelArg(k, 2, sizeof a->tid, &a->tid), "s2");
    chk(clSetKernelArg(k, 3, sizeof b_target, &b_target), "s3");
    chk(clSetKernelArg(k, 4, sizeof full_bytes, &full_bytes), "s4");
    chk(clSetKernelArg(k, 5, sizeof a->mask, &a->mask), "s5");
    chk(clSetKernelArg(k, 6, sizeof a->top, &a->top), "s6");
    chk(clSetKernelArg(k, 7, sizeof b_flag, &b_flag), "s7");
    chk(clSetKernelArg(k, 8, sizeof b_ctr, &b_ctr), "s8");
    chk(clSetKernelArg(k, 9, sizeof b_pk, &b_pk), "s9");
    chk(clSetKernelArg(k, 10, sizeof count, &count), "s10");

    uint64_t counter_base = a->initial_base;
    char ckpt[128]; snprintf(ckpt, sizeof ckpt, ".gpu_checkpoint_t%u.txt", a->tid);
    size_t global = a->batch;

    while (!__atomic_load_n(a->found, __ATOMIC_ACQUIRE)) {
        cl_uint zero = 0;
        chk(clEnqueueWriteBuffer(q, b_flag, CL_TRUE, 0, sizeof zero, &zero, 0, NULL, NULL), "wflag");
        cl_ulong cb = counter_base;
        chk(clSetKernelArg(k, 1, sizeof cb, &cb), "s1");
        chk(clEnqueueNDRangeKernel(q, k, 1, NULL, &global, NULL, 0, NULL, NULL), "launch");
        chk(clFinish(q), "finish");

        cl_uint flag = 0;
        chk(clEnqueueReadBuffer(q, b_flag, CL_TRUE, 0, sizeof flag, &flag, 0, NULL, NULL), "rflag");
        __atomic_fetch_add(a->total, (unsigned long long)a->batch, __ATOMIC_RELAXED);
        counter_base += a->batch;

        FILE *cf = fopen(ckpt, "w");
        if (cf) { fprintf(cf, "%llu\n", (unsigned long long)counter_base); fclose(cf); }

        if (flag) {
            cl_ulong fctr = 0;
            unsigned char fpk[32];
            chk(clEnqueueReadBuffer(q, b_ctr, CL_TRUE, 0, sizeof fctr, &fctr, 0, NULL, NULL), "rctr");
            chk(clEnqueueReadBuffer(q, b_pk, CL_TRUE, 0, 32, fpk, 0, NULL, NULL), "rpk");
            a->dev_matched = 1;
            a->dev_fctr = fctr;
            unsigned char seed[32];
            memcpy(seed, a->salt, 16);
            memcpy(seed + 16, &a->tid, 4);
            memcpy(seed + 20, &fctr, 8);
            memset(seed + 28, 0, 4);
            unsigned char vpk[crypto_sign_PUBLICKEYBYTES], vsk[crypto_sign_SECRETKEYBYTES];
            crypto_sign_seed_keypair(vpk, vsk, seed);
            if (memcmp(vpk, fpk, 32) != 0) {
                fprintf(stderr, "[-] GPU/CPU mismatch (tid %u counter %llu); ignoring\n",
                        a->tid, (unsigned long long)fctr);
                continue;
            }
            char b64pk[64];
            sodium_bin2base64(b64pk, sizeof b64pk, vpk, 32, sodium_base64_VARIANT_ORIGINAL);
            if (strncmp(b64pk, a->prefix, a->plen) != 0) continue; // 43rd-char fallback
            // Claim the win (first thread wins)
            int expected = 0;
            if (__atomic_compare_exchange_n(a->found, &expected, 1, 0,
                                            __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
                pthread_mutex_lock(a->win_lock);
                *a->winner_tid = (int)a->tid;
                a->win_counter = fctr;
                memcpy(a->win_seed, seed, 32);
                memcpy(a->win_pk, vpk, 32);
                pthread_mutex_unlock(a->win_lock);
            }
            break;
        }
    }

    a->final_base = counter_base;
    clReleaseKernel(k); clReleaseProgram(prog);
    clReleaseMemObject(b_salt); clReleaseMemObject(b_target);
    clReleaseMemObject(b_flag); clReleaseMemObject(b_ctr); clReleaseMemObject(b_pk);
    clReleaseCommandQueue(q); clReleaseContext(ctx);
    return NULL;
}

static int check_mode(const char *prog) {
    // Doctor mode for run.sh preflight: list OpenCL platforms/GPUs.
    (void)prog;
    cl_platform_id plats[8]; cl_uint nplat = 0;
    cl_int e = clGetPlatformIDs(8, plats, &nplat);
    if (e != CL_SUCCESS) { printf("platforms: OpenCL error %d\n", e); return 1; }
    int ngpu = 0;
    for (cl_uint pi = 0; pi < nplat; pi++) {
        char pn[128] = {0}, pv[128] = {0};
        clGetPlatformInfo(plats[pi], CL_PLATFORM_NAME, sizeof pn, pn, NULL);
        clGetPlatformInfo(plats[pi], CL_PLATFORM_VERSION, sizeof pv, pv, NULL);
        printf("platform %u: %s (%s)\n", pi, pn, pv);
        cl_device_id ds[16]; cl_uint nd = 0;
        if (clGetDeviceIDs(plats[pi], CL_DEVICE_TYPE_GPU, 16, ds, &nd) != CL_SUCCESS || nd == 0) {
            printf("  (no GPU devices)\n");
            continue;
        }
        for (cl_uint di = 0; di < nd; di++) {
            char dn[128] = {0}, dv[64] = {0};
            clGetDeviceInfo(ds[di], CL_DEVICE_NAME, sizeof dn, dn, NULL);
            clGetDeviceInfo(ds[di], CL_DEVICE_VERSION, sizeof dv, dv, NULL);
            printf("  gpu %d: %s [%s]\n", ngpu, dn, dv);
            ngpu++;
        }
    }
    printf("gpus: %d\n", ngpu);
    return ngpu > 0 ? 0 : 1;
}

int main(int argc, char *argv[]) {
    if (sodium_init() < 0) return 1;
    if (argc >= 2 && !strcmp(argv[1], "--check")) return check_mode(argv[0]);
    if (argc < 2) {
        printf("Usage: %s <PREFIX> [DEVICE_ID] [-t TID] [-b BATCH] [--salt HEX32] [--quiet]\n", argv[0]);
        printf("       %s --check   list OpenCL platforms/GPUs and exit\n", argv[0]);
        return 1;
    }
    const char *prefix = argv[1];
    size_t plen = strlen(prefix);
    unsigned char machine_salt[16];
    randombytes_buf(machine_salt, 16);
    int explicit_device = 0, explicit_salt = 0, quiet = 0;
    uint32_t base_tid = 0;
    size_t batch = 1 << 20;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "-t") && i + 1 < argc) base_tid = (uint32_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "-b") && i + 1 < argc) batch = (size_t)atoll(argv[++i]);
        else if (strcmp(argv[i], "--salt") == 0 && i + 1 < argc) {
            const char *hex = argv[++i];
            if (strlen(hex) != 32) { fprintf(stderr, "[-] --salt needs 32 hex chars\n"); return 1; }
            for (int b = 0; b < 16; b++) {
                unsigned int v = 0;
                if (sscanf(hex + 2 * b, "%2x", &v) != 1) {
                    fprintf(stderr, "[-] --salt is not valid hex\n"); return 1;
                }
                machine_salt[b] = (unsigned char)v;
            }
            explicit_salt = 1; explicit_device = 1;
        } else if (strcmp(argv[i], "--quiet") == 0) { quiet = 1; }
        else if (!explicit_device && !explicit_salt && argv[i][0] != '-') {
            uint64_t dev = strtoull(argv[i], NULL, 10);
            memset(machine_salt, 0, 16);
            memcpy(machine_salt, &dev, 8);
            explicit_device = 1;
        }
    }
    (void)explicit_salt;

    unsigned char target[33] = {0};
    unsigned full_bytes = 0; unsigned char mask = 0, top = 0;
    prefix_to_target(prefix, target, &full_bytes, &mask, &top);

    double expected = 1;
    for (size_t i = 0; i < plen && i < 42; i++) expected *= 64;
    if (plen == 43) expected /= 4;

    // Enumerate all GPUs on all platforms
    cl_platform_id plats[8]; cl_uint nplat = 0;
    chk(clGetPlatformIDs(8, plats, &nplat), "plats");
    typedef struct { cl_platform_id p; cl_device_id d; char pn[128], dn[128]; } devinfo;
    devinfo devs[16]; int ndev = 0;
    for (cl_uint pi = 0; pi < nplat && ndev < 16; pi++) {
        cl_device_id ds[16]; cl_uint nd = 0;
        if (clGetDeviceIDs(plats[pi], CL_DEVICE_TYPE_GPU, 16, ds, &nd) != CL_SUCCESS) continue;
        char pn[128] = {0};
        clGetPlatformInfo(plats[pi], CL_PLATFORM_NAME, sizeof pn, pn, NULL);
        for (cl_uint di = 0; di < nd && ndev < 16; di++) {
            devs[ndev].p = plats[pi]; devs[ndev].d = ds[di];
            snprintf(devs[ndev].pn, sizeof devs[ndev].pn, "%s", pn);
            clGetDeviceInfo(ds[di], CL_DEVICE_NAME, sizeof devs[ndev].dn, devs[ndev].dn, NULL);
            ndev++;
        }
    }
    if (ndev == 0) { fprintf(stderr, "no GPU devices found\n"); return 1; }

    if (!quiet) {
    printf("==================================================\n");
    printf("[*] Target Prefix      : '%s' (%zu chars)\n", prefix, plen);
    printf("[*] Mode               : %s (OpenCL, %d GPU%s)\n",
           explicit_device ? "Manual Device ID" : "Auto-Random Device Salt",
           ndev, ndev > 1 ? "s" : "");
    for (int i = 0; i < ndev; i++)
        printf("[*] GPU %d                : %s [%s] (tid %u)\n",
               i, devs[i].dn, devs[i].pn, base_tid + i);
    printf("[*] GPU match bytes    : %u full + %s\n", full_bytes, mask ? "partial" : "none");
    printf("[*] Expected Avg Hashes: %.3g\n", expected);
    printf("[*] Batch size         : %zu per GPU\n", batch);
    printf("==================================================\n\n");
    }

    char *src[4] = { slurp("sha512_consts.cl"), slurp("fe25519.cl"),
                     slurp("ge25519.cl"), slurp("gpuminer.cl") };

    volatile int found = 0;
    volatile unsigned long long total = 0;
    pthread_mutex_t win_lock = PTHREAD_MUTEX_INITIALIZER;
    int winner_tid = -1;
    unsigned char win_seed[32] = {0}, win_pk[32] = {0};

    pthread_t *threads = malloc(sizeof(pthread_t) * ndev);
    worker_arg *args = calloc(ndev, sizeof(worker_arg)); // zeroed: dev_matched/dev_fctr/final_base
    if (!args) { fprintf(stderr, "out of memory\n"); return 1; }
    for (int i = 0; i < ndev; i++) {
        args[i].plat = devs[i].p; args[i].dev = devs[i].d;
        snprintf(args[i].plat_name, sizeof args[i].plat_name, "%s", devs[i].pn);
        snprintf(args[i].dev_name, sizeof args[i].dev_name, "%s", devs[i].dn);
        args[i].tid = base_tid + i;
        memcpy(args[i].salt, machine_salt, 16);
        memcpy(args[i].target, target, 33);
        args[i].full_bytes = full_bytes; args[i].mask = mask; args[i].top = top;
        args[i].prefix = prefix; args[i].plen = plen; args[i].batch = batch;
        args[i].quiet = quiet;
        for (int s = 0; s < 4; s++) args[i].src[s] = src[s];
        args[i].found = &found; args[i].win_lock = &win_lock;
        args[i].winner_tid = &winner_tid;
        args[i].win_seed = win_seed; args[i].win_pk = win_pk;
        args[i].total = &total;
        // per-tid resume
        uint64_t base = 0;
        char ckpt[128]; snprintf(ckpt, sizeof ckpt, ".gpu_checkpoint_t%u.txt", args[i].tid);
        FILE *cf = fopen(ckpt, "r");
        if (cf) {
            if (fscanf(cf, "%llu", (unsigned long long *)&base) == 1)
                if (!quiet) printf("[*] GPU %d resumed from counter %llu\n", i, (unsigned long long)base);
            fclose(cf);
        }
        args[i].initial_base = base;
        chk(pthread_create(&threads[i], NULL, worker, &args[i]), "thread");
    }

    struct timespec ts_start, ts_now;
    clock_gettime(CLOCK_MONOTONIC, &ts_start);
    while (!__atomic_load_n(&found, __ATOMIC_ACQUIRE)) {
        struct timespec rq = { 0, 300000000 };
        nanosleep(&rq, NULL);
        if (__atomic_load_n(&found, __ATOMIC_ACQUIRE)) break;
        clock_gettime(CLOCK_MONOTONIC, &ts_now);
        double elapsed = (ts_now.tv_sec - ts_start.tv_sec)
                       + (ts_now.tv_nsec - ts_start.tv_nsec) / 1e9;
        unsigned long long mined = __atomic_load_n(&total, __ATOMIC_RELAXED);
        double speed = elapsed > 0 ? (double)mined / elapsed : 0;
        double pct = expected > 0 ? ((double)mined / expected * 100.0) : 0;
        char eta[32];
        if (speed > 0 && expected > (double)mined) format_time((expected - mined) / speed, eta, sizeof eta);
        else strcpy(eta, (double)mined >= expected ? "0s" : "calc");
        if (!quiet) {
            printf("\r[*] Hashes: %llu (%.1f%% Avg) | Speed: %.0f H/s | ETA: %s   ",
                   mined, pct, speed, eta);
            fflush(stdout);
        }
    }
    for (int i = 0; i < ndev; i++) pthread_join(threads[i], NULL);

    clock_gettime(CLOCK_MONOTONIC, &ts_now);
    double elapsed = (ts_now.tv_sec - ts_start.tv_sec)
                   + (ts_now.tv_nsec - ts_start.tv_nsec) / 1e9;
    // Exact count: per-thread checked ranges minus each matching device's
    // unexecuted batch tail (device-side early exit stops work after a match).
    // Approximate to wave granularity: items launch in gid order, so the
    // tail beyond the match counter is the part skipped. Display-only.
    unsigned long long mined = 0;
    for (int i = 0; i < ndev; i++)
        mined += args[i].final_base - args[i].initial_base;
    for (int i = 0; i < ndev; i++) {
        if (args[i].dev_matched && args[i].dev_fctr + 1 >= args[i].final_base - batch)
            mined -= args[i].final_base - (args[i].dev_fctr + 1);
    }
    printf("\n\n[+] MATCH FOUND in %.2fs! (GPU tid %d)\n", elapsed, winner_tid);
    printf("--------------------------------------------------\n");
    printf("Total Hashes Mined : %llu\n", mined);
    printf("Average Speed      : %.0f H/s\n", elapsed > 0 ? (double)mined / elapsed : 0);

    unsigned char sk[crypto_sign_SECRETKEYBYTES];
    {
        unsigned char vpk[crypto_sign_PUBLICKEYBYTES];
        crypto_sign_seed_keypair(vpk, sk, win_seed);
    }
    char b64sk[128], b64pk[64];
    sodium_bin2base64(b64sk, sizeof b64sk, sk, 64, sodium_base64_VARIANT_ORIGINAL);
    sodium_bin2base64(b64pk, sizeof b64pk, win_pk, 32, sodium_base64_VARIANT_ORIGINAL);
    printf("Secret Key (88 ch) : %s\n", b64sk);
    printf("Player ID  (44 ch) : %s\n", b64pk);
    printf("--------------------------------------------------\n");

    char outname[256];
    {
        char safe[128]; size_t si = 0;
        for (size_t i = 0; i < plen && si < sizeof(safe) - 1; i++) {
            char ch = prefix[i];
            if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
                (ch >= '0' && ch <= '9') || ch == '+' || ch == '=') safe[si++] = ch;
            else safe[si++] = '_';
        }
        safe[si] = 0;
        snprintf(outname, sizeof outname, "%s.sta2", safe);
    }
    char tmpname[300];
    snprintf(tmpname, sizeof tmpname, "%s.tmp.%u", outname, (unsigned)time(NULL) % 1000000u);
    FILE *fp = fopen(tmpname, "w");
    if (!fp) {
        fprintf(stderr, "[-] Error: Could not create %s\n", tmpname);
        return 2;
    }
    fprintf(fp, "WZ.STA.v3\n");
    fprintf(fp, "10 10 454 902788 10\n");
    fprintf(fp, "%s\n", b64sk);
    if (fclose(fp) != 0) {
        fprintf(stderr, "[-] Error: Failed writing %s\n", tmpname);
        remove(tmpname);
        return 2;
    }
    if (rename(tmpname, outname) != 0) {
        fprintf(stderr, "[-] Error: Failed publishing %s\n", outname);
        remove(tmpname);
        return 2;
    }
    printf("[+] Results successfully saved to '%s'\n", outname);
    return 0;
}
