#!/usr/bin/env python3
"""sptm_compare.py — characterise an SPTM image against the iOS 27.2 b1->b3
TLB-invalidation race fix documented in research/sptm-reference/README.md.

Self-contained: stdlib + macOS libcompression (ctypes) only. No pip modules.
Accepts a raw decompressed SPTM Mach-O, an IM4P envelope, or a bare LZFSE
('bvx2') stream; auto-detects and decompresses as needed.

Per input it reports:
  (a) presence/absence of every load-bearing marker string from the research
      repo, with file offset, VM address and the full string for context;
  (b) an instruction census computed ONLY over 4-byte-aligned words of the
      Mach-O __text sections (never a bytewise whole-file scan): dmb ish,
      dmb ishld, hint #62, and reads of S3_3_C14_C0_6 / S3_3_C14_C0_0 /
      S3_3_C4_C2_1 (the registers the README's pre/post table uses);
  (c) for found markers: ADRP+ADD / ADRP+LDR code xrefs, and the enclosing
      function start (scan back to pacibsp/paciasp), plus a small instruction
      dump around the flush-entry function. If research/sptm-reference/
      disasm_sptm.py is importable it is used for mnemonics; otherwise raw
      words are printed. Xrefs default off for large (__text > 4 MiB) inputs.

Reference points from the repo (iPhone18,4/T8150, SPTM 820.40.18 -> 820.40.23):
  pre-fix : dmb ish 3,  dmb ishld 11, hint#62 4,  S3_3_C14_C0_6 reads 18
  post-fix: dmb ish 27, dmb ishld 11, hint#62 10, S3_3_C14_C0_6 reads 41
The verdict printed at the end is a HEURISTIC comparison against those two
profiles, not a proof of (un)patchability on any given SoC.

usage: python3 research/sptm_compare.py <im4p|macho|bvx2> [more files...]
       [--xrefs]  force code-xref scan even on large images
"""

import ctypes
import re
import struct
import sys
import os

# ---------------------------------------------------------------- constants

# exact instruction words (AArch64, little-endian)
W_DMB_SY    = 0xD5033FFF
W_DMB_ISH   = 0xD5033FBF
W_DMB_ISHLD = 0xD5033BBF
W_HINT62    = 0xD50327DF   # hint #62 = 0xd503201f | (62 << 5)
W_PACIASP   = 0xD503233F
W_PACIBSP   = 0xD503237F

# MRS Xt, S<op0>_<op1>_C<cn>_C<cm>_<op2> — base 0xD5300000, Rt in low 5 bits.
def mrs_word(op0, op1, cn, cm, op2):
    return (0xD5300000 | (op0 << 19) | (op1 << 16) | (cn << 12) |
            (cm << 8) | (op2 << 5))

REGISTERS = {
    "S3_3_C14_C0_6 (SPTM tick counter)":  mrs_word(3, 3, 14, 0, 6),
    "S3_3_C14_C0_0 (tick frequency)":     mrs_word(3, 3, 14, 0, 0),
    "S3_3_C4_C2_1  (check-then-barrier)": mrs_word(3, 3, 4, 2, 1),
}

# marker strings from research/sptm-reference/README.md (sections 3, 5, 6, 7)
MARKERS = [
    # (needle, added-in-b3?, what it indicates)
    ("uat_sync_outer_tlb_sapt_flush", True,  "TLBI flush entry point (in all 5 guarded fns)"),
    ("VIOLATION_T8110_DART_UNGANG_GAPF_RACE", True, "names the DART un-ganged TLBI race"),
    ("uat_dekkerlock_lock",           True,  "Dekker mutual-exclusion gate"),
    ("uat_dekker_gate_lock",          True,  "Dekker gate"),
    ("UAT Dekker",                    True,  "gate acquisition timeout panic text"),
    ("verify-gmmu-tlbis-at-sync",     True,  "GMMU TLBI verification boot property"),
    ("gmmu-tlbis-at-retype",          True,  "GMMU TLBI-at-retype property"),
    ("gmmu-tlbi-verification-reg",    True,  "TLBI verification register property"),
    ("gmmu-tlbi-verification-bit",    True,  "TLBI verification bit property"),
    ("Failed to verify TLBI",         True,  "TLBI verification panic"),
    ("The GMMU TLBI verification register should be 8B-aligned", True, "verification alignment check"),
    ("relaxed_rw_protections",        True,  "relaxed_rw_protections/allow_pte_remap refusal"),
    ("allow_pte_remap",               True,  "PTE remap restriction"),
    ("issue-gmmu-tlbis-at-retype",    True,  "GPU peer issue property"),
    ("agx-address-space-mgmt-mode",   True,  "GPU address-space management (peer cluster)"),
    ("wrprot",                        False, "string REMOVED in b3; presence suggests pre-fix"),
]

XREF_MARKERS = {"uat_sync_outer_tlb_sapt_flush", "uat_dekkerlock_lock",
                "uat_dekker_gate_lock", "Failed to verify TLBI"}

VERSION_RE = re.compile(rb"SPTM-\d+(?:\.\d+)+")


# ---------------------------------------------------------------- input

def load_image(path):
    """Return raw Mach-O bytes from a raw Mach-O / IM4P / bvx2 input."""
    data = open(path, "rb").read()
    if len(data) < 4:
        raise SystemExit("%s: too small" % path)
    if struct.unpack_from("<I", data, 0)[0] in (0xFEEDFACF, 0xFEEDFACE):
        return data, "raw Mach-O"
    start = data.find(b"bvx2")
    if start < 0:
        raise SystemExit("%s: neither Mach-O nor an im4p/LZFSE (bvx2) stream" % path)
    end = data.find(b"bvx$", start)
    end = end + 4 if end >= 0 else len(data)
    payload = data[start:end]
    lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
    lib.compression_decode_buffer.restype = ctypes.c_size_t
    lib.compression_decode_buffer.argtypes = [
        ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
        ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
    src = ctypes.create_string_buffer(payload, len(payload))
    cap = 256 << 20
    out = ctypes.create_string_buffer(cap)
    n = lib.compression_decode_buffer(out, cap, src, len(payload), None, 0x801)
    if not n:
        raise SystemExit("%s: LZFSE decode failed" % path)
    kind = "IM4P+LZFSE" if start > 0 else "bare bvx2 LZFSE stream"
    return out.raw[:n], kind


# ---------------------------------------------------------------- Mach-O

class MachO:
    def __init__(self, data):
        self.d = data
        magic = struct.unpack_from("<I", data, 0)[0]
        if magic != 0xFEEDFACF:
            raise SystemExit("not a 64-bit Mach-O")
        ncmds = struct.unpack_from("<I", data, 16)[0]
        self.segs = []
        self.texts = []   # __text sections: dict(fileoff, size, vmaddr, seg)
        p = 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", data, p)
            if cmd == 0x19:  # LC_SEGMENT_64
                name = data[p+8:p+24].rstrip(b"\0").decode("ascii", "replace")
                seg = dict(name=name,
                           vmaddr=struct.unpack_from("<Q", data, p+24)[0],
                           fileoff=struct.unpack_from("<Q", data, p+40)[0],
                           filesize=struct.unpack_from("<Q", data, p+48)[0])
                self.segs.append(seg)
                nsects = struct.unpack_from("<I", data, p+64)[0]
                seg["nsects"] = nsects
                sp = p + 72
                for i in range(nsects):
                    sect = data[sp:sp+16].rstrip(b"\0").decode("ascii", "replace")
                    if sect == "__text":
                        soff = struct.unpack_from("<I", data, sp+56)[0]
                        ssize = struct.unpack_from("<Q", data, sp+40)[0]
                        # Decompressed images often carry section offsets that
                        # were never fixed up (e.g. 0 while the segment sits at
                        # a nonzero fileoff). Trust the segment in that case.
                        if (soff < seg["fileoff"] or
                                soff + ssize > seg["fileoff"] + seg["filesize"]):
                            soff, ssize = seg["fileoff"], seg["filesize"]
                        self.texts.append(dict(
                            seg=name,
                            vmaddr=struct.unpack_from("<Q", data, sp+32)[0],
                            size=ssize, fileoff=soff))
                    sp += 80
            p += size
        # Segments without a section table (nsects == 0, as in decompressed
        # kernelcaches and some SPTM images) are executable text in their own
        # right: census the whole segment. Sections, where present, win.
        covered = {t["seg"] for t in self.texts}
        for s in self.segs:
            if s["filesize"] and "TEXT" in s["name"] and s["name"] not in covered \
                    and s.get("nsects", 0) == 0:
                self.texts.append(dict(seg=s["name"], vmaddr=s["vmaddr"],
                                       size=s["filesize"], fileoff=s["fileoff"]))

    def off2vm(self, off):
        for s in self.segs:
            if s["fileoff"] <= off < s["fileoff"] + s["filesize"]:
                return s["vmaddr"] + (off - s["fileoff"])
        return None

    def vm2off(self, vm):
        for s in self.segs:
            if s["vmaddr"] <= vm < s["vmaddr"] + s["filesize"]:
                return s["fileoff"] + (vm - s["vmaddr"])
        return None


# ---------------------------------------------------------------- census

def instruction_census(m):
    """Aligned instruction census over __text sections only."""
    counts = {k: 0 for k in ("dmb ish", "dmb ishld", "hint #62")}
    regs = {k: 0 for k in REGISTERS}
    total = 0
    for t in m.texts:
        blob = m.d[t["fileoff"]:t["fileoff"] + t["size"]]
        total += len(blob) // 4
        for (w,) in struct.iter_unpack("<I", blob[:len(blob) & ~3]):
            if w == W_DMB_ISH:
                counts["dmb ish"] += 1
            elif w == W_DMB_ISHLD:
                counts["dmb ishld"] += 1
            elif w == W_HINT62:
                counts["hint #62"] += 1
            elif (w & 0xFFC00000) == 0xD5300000:      # cheap MRS prefilter
                base = w & 0xFFFFFFE0
                for name, word in REGISTERS.items():
                    if base == word:
                        regs[name] += 1
    return counts, regs, total


# ---------------------------------------------------------------- strings

def string_at(data, off, maxlen=200):
    end = data.find(b"\0", off, off + maxlen)
    if end < 0:
        return None
    try:
        return data[off:end].decode("ascii")
    except UnicodeDecodeError:
        return None


def find_markers(m):
    found = []
    for needle, added, meaning in MARKERS:
        off = m.d.find(needle.encode())
        if off < 0:
            found.append((needle, added, meaning, None, None, None))
            continue
        text = string_at(m.d, off)
        # a needle may be a substring of a longer string: show that string
        start = off
        while start > 0 and 32 <= m.d[start-1] < 127:
            start -= 1
        full = string_at(m.d, start) or text
        found.append((needle, added, meaning, off, m.off2vm(off), full))
    return found


# ---------------------------------------------------------------- xrefs

def xrefs_to(m, target, text):
    """adrp+add / adrp+ldr references to a VM address inside one text section."""
    out = []
    d = m.d
    base_off, size = text["fileoff"], text["size"]
    for off in range(base_off, base_off + size - 16, 4):
        w = struct.unpack_from("<I", d, off)[0]
        if (w & 0x9F000000) != 0x90000000:
            continue
        imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
        if imm & (1 << 20):
            imm -= (1 << 21)
        pc = text["vmaddr"] + (off - base_off)
        page = (pc & ~0xFFF) + (imm << 12)
        for k in (1, 2):
            w2 = struct.unpack_from("<I", d, off + 4*k)[0]
            if (w2 & 0xFF800000) == 0x91000000:            # add imm
                if page + ((w2 >> 10) & 0xFFF) == target:
                    out.append(pc)
            elif (w2 & 0xFFC00000) == 0xF9400000:          # ldr 64-bit imm
                if page + ((w2 >> 10) & 0xFFF)*8 == target:
                    out.append(pc)
    return out


def func_start(m, vm, maxback=0x4000):
    off = m.vm2off(vm)
    if off is None:
        return None
    for back in range(0, min(maxback, off), 4):
        w = struct.unpack_from("<I", m.d, off - back)[0]
        if w in (W_PACIBSP, W_PACIASP):
            return vm - back
    return None


def dump_words(m, vm, count=16):
    off = m.vm2off(vm)
    if off is None:
        return []
    lines = []
    dis = None
    here = os.path.dirname(os.path.abspath(__file__))
    if os.path.isdir(os.path.join(here, "sptm-reference")):
        sys.path.insert(0, os.path.join(here, "sptm-reference"))
        try:
            from disasm_sptm import dis as _dis
            dis = _dis
        except Exception:
            dis = None
    for i in range(count):
        w = struct.unpack_from("<I", m.d, off + i*4)[0]
        lines.append("    %#14x %08x  %s" % (vm + i*4, w, dis(w, vm + i*4) if dis else ""))
    return lines


# ---------------------------------------------------------------- report

def analyse(path, force_xrefs=False):
    data, kind = load_image(path)
    m = MachO(data)
    print("=" * 78)
    print("FILE: %s" % path)
    print("  input: %s -> %d bytes; Mach-O segments: %s" %
          (kind, len(data), ", ".join(s["name"] for s in m.segs)))
    for t in m.texts:
        print("  __text [%-12s] fileoff=%#x size=%#x vmaddr=%#x" %
              (t["seg"], t["fileoff"], t["size"], t["vmaddr"]))
    versions = sorted(set(v.decode() for v in VERSION_RE.findall(data)))
    print("  version strings: %s" % (", ".join(versions) or "(none found)"))

    counts, regs, words = instruction_census(m)
    print("\n  INSTRUCTION CENSUS (aligned __text words only, %d words):" % words)
    print("    dmb ish   : %4d     (reference: pre-fix 3, post-fix 27 on T8150)" % counts["dmb ish"])
    print("    dmb ishld : %4d     (reference: 11 pre and post)" % counts["dmb ishld"])
    print("    hint #62  : %4d     (reference: pre-fix 4, post-fix 10)" % counts["hint #62"])
    for name, n in regs.items():
        print("    mrs %-30s: %4d" % (name, n))

    markers = find_markers(m)
    print("\n  MARKER STRINGS:")
    for needle, added, meaning, off, vm, full in markers:
        if off is None:
            print("    [absent ] %-46s (%s)" % (needle, "new in b3" if added else "removed in b3"))
        else:
            print("    [PRESENT] %-46s off=%#x vm=%#x" % (needle, off, vm or 0))
            if full and full != needle:
                print("               full string: %s" % full)

    do_xrefs = force_xrefs or sum(t["size"] for t in m.texts) <= (4 << 20)
    if do_xrefs:
        print("\n  CODE XREFS (adrp+add / adrp+ldr):")
        any_xref = False
        for needle, added, meaning, off, vm, full in markers:
            if vm is None or needle not in XREF_MARKERS:
                continue
            for t in m.texts:
                for pc in xrefs_to(m, vm, t):
                    any_xref = True
                    start = func_start(m, pc)
                    print("    %-36s referenced at %#x (function start %s)" %
                          (needle, pc, ("%#x" % start) if start else "not found"))
                    if needle == "uat_sync_outer_tlb_sapt_flush" and start:
                        for line in dump_words(m, start):
                            print(line)
        if not any_xref:
            print("    (no references to xref-tracked markers)")
    else:
        print("\n  CODE XREFS: skipped (large image; pass --xrefs to force)")

    # heuristic verdict against the two T8150 reference profiles
    flush = any(n == "uat_sync_outer_tlb_sapt_flush" and o is not None
                for n, a, me, o, v, f in markers)
    dekker = any(n.startswith("uat_dekker") and o is not None
                 for n, a, me, o, v, f in markers)
    verify = any(n.startswith(("gmmu-tlbi-verification", "verify-gmmu")) and o is not None
                 for n, a, me, o, v, f in markers)
    race = any(n == "VIOLATION_T8110_DART_UNGANG_GAPF_RACE" and o is not None
               for n, a, me, o, v, f in markers)
    print("\n  PROFILE ASSESSMENT (heuristic, SPTM images only):")
    if not flush and not dekker and not verify and not race:
        print("    no post-fix markers at all -> consistent with the PRE-fix (b1) profile")
        print("    (also the expected result for a NON-SPTM image such as XNU:")
        print("     uat_sync_outer_tlb_sapt_flush is absent from every XNU build)")
    else:
        print("    flush entry point : %s" % ("PRESENT" if flush else "absent"))
        print("    Dekker gate       : %s" % ("PRESENT" if dekker else "absent"))
        print("    TLBI verification : %s" % ("PRESENT" if verify else "absent"))
        print("    race-name string  : %s" % ("PRESENT" if race else "absent"))
        if flush and dekker and counts["dmb ish"] >= 20:
            print("    -> consistent with the POST-fix (b3) profile")
        else:
            print("    -> partial match; compare the census numbers with the")
            print("       reference table before drawing a conclusion")
    print()


def main(argv):
    args = [a for a in argv[1:] if a != "--xrefs"]
    force = "--xrefs" in argv
    if not args:
        print(__doc__)
        return 2
    for path in args:
        analyse(path, force_xrefs=force)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
