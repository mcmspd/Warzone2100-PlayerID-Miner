#!/usr/bin/env python3
"""Property test from AGENTS.md §8: validate a mined .sta2 against every invariant.

Usage: python3 test_property.py <file.sta2> <expected-prefix>

Checks:
  1. secret key decodes to 64 bytes and equals seed || public_key
  2. public_key == base64decode(player_id derivation) and is 32 bytes
  3. public_key re-derives from seed alone (SHA-512 + clamp + base scalarmult)
  4. the key signs, and the signature verifies under the reported player ID
  5. player_id.startswith(prefix) — catches pubkey/seed mismatches
  6. seed layout: mminer-compatible salt||tid||counter||pad (§2)
"""
import base64
import hashlib
import sys

from nacl.bindings import crypto_scalarmult_ed25519_base_noclamp
from nacl.signing import SigningKey


def main(sta2_path, prefix):
    lines = open(sta2_path).read().splitlines()
    assert lines[0] == "WZ.STA.v3", f"line 1: {lines[0]!r}"
    assert lines[1] == "10 10 454 902788 10", f"line 2: {lines[1]!r}"
    sk_b64 = lines[2].strip()

    sk = base64.b64decode(sk_b64)
    assert len(sk) == 64, f"secret key is {len(sk)} bytes, want 64"
    seed, pk = sk[:32], sk[32:]

    # 2. player ID is base64(pubkey), 32 bytes
    assert len(pk) == 32
    player_id = base64.b64encode(pk).decode()
    assert len(player_id) == 44 and player_id.endswith("=")

    # 3. re-derive via documented path (SHA-512 + clamp + base scalarmult)
    az = bytearray(hashlib.sha512(seed).digest())
    az[0] &= 248
    az[31] &= 127
    az[31] |= 64
    assert crypto_scalarmult_ed25519_base_noclamp(bytes(az[:32])) == pk, \
        "pubkey does not re-derive from seed (broken clamp or scalarmult)"
    assert bytes(SigningKey(seed=seed).verify_key) == pk, \
        "PyNaCl re-derivation mismatch"

    # 4. signs and verifies
    signer = SigningKey(seed=seed)
    msg = b"warzone2100-property-test"
    assert signer.verify_key.verify(msg, signer.sign(msg).signature) == msg

    # 5. prefix — the actual vanity requirement
    assert player_id.startswith(prefix), f"{player_id!r} lacks prefix {prefix!r}"

    # 6. seed layout (§2): salt[16] + tid u32 LE + counter u64 LE + pad
    tid = int.from_bytes(seed[16:20], "little")
    ctr = int.from_bytes(seed[20:28], "little")
    assert seed[28:] == b"\0" * 4, "seed padding nonzero"
    print(f"seed: tid={tid} counter={ctr}")
    print(f"player ID: {player_id}")

    print("ALL PROPERTY CHECKS PASS")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
