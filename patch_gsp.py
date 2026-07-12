#!/usr/bin/env python3
import struct, sys
from pathlib import Path

PAYLOAD_SIZE = 0xF800
SIGNATURE_NAME = b".fwsignature_ga100"

def patch_gsp(input_path, payload_path, output_path):
    gsp = bytearray(Path(input_path).read_bytes())
    payload = Path(payload_path).read_bytes()
    if len(payload) != PAYLOAD_SIZE:
        raise ValueError(f"Payload size mismatch: {len(payload)} != {PAYLOAD_SIZE}")
    if gsp[:4] != b'\x7fELF':
        raise ValueError("Not an ELF file")
    e_shoff = struct.unpack_from('<Q', gsp, 0x28)[0]
    e_shentsize = struct.unpack_from('<H', gsp, 0x3A)[0]
    e_shnum = struct.unpack_from('<H', gsp, 0x3C)[0]
    e_shstrndx = struct.unpack_from('<H', gsp, 0x3E)[0]
    shdr_total = e_shnum * e_shentsize
    orig_shdrs = bytearray(gsp[e_shoff:e_shoff + shdr_total])
    strtab_hdr_off = e_shstrndx * e_shentsize
    strtab_off = struct.unpack_from('<Q', orig_shdrs, strtab_hdr_off + 0x18)[0]
    strtab_sz = struct.unpack_from('<Q', orig_shdrs, strtab_hdr_off + 0x20)[0]
    strtab = bytes(gsp[strtab_off:strtab_off + strtab_sz])
    sig_idx = -1; sig_off = 0
    for i in range(e_shnum):
        hdr_base = i * e_shentsize
        name_idx = struct.unpack_from('<I', orig_shdrs, hdr_base)[0]
        end = strtab.find(b'\x00', name_idx)
        if end == -1: end = len(strtab)
        name = strtab[name_idx:end]
        if name == SIGNATURE_NAME:
            sig_idx = i
            sig_off = struct.unpack_from('<Q', orig_shdrs, hdr_base + 0x18)[0]
            print(f"Found .fwsignature_ga100 at offset 0x{sig_off:X}")
            break
    if sig_idx == -1:
        raise ValueError("Signature section not found")
    payload_end = sig_off + PAYLOAD_SIZE
    if len(gsp) < payload_end:
        gsp.extend(b'\x00' * (payload_end - len(gsp)))
    gsp[sig_off:sig_off + PAYLOAD_SIZE] = payload
    new_shdrs = bytearray(orig_shdrs)
    sig_hdr_base = sig_idx * e_shentsize
    struct.pack_into('<Q', new_shdrs, sig_hdr_base + 0x20, PAYLOAD_SIZE)
    new_strtab_off = len(gsp)
    gsp.extend(strtab)
    strtab_hdr_base = e_shstrndx * e_shentsize
    struct.pack_into('<Q', new_shdrs, strtab_hdr_base + 0x18, new_strtab_off)
    new_shoff = len(gsp)
    gsp.extend(new_shdrs)
    struct.pack_into('<Q', gsp, 0x28, new_shoff)
    Path(output_path).write_bytes(bytes(gsp))
    print(f"Patched GSP written to: {output_path}")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: patch_gsp.py <stock_gsp.bin> <payload.bin> <output.bin>")
        sys.exit(1)
    patch_gsp(sys.argv[1], sys.argv[2], sys.argv[3])
