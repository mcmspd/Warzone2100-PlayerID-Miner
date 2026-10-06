#!/usr/bin/env python3
"""Generate fe25519.cl from libsodium ref10 sources by scripted transformation.

Sources (local clones, not committed):
  ref-libsodium/src/libsodium/include/sodium/private/ed25519_ref10_fe_25_5.h
  ref-libsodium/src/libsodium/crypto_core/ed25519/ref10/fe_25_5/fe.h
  ref-libsodium/src/libsodium/crypto_core/ed25519/ref10/ed25519_ref10.c
    (fe25519_invert, fe25519_pow22523 only)

Transformation is mechanical (type map + load_3/4 rename + libc removal) so
the OpenCL matches the reference verbatim. Never hand-edit the output.
"""
import re
import sys

REF = "/tmp/opencode/ref-libsodium"
FE25519_H = REF + "/src/libsodium/include/sodium/private/ed25519_ref10_fe_25_5.h"
FE_H = REF + "/src/libsodium/crypto_core/ed25519/ref10/fe_25_5/fe.h"
REF10_C = REF + "/src/libsodium/crypto_core/ed25519/ref10/ed25519_ref10.c"


def transform(code):
    code = re.sub(r"\bint32_t\b", "int", code)
    code = re.sub(r"\bint64_t\b", "long", code)
    code = re.sub(r"\buint32_t\b", "uint", code)
    code = re.sub(r"\buint64_t\b", "ulong", code)
    code = re.sub(r"\bunsigned char\b", "uchar", code)
    code = re.sub(r"\bsigned char\b", "char", code)
    code = re.sub(r"\bload_3\b", "fe_load_3", code)
    code = re.sub(r"\bload_4\b", "fe_load_4", code)
    return code


def main():
    fe25_5_h = open(FE25519_H).read()
    fe_h = open(FE_H).read()
    ref10_c = open(REF10_C).read()

    m_inv = re.search(r"\nfe25519_invert\(fe25519 out.*?\n\}\n", ref10_c, re.S)
    m_pow = re.search(r"\nfe25519_pow22523\(fe25519 out.*?\n\}\n", ref10_c, re.S)
    if not m_inv or not m_pow:
        sys.exit("could not extract invert/pow22523")

    fe_h = re.sub(r"#include.*?\n", "", fe_h)
    fe25_5_h = re.sub(r"#include.*?\n", "", fe25_5_h)
    fe25_5_h = re.sub(r"^#.*?$", "", fe25_5_h, flags=re.M)
    fe_h = re.sub(r"^#.*?$", "", fe_h, flags=re.M)

    out = []
    out.append("/* Generated from libsodium ref10 by gen_fe.py - do not edit by hand. */")
    out.append("/* Sources: ed25519_ref10_fe_25_5.h, fe_25_5/fe.h, ed25519_ref10.c */")
    out.append("")
    out.append("typedef int fe25519[10];")
    out.append("")
    out.append("inline ulong fe_load_3(const uchar *in) {")
    out.append("    ulong r = (ulong)in[0];")
    out.append("    r |= ((ulong)in[1]) << 8;")
    out.append("    r |= ((ulong)in[2]) << 16;")
    out.append("    return r;")
    out.append("}")
    out.append("inline ulong fe_load_4(const uchar *in) {")
    out.append("    ulong r = (ulong)in[0];")
    out.append("    r |= ((ulong)in[1]) << 8;")
    out.append("    r |= ((ulong)in[2]) << 16;")
    out.append("    r |= ((ulong)in[3]) << 24;")
    out.append("    return r;")
    out.append("}")
    out.append(transform(fe_h))
    out.append(transform(fe25_5_h))
    out.append("void " + transform(m_inv.group(0)).lstrip())
    out.append("static void " + transform(m_pow.group(0)).lstrip().lstrip("\n"))

    full = "\n".join(out)
    # OpenCL has no libc string/zero helpers or inline asm barriers
    full = full.replace("    memset(&h[0], 0, 10 * sizeof h[0]);",
                        "    for (int _i = 0; _i < 10; _i++) h[_i] = 0;")
    full = full.replace("    memset(&h[2], 0, 8 * sizeof h[0]);",
                        "    for (int _i = 2; _i < 10; _i++) h[_i] = 0;")
    full = full.replace("    memcpy(h, f, 10 * sizeof h[0]);",
                        "    for (int _i = 0; _i < 10; _i++) h[_i] = f[_i];")
    full = full.replace("    return sodium_is_zero(s, 32);",
                        "    uchar _d = 0; for (int _i = 0; _i < 32; _i++) _d |= s[_i]; return _d == 0;")
    full = full.replace('    __asm__ __volatile__("" : "+r"(mask));', "")
    full = re.sub(r"^#(if|ifdef|ifndef|else|elif|endif|define).*$", "", full, flags=re.M)

    with open("fe25519.cl", "w") as f:
        f.write(full)
    print(f"wrote fe25519.cl ({full.count(chr(10))} lines)")


if __name__ == "__main__":
    main()
