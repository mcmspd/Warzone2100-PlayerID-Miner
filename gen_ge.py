#!/usr/bin/env python3
"""Generate ge25519.cl from libsodium ref10 ed25519_ref10.c + base.h.

Only the functions needed for fixed-base scalarmult are ported:
  p3_0, p1p1_to_p2/p3, p2_to_p3, p3_to_p2, p2_dbl, p3_dbl,
  add_precomp, p3_tobytes, plus a GPU-specific direct table select
  (ge_select_base) and ge_scalarmult_base.

Deliberate deviation from reference: ge25519_cmov8_base's constant-time
cmov chain is replaced with direct indexed loads from the __constant
base table. Side-channel hardening is meaningless for mining (scalars
are ephemeral per-candidate); this also avoids OpenCL address-space
mismatches between __constant table data and __private working state.
"""
import re
import sys

REF = "/tmp/opencode/ref-libsodium"
REF10_C = REF + "/src/libsodium/crypto_core/ed25519/ref10/ed25519_ref10.c"
BASE_H = REF + "/src/libsodium/crypto_core/ed25519/ref10/fe_25_5/base.h"

KEEP = ["ge25519_p3_0", "ge25519_p1p1_to_p2", "ge25519_p1p1_to_p3",
        "ge25519_p2_to_p3", "ge25519_p3_to_p2", "ge25519_p2_dbl",
        "ge25519_p3_dbl", "ge25519_add_precomp", "ge25519_p3_tobytes"]


def extract(src, name):
    pat = re.compile(r"\n((?:static\s+)?(?:void|int|unsigned char)\s*\n?"
                     + name + r"\s*\(.*?\)\s*\n\{.*?\n\})", re.S)
    m = pat.search(src)
    if not m:
        pat2 = re.compile(r"\n" + name + r"\(.*?\)\n\{.*?\n\}", re.S)
        m = pat2.search(src)
    return m.group(1) if m else None


def transform(code):
    code = re.sub(r"\bint32_t\b", "int", code)
    code = re.sub(r"\bint64_t\b", "long", code)
    code = re.sub(r"\buint32_t\b", "uint", code)
    code = re.sub(r"\buint64_t\b", "ulong", code)
    code = re.sub(r"\bunsigned char\b", "uchar", code)
    code = re.sub(r"\bsigned char\b", "char", code)
    return code


SCALARMULT = """
// Direct (non-constant-time) select from base table. Mining does not need
// side-channel hardening: scalars are ephemeral per-candidate.
inline void ge_select_base(ge25519_precomp *t, int pos, char b) {
    uchar neg = (b < 0) ? 1 : 0;
    int ab = neg ? -b : b;  // 0..8
    if (ab == 0) {
        fe25519_1(t->yplusx); fe25519_1(t->yminusx); fe25519_0(t->xy2d);
    } else {
        int k = ab - 1;  // 0..7
        for (int j = 0; j < 10; j++) {
            t->yplusx[j]  = GE_BASE[pos][k][0][j];
            t->yminusx[j] = GE_BASE[pos][k][1][j];
            t->xy2d[j]    = GE_BASE[pos][k][2][j];
        }
        if (neg) {
            for (int j = 0; j < 10; j++) {
                int tmp = t->yplusx[j];
                t->yplusx[j] = t->yminusx[j];
                t->yminusx[j] = tmp;
                t->xy2d[j] = -t->xy2d[j];
            }
        }
    }
}

void ge_scalarmult_base(ge25519_p3 *h, const uchar *a) {
    char e[64];
    char carry;
    ge25519_p1p1 r;
    ge25519_p2 s;
    ge25519_precomp t;
    int i;
    for (i = 0; i < 32; ++i) {
        e[2*i+0] = (a[i] >> 0) & 15;
        e[2*i+1] = (a[i] >> 4) & 15;
    }
    carry = 0;
    for (i = 0; i < 63; ++i) {
        e[i] += carry;
        carry = e[i] + 8;
        carry >>= 4;
        e[i] -= carry * 16;
    }
    e[63] += carry;
    ge25519_p3_0(h);
    for (i = 1; i < 64; i += 2) {
        ge_select_base(&t, i/2, e[i]);
        ge25519_add_precomp(&r, h, &t);
        ge25519_p1p1_to_p3(h, &r);
    }
    ge25519_p3_dbl(&r, h);
    ge25519_p1p1_to_p2(&s, &r);
    ge25519_p2_dbl(&r, &s);
    ge25519_p1p1_to_p2(&s, &r);
    ge25519_p2_dbl(&r, &s);
    ge25519_p1p1_to_p2(&s, &r);
    ge25519_p2_dbl(&r, &s);
    ge25519_p1p1_to_p3(h, &r);
    for (i = 0; i < 64; i += 2) {
        ge_select_base(&t, i/2, e[i]);
        ge25519_add_precomp(&r, h, &t);
        ge25519_p1p1_to_p3(h, &r);
    }
}
"""


def main():
    ref10_c = open(REF10_C).read()
    base_h = open(BASE_H).read()

    codes = {}
    for n in KEEP:
        c = extract(ref10_c, n)
        if not c:
            sys.exit(f"could not extract {n}")
        codes[n] = c

    out = []
    out.append("/* Generated from libsodium ref10 by gen_ge.py - do not edit by hand. */")
    out.append("/* Simplified for GPU mining: direct table lookup (no side-channel hardening). */")
    out.append("")
    out.append("typedef struct { fe25519 X; fe25519 Y; fe25519 Z; } ge25519_p2;")
    out.append("typedef struct { fe25519 X; fe25519 Y; fe25519 Z; fe25519 T; } ge25519_p3;")
    out.append("typedef struct { fe25519 X; fe25519 Y; fe25519 Z; fe25519 T; } ge25519_p1p1;")
    out.append("typedef struct { fe25519 yplusx; fe25519 yminusx; fe25519 xy2d; } ge25519_precomp;")
    out.append("")
    out.append("__constant static const int GE_BASE[32][8][3][10] = {")
    out.append(transform(base_h))
    out.append("};")
    out.append("")
    for n in KEEP:
        out.append(transform(codes[n]))
        out.append("")
    out.append(SCALARMULT)

    full = "\n".join(out)
    with open("ge25519.cl", "w") as f:
        f.write(full)
    print(f"wrote ge25519.cl ({full.count(chr(10))} lines)")


if __name__ == "__main__":
    main()
