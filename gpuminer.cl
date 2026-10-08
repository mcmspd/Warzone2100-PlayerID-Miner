// GPU vanity miner kernel: seed -> pubkey -> prefix match.
// Seed layout (mminer-compatible): salt[16] + tid[4 LE] + counter[8 LE] + pad[4].
// Prefix match via direct byte compare (no base64 on GPU).
#define ROR64(x, n) (((x) >> (n)) | ((x) << (64 - (n))))
#define S0(x) (ROR64(x, 28) ^ ROR64(x, 34) ^ ROR64(x, 39))
#define S1(x) (ROR64(x, 14) ^ ROR64(x, 18) ^ ROR64(x, 41))
#define s0(x) (ROR64(x, 1) ^ ROR64(x, 8) ^ ((x) >> 7))
#define s1(x) (ROR64(x, 19) ^ ROR64(x, 61) ^ ((x) >> 6))
#define Ch(x, y, z) (((x) & ((y) ^ (z))) ^ (z))
#define Maj(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))

__kernel void mine(
    __global const uchar *salt,          // 16 bytes
    ulong counter_base,                  // starting counter for gid 0
    uint tid,                            // thread id for seed bytes 16..19
    __global const uchar *target,        // target prefix bytes (full_bytes + 1 if rem)
    uint full_bytes,                     // number of exact-match bytes
    uchar mask,                          // mask for partial byte (0 if rem==0)
    uchar target_top,                    // expected top bits of partial byte
    __global volatile uint *found_flag,  // 0 = not found, 1 = found
    __global ulong *found_counter,       // counter of match
    __global uchar *found_pubkey,        // 32-byte pubkey of match
    uint count)                          // work-items in this batch
{
    uint gid = get_global_id(0);
    if (gid >= count) return;
    if (*found_flag) return;  // early exit if another item won

    ulong counter = counter_base + (ulong)gid;

    // Build seed bytes
    uchar seed[32];
    for (int k = 0; k < 16; k++) seed[k] = salt[k];
    seed[16] = (uchar)(tid >> 0);  seed[17] = (uchar)(tid >> 8);
    seed[18] = (uchar)(tid >> 16); seed[19] = (uchar)(tid >> 24);
    seed[20] = (uchar)(counter >> 0);  seed[21] = (uchar)(counter >> 8);
    seed[22] = (uchar)(counter >> 16); seed[23] = (uchar)(counter >> 24);
    seed[24] = (uchar)(counter >> 32); seed[25] = (uchar)(counter >> 40);
    seed[26] = (uchar)(counter >> 48); seed[27] = (uchar)(counter >> 56);
    seed[28] = 0; seed[29] = 0; seed[30] = 0; seed[31] = 0;

    // SHA-512(seed): single 1024-bit block. 16-word sliding window
    // instead of w[80] (640B of registers per work-item) for occupancy.
    ulong w[16];
    #define LDWORD(k) (((ulong)seed[(k)*8+0] << 56) | ((ulong)seed[(k)*8+1] << 48) | \
                        ((ulong)seed[(k)*8+2] << 40) | ((ulong)seed[(k)*8+3] << 32) | \
                        ((ulong)seed[(k)*8+4] << 24) | ((ulong)seed[(k)*8+5] << 16) | \
                        ((ulong)seed[(k)*8+6] <<  8) | ((ulong)seed[(k)*8+7]))
    w[0] = LDWORD(0); w[1] = LDWORD(1); w[2] = LDWORD(2); w[3] = LDWORD(3);
    #undef LDWORD
    w[4] = 0x8000000000000000UL;
    for (int t = 5; t < 14; t++) w[t] = 0;
    w[14] = 0; w[15] = 256;
    ulong a = SHA512_H0[0], b = SHA512_H0[1], c = SHA512_H0[2], dd = SHA512_H0[3];
    ulong e = SHA512_H0[4], f = SHA512_H0[5], g = SHA512_H0[6], hh = SHA512_H0[7];
    for (int t = 0; t < 80; t++) {
        if (t >= 16)
            w[t & 15] = s1(w[(t-2) & 15]) + w[(t-7) & 15] + s0(w[(t-15) & 15]) + w[(t-16) & 15];
        ulong t1 = hh + S1(e) + Ch(e, f, g) + SHA512_K[t] + w[t & 15];
        ulong t2 = S0(a) + Maj(a, b, c);
        hh = g; g = f; f = e; e = dd + t1;
        dd = c; c = b; b = a; a = t1 + t2;
    }
    ulong h0 = a + SHA512_H0[0], h1 = b + SHA512_H0[1];
    ulong h2 = c + SHA512_H0[2], h3 = dd + SHA512_H0[3];

    uchar scalar[32];
    scalar[0]=(uchar)(h0>>56); scalar[1]=(uchar)(h0>>48);
    scalar[2]=(uchar)(h0>>40); scalar[3]=(uchar)(h0>>32);
    scalar[4]=(uchar)(h0>>24); scalar[5]=(uchar)(h0>>16);
    scalar[6]=(uchar)(h0>>8);  scalar[7]=(uchar)(h0>>0);
    scalar[8]=(uchar)(h1>>56); scalar[9]=(uchar)(h1>>48);
    scalar[10]=(uchar)(h1>>40); scalar[11]=(uchar)(h1>>32);
    scalar[12]=(uchar)(h1>>24); scalar[13]=(uchar)(h1>>16);
    scalar[14]=(uchar)(h1>>8);  scalar[15]=(uchar)(h1>>0);
    scalar[16]=(uchar)(h2>>56); scalar[17]=(uchar)(h2>>48);
    scalar[18]=(uchar)(h2>>40); scalar[19]=(uchar)(h2>>32);
    scalar[20]=(uchar)(h2>>24); scalar[21]=(uchar)(h2>>16);
    scalar[22]=(uchar)(h2>>8);  scalar[23]=(uchar)(h2>>0);
    scalar[24]=(uchar)(h3>>56); scalar[25]=(uchar)(h3>>48);
    scalar[26]=(uchar)(h3>>40); scalar[27]=(uchar)(h3>>32);
    scalar[28]=(uchar)(h3>>24); scalar[29]=(uchar)(h3>>16);
    scalar[30]=(uchar)(h3>>8);  scalar[31]=(uchar)(h3>>0);
    scalar[0] &= 248; scalar[31] &= 127; scalar[31] |= 64;

    ge25519_p3 P;
    ge_scalarmult_base(&P, scalar);
    uchar pk[32];
    ge25519_p3_tobytes(pk, &P);

    // Prefix check
    bool match = true;
    for (uint k = 0; k < full_bytes; k++) {
        if (pk[k] != target[k]) { match = false; break; }
    }
    if (match && mask != 0) {
        if ((pk[full_bytes] & mask) != target_top) match = false;
    }

    if (match) {
        // Claim once
        if (atomic_cmpxchg(found_flag, 0, 1) == 0) {
            *found_counter = counter;
            for (int k = 0; k < 32; k++) found_pubkey[k] = pk[k];
        }
    }
}
