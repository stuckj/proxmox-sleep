#!/usr/bin/env python3
"""Write a synthetic rpm whose signature header holds exactly what is asked for.

Only the lead and the signature header are real; nothing downstream of them is,
because check-rpm-signature.py reads no further. Building the header here rather
than committing binary fixtures keeps what each test asserts visible in the test.

Usage:
  rpm-fixture.py <out> [--sig-tag N] [--issuer HEX16] [--digests] [--truncate]

  --sig-tag N   put an OpenPGP signature packet in signature tag N (267, 268,
                1002 and 1005 are the tags that hold one)
  --issuer HEX  16-hex-digit key id to name as the signature's issuer
  --digests     add SHA1HEADER (269) and SHA256HEADER (273), which every rpm
                carries and neither of which is a signature
  --not-a-sig   put a well-formed OpenPGP packet that is *not* a signature in
                the signature tag, so a checker that trusts the tag's presence
                rather than its contents reports the package as signed
  --truncate    cut the file off inside the signature header
"""
import struct
import sys

LEAD = b"\xed\xab\xee\xdb" + bytes(92)
HEADER_MAGIC = b"\x8e\xad\xe8\x01" + bytes(4)


def signature_packet(issuer_hex):
    """A v4 EdDSA/SHA256 signature packet naming issuer_hex in its unhashed area."""
    issuer = bytes.fromhex(issuer_hex)
    assert len(issuer) == 8, "issuer must be 16 hex digits"
    # Issuer is subpacket type 16; its length octet counts the type octet too.
    unhashed = b"\x09\x10" + issuer
    body = (b"\x04\x00"              # version 4, signature type 0
            + bytes([22])            # public-key algorithm: EdDSA
            + bytes([8])             # hash algorithm: SHA256
            + struct.pack(">H", 0)   # empty hashed subpacket area
            + struct.pack(">H", len(unhashed)) + unhashed)
    # New-format packet header, tag 2 (signature), one-octet length.
    return bytes([0xC2, len(body)]) + body


def other_packet():
    """A well-formed OpenPGP packet of a type that is not a signature."""
    body = b"\x03" + bytes(16)
    # New-format packet header, tag 1 (public-key encrypted session key).
    return bytes([0xC1, len(body)]) + body


def build(entries):
    """entries: list of (tag, type, payload). Returns the signature header."""
    store = b""
    index = b""
    for tag, typ, payload in entries:
        index += struct.pack(">IIII", tag, typ, len(store), len(payload))
        store += payload
    return (HEADER_MAGIC + struct.pack(">II", len(entries), len(store))
            + index + store)


def main(argv):
    out = argv[0]
    sig_tag = None
    issuer = "cdb7b8f88afccbe3"
    digests = truncate = not_a_sig = False
    i = 1
    while i < len(argv):
        if argv[i] == "--sig-tag":
            sig_tag = int(argv[i + 1]); i += 2
        elif argv[i] == "--issuer":
            issuer = argv[i + 1]; i += 2
        elif argv[i] == "--digests":
            digests = True; i += 1
        elif argv[i] == "--not-a-sig":
            not_a_sig = True; i += 1
        elif argv[i] == "--truncate":
            truncate = True; i += 1
        else:
            sys.exit(f"unknown argument {argv[i]!r}")

    entries = [(62, 7, bytes(16))]                    # HEADERSIGNATURES
    if digests:
        entries.append((269, 6, b"0" * 40 + b"\0"))   # SHA1HEADER
        entries.append((273, 6, b"0" * 64 + b"\0"))   # SHA256HEADER
    if sig_tag is not None:
        payload = other_packet() if not_a_sig else signature_packet(issuer)
        entries.append((sig_tag, 7, payload))
    entries.append((1000, 4, struct.pack(">I", 4096)))  # SIZE

    blob = LEAD + build(entries)
    if truncate:
        blob = blob[:len(LEAD) + 20]
    with open(out, "wb") as fh:
        fh.write(blob)


if __name__ == "__main__":
    main(sys.argv[1:])
