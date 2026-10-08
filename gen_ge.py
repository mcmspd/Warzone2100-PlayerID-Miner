#!/usr/bin/env python3
"""Generate ge25519.cl from libsodium ref10 ed25519_ref10.c + a Python-built
width-5 fixed-base table (each entry cross-checked against libsodium).

Only the functions needed for fixed-base scalarmult are ported:
  p3_0, p1p1_to_p2/p3, p2_to_p3, p3_to_p2, p2_dbl, p3_dbl,
  add_precomp, p3_tobytes, plus a GPU-specific direct table select
  (ge_select_base) and ge_scalarmult_base.

Schedule: 52 signed 5-bit digits (2 loops of 26 + x32 middle = 5 dbls),
52 point adds vs 64 for the old width-4 nibble schedule. Table
GE_BASE5[26][16][3][10] = k*B*2^(10*pos), k = 1..16 (~50 KB __constant).

Deliberate deviation from reference: ge25519_cmov8_base's constant-time
cmov chain is replaced with direct indexed loads from the __constant
base table. Side-channel hardening is meaningless for mining (scalars
are ephemeral per-candidate); this also avoids OpenCL address-space
mismatches between __constant table data and __private working state.
"""
import re
import sys

try:
    from nacl.bindings import crypto_scalarmult_ed25519_base_noclamp as base_mult
except ImportError:
    sys.exit("need PyNaCl to build the width-5 table: pip install pynacl")

REF = "/tmp/opencode/ref-libsodium"
REF10_C = REF + "/src/libsodium/crypto_core/ed25519/ref10/ed25519_ref10.c"
BASE_H = REF + "/src/libsodium/crypto_core/ed25519/ref10/fe_25_5/base.h"

P25519 = 2**255 - 19
ED_D = -121665 * pow(121666, -1, P25519) % P25519
ED_L = 2**252 + 27742317777372353535851937790883648493


def _expand(comp):
    y = int.from_bytes(comp, "little") & ((1 << 255) - 1)
    parity = comp[31] >> 7
    x2 = (y * y - 1) * pow((ED_D * y * y + 1) % P25519, -1, P25519) % P25519
    x = pow(x2, (P25519 + 3) // 8, P25519)
    if (x * x - x2) % P25519 != 0:
        x = x * pow(2, (P25519 - 1) // 4, P25519) % P25519
    if (x & 1) != parity:
        x = P25519 - x
    assert (x * x - x2) % P25519 == 0 and (x & 1) == parity
    return x, y


def _limbs(v):
    widths = [26, 25] * 5
    out, x = [], v % P25519
    for w in widths:
        out.append(x & ((1 << w) - 1))
        x >>= w
    assert x == 0
    return out


def build_w5_table():
    """GE_BASE5[26][16][3][10]: k*B*2^(10*pos), k=1..16, radix-2^25.5 limbs.
    Every entry's y-limbs must re-pack to libsodium's compressed bytes."""
    offs = [0, 26, 51, 77, 102, 128, 153, 179, 204, 230]
    rows = ["__constant static const int GE_BASE5[26][16][3][10] = {"]
    for pos in range(26):
        rows.append(f"{{ /* {pos}/25 */")
        for k in range(1, 17):
            # reduce mod L first: the ladder is only exercised on reduced
            # scalars (same point either way, verified in prototype)
            comp = base_mult(((k << (10 * pos)) % ED_L).to_bytes(32, "little"))
            x, y = _expand(comp)
            y_only = bytearray(comp)
            y_only[31] &= 0x7F
            assert sum(h << o for h, o in zip(_limbs(y), offs)).to_bytes(32, "little") == bytes(y_only), \
                f"table self-check failed at pos {pos} k {k}"
            triple = [_limbs((x + y) % P25519), _limbs((y - x) % P25519),
                      _limbs((2 * ED_D % P25519) * x * y % P25519)]
            rows.append("  { " + ", ".join(
                "{ " + ", ".join(str(v) for v in limbs) + " }" for limbs in triple) + " },")
        rows.append("},")
    rows.append("};")
    return "\n".join(rows)

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
// Direct (non-constant-time) select from width-5 base table. Mining does
// not need side-channel hardening: scalars are ephemeral per-candidate.
inline void ge_select_base(ge25519_precomp *t, int pos, char b) {
    int neg = (b < 0) ? 1 : 0;
    int ab = neg ? -b : b;  // 0..16
    if (ab == 0) {
        fe25519_1(t->yplusx); fe25519_1(t->yminusx); fe25519_0(t->xy2d);
    } else {
        int k = ab - 1;  // 0..15
        for (int j = 0; j < 10; j++) {
            t->yplusx[j]  = GE_BASE5[pos][k][0][j];
            t->yminusx[j] = GE_BASE5[pos][k][1][j];
            t->xy2d[j]    = GE_BASE5[pos][k][2][j];
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
    char e[52];
    int carry = 0;
    ge25519_p1p1 r;
    ge25519_p2 s;
    ge25519_precomp t;
    int i;
    for (i = 0; i < 51; ++i) {
        int bit = 5 * i, lo = bit >> 3, sh = bit & 7;
        int cur = (a[lo] >> sh) & 31;
        if (sh > 3 && lo + 1 < 32) cur |= (a[lo + 1] << (8 - sh)) & 31;
        cur += carry;
        if (cur > 16) { cur -= 32; carry = 1; } else carry = 0;
        e[i] = (char)cur;
    }
    e[51] = (char)(((a[31] >> 7) & 1) + carry);
    ge25519_p3_0(h);
    for (i = 1; i < 52; i += 2) {
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
    ge25519_p1p1_to_p2(&s, &r);
    ge25519_p2_dbl(&r, &s);
    ge25519_p1p1_to_p3(h, &r);
    for (i = 0; i < 52; i += 2) {
        ge_select_base(&t, i/2, e[i]);
        ge25519_add_precomp(&r, h, &t);
        ge25519_p1p1_to_p3(h, &r);
    }
}
"""


def main():
    ref10_c = open(REF10_C).read()

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
    out.append(build_w5_table())
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
