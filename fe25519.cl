/* Generated from libsodium ref10 by gen_fe.py - do not edit by hand. */
/* Sources: ed25519_ref10_fe_25_5.h, fe_25_5/fe.h, ed25519_ref10.c */

typedef int fe25519[10];

inline ulong fe_load_3(const uchar *in) {
    ulong r = (ulong)in[0];
    r |= ((ulong)in[1]) << 8;
    r |= ((ulong)in[2]) << 16;
    return r;
}
inline ulong fe_load_4(const uchar *in) {
    ulong r = (ulong)in[0];
    r |= ((ulong)in[1]) << 8;
    r |= ((ulong)in[2]) << 16;
    r |= ((ulong)in[3]) << 24;
    return r;
}

/*
 Ignores top bit of s.
 */

void
fe25519_frombytes(fe25519 h, const uchar *s)
{
    long h0 = fe_load_4(s);
    long h1 = fe_load_3(s + 4) << 6;
    long h2 = fe_load_3(s + 7) << 5;
    long h3 = fe_load_3(s + 10) << 3;
    long h4 = fe_load_3(s + 13) << 2;
    long h5 = fe_load_4(s + 16);
    long h6 = fe_load_3(s + 20) << 7;
    long h7 = fe_load_3(s + 23) << 5;
    long h8 = fe_load_3(s + 26) << 4;
    long h9 = (fe_load_3(s + 29) & 8388607) << 2;

    long carry0;
    long carry1;
    long carry2;
    long carry3;
    long carry4;
    long carry5;
    long carry6;
    long carry7;
    long carry8;
    long carry9;

    carry9 = (h9 + (long)(1L << 24)) >> 25;
    h0 += carry9 * 19;
    h9 -= carry9 * ((ulong) 1L << 25);
    carry1 = (h1 + (long)(1L << 24)) >> 25;
    h2 += carry1;
    h1 -= carry1 * ((ulong) 1L << 25);
    carry3 = (h3 + (long)(1L << 24)) >> 25;
    h4 += carry3;
    h3 -= carry3 * ((ulong) 1L << 25);
    carry5 = (h5 + (long)(1L << 24)) >> 25;
    h6 += carry5;
    h5 -= carry5 * ((ulong) 1L << 25);
    carry7 = (h7 + (long)(1L << 24)) >> 25;
    h8 += carry7;
    h7 -= carry7 * ((ulong) 1L << 25);

    carry0 = (h0 + (long)(1L << 25)) >> 26;
    h1 += carry0;
    h0 -= carry0 * ((ulong) 1L << 26);
    carry2 = (h2 + (long)(1L << 25)) >> 26;
    h3 += carry2;
    h2 -= carry2 * ((ulong) 1L << 26);
    carry4 = (h4 + (long)(1L << 25)) >> 26;
    h5 += carry4;
    h4 -= carry4 * ((ulong) 1L << 26);
    carry6 = (h6 + (long)(1L << 25)) >> 26;
    h7 += carry6;
    h6 -= carry6 * ((ulong) 1L << 26);
    carry8 = (h8 + (long)(1L << 25)) >> 26;
    h9 += carry8;
    h8 -= carry8 * ((ulong) 1L << 26);

    h[0] = (int) h0;
    h[1] = (int) h1;
    h[2] = (int) h2;
    h[3] = (int) h3;
    h[4] = (int) h4;
    h[5] = (int) h5;
    h[6] = (int) h6;
    h[7] = (int) h7;
    h[8] = (int) h8;
    h[9] = (int) h9;
}

/*
 Preconditions:
 |h| bounded by 1.1*2^26,1.1*2^25,1.1*2^26,1.1*2^25,etc.

 Write p=2^255-19; q=floor(h/p).
 Basic claim: q = floor(2^(-255)(h + 19 2^(-25)h9 + 2^(-1))).

 Proof:
 Have |h|<=p so |q|<=1 so |19^2 2^(-255) q|<1/4.
 Also have |h-2^230 h9|<2^231 so |19 2^(-255)(h-2^230 h9)|<1/4.

 Write y=2^(-1)-19^2 2^(-255)q-19 2^(-255)(h-2^230 h9).
 Then 0<y<1.

 Write r=h-pq.
 Have 0<=r<=p-1=2^255-20.
 Thus 0<=r+19(2^-255)r<r+19(2^-255)2^255<=2^255-1.

 Write x=r+19(2^-255)r+y.
 Then 0<x<2^255 so floor(2^(-255)x) = 0 so floor(q+2^(-255)x) = q.

 Have q+2^(-255)x = 2^(-255)(h + 19 2^(-25) h9 + 2^(-1))
 so floor(2^(-255)(h + 19 2^(-25) h9 + 2^(-1))) = q.
*/

static void
fe25519_reduce(fe25519 h, const fe25519 f)
{
    int h0 = f[0];
    int h1 = f[1];
    int h2 = f[2];
    int h3 = f[3];
    int h4 = f[4];
    int h5 = f[5];
    int h6 = f[6];
    int h7 = f[7];
    int h8 = f[8];
    int h9 = f[9];

    int q;
    int carry0, carry1, carry2, carry3, carry4, carry5, carry6, carry7, carry8, carry9;

    q = (19 * h9 + ((uint) 1L << 24)) >> 25;
    q = (h0 + q) >> 26;
    q = (h1 + q) >> 25;
    q = (h2 + q) >> 26;
    q = (h3 + q) >> 25;
    q = (h4 + q) >> 26;
    q = (h5 + q) >> 25;
    q = (h6 + q) >> 26;
    q = (h7 + q) >> 25;
    q = (h8 + q) >> 26;
    q = (h9 + q) >> 25;

    /* Goal: Output h-(2^255-19)q, which is between 0 and 2^255-20. */
    h0 += 19 * q;
    /* Goal: Output h-2^255 q, which is between 0 and 2^255-20. */

    carry0 = h0 >> 26;
    h1 += carry0;
    h0 -= carry0 * ((uint) 1L << 26);
    carry1 = h1 >> 25;
    h2 += carry1;
    h1 -= carry1 * ((uint) 1L << 25);
    carry2 = h2 >> 26;
    h3 += carry2;
    h2 -= carry2 * ((uint) 1L << 26);
    carry3 = h3 >> 25;
    h4 += carry3;
    h3 -= carry3 * ((uint) 1L << 25);
    carry4 = h4 >> 26;
    h5 += carry4;
    h4 -= carry4 * ((uint) 1L << 26);
    carry5 = h5 >> 25;
    h6 += carry5;
    h5 -= carry5 * ((uint) 1L << 25);
    carry6 = h6 >> 26;
    h7 += carry6;
    h6 -= carry6 * ((uint) 1L << 26);
    carry7 = h7 >> 25;
    h8 += carry7;
    h7 -= carry7 * ((uint) 1L << 25);
    carry8 = h8 >> 26;
    h9 += carry8;
    h8 -= carry8 * ((uint) 1L << 26);
    carry9 = h9 >> 25;
    h9 -= carry9 * ((uint) 1L << 25);

    h[0] = h0;
    h[1] = h1;
    h[2] = h2;
    h[3] = h3;
    h[4] = h4;
    h[5] = h5;
    h[6] = h6;
    h[7] = h7;
    h[8] = h8;
    h[9] = h9;
}

/*
 Goal: Output h0+...+2^255 h10-2^255 q, which is between 0 and 2^255-20.
 Have h0+...+2^230 h9 between 0 and 2^255-1;
 evidently 2^255 h10-2^255 q = 0.

 Goal: Output h0+...+2^230 h9.
 */

void
fe25519_tobytes(uchar *s, const fe25519 h)
{
    fe25519 t;

    fe25519_reduce(t, h);
    s[0]  = t[0] >> 0;
    s[1]  = t[0] >> 8;
    s[2]  = t[0] >> 16;
    s[3]  = (t[0] >> 24) | (t[1] * ((uint) 1 << 2));
    s[4]  = t[1] >> 6;
    s[5]  = t[1] >> 14;
    s[6]  = (t[1] >> 22) | (t[2] * ((uint) 1 << 3));
    s[7]  = t[2] >> 5;
    s[8]  = t[2] >> 13;
    s[9]  = (t[2] >> 21) | (t[3] * ((uint) 1 << 5));
    s[10] = t[3] >> 3;
    s[11] = t[3] >> 11;
    s[12] = (t[3] >> 19) | (t[4] * ((uint) 1 << 6));
    s[13] = t[4] >> 2;
    s[14] = t[4] >> 10;
    s[15] = t[4] >> 18;
    s[16] = t[5] >> 0;
    s[17] = t[5] >> 8;
    s[18] = t[5] >> 16;
    s[19] = (t[5] >> 24) | (t[6] * ((uint) 1 << 1));
    s[20] = t[6] >> 7;
    s[21] = t[6] >> 15;
    s[22] = (t[6] >> 23) | (t[7] * ((uint) 1 << 3));
    s[23] = t[7] >> 5;
    s[24] = t[7] >> 13;
    s[25] = (t[7] >> 21) | (t[8] * ((uint) 1 << 4));
    s[26] = t[8] >> 4;
    s[27] = t[8] >> 12;
    s[28] = (t[8] >> 20) | (t[9] * ((uint) 1 << 6));
    s[29] = t[9] >> 2;
    s[30] = t[9] >> 10;
    s[31] = t[9] >> 18;
}



/*
 h = 0
 */

static inline void
fe25519_0(fe25519 h)
{
    for (int _i = 0; _i < 10; _i++) h[_i] = 0;
}

/*
 h = 1
 */

static inline void
fe25519_1(fe25519 h)
{
    h[0] = 1;
    h[1] = 0;
    for (int _i = 2; _i < 10; _i++) h[_i] = 0;
}

/*
 h = f + g
 Can overlap h with f or g.
 *
 Preconditions:
 |f| bounded by 1.1*2^25,1.1*2^24,1.1*2^25,1.1*2^24,etc.
 |g| bounded by 1.1*2^25,1.1*2^24,1.1*2^25,1.1*2^24,etc.
 *
 Postconditions:
 |h| bounded by 1.1*2^26,1.1*2^25,1.1*2^26,1.1*2^25,etc.
 */

static inline void
fe25519_add(fe25519 h, const fe25519 f, const fe25519 g)
{
    int h0 = f[0] + g[0];
    int h1 = f[1] + g[1];
    int h2 = f[2] + g[2];
    int h3 = f[3] + g[3];
    int h4 = f[4] + g[4];
    int h5 = f[5] + g[5];
    int h6 = f[6] + g[6];
    int h7 = f[7] + g[7];
    int h8 = f[8] + g[8];
    int h9 = f[9] + g[9];

    h[0] = h0;
    h[1] = h1;
    h[2] = h2;
    h[3] = h3;
    h[4] = h4;
    h[5] = h5;
    h[6] = h6;
    h[7] = h7;
    h[8] = h8;
    h[9] = h9;
}

/*
 h = f - g
 Can overlap h with f or g.
 *
 Preconditions:
 |f| bounded by 1.1*2^25,1.1*2^24,1.1*2^25,1.1*2^24,etc.
 |g| bounded by 1.1*2^25,1.1*2^24,1.1*2^25,1.1*2^24,etc.
 *
 Postconditions:
 |h| bounded by 1.1*2^26,1.1*2^25,1.1*2^26,1.1*2^25,etc.
 */

static void
fe25519_sub(fe25519 h, const fe25519 f, const fe25519 g)
{
    int h0 = f[0] - g[0];
    int h1 = f[1] - g[1];
    int h2 = f[2] - g[2];
    int h3 = f[3] - g[3];
    int h4 = f[4] - g[4];
    int h5 = f[5] - g[5];
    int h6 = f[6] - g[6];
    int h7 = f[7] - g[7];
    int h8 = f[8] - g[8];
    int h9 = f[9] - g[9];

    h[0] = h0;
    h[1] = h1;
    h[2] = h2;
    h[3] = h3;
    h[4] = h4;
    h[5] = h5;
    h[6] = h6;
    h[7] = h7;
    h[8] = h8;
    h[9] = h9;
}

/*
 h = -f
 *
 Preconditions:
 |f| bounded by 1.1*2^25,1.1*2^24,1.1*2^25,1.1*2^24,etc.
 *
 Postconditions:
 |h| bounded by 1.1*2^25,1.1*2^24,1.1*2^25,1.1*2^24,etc.
 */

static inline void
fe25519_neg(fe25519 h, const fe25519 f)
{
    int h0 = -f[0];
    int h1 = -f[1];
    int h2 = -f[2];
    int h3 = -f[3];
    int h4 = -f[4];
    int h5 = -f[5];
    int h6 = -f[6];
    int h7 = -f[7];
    int h8 = -f[8];
    int h9 = -f[9];

    h[0] = h0;
    h[1] = h1;
    h[2] = h2;
    h[3] = h3;
    h[4] = h4;
    h[5] = h5;
    h[6] = h6;
    h[7] = h7;
    h[8] = h8;
    h[9] = h9;
}

/*
 Replace (f,g) with (g,g) if b == 1;
 replace (f,g) with (f,g) if b == 0.
 *
 Preconditions: b in {0,1}.
 */

static void
fe25519_cmov(fe25519 f, const fe25519 g, unsigned int b)
{
    uint mask = (uint) (-(int) b);
    int  f0, f1, f2, f3, f4, f5, f6, f7, f8, f9;
    int  x0, x1, x2, x3, x4, x5, x6, x7, x8, x9;

    f0 = f[0];
    f1 = f[1];
    f2 = f[2];
    f3 = f[3];
    f4 = f[4];
    f5 = f[5];
    f6 = f[6];
    f7 = f[7];
    f8 = f[8];
    f9 = f[9];

    x0 = f0 ^ g[0];
    x1 = f1 ^ g[1];
    x2 = f2 ^ g[2];
    x3 = f3 ^ g[3];
    x4 = f4 ^ g[4];
    x5 = f5 ^ g[5];
    x6 = f6 ^ g[6];
    x7 = f7 ^ g[7];
    x8 = f8 ^ g[8];
    x9 = f9 ^ g[9];





    x0 &= mask;
    x1 &= mask;
    x2 &= mask;
    x3 &= mask;
    x4 &= mask;
    x5 &= mask;
    x6 &= mask;
    x7 &= mask;
    x8 &= mask;
    x9 &= mask;

    f[0] = f0 ^ x0;
    f[1] = f1 ^ x1;
    f[2] = f2 ^ x2;
    f[3] = f3 ^ x3;
    f[4] = f4 ^ x4;
    f[5] = f5 ^ x5;
    f[6] = f6 ^ x6;
    f[7] = f7 ^ x7;
    f[8] = f8 ^ x8;
    f[9] = f9 ^ x9;
}

static void
fe25519_cswap(fe25519 f, fe25519 g, unsigned int b)
{
    uint mask = (uint) (-(long) b);
    int  f0, f1, f2, f3, f4, f5, f6, f7, f8, f9;
    int  g0, g1, g2, g3, g4, g5, g6, g7, g8, g9;
    int  x0, x1, x2, x3, x4, x5, x6, x7, x8, x9;

    f0 = f[0];
    f1 = f[1];
    f2 = f[2];
    f3 = f[3];
    f4 = f[4];
    f5 = f[5];
    f6 = f[6];
    f7 = f[7];
    f8 = f[8];
    f9 = f[9];

    g0 = g[0];
    g1 = g[1];
    g2 = g[2];
    g3 = g[3];
    g4 = g[4];
    g5 = g[5];
    g6 = g[6];
    g7 = g[7];
    g8 = g[8];
    g9 = g[9];

    x0 = f0 ^ g0;
    x1 = f1 ^ g1;
    x2 = f2 ^ g2;
    x3 = f3 ^ g3;
    x4 = f4 ^ g4;
    x5 = f5 ^ g5;
    x6 = f6 ^ g6;
    x7 = f7 ^ g7;
    x8 = f8 ^ g8;
    x9 = f9 ^ g9;





    x0 &= mask;
    x1 &= mask;
    x2 &= mask;
    x3 &= mask;
    x4 &= mask;
    x5 &= mask;
    x6 &= mask;
    x7 &= mask;
    x8 &= mask;
    x9 &= mask;

    f[0] = f0 ^ x0;
    f[1] = f1 ^ x1;
    f[2] = f2 ^ x2;
    f[3] = f3 ^ x3;
    f[4] = f4 ^ x4;
    f[5] = f5 ^ x5;
    f[6] = f6 ^ x6;
    f[7] = f7 ^ x7;
    f[8] = f8 ^ x8;
    f[9] = f9 ^ x9;

    g[0] = g0 ^ x0;
    g[1] = g1 ^ x1;
    g[2] = g2 ^ x2;
    g[3] = g3 ^ x3;
    g[4] = g4 ^ x4;
    g[5] = g5 ^ x5;
    g[6] = g6 ^ x6;
    g[7] = g7 ^ x7;
    g[8] = g8 ^ x8;
    g[9] = g9 ^ x9;
}

/*
 h = f
 */

static inline void
fe25519_copy(fe25519 h, const fe25519 f)
{
    for (int _i = 0; _i < 10; _i++) h[_i] = f[_i];
}

/*
 return 1 if f is in {1,3,5,...,q-2}
 return 0 if f is in {0,2,4,...,q-1}

 Preconditions:
 |f| bounded by 1.1*2^26,1.1*2^25,1.1*2^26,1.1*2^25,etc.
 */

static inline int
fe25519_isnegative(const fe25519 f)
{
    uchar s[32];

    fe25519_tobytes(s, f);

    return s[0] & 1;
}

/*
 return 1 if f == 0
 return 0 if f != 0

 Preconditions:
 |f| bounded by 1.1*2^26,1.1*2^25,1.1*2^26,1.1*2^25,etc.
 */

static inline int
fe25519_iszero(const fe25519 f)
{
    uchar s[32];

    fe25519_tobytes(s, f);

    uchar _d = 0; for (int _i = 0; _i < 32; _i++) _d |= s[_i]; return _d == 0;
}

/*
 h = f * g
 Can overlap h with f or g.
 *
 Preconditions:
 |f| bounded by 1.65*2^26,1.65*2^25,1.65*2^26,1.65*2^25,etc.
 |g| bounded by 1.65*2^26,1.65*2^25,1.65*2^26,1.65*2^25,etc.
 *
 Postconditions:
 |h| bounded by 1.01*2^25,1.01*2^24,1.01*2^25,1.01*2^24,etc.
 */

/*
 Notes on implementation strategy:
 *
 Using schoolbook multiplication.
 Karatsuba would save a little in some cost models.
 *
 Most multiplications by 2 and 19 are 32-bit precomputations;
 cheaper than 64-bit postcomputations.
 *
 There is one remaining multiplication by 19 in the carry chain;
 one *19 precomputation can be merged into this,
 but the resulting data flow is considerably less clean.
 *
 There are 12 carries below.
 10 of them are 2-way parallelizable and vectorizable.
 Can get away with 11 carries, but then data flow is much deeper.
 *
 With tighter constraints on inputs can squeeze carries into int32.
 */

static void
fe25519_mul(fe25519 h, const fe25519 f, const fe25519 g)
{
    int f0 = f[0];
    int f1 = f[1];
    int f2 = f[2];
    int f3 = f[3];
    int f4 = f[4];
    int f5 = f[5];
    int f6 = f[6];
    int f7 = f[7];
    int f8 = f[8];
    int f9 = f[9];

    int g0 = g[0];
    int g1 = g[1];
    int g2 = g[2];
    int g3 = g[3];
    int g4 = g[4];
    int g5 = g[5];
    int g6 = g[6];
    int g7 = g[7];
    int g8 = g[8];
    int g9 = g[9];

    int g1_19 = 19 * g1; /* 1.959375*2^29 */
    int g2_19 = 19 * g2; /* 1.959375*2^30; still ok */
    int g3_19 = 19 * g3;
    int g4_19 = 19 * g4;
    int g5_19 = 19 * g5;
    int g6_19 = 19 * g6;
    int g7_19 = 19 * g7;
    int g8_19 = 19 * g8;
    int g9_19 = 19 * g9;
    int f1_2  = 2 * f1;
    int f3_2  = 2 * f3;
    int f5_2  = 2 * f5;
    int f7_2  = 2 * f7;
    int f9_2  = 2 * f9;

    long f0g0    = f0 * (long) g0;
    long f0g1    = f0 * (long) g1;
    long f0g2    = f0 * (long) g2;
    long f0g3    = f0 * (long) g3;
    long f0g4    = f0 * (long) g4;
    long f0g5    = f0 * (long) g5;
    long f0g6    = f0 * (long) g6;
    long f0g7    = f0 * (long) g7;
    long f0g8    = f0 * (long) g8;
    long f0g9    = f0 * (long) g9;
    long f1g0    = f1 * (long) g0;
    long f1g1_2  = f1_2 * (long) g1;
    long f1g2    = f1 * (long) g2;
    long f1g3_2  = f1_2 * (long) g3;
    long f1g4    = f1 * (long) g4;
    long f1g5_2  = f1_2 * (long) g5;
    long f1g6    = f1 * (long) g6;
    long f1g7_2  = f1_2 * (long) g7;
    long f1g8    = f1 * (long) g8;
    long f1g9_38 = f1_2 * (long) g9_19;
    long f2g0    = f2 * (long) g0;
    long f2g1    = f2 * (long) g1;
    long f2g2    = f2 * (long) g2;
    long f2g3    = f2 * (long) g3;
    long f2g4    = f2 * (long) g4;
    long f2g5    = f2 * (long) g5;
    long f2g6    = f2 * (long) g6;
    long f2g7    = f2 * (long) g7;
    long f2g8_19 = f2 * (long) g8_19;
    long f2g9_19 = f2 * (long) g9_19;
    long f3g0    = f3 * (long) g0;
    long f3g1_2  = f3_2 * (long) g1;
    long f3g2    = f3 * (long) g2;
    long f3g3_2  = f3_2 * (long) g3;
    long f3g4    = f3 * (long) g4;
    long f3g5_2  = f3_2 * (long) g5;
    long f3g6    = f3 * (long) g6;
    long f3g7_38 = f3_2 * (long) g7_19;
    long f3g8_19 = f3 * (long) g8_19;
    long f3g9_38 = f3_2 * (long) g9_19;
    long f4g0    = f4 * (long) g0;
    long f4g1    = f4 * (long) g1;
    long f4g2    = f4 * (long) g2;
    long f4g3    = f4 * (long) g3;
    long f4g4    = f4 * (long) g4;
    long f4g5    = f4 * (long) g5;
    long f4g6_19 = f4 * (long) g6_19;
    long f4g7_19 = f4 * (long) g7_19;
    long f4g8_19 = f4 * (long) g8_19;
    long f4g9_19 = f4 * (long) g9_19;
    long f5g0    = f5 * (long) g0;
    long f5g1_2  = f5_2 * (long) g1;
    long f5g2    = f5 * (long) g2;
    long f5g3_2  = f5_2 * (long) g3;
    long f5g4    = f5 * (long) g4;
    long f5g5_38 = f5_2 * (long) g5_19;
    long f5g6_19 = f5 * (long) g6_19;
    long f5g7_38 = f5_2 * (long) g7_19;
    long f5g8_19 = f5 * (long) g8_19;
    long f5g9_38 = f5_2 * (long) g9_19;
    long f6g0    = f6 * (long) g0;
    long f6g1    = f6 * (long) g1;
    long f6g2    = f6 * (long) g2;
    long f6g3    = f6 * (long) g3;
    long f6g4_19 = f6 * (long) g4_19;
    long f6g5_19 = f6 * (long) g5_19;
    long f6g6_19 = f6 * (long) g6_19;
    long f6g7_19 = f6 * (long) g7_19;
    long f6g8_19 = f6 * (long) g8_19;
    long f6g9_19 = f6 * (long) g9_19;
    long f7g0    = f7 * (long) g0;
    long f7g1_2  = f7_2 * (long) g1;
    long f7g2    = f7 * (long) g2;
    long f7g3_38 = f7_2 * (long) g3_19;
    long f7g4_19 = f7 * (long) g4_19;
    long f7g5_38 = f7_2 * (long) g5_19;
    long f7g6_19 = f7 * (long) g6_19;
    long f7g7_38 = f7_2 * (long) g7_19;
    long f7g8_19 = f7 * (long) g8_19;
    long f7g9_38 = f7_2 * (long) g9_19;
    long f8g0    = f8 * (long) g0;
    long f8g1    = f8 * (long) g1;
    long f8g2_19 = f8 * (long) g2_19;
    long f8g3_19 = f8 * (long) g3_19;
    long f8g4_19 = f8 * (long) g4_19;
    long f8g5_19 = f8 * (long) g5_19;
    long f8g6_19 = f8 * (long) g6_19;
    long f8g7_19 = f8 * (long) g7_19;
    long f8g8_19 = f8 * (long) g8_19;
    long f8g9_19 = f8 * (long) g9_19;
    long f9g0    = f9 * (long) g0;
    long f9g1_38 = f9_2 * (long) g1_19;
    long f9g2_19 = f9 * (long) g2_19;
    long f9g3_38 = f9_2 * (long) g3_19;
    long f9g4_19 = f9 * (long) g4_19;
    long f9g5_38 = f9_2 * (long) g5_19;
    long f9g6_19 = f9 * (long) g6_19;
    long f9g7_38 = f9_2 * (long) g7_19;
    long f9g8_19 = f9 * (long) g8_19;
    long f9g9_38 = f9_2 * (long) g9_19;

    long h0 = f0g0 + f1g9_38 + f2g8_19 + f3g7_38 + f4g6_19 + f5g5_38 +
                 f6g4_19 + f7g3_38 + f8g2_19 + f9g1_38;
    long h1 = f0g1 + f1g0 + f2g9_19 + f3g8_19 + f4g7_19 + f5g6_19 + f6g5_19 +
                 f7g4_19 + f8g3_19 + f9g2_19;
    long h2 = f0g2 + f1g1_2 + f2g0 + f3g9_38 + f4g8_19 + f5g7_38 + f6g6_19 +
                 f7g5_38 + f8g4_19 + f9g3_38;
    long h3 = f0g3 + f1g2 + f2g1 + f3g0 + f4g9_19 + f5g8_19 + f6g7_19 +
                 f7g6_19 + f8g5_19 + f9g4_19;
    long h4 = f0g4 + f1g3_2 + f2g2 + f3g1_2 + f4g0 + f5g9_38 + f6g8_19 +
                 f7g7_38 + f8g6_19 + f9g5_38;
    long h5 = f0g5 + f1g4 + f2g3 + f3g2 + f4g1 + f5g0 + f6g9_19 + f7g8_19 +
                 f8g7_19 + f9g6_19;
    long h6 = f0g6 + f1g5_2 + f2g4 + f3g3_2 + f4g2 + f5g1_2 + f6g0 +
                 f7g9_38 + f8g8_19 + f9g7_38;
    long h7 = f0g7 + f1g6 + f2g5 + f3g4 + f4g3 + f5g2 + f6g1 + f7g0 +
                 f8g9_19 + f9g8_19;
    long h8 = f0g8 + f1g7_2 + f2g6 + f3g5_2 + f4g4 + f5g3_2 + f6g2 + f7g1_2 +
                 f8g0 + f9g9_38;
    long h9 =
        f0g9 + f1g8 + f2g7 + f3g6 + f4g5 + f5g4 + f6g3 + f7g2 + f8g1 + f9g0;

    long carry0;
    long carry1;
    long carry2;
    long carry3;
    long carry4;
    long carry5;
    long carry6;
    long carry7;
    long carry8;
    long carry9;

    /*
     |h0| <= (1.65*1.65*2^52*(1+19+19+19+19)+1.65*1.65*2^50*(38+38+38+38+38))
     i.e. |h0| <= 1.4*2^60; narrower ranges for h2, h4, h6, h8
     |h1| <= (1.65*1.65*2^51*(1+1+19+19+19+19+19+19+19+19))
     i.e. |h1| <= 1.7*2^59; narrower ranges for h3, h5, h7, h9
     */

    carry0 = (h0 + (long)(1L << 25)) >> 26;
    h1 += carry0;
    h0 -= carry0 * ((ulong) 1L << 26);
    carry4 = (h4 + (long)(1L << 25)) >> 26;
    h5 += carry4;
    h4 -= carry4 * ((ulong) 1L << 26);
    /* |h0| <= 2^25 */
    /* |h4| <= 2^25 */
    /* |h1| <= 1.71*2^59 */
    /* |h5| <= 1.71*2^59 */

    carry1 = (h1 + (long)(1L << 24)) >> 25;
    h2 += carry1;
    h1 -= carry1 * ((ulong) 1L << 25);
    carry5 = (h5 + (long)(1L << 24)) >> 25;
    h6 += carry5;
    h5 -= carry5 * ((ulong) 1L << 25);
    /* |h1| <= 2^24; from now on fits into int32 */
    /* |h5| <= 2^24; from now on fits into int32 */
    /* |h2| <= 1.41*2^60 */
    /* |h6| <= 1.41*2^60 */

    carry2 = (h2 + (long)(1L << 25)) >> 26;
    h3 += carry2;
    h2 -= carry2 * ((ulong) 1L << 26);
    carry6 = (h6 + (long)(1L << 25)) >> 26;
    h7 += carry6;
    h6 -= carry6 * ((ulong) 1L << 26);
    /* |h2| <= 2^25; from now on fits into int32 unchanged */
    /* |h6| <= 2^25; from now on fits into int32 unchanged */
    /* |h3| <= 1.71*2^59 */
    /* |h7| <= 1.71*2^59 */

    carry3 = (h3 + (long)(1L << 24)) >> 25;
    h4 += carry3;
    h3 -= carry3 * ((ulong) 1L << 25);
    carry7 = (h7 + (long)(1L << 24)) >> 25;
    h8 += carry7;
    h7 -= carry7 * ((ulong) 1L << 25);
    /* |h3| <= 2^24; from now on fits into int32 unchanged */
    /* |h7| <= 2^24; from now on fits into int32 unchanged */
    /* |h4| <= 1.72*2^34 */
    /* |h8| <= 1.41*2^60 */

    carry4 = (h4 + (long)(1L << 25)) >> 26;
    h5 += carry4;
    h4 -= carry4 * ((ulong) 1L << 26);
    carry8 = (h8 + (long)(1L << 25)) >> 26;
    h9 += carry8;
    h8 -= carry8 * ((ulong) 1L << 26);
    /* |h4| <= 2^25; from now on fits into int32 unchanged */
    /* |h8| <= 2^25; from now on fits into int32 unchanged */
    /* |h5| <= 1.01*2^24 */
    /* |h9| <= 1.71*2^59 */

    carry9 = (h9 + (long)(1L << 24)) >> 25;
    h0 += carry9 * 19;
    h9 -= carry9 * ((ulong) 1L << 25);
    /* |h9| <= 2^24; from now on fits into int32 unchanged */
    /* |h0| <= 1.1*2^39 */

    carry0 = (h0 + (long)(1L << 25)) >> 26;
    h1 += carry0;
    h0 -= carry0 * ((ulong) 1L << 26);
    /* |h0| <= 2^25; from now on fits into int32 unchanged */
    /* |h1| <= 1.01*2^24 */

    h[0] = (int) h0;
    h[1] = (int) h1;
    h[2] = (int) h2;
    h[3] = (int) h3;
    h[4] = (int) h4;
    h[5] = (int) h5;
    h[6] = (int) h6;
    h[7] = (int) h7;
    h[8] = (int) h8;
    h[9] = (int) h9;
}

/*
 h = f * f
 Can overlap h with f.
 *
 Preconditions:
 |f| bounded by 1.65*2^26,1.65*2^25,1.65*2^26,1.65*2^25,etc.
 *
 Postconditions:
 |h| bounded by 1.01*2^25,1.01*2^24,1.01*2^25,1.01*2^24,etc.
 */

static void
fe25519_sq(fe25519 h, const fe25519 f)
{
    int f0 = f[0];
    int f1 = f[1];
    int f2 = f[2];
    int f3 = f[3];
    int f4 = f[4];
    int f5 = f[5];
    int f6 = f[6];
    int f7 = f[7];
    int f8 = f[8];
    int f9 = f[9];

    int f0_2  = 2 * f0;
    int f1_2  = 2 * f1;
    int f2_2  = 2 * f2;
    int f3_2  = 2 * f3;
    int f4_2  = 2 * f4;
    int f5_2  = 2 * f5;
    int f6_2  = 2 * f6;
    int f7_2  = 2 * f7;
    int f5_38 = 38 * f5; /* 1.959375*2^30 */
    int f6_19 = 19 * f6; /* 1.959375*2^30 */
    int f7_38 = 38 * f7; /* 1.959375*2^30 */
    int f8_19 = 19 * f8; /* 1.959375*2^30 */
    int f9_38 = 38 * f9; /* 1.959375*2^30 */

    long f0f0    = f0 * (long) f0;
    long f0f1_2  = f0_2 * (long) f1;
    long f0f2_2  = f0_2 * (long) f2;
    long f0f3_2  = f0_2 * (long) f3;
    long f0f4_2  = f0_2 * (long) f4;
    long f0f5_2  = f0_2 * (long) f5;
    long f0f6_2  = f0_2 * (long) f6;
    long f0f7_2  = f0_2 * (long) f7;
    long f0f8_2  = f0_2 * (long) f8;
    long f0f9_2  = f0_2 * (long) f9;
    long f1f1_2  = f1_2 * (long) f1;
    long f1f2_2  = f1_2 * (long) f2;
    long f1f3_4  = f1_2 * (long) f3_2;
    long f1f4_2  = f1_2 * (long) f4;
    long f1f5_4  = f1_2 * (long) f5_2;
    long f1f6_2  = f1_2 * (long) f6;
    long f1f7_4  = f1_2 * (long) f7_2;
    long f1f8_2  = f1_2 * (long) f8;
    long f1f9_76 = f1_2 * (long) f9_38;
    long f2f2    = f2 * (long) f2;
    long f2f3_2  = f2_2 * (long) f3;
    long f2f4_2  = f2_2 * (long) f4;
    long f2f5_2  = f2_2 * (long) f5;
    long f2f6_2  = f2_2 * (long) f6;
    long f2f7_2  = f2_2 * (long) f7;
    long f2f8_38 = f2_2 * (long) f8_19;
    long f2f9_38 = f2 * (long) f9_38;
    long f3f3_2  = f3_2 * (long) f3;
    long f3f4_2  = f3_2 * (long) f4;
    long f3f5_4  = f3_2 * (long) f5_2;
    long f3f6_2  = f3_2 * (long) f6;
    long f3f7_76 = f3_2 * (long) f7_38;
    long f3f8_38 = f3_2 * (long) f8_19;
    long f3f9_76 = f3_2 * (long) f9_38;
    long f4f4    = f4 * (long) f4;
    long f4f5_2  = f4_2 * (long) f5;
    long f4f6_38 = f4_2 * (long) f6_19;
    long f4f7_38 = f4 * (long) f7_38;
    long f4f8_38 = f4_2 * (long) f8_19;
    long f4f9_38 = f4 * (long) f9_38;
    long f5f5_38 = f5 * (long) f5_38;
    long f5f6_38 = f5_2 * (long) f6_19;
    long f5f7_76 = f5_2 * (long) f7_38;
    long f5f8_38 = f5_2 * (long) f8_19;
    long f5f9_76 = f5_2 * (long) f9_38;
    long f6f6_19 = f6 * (long) f6_19;
    long f6f7_38 = f6 * (long) f7_38;
    long f6f8_38 = f6_2 * (long) f8_19;
    long f6f9_38 = f6 * (long) f9_38;
    long f7f7_38 = f7 * (long) f7_38;
    long f7f8_38 = f7_2 * (long) f8_19;
    long f7f9_76 = f7_2 * (long) f9_38;
    long f8f8_19 = f8 * (long) f8_19;
    long f8f9_38 = f8 * (long) f9_38;
    long f9f9_38 = f9 * (long) f9_38;

    long h0 = f0f0 + f1f9_76 + f2f8_38 + f3f7_76 + f4f6_38 + f5f5_38;
    long h1 = f0f1_2 + f2f9_38 + f3f8_38 + f4f7_38 + f5f6_38;
    long h2 = f0f2_2 + f1f1_2 + f3f9_76 + f4f8_38 + f5f7_76 + f6f6_19;
    long h3 = f0f3_2 + f1f2_2 + f4f9_38 + f5f8_38 + f6f7_38;
    long h4 = f0f4_2 + f1f3_4 + f2f2 + f5f9_76 + f6f8_38 + f7f7_38;
    long h5 = f0f5_2 + f1f4_2 + f2f3_2 + f6f9_38 + f7f8_38;
    long h6 = f0f6_2 + f1f5_4 + f2f4_2 + f3f3_2 + f7f9_76 + f8f8_19;
    long h7 = f0f7_2 + f1f6_2 + f2f5_2 + f3f4_2 + f8f9_38;
    long h8 = f0f8_2 + f1f7_4 + f2f6_2 + f3f5_4 + f4f4 + f9f9_38;
    long h9 = f0f9_2 + f1f8_2 + f2f7_2 + f3f6_2 + f4f5_2;

    long carry0;
    long carry1;
    long carry2;
    long carry3;
    long carry4;
    long carry5;
    long carry6;
    long carry7;
    long carry8;
    long carry9;

    carry0 = (h0 + (long)(1L << 25)) >> 26;
    h1 += carry0;
    h0 -= carry0 * ((ulong) 1L << 26);
    carry4 = (h4 + (long)(1L << 25)) >> 26;
    h5 += carry4;
    h4 -= carry4 * ((ulong) 1L << 26);

    carry1 = (h1 + (long)(1L << 24)) >> 25;
    h2 += carry1;
    h1 -= carry1 * ((ulong) 1L << 25);
    carry5 = (h5 + (long)(1L << 24)) >> 25;
    h6 += carry5;
    h5 -= carry5 * ((ulong) 1L << 25);

    carry2 = (h2 + (long)(1L << 25)) >> 26;
    h3 += carry2;
    h2 -= carry2 * ((ulong) 1L << 26);
    carry6 = (h6 + (long)(1L << 25)) >> 26;
    h7 += carry6;
    h6 -= carry6 * ((ulong) 1L << 26);

    carry3 = (h3 + (long)(1L << 24)) >> 25;
    h4 += carry3;
    h3 -= carry3 * ((ulong) 1L << 25);
    carry7 = (h7 + (long)(1L << 24)) >> 25;
    h8 += carry7;
    h7 -= carry7 * ((ulong) 1L << 25);

    carry4 = (h4 + (long)(1L << 25)) >> 26;
    h5 += carry4;
    h4 -= carry4 * ((ulong) 1L << 26);
    carry8 = (h8 + (long)(1L << 25)) >> 26;
    h9 += carry8;
    h8 -= carry8 * ((ulong) 1L << 26);

    carry9 = (h9 + (long)(1L << 24)) >> 25;
    h0 += carry9 * 19;
    h9 -= carry9 * ((ulong) 1L << 25);

    carry0 = (h0 + (long)(1L << 25)) >> 26;
    h1 += carry0;
    h0 -= carry0 * ((ulong) 1L << 26);

    h[0] = (int) h0;
    h[1] = (int) h1;
    h[2] = (int) h2;
    h[3] = (int) h3;
    h[4] = (int) h4;
    h[5] = (int) h5;
    h[6] = (int) h6;
    h[7] = (int) h7;
    h[8] = (int) h8;
    h[9] = (int) h9;
}

/*
 h = 2 * f * f
 Can overlap h with f.
 *
 Preconditions:
 |f| bounded by 1.65*2^26,1.65*2^25,1.65*2^26,1.65*2^25,etc.
 *
 Postconditions:
 |h| bounded by 1.01*2^25,1.01*2^24,1.01*2^25,1.01*2^24,etc.
 */

static void
fe25519_sq2(fe25519 h, const fe25519 f)
{
    int f0 = f[0];
    int f1 = f[1];
    int f2 = f[2];
    int f3 = f[3];
    int f4 = f[4];
    int f5 = f[5];
    int f6 = f[6];
    int f7 = f[7];
    int f8 = f[8];
    int f9 = f[9];

    int f0_2  = 2 * f0;
    int f1_2  = 2 * f1;
    int f2_2  = 2 * f2;
    int f3_2  = 2 * f3;
    int f4_2  = 2 * f4;
    int f5_2  = 2 * f5;
    int f6_2  = 2 * f6;
    int f7_2  = 2 * f7;
    int f5_38 = 38 * f5; /* 1.959375*2^30 */
    int f6_19 = 19 * f6; /* 1.959375*2^30 */
    int f7_38 = 38 * f7; /* 1.959375*2^30 */
    int f8_19 = 19 * f8; /* 1.959375*2^30 */
    int f9_38 = 38 * f9; /* 1.959375*2^30 */

    long f0f0    = f0 * (long) f0;
    long f0f1_2  = f0_2 * (long) f1;
    long f0f2_2  = f0_2 * (long) f2;
    long f0f3_2  = f0_2 * (long) f3;
    long f0f4_2  = f0_2 * (long) f4;
    long f0f5_2  = f0_2 * (long) f5;
    long f0f6_2  = f0_2 * (long) f6;
    long f0f7_2  = f0_2 * (long) f7;
    long f0f8_2  = f0_2 * (long) f8;
    long f0f9_2  = f0_2 * (long) f9;
    long f1f1_2  = f1_2 * (long) f1;
    long f1f2_2  = f1_2 * (long) f2;
    long f1f3_4  = f1_2 * (long) f3_2;
    long f1f4_2  = f1_2 * (long) f4;
    long f1f5_4  = f1_2 * (long) f5_2;
    long f1f6_2  = f1_2 * (long) f6;
    long f1f7_4  = f1_2 * (long) f7_2;
    long f1f8_2  = f1_2 * (long) f8;
    long f1f9_76 = f1_2 * (long) f9_38;
    long f2f2    = f2 * (long) f2;
    long f2f3_2  = f2_2 * (long) f3;
    long f2f4_2  = f2_2 * (long) f4;
    long f2f5_2  = f2_2 * (long) f5;
    long f2f6_2  = f2_2 * (long) f6;
    long f2f7_2  = f2_2 * (long) f7;
    long f2f8_38 = f2_2 * (long) f8_19;
    long f2f9_38 = f2 * (long) f9_38;
    long f3f3_2  = f3_2 * (long) f3;
    long f3f4_2  = f3_2 * (long) f4;
    long f3f5_4  = f3_2 * (long) f5_2;
    long f3f6_2  = f3_2 * (long) f6;
    long f3f7_76 = f3_2 * (long) f7_38;
    long f3f8_38 = f3_2 * (long) f8_19;
    long f3f9_76 = f3_2 * (long) f9_38;
    long f4f4    = f4 * (long) f4;
    long f4f5_2  = f4_2 * (long) f5;
    long f4f6_38 = f4_2 * (long) f6_19;
    long f4f7_38 = f4 * (long) f7_38;
    long f4f8_38 = f4_2 * (long) f8_19;
    long f4f9_38 = f4 * (long) f9_38;
    long f5f5_38 = f5 * (long) f5_38;
    long f5f6_38 = f5_2 * (long) f6_19;
    long f5f7_76 = f5_2 * (long) f7_38;
    long f5f8_38 = f5_2 * (long) f8_19;
    long f5f9_76 = f5_2 * (long) f9_38;
    long f6f6_19 = f6 * (long) f6_19;
    long f6f7_38 = f6 * (long) f7_38;
    long f6f8_38 = f6_2 * (long) f8_19;
    long f6f9_38 = f6 * (long) f9_38;
    long f7f7_38 = f7 * (long) f7_38;
    long f7f8_38 = f7_2 * (long) f8_19;
    long f7f9_76 = f7_2 * (long) f9_38;
    long f8f8_19 = f8 * (long) f8_19;
    long f8f9_38 = f8 * (long) f9_38;
    long f9f9_38 = f9 * (long) f9_38;

    long h0 = f0f0 + f1f9_76 + f2f8_38 + f3f7_76 + f4f6_38 + f5f5_38;
    long h1 = f0f1_2 + f2f9_38 + f3f8_38 + f4f7_38 + f5f6_38;
    long h2 = f0f2_2 + f1f1_2 + f3f9_76 + f4f8_38 + f5f7_76 + f6f6_19;
    long h3 = f0f3_2 + f1f2_2 + f4f9_38 + f5f8_38 + f6f7_38;
    long h4 = f0f4_2 + f1f3_4 + f2f2 + f5f9_76 + f6f8_38 + f7f7_38;
    long h5 = f0f5_2 + f1f4_2 + f2f3_2 + f6f9_38 + f7f8_38;
    long h6 = f0f6_2 + f1f5_4 + f2f4_2 + f3f3_2 + f7f9_76 + f8f8_19;
    long h7 = f0f7_2 + f1f6_2 + f2f5_2 + f3f4_2 + f8f9_38;
    long h8 = f0f8_2 + f1f7_4 + f2f6_2 + f3f5_4 + f4f4 + f9f9_38;
    long h9 = f0f9_2 + f1f8_2 + f2f7_2 + f3f6_2 + f4f5_2;

    long carry0;
    long carry1;
    long carry2;
    long carry3;
    long carry4;
    long carry5;
    long carry6;
    long carry7;
    long carry8;
    long carry9;

    h0 += h0;
    h1 += h1;
    h2 += h2;
    h3 += h3;
    h4 += h4;
    h5 += h5;
    h6 += h6;
    h7 += h7;
    h8 += h8;
    h9 += h9;

    carry0 = (h0 + (long)(1L << 25)) >> 26;
    h1 += carry0;
    h0 -= carry0 * ((ulong) 1L << 26);
    carry4 = (h4 + (long)(1L << 25)) >> 26;
    h5 += carry4;
    h4 -= carry4 * ((ulong) 1L << 26);

    carry1 = (h1 + (long)(1L << 24)) >> 25;
    h2 += carry1;
    h1 -= carry1 * ((ulong) 1L << 25);
    carry5 = (h5 + (long)(1L << 24)) >> 25;
    h6 += carry5;
    h5 -= carry5 * ((ulong) 1L << 25);

    carry2 = (h2 + (long)(1L << 25)) >> 26;
    h3 += carry2;
    h2 -= carry2 * ((ulong) 1L << 26);
    carry6 = (h6 + (long)(1L << 25)) >> 26;
    h7 += carry6;
    h6 -= carry6 * ((ulong) 1L << 26);

    carry3 = (h3 + (long)(1L << 24)) >> 25;
    h4 += carry3;
    h3 -= carry3 * ((ulong) 1L << 25);
    carry7 = (h7 + (long)(1L << 24)) >> 25;
    h8 += carry7;
    h7 -= carry7 * ((ulong) 1L << 25);

    carry4 = (h4 + (long)(1L << 25)) >> 26;
    h5 += carry4;
    h4 -= carry4 * ((ulong) 1L << 26);
    carry8 = (h8 + (long)(1L << 25)) >> 26;
    h9 += carry8;
    h8 -= carry8 * ((ulong) 1L << 26);

    carry9 = (h9 + (long)(1L << 24)) >> 25;
    h0 += carry9 * 19;
    h9 -= carry9 * ((ulong) 1L << 25);

    carry0 = (h0 + (long)(1L << 25)) >> 26;
    h1 += carry0;
    h0 -= carry0 * ((ulong) 1L << 26);

    h[0] = (int) h0;
    h[1] = (int) h1;
    h[2] = (int) h2;
    h[3] = (int) h3;
    h[4] = (int) h4;
    h[5] = (int) h5;
    h[6] = (int) h6;
    h[7] = (int) h7;
    h[8] = (int) h8;
    h[9] = (int) h9;
}

static inline void
fe25519_mul32(fe25519 h, const fe25519 f, uint n)
{
    long sn = (long) n;
    int f0 = f[0];
    int f1 = f[1];
    int f2 = f[2];
    int f3 = f[3];
    int f4 = f[4];
    int f5 = f[5];
    int f6 = f[6];
    int f7 = f[7];
    int f8 = f[8];
    int f9 = f[9];
    long h0 = f0 * sn;
    long h1 = f1 * sn;
    long h2 = f2 * sn;
    long h3 = f3 * sn;
    long h4 = f4 * sn;
    long h5 = f5 * sn;
    long h6 = f6 * sn;
    long h7 = f7 * sn;
    long h8 = f8 * sn;
    long h9 = f9 * sn;
    long carry0, carry1, carry2, carry3, carry4, carry5, carry6, carry7,
            carry8, carry9;

    carry9 = (h9 + ((long) 1 << 24)) >> 25;
    h0 += carry9 * 19;
    h9 -= carry9 * ((long) 1 << 25);
    carry1 = (h1 + ((long) 1 << 24)) >> 25;
    h2 += carry1;
    h1 -= carry1 * ((long) 1 << 25);
    carry3 = (h3 + ((long) 1 << 24)) >> 25;
    h4 += carry3;
    h3 -= carry3 * ((long) 1 << 25);
    carry5 = (h5 + ((long) 1 << 24)) >> 25;
    h6 += carry5;
    h5 -= carry5 * ((long) 1 << 25);
    carry7 = (h7 + ((long) 1 << 24)) >> 25;
    h8 += carry7;
    h7 -= carry7 * ((long) 1 << 25);

    carry0 = (h0 + ((long) 1 << 25)) >> 26;
    h1 += carry0;
    h0 -= carry0 * ((long) 1 << 26);
    carry2 = (h2 + ((long) 1 << 25)) >> 26;
    h3 += carry2;
    h2 -= carry2 * ((long) 1 << 26);
    carry4 = (h4 + ((long) 1 << 25)) >> 26;
    h5 += carry4;
    h4 -= carry4 * ((long) 1 << 26);
    carry6 = (h6 + ((long) 1 << 25)) >> 26;
    h7 += carry6;
    h6 -= carry6 * ((long) 1 << 26);
    carry8 = (h8 + ((long) 1 << 25)) >> 26;
    h9 += carry8;
    h8 -= carry8 * ((long) 1 << 26);

    h[0] = (int) h0;
    h[1] = (int) h1;
    h[2] = (int) h2;
    h[3] = (int) h3;
    h[4] = (int) h4;
    h[5] = (int) h5;
    h[6] = (int) h6;
    h[7] = (int) h7;
    h[8] = (int) h8;
    h[9] = (int) h9;
}

void fe25519_invert(fe25519 out, const fe25519 z)
{
    fe25519 t0, t1, t2, t3;
    int     i;

    fe25519_sq(t0, z);
    fe25519_sq(t1, t0);
    fe25519_sq(t1, t1);
    fe25519_mul(t1, z, t1);
    fe25519_mul(t0, t0, t1);
    fe25519_sq(t2, t0);
    fe25519_mul(t1, t1, t2);
    fe25519_sq(t2, t1);
    for (i = 1; i < 5; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    fe25519_sq(t2, t1);
    for (i = 1; i < 10; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t2, t2, t1);
    fe25519_sq(t3, t2);
    for (i = 1; i < 20; ++i) {
        fe25519_sq(t3, t3);
    }
    fe25519_mul(t2, t3, t2);
    for (i = 1; i < 11; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    fe25519_sq(t2, t1);
    for (i = 1; i < 50; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t2, t2, t1);
    fe25519_sq(t3, t2);
    for (i = 1; i < 100; ++i) {
        fe25519_sq(t3, t3);
    }
    fe25519_mul(t2, t3, t2);
    for (i = 1; i < 51; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    for (i = 1; i < 6; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(out, t1, t0);
}

static void fe25519_pow22523(fe25519 out, const fe25519 z)
{
    fe25519 t0, t1, t2;
    int     i;

    fe25519_sq(t0, z);
    fe25519_sq(t1, t0);
    fe25519_sq(t1, t1);
    fe25519_mul(t1, z, t1);
    fe25519_mul(t0, t0, t1);
    fe25519_sq(t0, t0);
    fe25519_mul(t0, t1, t0);
    fe25519_sq(t1, t0);
    for (i = 1; i < 5; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t0, t1, t0);
    fe25519_sq(t1, t0);
    for (i = 1; i < 10; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t1, t1, t0);
    fe25519_sq(t2, t1);
    for (i = 1; i < 20; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    for (i = 1; i < 11; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t0, t1, t0);
    fe25519_sq(t1, t0);
    for (i = 1; i < 50; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t1, t1, t0);
    fe25519_sq(t2, t1);
    for (i = 1; i < 100; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    for (i = 1; i < 51; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t0, t1, t0);
    fe25519_sq(t0, t0);
    fe25519_sq(t0, t0);
    fe25519_mul(out, t0, z);
}
