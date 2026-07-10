#!/usr/bin/env python3
# [stol:infra-crash-diag-format]
# Offline symbolication for ER-301 crash reports (schema v2, see
# docs/CRASH_REPORT_FORMAT.md).
#
# Reads a crash report's Module Map + a directory of matching build artifacts
# (.so / .elf), turns each captured address (pc, lr, and any stack addresses)
# into "package.so + offset" and then, if an addr2line is available, into
# file:line. Stdlib only.
#
# The addr2line binary is configurable (env CRASH_ADDR2LINE or --addr2line;
# default arm-none-eabi-addr2line). If it is absent the tool degrades gracefully:
# it still prints the package + offset resolution, just without file:line.
#
# Run `python3 tools/symbolize_crash.py --selftest` to validate the resolver +
# addr2line plumbing against a synthetic report and a mock addr2line, with no real
# crash and no cross toolchain required.

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

DEFAULT_ADDR2LINE = os.environ.get("CRASH_ADDR2LINE", "arm-none-eabi-addr2line")

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
    def relocatable(self):
        # kernel renders as "text=0" (no range) and is not relocated.
        return self.text_hi is not None and self.text_hi > self.text_lo


def parse_report(text):
    """Return (modules, addresses) where addresses maps name -> int."""
    modules = []
    addresses = {}
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
    return modules, addresses


def resolve(addr, modules):
    """Return (module_path, offset). A raw address in no relocated module is
    attributed to the kernel (which is not relocated: offset == addr)."""
    for m in modules:
        if m.relocatable and m.text_lo <= addr < m.text_hi:
            return (m.path, addr - m.text_lo)
    return ("kernel", addr)


def find_artifact(module_path, build_dir):
    """Locate the .elf/.so for a module by basename inside build_dir."""
    want = os.path.basename(module_path)
    candidates = []
    if want == "kernel":
        # Common kernel artifact names, most specific first.
        for pat in ("kernel", "app.elf", "emu.elf", "pbl.elf", "sbl.elf"):
            candidates.append(pat)
    else:
        candidates.append(want)
    for root, _dirs, files in os.walk(build_dir):
        for f in files:
            base = os.path.basename(f)
            if base == want or base in candidates:
                return os.path.join(root, f)
    # Kernel fallback: first *.elf found.
    if want == "kernel":
        for root, _dirs, files in os.walk(build_dir):
            for f in files:
                if f.endswith(".elf"):
                    return os.path.join(root, f)
    return None


def run_addr2line(addr2line, artifact, offset):
    """Return "func at file:line" or None if addr2line is unavailable/failed."""
    exe = shutil.which(addr2line) or (
        addr2line if os.path.isfile(addr2line) and os.access(addr2line, os.X_OK)
        else None
    )
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


def symbolize(report_text, build_dir, addr2line):
    modules, addresses = parse_report(report_text)
    out_lines = []
    out_lines.append("Modules: %d (%d relocatable)" % (
        len(modules), sum(1 for m in modules if m.relocatable)))
    have_a2l = shutil.which(addr2line) is not None or (
        os.path.isfile(addr2line) and os.access(addr2line, os.X_OK))
    if not have_a2l:
        out_lines.append(
            "addr2line '%s' not found -- printing package+offset only." % addr2line)
    for name in ("pc", "lr"):
        if name not in addresses:
            continue
        addr = addresses[name]
        module_path, offset = resolve(addr, modules)
        line = " %s=%08x -> %s + 0x%x" % (name, addr, module_path, offset)
        if build_dir:
            artifact = find_artifact(module_path, build_dir)
            if artifact:
                sym = run_addr2line(addr2line, artifact, offset)
                if sym:
                    line += "   %s" % sym
                else:
                    line += "   (%s: no line info)" % os.path.basename(artifact)
            else:
                line += "   (no artifact for %s in %s)" % (
                    os.path.basename(module_path), build_dir)
        out_lines.append(line)
    return "\n".join(out_lines), addresses, modules


# ---------------------------------------------------------------------------
# Selftest
# ---------------------------------------------------------------------------

SELFTEST_REPORT = """\
---CRASH REPORT BEGIN
Schema: 2
Kind: data-abort
Thread: audio
--- Registers ---
 pc=000014d0 lr=00001200 sp=4fff0100 psr=60000013
--- Module Map ---
 kernel                   text=0
 core.so                  text=00001000..00002000  data=00002000..00003000
--- Recent Log ---
---CRASH REPORT END
"""

MOCK_ADDR2LINE = """\
#!/usr/bin/env python3
import sys
# args: -f -C -e <file> 0x<addr>
addr = sys.argv[-1]
print("myFaultingFunc")
print("/src/core/foo.cpp:42")
"""


def selftest():
    ok = True

    # 1. Pure resolver: pc in core.so range -> core.so + offset.
    modules, addresses = parse_report(SELFTEST_REPORT)
    assert addresses.get("pc") == 0x14d0, addresses
    module_path, offset = resolve(0x14d0, modules)
    if not (module_path == "core.so" and offset == 0x4d0):
        print("FAIL: resolve pc -> %s + 0x%x (want core.so + 0x4d0)" % (
            module_path, offset))
        ok = False
    else:
        print("PASS: pc resolves to core.so + 0x4d0")

    # lr in no package range -> kernel + raw addr.
    module_path, offset = resolve(0x1200 - 0x1000 + 0x9000, modules)  # 0x9200
    if module_path == "kernel" and offset == 0x9200:
        print("PASS: out-of-range address attributed to kernel")
    else:
        print("FAIL: kernel fallback -> %s + 0x%x" % (module_path, offset))
        ok = False

    tmp = tempfile.mkdtemp(prefix="symcrash-selftest-")
    try:
        # Fake build dir with a core.so artifact (content irrelevant: addr2line is
        # mocked) and a kernel elf.
        build = os.path.join(tmp, "build")
        os.makedirs(build)
        with open(os.path.join(build, "core.so"), "w") as f:
            f.write("fake")
        with open(os.path.join(build, "app.elf"), "w") as f:
            f.write("fake")

        # 2. With a mock addr2line, we get file:line.
        mock = os.path.join(tmp, "addr2line")
        with open(mock, "w") as f:
            f.write(MOCK_ADDR2LINE)
        os.chmod(mock, 0o755)
        out, _, _ = symbolize(SELFTEST_REPORT, build, mock)
        if "core.so + 0x4d0" in out and "/src/core/foo.cpp:42" in out:
            print("PASS: mock addr2line yields file:line")
        else:
            print("FAIL: mock addr2line output:\n%s" % out)
            ok = False

        # 3. Missing addr2line degrades gracefully (still package+offset).
        out, _, _ = symbolize(
            SELFTEST_REPORT, build, os.path.join(tmp, "nonexistent-a2l"))
        if "core.so + 0x4d0" in out and "not found" in out:
            print("PASS: missing addr2line degrades to package+offset")
        else:
            print("FAIL: degrade path output:\n%s" % out)
            ok = False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("SELFTEST %s" % ("OK" if ok else "FAILED"))
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
    # If given a multi-report crash.log, symbolize the last block.
    blocks = text.split("---CRASH REPORT BEGIN")
    if len(blocks) > 1:
        text = "---CRASH REPORT BEGIN" + blocks[-1]

    out, addresses, modules = symbolize(text, args.build_dir, args.addr2line)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
