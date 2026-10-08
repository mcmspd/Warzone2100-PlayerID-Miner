#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sodium.h>
#include <omp.h>
#include <time.h>

// Format numbers with commas (e.g. 1000000 -> "1,000,000")
void format_number(uint64_t val, char *buf, size_t size) {
    char temp[32];
    snprintf(temp, sizeof(temp), "%llu", (unsigned long long)val);
    int len = strlen(temp);
    int commas = (len - 1) / 3;
    int out_len = len + commas;

    if (out_len >= size) {
        snprintf(buf, size, "%llu", (unsigned long long)val);
        return;
    }

    buf[out_len] = '\0';
    int j = out_len - 1, count = 0;

    for (int i = len - 1; i >= 0; i--) {
        buf[j--] = temp[i];
        if (++count == 3 && i > 0) {
            buf[j--] = ',';
            count = 0;
        }
    }
}

// Format seconds into human-readable strings
void format_time(double seconds, char *buf, size_t size) {
    if (seconds < 0) seconds = 0;
    if (seconds < 60) {
        snprintf(buf, size, "%ds", (int)seconds);
    } else if (seconds < 3600) {
        snprintf(buf, size, "%dm %ds", (int)(seconds / 60), (int)seconds % 60);
    } else if (seconds < 86400) {
        int h = (int)(seconds / 3600);
        snprintf(buf, size, "%dh %dm", h, (int)(seconds - h * 3600) / 60);
    } else {
        int d = (int)(seconds / 86400);
        snprintf(buf, size, "%dd %dh", d, (int)(seconds - d * 86400) / 3600);
    }
}

int main(int argc, char *argv[]) {
    if (sodium_init() < 0) {
        fprintf(stderr, "[-] Error: Failed to initialize libsodium\n");
        return 1;
    }

    if (argc < 2) {
        printf("Usage: %s <PREFIX> [DEVICE_ID] [-t THREADS] [--salt HEX32] [--tid-base N] [-o OFFSET] [--quiet]\n\n", argv[0]);
        printf("Examples:\n");
        printf("  %s VIP           # Auto-detects cores & uses random unique machine salt\n", argv[0]);
        printf("  %s VIP 1         # Uses explicit Device ID 1\n", argv[0]);
        printf("  %s VIP 1 -t 8    # Device ID 1 using 8 threads\n", argv[0]);
        return 1;
    }

    char *target_prefix = argv[1];
    // Default to 25% of cores: leaves package power/thermals for the iGPU
    // (which shares the die budget) and dGPU host threads. Override with -t.
    int num_threads = (omp_get_max_threads() + 3) / 4;
    if (num_threads < 1) num_threads = 1;
    uint32_t tid_base = 0;
    uint64_t start_offset = 0;
    int quiet = 0;

    // Default: generate a random 16-byte machine salt so multiple devices never overlap
    unsigned char machine_salt[16];
    randombytes_buf(machine_salt, sizeof(machine_salt));
    int explicit_device = 0;
    int explicit_salt = 0;

    // Parse optional positional DEVICE_ID and optional -t THREADS flag
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "-t") == 0 && i + 1 < argc) {
            num_threads = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--salt") == 0 && i + 1 < argc) {
            const char *hex = argv[++i];
            if (strlen(hex) != 32) {
                fprintf(stderr, "[-] Error: --salt needs 32 hex chars (16 bytes)\n");
                return 1;
            }
            for (int b = 0; b < 16; b++) {
                unsigned int v = 0;
                if (sscanf(hex + 2 * b, "%2x", &v) != 1) {
                    fprintf(stderr, "[-] Error: --salt is not valid hex\n");
                    return 1;
                }
                machine_salt[b] = (unsigned char)v;
            }
            explicit_salt = 1;
            explicit_device = 1;
        } else if (strcmp(argv[i], "--tid-base") == 0 && i + 1 < argc) {
            tid_base = (uint32_t)strtoul(argv[++i], NULL, 10);
        } else if ((strcmp(argv[i], "-o") == 0 || strcmp(argv[i], "--offset") == 0) && i + 1 < argc) {
            start_offset = strtoull(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--quiet") == 0) {
            quiet = 1;
        } else if (!explicit_device && !explicit_salt && argv[i][0] != '-') {
            uint64_t dev_id = strtoull(argv[i], NULL, 10);
            memset(machine_salt, 0, sizeof(machine_salt));
            memcpy(machine_salt, &dev_id, sizeof(dev_id));
            explicit_device = 1;
        }
    }
    if (num_threads < 1) num_threads = 1;

    int prefix_len = strlen(target_prefix);

    // Calculate statistical baselines (64^N)
    uint64_t expected_avg_hashes = 1;
    for (int i = 0; i < prefix_len; i++) expected_avg_hashes *= 64;

    char str_avg[32];
    format_number(expected_avg_hashes, str_avg, sizeof(str_avg));

    // 99% worst-case budget (ln 100 = 4.6052x mean): plan for this, not the mean.
    double budget_avg_hashes = (double)expected_avg_hashes * 4.6052;

    printf("==================================================\n");
    printf("[*] Target Prefix      : '%s'\n", target_prefix);
    printf("[*] Mode               : %s\n", explicit_device ? "Manual Device ID" : "Auto-Random Device Salt");
    printf("[*] Expected Avg Hashes: %s\n", str_avg);
    printf("[*] 99%% Budget Hashes  : %.3g (plan for this)\n", budget_avg_hashes);
    printf("[*] Worker Threads     : %d\n", num_threads);
    printf("==================================================\n\n");

    omp_set_num_threads(num_threads);

    volatile uint64_t total_hashes = 0;
    volatile int found = 0;

    char found_b64_pk[64] = {0};
    char found_b64_sk[128] = {0};

    double start_time = omp_get_wtime();

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        uint64_t local_attempts = 0;
        double last_hud_time = omp_get_wtime();

        // 32-byte seed layout:
        // Bytes 0..15  : Machine Salt / Device Identifier
        // Bytes 16..19 : Thread ID
        // Bytes 20..27 : Per-Thread Counter
        // Bytes 28..31 : Padding (Zero)
        unsigned char seed[crypto_sign_SEEDBYTES] = {0};
        memcpy(seed, machine_salt, 16);

        uint32_t thread_id = tid_base + (uint32_t)tid;
        memcpy(seed + 16, &thread_id, sizeof(thread_id));

        // Resume: per-tid checkpoint file wins over --offset.
        uint64_t counter = start_offset;
        char ckpt_path[128];
        snprintf(ckpt_path, sizeof(ckpt_path), ".cpu_checkpoint_t%u.txt", thread_id);
        FILE *ckf = fopen(ckpt_path, "r");
        if (ckf) {
            unsigned long long saved = 0;
            if (fscanf(ckf, "%llu", &saved) == 1) counter = (uint64_t)saved;
            fclose(ckf);
        }
        uint64_t since_ckpt = 0;

        unsigned char pk[crypto_sign_PUBLICKEYBYTES];
        unsigned char az[64]; // Temporary buffer for SHA-512 output

        char b64_pk[sodium_base64_ENCODED_LEN(crypto_sign_PUBLICKEYBYTES, sodium_base64_VARIANT_ORIGINAL)];

        while (!found) {
            // Update counter in seed buffer
            memcpy(seed + 20, &counter, sizeof(counter));
            counter++;

            // --- DEFERRED OPTIMIZATION START ---
            // Compute Public Key directly without building the full secret key structure
            crypto_hash_sha512(az, seed, crypto_sign_SEEDBYTES);
            az[0] &= 248;
            az[31] &= 127;
            az[31] |= 64;

            crypto_scalarmult_ed25519_base_noclamp(pk, az);
            // --- DEFERRED OPTIMIZATION END ---

            sodium_bin2base64(b64_pk, sizeof(b64_pk), pk, sizeof(pk), sodium_base64_VARIANT_ORIGINAL);
            local_attempts++;

            // Update global hash count & render HUD
            if (local_attempts >= 5000) {
                #pragma omp atomic
                total_hashes += local_attempts;
                local_attempts = 0;

                since_ckpt += 5000;
                if (since_ckpt >= 250000) {
                    since_ckpt = 0;
                    FILE *wf = fopen(ckpt_path, "w");
                    if (wf) { fprintf(wf, "%llu\n", (unsigned long long)counter); fclose(wf); }
                }

                if (tid == 0 && !quiet) {
                    double now = omp_get_wtime();
                    if (now - last_hud_time >= 0.3) {
                        double elapsed = now - start_time;
                        uint64_t current_mined = total_hashes;
                        double speed = (elapsed > 0) ? ((double)current_mined / elapsed) : 0;
                        double pct = ((double)current_mined / budget_avg_hashes) * 100.0;

                        char eta_buf[32], str_mined[32], str_speed[32];
                        if (speed > 0) {
                            double remaining = ((double)current_mined < budget_avg_hashes) ? (budget_avg_hashes - (double)current_mined) : 0;
                            format_time(remaining / speed, eta_buf, sizeof(eta_buf));
                        } else {
                            strcpy(eta_buf, "Calculating...");
                        }

                        format_number(current_mined, str_mined, sizeof(str_mined));
                        format_number((uint64_t)speed, str_speed, sizeof(str_speed));

                        printf("\r[*] Hashes: %s (%.1f%% of 99%%) | Speed: %s H/s | ETA (99%%): %s   ",
                               str_mined, pct, str_speed, eta_buf);
                        fflush(stdout);
                        last_hud_time = now;
                    }
                }
            }

            // Match verification
            if (strncmp(b64_pk, target_prefix, prefix_len) == 0) {
                #pragma omp atomic write
                found = 1;

                #pragma omp atomic
                total_hashes += local_attempts;

                // --- DEFERRED GENERATION OF PRIVATE KEY ---
                // Only build the full keypair and secret key string ONCE a match is found
                unsigned char full_pk[crypto_sign_PUBLICKEYBYTES];
                unsigned char sk[crypto_sign_SECRETKEYBYTES];
                char b64_sk[sodium_base64_ENCODED_LEN(crypto_sign_SECRETKEYBYTES, sodium_base64_VARIANT_ORIGINAL)];

                crypto_sign_seed_keypair(full_pk, sk, seed);
                sodium_bin2base64(b64_sk, sizeof(b64_sk), sk, sizeof(sk), sodium_base64_VARIANT_ORIGINAL);

                #pragma omp critical
                {
                    strncpy(found_b64_pk, b64_pk, sizeof(found_b64_pk));
                    strncpy(found_b64_sk, b64_sk, sizeof(found_b64_sk));
                }
                break;
            }
        }
    }

    double elapsed = omp_get_wtime() - start_time;
    uint64_t final_hashes = total_hashes;
    double avg_speed = (elapsed > 0) ? ((double)final_hashes / elapsed) : 0;

    char str_final_hashes[32], str_avg_speed[32], str_elapsed[32];
    format_number(final_hashes, str_final_hashes, sizeof(str_final_hashes));
    format_number((uint64_t)avg_speed, str_avg_speed, sizeof(str_avg_speed));
    format_time(elapsed, str_elapsed, sizeof(str_elapsed));

    printf("\n\n[+] MATCH FOUND in %s (%.2fs)!\n", str_elapsed, elapsed);
    printf("--------------------------------------------------\n");
    printf("Total Hashes Mined : %s\n", str_final_hashes);
    printf("Average Speed      : %s H/s\n", str_avg_speed);
    printf("Secret Key (88 ch) : %s\n", found_b64_sk);
    printf("Player ID  (44 ch) : %s\n", found_b64_pk);
    printf("--------------------------------------------------\n");

    // --- WRITE STA2 FORMAT OUTPUT TO FILE ---
    // Sanitize: '/' is a valid Base64 char but a path separator on disk.
    char output_filename[256];
    {
        char safe[200];
        size_t si = 0;
        for (size_t i = 0; target_prefix[i] && si < sizeof(safe) - 1; i++) {
            char ch = target_prefix[i];
            if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
                (ch >= '0' && ch <= '9') || ch == '+' || ch == '=') safe[si++] = ch;
            else safe[si++] = '_';
        }
        safe[si] = 0;
        snprintf(output_filename, sizeof(output_filename), "%s.sta2", safe);
    }

    // Atomic publish: concurrent workers (see run.sh) must never interleave.
    char tmp_filename[300];
    snprintf(tmp_filename, sizeof(tmp_filename), "%s.tmp.%u", output_filename, (unsigned)time(NULL) % 1000000u);
    FILE *fp = fopen(tmp_filename, "w");

    if (fp == NULL) {
        fprintf(stderr, "[-] Error: Could not create or open file %s\n", tmp_filename);
        return 2; // never report success when the key was not saved
    }
    fprintf(fp, "WZ.STA.v3\n");
    fprintf(fp, "10 10 454 902788 10\n");
    fprintf(fp, "%s\n", found_b64_sk);

    if (fclose(fp) != 0) {
        fprintf(stderr, "[-] Error: Failed writing file %s\n", tmp_filename);
        remove(tmp_filename);
        return 2;
    }
    if (rename(tmp_filename, output_filename) != 0) {
        fprintf(stderr, "[-] Error: Failed publishing file %s\n", output_filename);
        remove(tmp_filename);
        return 2;
    }
    printf("[+] Results successfully saved to '%s'\n", output_filename);

    return 0;
}
