#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <math.h>
#include <sodium.h>
#include <omp.h>

// Helper to format large numbers with commas (e.g. 1000000 -> "1,000,000")
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
    int j = out_len - 1;
    int count = 0;

    for (int i = len - 1; i >= 0; i--) {
        buf[j--] = temp[i];
        count++;
        if (count == 3 && i > 0) {
            buf[j--] = ',';
            count = 0;
        }
    }
}

// Helper to format time into human-readable strings
void format_time(double seconds, char *buf, size_t size) {
    if (seconds < 0) seconds = 0;

    if (seconds < 60) {
        snprintf(buf, size, "%ds", (int)seconds);
    } else if (seconds < 3600) {
        snprintf(buf, size, "%dm %ds", (int)(seconds / 60), (int)seconds % 60);
    } else if (seconds < 86400) {
        int h = (int)(seconds / 3600);
        int m = (int)((seconds - h * 3600) / 60);
        snprintf(buf, size, "%dh %dm", h, m);
    } else {
        int d = (int)(seconds / 86400);
        int h = (int)((seconds - d * 86400) / 3600);
        snprintf(buf, size, "%dd %dh", d, h);
    }
}

int main(int argc, char *argv[]) {
    if (sodium_init() < 0) {
        fprintf(stderr, "[-] Error: Failed to initialize libsodium\n");
        return 1;
    }

    // Default configuration
    char *target_prefix = NULL;
    int num_threads = omp_get_max_threads();

    // Parse CLI arguments: ./miner <prefix> [-t threads]
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-t") == 0 || strcmp(argv[i], "--threads") == 0) {
            if (i + 1 < argc) {
                num_threads = atoi(argv[++i]);
            }
        } else if (argv[i][0] != '-') {
            target_prefix = argv[i];
        }
    }

    if (!target_prefix) {
        printf("Usage: %s <PREFIX> [-t THREADS]\n", argv[0]);
        printf("Example: %s VIP -t 8\n", argv[0]);
        return 1;
    }

    int prefix_len = strlen(target_prefix);

    // Calculate statistical baselines (64^N)
    uint64_t expected_avg_hashes = 1;
    for (int i = 0; i < prefix_len; i++) {
        expected_avg_hashes *= 64;
    }
    uint64_t expected_99_hashes = (uint64_t)(4.605 * (double)expected_avg_hashes);

    char str_avg[32], str_99[32];
    format_number(expected_avg_hashes, str_avg, sizeof(str_avg));
    format_number(expected_99_hashes, str_99, sizeof(str_99));

    printf("==================================================\n");
    printf("[*] Target Prefix      : '%s' (%d characters)\n", target_prefix, prefix_len);
    printf("[*] Expected Avg Hashes: %s\n", str_avg);
    printf("[*] Practical Max (99%%): %s\n", str_99);
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

        // Thread-local cryptographic key buffers
        unsigned char pk[crypto_sign_PUBLICKEYBYTES];
        unsigned char sk[crypto_sign_SECRETKEYBYTES];

        char b64_pk[sodium_base64_ENCODED_LEN(crypto_sign_PUBLICKEYBYTES, sodium_base64_VARIANT_ORIGINAL)];
        char b64_sk[sodium_base64_ENCODED_LEN(crypto_sign_SECRETKEYBYTES, sodium_base64_VARIANT_ORIGINAL)];

        while (!found) {
            // 1. Key generation & public key encoding
            crypto_sign_keypair(pk, sk);
            sodium_bin2base64(b64_pk, sizeof(b64_pk), pk, sizeof(pk), sodium_base64_VARIANT_ORIGINAL);
            local_attempts++;

            // Periodic batch update to shared counter
            if (local_attempts >= 5000) {
                #pragma omp atomic
                total_hashes += local_attempts;
                local_attempts = 0;

                // Live HUD rendering driven by Thread 0
                if (tid == 0) {
                    double now = omp_get_wtime();
                    if (now - last_hud_time >= 0.3) {
                        double elapsed = now - start_time;
                        uint64_t current_mined = total_hashes;
                        double speed = (elapsed > 0) ? ((double)current_mined / elapsed) : 0;

                        double pct = ((double)current_mined / (double)expected_avg_hashes) * 100.0;

                        char eta_buf[32];
                        if (speed > 0) {
                            double remaining = (current_mined < expected_avg_hashes) ? (double)(expected_avg_hashes - current_mined) : 0;
                            format_time(remaining / speed, eta_buf, sizeof(eta_buf));
                        } else {
                            strcpy(eta_buf, "Calculating...");
                        }

                        char str_mined[32], str_speed[32];
                        format_number(current_mined, str_mined, sizeof(str_mined));
                        format_number((uint64_t)speed, str_speed, sizeof(str_speed));

                        printf("\r[*] Hashes: %s (%.1f%% Avg) | Speed: %s H/s | ETA: %s   ",
                               str_mined, pct, str_speed, eta_buf);
                        fflush(stdout);
                        last_hud_time = now;
                    }
                }
            }

            // 2. Prefix verification
            if (strncmp(b64_pk, target_prefix, prefix_len) == 0) {
                #pragma omp atomic write
                found = 1;

                #pragma omp atomic
                total_hashes += local_attempts;

                // Encode secret key only when match is found
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

    return 0;
}
