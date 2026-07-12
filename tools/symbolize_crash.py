#!/usr/bin/env python3
# [stol:infra-crash-diag-format]
# Offline symbolication for ER-301 crash reports (schema v2, see
# docs/CRASH_REPORT_FORMAT.md).
#
# Reads a crash report's Module Map + a directory of matching build artifacts
# (.so / .elf), turns each captured address (pc, lr) into "module + offset" and
# then, if an addr2line is available, into file:line. Stdlib only.
#
# TWO artifact shapes are handled, keyed off the ELF e_type of the matched file:
#
#   * ET_EXEC / ET_DYN  (the AM335x kernel `app.elf`, the emu main + its .so's):
#     the captured address maps linearly onto a link-time address, so
#     `addr2line -e file 0x<offset>` works directly. Unchanged behaviour.
#
#   * ET_REL  (every AM335x *package* .so -- built `-r -nostdlib`, full of
#     zero-based `.text.*` / `.rodata.*` sections from `-ffunction-sections`):
#     the device loader (arch/am335x/hal/dynload/ElfFile.cpp) does NOT map these
#     at their (zero) sh_addr. It REPACKS every SHF_ALLOC non-writable section
#     sequentially into one text blob with 4-byte alignment, in section-header
#     order (see ElfFile.cpp:168-241). So a captured `pc - textBase` is an OFFSET
#     INTO THAT REPACKED BLOB, not a link-time vaddr. Feeding it straight to
#     addr2line (the old bug) yields "??:0" or a confidently-wrong file:line.
#     This tool replicates the loader's deterministic packing to recover the
#     originating section + section-relative offset, names the function from the
#     package's own symbol table (authoritative), and only trusts an
#     `addr2line -j <section>` file:line when it corroborates that name.
#
# The addr2line binary is configurable (env CRASH_ADDR2LINE or --addr2line;
# default arm-none-eabi-addr2line). If it is absent the tool degrades gracefully:
# it still prints the module + section + offset resolution, just without
# file:line.
#
# Run `python3 tools/symbolize_crash.py --selftest` to validate the resolver, the
# ET_REL section-walk, and the addr2line plumbing. The selftest is self
# contained (a synthetic in-memory ELF exercises the pure-Python reader with no
# toolchain); when arm-none-eabi-gcc/nm/addr2line are present it additionally
# builds a REAL relocatable package fixture and cross-checks the resolved
# function against nm.

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

DEFAULT_ADDR2LINE = os.environ.get("CRASH_ADDR2LINE", "arm-none-eabi-addr2line")

# --- ELF constants (ELF32) -------------------------------------------------
ET_REL = 1
ET_EXEC = 2
ET_DYN = 3

SHF_WRITE = 0x1
SHF_ALLOC = 0x2

SHT_SYMTAB = 2

STT_FUNC = 2  # ELF32_ST_TYPE(st_info)

# The loader aligns each packed section by CONFIG_ELF_ALIGN_LOG2 = 2 -> 4 bytes
# (ElfFile.cpp:18-20, ELF_ALIGNUP). Text space and data space are SEPARATE
# allocations (mpTextSpace vs mpDataSpace, ElfFile.cpp:194-217): SHF_ALLOC and
# NOT SHF_WRITE -> text; SHF_ALLOC and SHF_WRITE -> data. Captured PCs are code,
# so we only ever pack + search the text space.
ELF_ALIGN = 1 << 2


def _align_up(n, a=ELF_ALIGN):
    return (n + (a - 1)) & ~(a - 1)


MODULE_RE = re.compile(
    r"^\s*(\S+)\s+text=([0-9a-fA-F]+)(?:\.\.([0-9a-fA-F]+))?"
    r"(?:\s+data=([0-9a-fA-F]+)\.\.([0-9a-fA-F]+))?"
)
ADDR_RE = re.compile(r"\b(pc|lr|sp)=([0-9a-fA-F]+)")


class Module:
    def __init__(self, path, text_lo, text_hi):
        self.path = path
        self.text_lo = text_lo
        self.text_hi = text_hi

    @property
    def is_kernel(self):
        # The module map labels the non-relocated kernel (AM335x app.elf) -- and,
        # on emu, the main program -- literally "kernel".
        return os.path.basename(self.path) == "kernel"

    @property
    def bounded(self):
        # A real text extent (lo..hi with hi>lo). Old-format reports render the
        # kernel as "text=0" (no hi) -> unbounded.
        return self.text_hi is not None and self.text_hi > self.text_lo

    @property
    def relocatable(self):
        # A relocated object (all emu .so's, all AM335x packages) renders a real
        # range and is loaded at text_lo; the kernel is not relocated.
        return self.bounded and not self.is_kernel


STACK_SP_RE = re.compile(r"\bsp=([0-9a-fA-F]+)")
STACK_WORD_RE = re.compile(r"[0-9a-fA-F]{8}")


def parse_report(text):
    """Return (modules, addresses, stack).

    modules   -- list[Module] from the Module Map.
    addresses -- {name: int} from Registers (pc/lr/sp).
    stack     -- {"sp": int|None, "words": [int]} from the Stack Window section
                 (hang-watchdog captures; empty for trap reports).
    """
    modules = []
    addresses = {}
    stack = {"sp": None, "words": []}
    section = None
    for raw in text.splitlines():
        line = raw.rstrip("\n")
        stripped = line.strip()
        if stripped.startswith("--- ") and stripped.endswith(" ---"):
            section = stripped.strip("- ").strip()
            continue
        if section == "Module Map":
            m = MODULE_RE.match(line)
            if m:
                path = m.group(1)
                lo = int(m.group(2), 16)
                hi = int(m.group(3), 16) if m.group(3) else None
                modules.append(Module(path, lo, hi))
        if section == "Registers":
            for name, hexval in ADDR_RE.findall(line):
                addresses[name] = int(hexval, 16)
        if section == "Stack Window":
            # Header line: " sp=<hex> bytes=<n>" (no colon).
            if ":" not in line:
                msp = STACK_SP_RE.search(line)
                if msp:
                    stack["sp"] = int(msp.group(1), 16)
                continue
            # Data line: " <addr>: <w0> <w1> <w2> <w3>". Words are the 8-hex
            # tokens AFTER the colon (the address prefix is excluded); each is a
            # little-endian stack word, ascending address == innermost-first.
            body = line[line.find(":") + 1:]
            for tok in STACK_WORD_RE.findall(body):
                stack["words"].append(int(tok, 16))
    return modules, addresses, stack


class Resolution:
    """The module (if any) an address falls in.

    path      -- module path, or None when the address is outside ALL ranges.
    offset    -- for a relocated module: addr - text_lo (a blob offset for ET_REL
                 packages, a load-relative offset for ET_DYN). For the kernel
                 (non-relocated): the raw addr, which already IS the link-time
                 vaddr addr2line wants against app.elf.
    is_kernel -- the match is the kernel entry.
    note      -- human-readable qualifier (e.g. best-effort / unresolved).
    """

    def __init__(self, path, offset, is_kernel=False, note=None):
        self.path = path
        self.offset = offset
        self.is_kernel = is_kernel
        self.note = note

    @property
    def unresolved(self):
        return self.path is None


def resolve(addr, modules):
    """Attribute an address to a module.

    M1 (bounded kernel, no whole-range fallback): resolve against EVERY bounded
    module range -- packages AND the bounded kernel entry -- and return an
    unresolved '?' for anything outside them all. The old code returned
    ("kernel", addr) for any unmatched address, which confidently mislabels a
    package PC that is missing from the map (>48 loaded, path truncated,
    mid-dlopen) as kernel. Packages live in the od heap (DDR), same space as the
    kernel, so that guess is not safe.
    """
    # 1. Relocated modules (packages, emu .so's): loaded at text_lo.
    for m in modules:
        if m.relocatable and m.text_lo <= addr < m.text_hi:
            return Resolution(m.path, addr - m.text_lo)

    # 2. The kernel. Non-relocated: its PCs map directly onto the kernel .elf, so
    #    the symbolication offset is the RAW addr (a link-time vaddr), not
    #    addr - text_lo.
    kern = next((m for m in modules if m.is_kernel), None)
    if kern is not None:
        if kern.bounded:
            if kern.text_lo <= addr < kern.text_hi:
                return Resolution(kern.path, addr, is_kernel=True)
            # Bounded and outside -> genuinely unresolved.
            return Resolution(None, addr, note="outside all module ranges")
        # Old-format report: kernel has no bounded range. Prefer '?', but keep a
        # clearly-labelled best-effort so pre-M1 reports still say something.
        return Resolution(kern.path, addr, is_kernel=True,
                          note="unbounded kernel entry (old-format, best-effort)")

    # 3. No kernel entry and nothing matched.
    return Resolution(None, addr, note="outside all module ranges")


# ---------------------------------------------------------------------------
# Minimal, stdlib-only ELF32 reader (little-endian).
#
# Enough to (a) sniff e_type, (b) walk section headers to replicate the loader's
# text-space packing, and (c) read the symbol table to name a packed offset.
# ---------------------------------------------------------------------------

class Section:
    __slots__ = ("index", "name", "sh_type", "sh_flags", "sh_addr",
                 "sh_offset", "sh_size", "sh_link", "sh_info", "sh_entsize")

    @property
    def alloc(self):
        return bool(self.sh_flags & SHF_ALLOC)

    @property
    def write(self):
        return bool(self.sh_flags & SHF_WRITE)


class Sym:
    __slots__ = ("name", "value", "size", "info", "shndx")

    @property
    def type(self):
        return self.info & 0xF


def peek_elf_type(path):
    """Return e_type (ET_REL/ET_EXEC/ET_DYN/...) or None if not an ELF we read.

    e_type lives at file offset 16 for both ELF32 and ELF64, so we can sniff it
    without committing to a class."""
    try:
        with open(path, "rb") as f:
            hdr = f.read(20)
    except OSError:
        return None
    if len(hdr) < 20 or hdr[:4] != b"\x7fELF":
        return None
    little = hdr[5] == 1
    e_type = struct.unpack("<H" if little else ">H", hdr[16:18])[0]
    return e_type


class Elf32:
    """A parsed ELF32 little-endian object (section headers + symbol table)."""

    def __init__(self, sections, symbols):
        self.sections = sections            # list[Section], index order
        self.symbols = symbols              # list[Sym]

    @classmethod
    def from_file(cls, path):
        with open(path, "rb") as f:
            data = f.read()
        if data[:4] != b"\x7fELF":
            raise ValueError("not an ELF file: %s" % path)
        if data[4] != 1:  # EI_CLASS ELFCLASS32
            raise ValueError("not ELF32 (class=%d): %s" % (data[4], path))
        if data[5] != 1:  # EI_DATA little-endian
            raise ValueError("not little-endian ELF: %s" % path)

        # Elf32_Ehdr: e_shoff@32, e_shentsize@46, e_shnum@48, e_shstrndx@50.
        (e_shoff,) = struct.unpack_from("<I", data, 32)
        (e_shentsize, e_shnum, e_shstrndx) = struct.unpack_from("<HHH", data, 46)

        sections = []
        raw_names = []  # sh_name index per section, resolved after shstrtab known
        for i in range(e_shnum):
            base = e_shoff + i * e_shentsize
            (sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size,
             sh_link, sh_info, _sh_addralign, sh_entsize) = struct.unpack_from(
                "<10I", data, base)
            s = Section()
            s.index = i
            s.name = ""  # filled below from shstrtab
            s.sh_type = sh_type
            s.sh_flags = sh_flags
            s.sh_addr = sh_addr
            s.sh_offset = sh_offset
            s.sh_size = sh_size
            s.sh_link = sh_link
            s.sh_info = sh_info
            s.sh_entsize = sh_entsize
            sections.append(s)
            raw_names.append(sh_name)

        # Resolve section names from the section-header string table.
        if 0 <= e_shstrndx < len(sections):
            strtab = sections[e_shstrndx]
            blob = data[strtab.sh_offset:strtab.sh_offset + strtab.sh_size]
            for s, name_idx in zip(sections, raw_names):
                s.name = _cstr(blob, name_idx)

        # Symbol table (first SHT_SYMTAB) + its linked string table.
        symbols = []
        for s in sections:
            if s.sh_type != SHT_SYMTAB or s.sh_entsize == 0:
                continue
            link = sections[s.sh_link] if 0 <= s.sh_link < len(sections) else None
            strblob = b""
            if link is not None:
                strblob = data[link.sh_offset:link.sh_offset + link.sh_size]
            n = s.sh_size // s.sh_entsize
            for j in range(n):
                off = s.sh_offset + j * s.sh_entsize
                (st_name, st_value, st_size, st_info, _st_other,
                 st_shndx) = struct.unpack_from("<IIIBBH", data, off)
                sym = Sym()
                sym.name = _cstr(strblob, st_name)
                sym.value = st_value
                sym.size = st_size
                sym.info = st_info
                sym.shndx = st_shndx
                symbols.append(sym)
            break  # one symtab is enough

        return cls(sections, symbols)

    # -- loader packing replication ----------------------------------------
    def pack_text_space(self):
        """Replicate ElfFile.cpp's text-space packing.

        Walk sections in header order; a section participates iff SHF_ALLOC.
        SHF_WRITE sections go to the (separate) DATA space and are skipped here.
        Each placed section starts at the running text pointer (which is already
        4-aligned, since the base is aligned and every advance is a multiple of
        4) and the pointer then advances by ELF_ALIGNUP(sh_size). NOBITS
        non-writable sections participate too (the loader memset()s them into the
        same text allocation) -- so we filter purely on the flags, exactly like
        the loader, never on sh_type.

        Returns list of (section, packed_start).
        """
        packed = []
        cursor = 0
        for s in self.sections:
            if not s.alloc:
                continue
            if s.write:
                continue  # -> data space, a distinct allocation
            packed.append((s, cursor))
            cursor += _align_up(s.sh_size)
        return packed

    def map_blob_offset(self, blob_off):
        """Map a text-blob offset to (section, section_offset), or None."""
        for s, start in self.pack_text_space():
            if s.sh_size == 0:
                continue
            if start <= blob_off < start + s.sh_size:
                return (s, blob_off - start)
        return None

    def function_at(self, section, section_offset):
        """Nearest-preceding STT_FUNC symbol in `section`.

        In an ET_REL object st_value is section-relative, so the function
        covering section_offset is the STT_FUNC symbol with st_shndx ==
        section.index and the largest st_value <= section_offset. This is the
        authoritative name (the package's own symtab); addr2line line info is
        only ever used to corroborate it."""
        best = None
        for sym in self.symbols:
            if sym.type != STT_FUNC:
                continue
            if sym.shndx != section.index:
                continue
            if sym.value <= section_offset and (best is None or
                                                sym.value > best.value):
                best = sym
        if best is None:
            return None
        return (best.name, section_offset - best.value)


def _cstr(blob, off):
    if off < 0 or off >= len(blob):
        return ""
    end = blob.find(b"\x00", off)
    if end < 0:
        end = len(blob)
    return blob[off:end].decode("utf-8", "replace")


# ---------------------------------------------------------------------------
# addr2line plumbing
# ---------------------------------------------------------------------------

def _resolve_exe(addr2line):
    return shutil.which(addr2line) or (
        addr2line if os.path.isfile(addr2line) and os.access(addr2line, os.X_OK)
        else None)


def run_addr2line(addr2line, artifact, offset):
    """Plain (ET_EXEC/ET_DYN) lookup. Returns "func at file:line" or None."""
    exe = _resolve_exe(addr2line)
    if not exe:
        return None
    try:
        out = subprocess.run(
            [exe, "-f", "-C", "-e", artifact, "0x%x" % offset],
            capture_output=True, text=True, timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    lines = [l for l in out.stdout.splitlines() if l.strip()]
    if len(lines) >= 2:
        return "%s at %s" % (lines[0], lines[1])
    if lines:
        return lines[0]
    return None


def run_addr2line_section(addr2line, artifact, section_name, section_offset):
    """Section-relative (ET_REL) lookup: `addr2line -j <section> <off>`.

    Returns (func, file_line) or None. NOTE: for ET_REL objects every section
    has sh_addr 0, so this is only reliable when a section holds a single
    function (the common `-ffunction-sections` case). The caller cross-checks the
    returned func against the symbol table and discards the file:line on
    disagreement -- so this is corroboration only, never the source of truth."""
    exe = _resolve_exe(addr2line)
    if not exe:
        return None
    try:
        out = subprocess.run(
            [exe, "-f", "-C", "-e", artifact, "-j", section_name,
             "0x%x" % section_offset],
            capture_output=True, text=True, timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    lines = [l for l in out.stdout.splitlines() if l.strip()]
    func = lines[0] if lines else None
    file_line = lines[1] if len(lines) >= 2 else None
    if file_line in ("??:0", "??:?"):
        file_line = None
    return (func, file_line)


# ---------------------------------------------------------------------------
# Artifact lookup
# ---------------------------------------------------------------------------

def find_artifact(module_path, build_dir):
    """Locate the .elf/.so for a module by basename inside build_dir."""
    want = os.path.basename(module_path)
    candidates = []
    if want == "kernel":
        for pat in ("kernel", "app.elf", "emu.elf", "pbl.elf", "sbl.elf"):
            candidates.append(pat)
    else:
        candidates.append(want)
    for root, _dirs, files in os.walk(build_dir):
        for f in files:
            base = os.path.basename(f)
            if base == want or base in candidates:
                return os.path.join(root, f)
    if want == "kernel":
        for root, _dirs, files in os.walk(build_dir):
            for f in files:
                if f.endswith(".elf"):
                    return os.path.join(root, f)
    return None


# ---------------------------------------------------------------------------
# ET_REL symbolication (the headline fix)
# ---------------------------------------------------------------------------

def symbolize_package_offset(artifact, blob_off, addr2line):
    """Turn a repacked-text-blob offset into a human description for an ET_REL
    package. Returns a string, e.g.
        "beta_fn (.text.beta_fn+0x8)   fix.c:12"
    """
    try:
        elf = Elf32.from_file(artifact)
    except (OSError, ValueError, struct.error) as e:
        return "(cannot read %s: %s)" % (os.path.basename(artifact), e)

    hit = elf.map_blob_offset(blob_off)
    if hit is None:
        return "(blob offset 0x%x outside packed text space of %s)" % (
            blob_off, os.path.basename(artifact))
    section, sec_off = hit

    fn = elf.function_at(section, sec_off)
    if fn is not None:
        func_name, func_off = fn
        head = "%s (%s+0x%x)" % (func_name, section.name, sec_off)
    else:
        func_name = None
        head = "(%s+0x%x)" % (section.name, sec_off)

    a2l = run_addr2line_section(addr2line, artifact, section.name, sec_off)
    if a2l is not None:
        a2l_func, a2l_line = a2l
        if a2l_line and (func_name is None or a2l_func == func_name):
            return "%s   %s" % (head, a2l_line)
        # addr2line's function disagrees with the symtab (ET_REL sh_addr==0
        # ambiguity across sibling functions in a CU): trust the symtab name,
        # drop the unreliable line.
        return "%s   [ET_REL: line info unavailable]" % head
    return head


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def _enrich(res, build_dir, addr2line):
    """Append the file:line (or section/offset) tail for a resolved address."""
    tail = ""
    artifact = find_artifact(res.path, build_dir)
    if not artifact:
        return "   (no artifact for %s in %s)" % (
            os.path.basename(res.path), build_dir)
    etype = peek_elf_type(artifact)
    if etype == ET_REL and not res.is_kernel:
        tail = "   " + symbolize_package_offset(artifact, res.offset, addr2line)
    else:
        sym = run_addr2line(addr2line, artifact, res.offset)
        if sym:
            tail = "   %s" % sym
        else:
            tail = "   (%s: no line info)" % os.path.basename(artifact)
    return tail


def symbolize(report_text, build_dir, addr2line):
    modules, addresses, stack = parse_report(report_text)
    out_lines = []
    out_lines.append("Modules: %d (%d relocatable)" % (
        len(modules), sum(1 for m in modules if m.relocatable)))
    have_a2l = _resolve_exe(addr2line) is not None
    if not have_a2l:
        out_lines.append(
            "addr2line '%s' not found -- printing module+section+offset only."
            % addr2line)
    for name in ("pc", "lr"):
        if name not in addresses:
            continue
        addr = addresses[name]
        res = resolve(addr, modules)

        if res.unresolved:
            note = " (%s)" % res.note if res.note else ""
            out_lines.append(" %s=%08x -> ?%s" % (name, addr, note))
            continue

        line = " %s=%08x -> %s + 0x%x" % (name, addr, res.path, res.offset)
        if res.note:
            line += " [%s]" % res.note
        if build_dir:
            line += _enrich(res, build_dir, addr2line)
        out_lines.append(line)

    # Hang-watchdog stack-window scan (section 8.4). A hang hands us no register
    # frame, so we scan the raw stack window for words that land in a BOUNDED
    # module .text range and print them innermost-first as a candidate backtrace.
    # A word only counts as a return-address candidate on a confident bounded
    # match (res.note is None) -- the unbounded old-format kernel best-effort is
    # excluded so junk stack words do not all "resolve" to kernel.
    if stack["words"]:
        out_lines.append("--- Stack Window scan ---")
        if stack["sp"] is not None:
            out_lines.append(" window base sp=%08x, %d words" % (
                stack["sp"], len(stack["words"])))
        candidates = []
        for w in stack["words"]:
            res = resolve(w, modules)
            if not res.unresolved and res.note is None:
                candidates.append((w, res))
        if not candidates:
            out_lines.append(" (no in-.text return addresses found)")
        else:
            out_lines.append(" candidate backtrace (innermost first):")
            for addr, res in candidates:
                line = "  %08x -> %s + 0x%x" % (addr, res.path, res.offset)
                if build_dir:
                    line += _enrich(res, build_dir, addr2line)
                out_lines.append(line)
    return "\n".join(out_lines), addresses, modules


# ---------------------------------------------------------------------------
# Selftest
# ---------------------------------------------------------------------------

# New-format report: the kernel carries a BOUNDED text range (M1).
SELFTEST_REPORT = """\
---CRASH REPORT BEGIN
Schema: 2
Kind: data-abort
Thread: audio
--- Registers ---
 pc=800014d0 lr=00001200 sp=4fff0100 psr=60000013
--- Module Map ---
 kernel                   text=80000000..80100000
 core.so                  text=00001000..00002000  data=00002000..00003000
--- Recent Log ---
---CRASH REPORT END
"""

MOCK_ADDR2LINE = """\
#!/usr/bin/env python3
import sys
# args: ... -e <file> [-j <section>] 0x<addr>
print("myFaultingFunc")
print("/src/core/foo.cpp:42")
"""

# Hang-watchdog report: no register frame; a raw Stack Window whose words are a
# mix of in-.text return addresses (kernel + package) and junk (stack addresses,
# zeros, deadbeef). The scan must recover exactly the in-range words, innermost
# (lowest-address == stream order) first, and drop the junk.
SELFTEST_HANG_REPORT = """\
---CRASH REPORT BEGIN
Schema: 2
Kind: hang-watchdog
Thread: audio
--- Registers ---
 pc=00000000 lr=00000000 sp=9ffe0100 psr=00000000
--- Module Map ---
 kernel                   text=80000000..80100000
 core.so                  text=00001000..00002000  data=00002000..00003000
--- Stack Window ---
 sp=9ffe0100 bytes=64
 9ffe0100: 80012abc 00000000 9ffe0140 80013344
 9ffe0110: 00000000 00001500 9ffe0180 80014400
 9ffe0120: deadbeef 00000000 9ffe01c0 00000000
 9ffe0130: 00000000 00000000 9ffe0200 800aabbc
--- Recent Log ---
---CRASH REPORT END
"""


def _build_min_elf():
    """Construct a minimal ELF32-LE ARM ET_REL object in memory.

    Sections (header order): NULL, .text.foo (ALLOC|EXEC, 0x20),
    .text.bar (ALLOC|EXEC, 0x40), .rodata.tbl (ALLOC, 0x10),
    .bss.x (ALLOC|WRITE|NOBITS, 0x8), .symtab, .strtab, .shstrtab.
    Symbols: foo@0 (shndx .text.foo), bar@0 and mid@0x10 (both shndx .text.bar).

    Expected text packing (SHF_ALLOC, !WRITE, +align4):
      .text.foo   @ 0x00 (0x20)
      .text.bar   @ 0x20 (0x40)
      .rodata.tbl @ 0x60 (0x10)
    .bss.x -> data space (skipped). This exercises the pure-Python reader,
    packer, and nearest-preceding-symbol lookup with no toolchain.
    """
    SHT_PROGBITS, SHT_NOBITS, SHT_SYMTAB_, SHT_STRTAB = 1, 8, 2, 3
    A, W, X = 0x2, 0x1, 0x4

    shstr = b"\x00"
    shoff = {}

    def shname(n):
        nonlocal shstr
        shoff[n] = len(shstr)
        shstr += n.encode() + b"\x00"

    for n in (".text.foo", ".text.bar", ".rodata.tbl", ".bss.x",
              ".symtab", ".strtab", ".shstrtab"):
        shname(n)

    strtab = b"\x00"
    symoff = {}

    def symname(n):
        nonlocal strtab
        symoff[n] = len(strtab)
        strtab += n.encode() + b"\x00"

    for n in ("foo", "bar", "mid"):
        symname(n)

    # Symbol table: index 0 is the reserved null symbol.
    def sym(name, value, shndx, typ=STT_FUNC, bind=1):
        info = (bind << 4) | typ
        return struct.pack("<IIIBBH", symoff.get(name, 0), value, 0, info, 0, shndx)

    IDX_TEXT_FOO, IDX_TEXT_BAR = 1, 2
    symtab = b"".join([
        struct.pack("<IIIBBH", 0, 0, 0, 0, 0, 0),
        sym("foo", 0x00, IDX_TEXT_FOO),
        sym("bar", 0x00, IDX_TEXT_BAR),
        sym("mid", 0x10, IDX_TEXT_BAR),
    ])

    EHSIZE = 52
    SHENT = 40
    NSEC = 8
    # Lay out the file: ehdr, then symtab/strtab/shstrtab blobs, then section
    # headers. Alloc sections carry no file bytes (reader never reads them).
    cur = EHSIZE
    symtab_off = cur
    cur += len(symtab)
    strtab_off = cur
    cur += len(strtab)
    shstr_off = cur
    cur += len(shstr)
    # 4-align the section-header table.
    while cur % 4:
        cur += 1
    shtab_off = cur

    def shdr(name, typ, flags, size, offset, link=0, info=0, entsize=0, addralign=1):
        return struct.pack("<10I", shoff.get(name, 0), typ, flags, 0, offset,
                           size, link, info, addralign, entsize)

    IDX_SYMTAB, IDX_STRTAB, IDX_SHSTRTAB = 5, 6, 7
    shdrs = b"".join([
        shdr("", 0, 0, 0, 0),                                    # 0 NULL
        shdr(".text.foo", SHT_PROGBITS, A | X, 0x20, EHSIZE, addralign=4),   # 1
        shdr(".text.bar", SHT_PROGBITS, A | X, 0x40, EHSIZE, addralign=4),   # 2
        shdr(".rodata.tbl", SHT_PROGBITS, A, 0x10, EHSIZE, addralign=4),     # 3
        shdr(".bss.x", SHT_NOBITS, A | W, 0x08, EHSIZE, addralign=4),        # 4
        shdr(".symtab", SHT_SYMTAB_, 0, len(symtab), symtab_off,
             link=IDX_STRTAB, info=1, entsize=16, addralign=4),             # 5
        shdr(".strtab", SHT_STRTAB, 0, len(strtab), strtab_off),            # 6
        shdr(".shstrtab", SHT_STRTAB, 0, len(shstr), shstr_off),            # 7
    ])

    ehdr = b"\x7fELF" + bytes([1, 1, 1, 0]) + b"\x00" * 8   # e_ident (ELF32/LE)
    ehdr += struct.pack("<HHIIIIIHHHHHH",
                        ET_REL,      # e_type
                        40,          # e_machine = EM_ARM
                        1,           # e_version
                        0,           # e_entry
                        0,           # e_phoff
                        shtab_off,   # e_shoff
                        0,           # e_flags
                        EHSIZE,      # e_ehsize
                        0, 0,        # e_phentsize, e_phnum
                        SHENT, NSEC, # e_shentsize, e_shnum
                        IDX_SHSTRTAB)  # e_shstrndx

    body = bytearray(shtab_off - EHSIZE)
    body[symtab_off - EHSIZE:symtab_off - EHSIZE + len(symtab)] = symtab
    body[strtab_off - EHSIZE:strtab_off - EHSIZE + len(strtab)] = strtab
    body[shstr_off - EHSIZE:shstr_off - EHSIZE + len(shstr)] = shstr

    return ehdr + bytes(body) + shdrs


def _selftest_synthetic_reader():
    """Toolchain-free: exercise the pure-Python reader + packer + symtab walk."""
    ok = True
    blob = _build_min_elf()
    tmp = tempfile.NamedTemporaryFile(prefix="symcrash-min-", suffix=".so",
                                      delete=False)
    try:
        tmp.write(blob)
        tmp.close()

        if peek_elf_type(tmp.name) != ET_REL:
            print("FAIL: synthetic ELF e_type != ET_REL")
            return False

        elf = Elf32.from_file(tmp.name)
        packed = {s.name: start for s, start in elf.pack_text_space()}
        want = {".text.foo": 0x00, ".text.bar": 0x20, ".rodata.tbl": 0x60}
        if packed != want:
            print("FAIL: packed text layout %r (want %r)" % (packed, want))
            ok = False
        else:
            print("PASS: text packing .text.foo@0x0 .text.bar@0x20 "
                  ".rodata.tbl@0x60 (.bss.x -> data space, excluded)")

        # blob 0x24 -> .text.bar +0x04 -> bar (bar@0 nearest preceding, mid@0x10)
        hit = elf.map_blob_offset(0x24)
        sec, off = hit
        fn = elf.function_at(sec, off)
        if sec.name == ".text.bar" and off == 0x04 and fn and fn[0] == "bar":
            print("PASS: blob 0x24 -> .text.bar+0x4 -> bar")
        else:
            print("FAIL: blob 0x24 -> %s+0x%x -> %r" % (sec.name, off, fn))
            ok = False

        # blob 0x35 -> .text.bar +0x15 -> mid (nearest preceding STT_FUNC @0x10)
        sec, off = elf.map_blob_offset(0x35)
        fn = elf.function_at(sec, off)
        if sec.name == ".text.bar" and off == 0x15 and fn and fn[0] == "mid":
            print("PASS: blob 0x35 -> .text.bar+0x15 -> mid (nearest-preceding)")
        else:
            print("FAIL: blob 0x35 -> %s+0x%x -> %r" % (sec.name, off, fn))
            ok = False

        # blob 0x62 -> .rodata.tbl +0x02 -> no function
        sec, off = elf.map_blob_offset(0x62)
        fn = elf.function_at(sec, off)
        if sec.name == ".rodata.tbl" and fn is None:
            print("PASS: blob 0x62 -> .rodata.tbl+0x2 -> (no STT_FUNC)")
        else:
            print("FAIL: blob 0x62 -> %s+0x%x -> %r" % (sec.name, off, fn))
            ok = False
    finally:
        os.unlink(tmp.name)
    return ok


FIXTURE_C = """\
#include <stdint.h>
volatile int g_counter;
const int g_table[4] = {10,20,30,40};
int alpha_fn(int x){ g_counter += x; return x*3 + g_table[x&3]; }
int beta_fn(int x){ int s=0; for(int i=0;i<x;i++) s+=alpha_fn(i); return s; }
int gamma_fn(int x){ return beta_fn(x) - alpha_fn(x) + g_table[0]; }
"""


def _selftest_real_fixture():
    """Toolchain path: build a REAL ET_REL package fixture the way mod-builder.mk
    does, resolve a known blob offset, and cross-check the function name against
    nm. Returns (ran, ok)."""
    gcc = _resolve_exe("arm-none-eabi-gcc")
    nm = _resolve_exe("arm-none-eabi-nm")
    a2l = _resolve_exe(DEFAULT_ADDR2LINE) or _resolve_exe("arm-none-eabi-addr2line")
    # Also try the pinned dev toolchain path.
    ti = "/home/bram/ti/gcc-arm-none-eabi-4_9-2015q3/bin"
    if not gcc and os.path.isdir(ti):
        gcc = os.path.join(ti, "arm-none-eabi-gcc")
        nm = nm or os.path.join(ti, "arm-none-eabi-nm")
        a2l = a2l or os.path.join(ti, "arm-none-eabi-addr2line")
    if not (gcc and os.access(gcc, os.X_OK)):
        print("SKIP: arm-none-eabi-gcc absent -- real-fixture cross-check skipped")
        return (False, True)

    ok = True
    tmp = tempfile.mkdtemp(prefix="symcrash-fixture-")
    try:
        cpath = os.path.join(tmp, "fix.c")
        opath = os.path.join(tmp, "fix.o")
        sopath = os.path.join(tmp, "libfixture.so")
        with open(cpath, "w") as f:
            f.write(FIXTURE_C)
        # Mimic scripts/env.mk (-ffunction-sections -fdata-sections) +
        # scripts/mod-builder.mk (-r -nostdlib) package build.
        subprocess.run([gcc, "-std=gnu11", "-c", "-g", "-O2", "-mcpu=cortex-a8",
                        "-ffunction-sections", "-fdata-sections", "-fno-common",
                        cpath, "-o", opath], check=True,
                       capture_output=True, text=True)
        subprocess.run([gcc, "-r", "-nostdlib", "-nodefaultlibs", opath,
                        "-o", sopath], check=True, capture_output=True, text=True)

        if peek_elf_type(sopath) != ET_REL:
            print("FAIL: fixture is not ET_REL")
            return (True, False)

        elf = Elf32.from_file(sopath)
        packed = {s.name: start for s, start in elf.pack_text_space()}

        # Cross-check packed layout against readelf-derived sizes, and pick a
        # blob offset inside a KNOWN function via nm sizes.
        # nm -S gives section-relative value(0) + size; combined with our packing
        # we know the packed start of each .text.<fn> section.
        # Choose the middle of beta_fn.
        beta_start = packed.get(".text.beta_fn")
        if beta_start is None:
            print("FAIL: .text.beta_fn missing from packed layout: %r" % packed)
            return (True, False)

        beta_size = next(s.sh_size for s, _ in elf.pack_text_space()
                         if s.name == ".text.beta_fn")
        blob_off = beta_start + beta_size // 2

        sec, sec_off = elf.map_blob_offset(blob_off)
        fn = elf.function_at(sec, sec_off)
        if not (sec.name == ".text.beta_fn" and fn and fn[0] == "beta_fn"):
            print("FAIL: blob 0x%x -> %s+0x%x -> %r (want beta_fn)" % (
                blob_off, sec.name, sec_off, fn))
            ok = False
        else:
            print("PASS: real fixture blob 0x%x -> beta_fn via %s+0x%x" % (
                blob_off, sec.name, sec_off))

        # nm cross-check: beta_fn must be a text symbol with the size we used.
        if nm and os.access(nm, os.X_OK):
            out = subprocess.run([nm, "-S", sopath], capture_output=True,
                                 text=True)
            found = False
            for ln in out.stdout.splitlines():
                parts = ln.split()
                if len(parts) >= 4 and parts[-1] == "beta_fn" and \
                        parts[-2].lower() == "t":
                    if int(parts[1], 16) == beta_size:
                        found = True
            if found:
                print("PASS: nm confirms beta_fn is text, size 0x%x" % beta_size)
            else:
                print("FAIL: nm did not confirm beta_fn size 0x%x" % beta_size)
                ok = False

        # End-to-end through symbolize_package_offset with real addr2line.
        if a2l and os.access(a2l, os.X_OK):
            desc = symbolize_package_offset(sopath, blob_off, a2l)
            if "beta_fn" in desc and ("fix.c:" in desc or "[ET_REL:" in desc):
                print("PASS: symbolize_package_offset -> %r" % desc)
            else:
                print("FAIL: symbolize_package_offset -> %r" % desc)
                ok = False

            # The known-hard gamma_fn case: addr2line -j mis-resolves it to a
            # sibling; the symtab cross-check must still name gamma_fn (never a
            # confidently-wrong sibling line).
            if ".text.gamma_fn" in packed:
                goff = packed[".text.gamma_fn"] + 4
                gdesc = symbolize_package_offset(sopath, goff, a2l)
                if gdesc.startswith("gamma_fn"):
                    print("PASS: gamma_fn resolves to gamma_fn (no sibling "
                          "mis-line): %r" % gdesc)
                else:
                    print("FAIL: gamma_fn mis-resolved: %r" % gdesc)
                    ok = False
    except subprocess.CalledProcessError as e:
        print("FAIL: fixture build failed: %s\n%s" % (e, e.stderr))
        ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return (True, ok)


def selftest():
    ok = True

    print("== M1 resolver (bounded kernel, '?' outside all ranges) ==")
    modules, addresses, _stack = parse_report(SELFTEST_REPORT)
    assert addresses.get("pc") == 0x800014d0, addresses

    # pc in the bounded kernel range -> kernel, RAW addr (non-relocated).
    res = resolve(0x800014d0, modules)
    if res.path and os.path.basename(res.path) == "kernel" and \
            res.offset == 0x800014d0 and res.is_kernel:
        print("PASS: pc in bounded kernel range -> kernel + raw vaddr")
    else:
        print("FAIL: kernel resolve -> path=%r off=0x%x kern=%r" % (
            res.path, res.offset, res.is_kernel))
        ok = False

    # lr in core.so package range -> core.so + (addr - lo).
    res = resolve(0x1200, modules)
    if res.path == "core.so" and res.offset == 0x200:
        print("PASS: pc in package range -> core.so + 0x200")
    else:
        print("FAIL: package resolve -> %r + 0x%x" % (res.path, res.offset))
        ok = False

    # Address outside EVERY range (packages + bounded kernel) -> '?'.
    res = resolve(0x40000000, modules)
    if res.unresolved:
        print("PASS: out-of-all-ranges address -> '?' (no kernel fallback)")
    else:
        print("FAIL: out-of-range should be '?', got %r + 0x%x" % (
            res.path, res.offset))
        ok = False

    # Old-format report (unbounded kernel) -> labelled best-effort, not '?'.
    old = SELFTEST_REPORT.replace(
        "text=80000000..80100000", "text=0")
    om, _, _ = parse_report(old)
    res = resolve(0xdeadbeef, om)
    if res.path and os.path.basename(res.path) == "kernel" and res.note:
        print("PASS: old-format unbounded kernel -> labelled best-effort")
    else:
        print("FAIL: old-format kernel -> %r (%r)" % (res.path, res.note))
        ok = False

    print("\n== hang-watchdog stack-window scan ==")
    hmods, haddrs, hstack = parse_report(SELFTEST_HANG_REPORT)
    if hstack["sp"] == 0x9ffe0100 and len(hstack["words"]) == 16:
        print("PASS: parsed Stack Window sp=9ffe0100, 16 words")
    else:
        print("FAIL: stack parse sp=%r words=%d" % (
            hstack["sp"], len(hstack["words"])))
        ok = False

    cands = [(w, resolve(w, hmods)) for w in hstack["words"]]
    cands = [(w, r) for w, r in cands if not r.unresolved and r.note is None]
    want = [0x80012abc, 0x80013344, 0x00001500, 0x80014400, 0x800aabbc]
    if [w for w, _ in cands] == want:
        print("PASS: scan recovered 5 in-.text words innermost-first, junk dropped")
    else:
        print("FAIL: scan candidates %r (want %r)" % (
            [hex(w) for w, _ in cands], [hex(w) for w in want]))
        ok = False

    # 00001500 lands in the relocated package -> core.so + 0x500; the kernel word
    # keeps its raw (non-relocated) address as the offset.
    hout, _, _ = symbolize(SELFTEST_HANG_REPORT, None, DEFAULT_ADDR2LINE)
    if ("candidate backtrace (innermost first):" in hout and
            "80012abc -> kernel + 0x80012abc" in hout and
            "00001500 -> core.so + 0x500" in hout):
        print("PASS: symbolize() renders the candidate backtrace")
    else:
        print("FAIL: hang symbolize output:\n%s" % hout)
        ok = False

    print("\n== ET_REL section-walk (pure-Python, synthetic ELF) ==")
    if not _selftest_synthetic_reader():
        ok = False

    print("\n== ET_REL real package fixture (needs arm-none-eabi toolchain) ==")
    _ran, fok = _selftest_real_fixture()
    if not fok:
        ok = False

    print("\n== ET_EXEC / kernel path + graceful degrade (mock addr2line) ==")
    tmp = tempfile.mkdtemp(prefix="symcrash-selftest-")
    try:
        build = os.path.join(tmp, "build")
        os.makedirs(build)
        # A real (tiny) ELF so peek_elf_type sees ET_REL... no: for the kernel
        # path we need an ET_EXEC-ish artifact. The mock addr2line ignores the
        # file contents, and peek_elf_type on a non-ELF returns None -> the code
        # takes the plain addr2line path (not ET_REL), which is what we want for
        # the kernel. Write plain files.
        with open(os.path.join(build, "core.so"), "w") as f:
            f.write("not-an-elf")
        with open(os.path.join(build, "app.elf"), "w") as f:
            f.write("not-an-elf")

        mock = os.path.join(tmp, "addr2line")
        with open(mock, "w") as f:
            f.write(MOCK_ADDR2LINE)
        os.chmod(mock, 0o755)

        # core.so is not a real ELF here (peek returns None) so it takes the
        # plain path -> mock yields file:line. pc(kernel) also plain path.
        out, _, _ = symbolize(SELFTEST_REPORT, build, mock)
        if "kernel + 0x800014d0" in out and "/src/core/foo.cpp:42" in out:
            print("PASS: kernel + package take plain addr2line path -> file:line")
        else:
            print("FAIL: mock addr2line output:\n%s" % out)
            ok = False

        out, _, _ = symbolize(
            SELFTEST_REPORT, build, os.path.join(tmp, "nonexistent-a2l"))
        if "core.so + 0x200" in out and "not found" in out:
            print("PASS: missing addr2line degrades to module+offset")
        else:
            print("FAIL: degrade path output:\n%s" % out)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\nSELFTEST %s" % ("OK" if ok else "FAILED"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="Symbolize an ER-301 crash report.")
    ap.add_argument("report", nargs="?", help="path to a crash report (or a "
                    "crash.log; the last report block is used)")
    ap.add_argument("-b", "--build-dir", help="directory of matching .so/.elf "
                    "build artifacts")
    ap.add_argument("--addr2line", default=DEFAULT_ADDR2LINE,
                    help="addr2line binary (default: %s, or $CRASH_ADDR2LINE)"
                    % DEFAULT_ADDR2LINE)
    ap.add_argument("--selftest", action="store_true",
                    help="run the built-in self test (no report/toolchain needed)")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if not args.report:
        ap.error("a report path is required (or use --selftest)")

    with open(args.report, "r") as f:
        text = f.read()
    blocks = text.split("---CRASH REPORT BEGIN")
    if len(blocks) > 1:
        text = "---CRASH REPORT BEGIN" + blocks[-1]

    out, addresses, modules = symbolize(text, args.build_dir, args.addr2line)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
