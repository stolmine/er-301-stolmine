#!/usr/bin/env python3
"""emu_test.py — automated test-harness runner for the ER-301 headless emulator.

Discovers tests/emu/*.test, runs each against a per-test hermetic instance of the
headless emulator, and reports results as TAP (Test Anything Protocol). Exit 0 iff
every test passes.

Stdlib only. See tests/emu/README.md for the test-file format and conventions, and
planning/headless-emu-plan.md (§2 protocol, §6 determinacy, §7 harness) for design.

  tools/emu_test.py                 run the whole suite (TAP to stdout)
  tools/emu_test.py TEST [TEST...]  run only the named tests (basenames or paths)
  tools/emu_test.py --selftest      validate the runner against a built-in fake emu

Environment:
  STOL_EMU_BIN            emu binary (default testing/linux-x86_64/emu/emu.elf).
                         A path ending in .py is run with the current interpreter
                         (used by --selftest; also handy for a scripted stand-in).
  STOL_EMU_TEST_TIMEOUT  per-test watchdog seconds (default 60).
  STOL_UPDATE_GOLDEN=1   write/overwrite goldens instead of comparing.
  STOL_EMU_PKG_DIR       source dir for `!packages` .pkg files (see below).
  STOL_KEEP_SANDBOX=1    keep every sandbox, not just failed ones.

  (test-location overrides, mainly for --selftest / out-of-tree runs)
  STOL_EMU_TESTS_DIR     dir of *.test files       (default <repo>/tests/emu)
  STOL_EMU_FIXTURES_DIR  fixtures root              (default <repo>/testing-assets/emu/fixtures)
  STOL_EMU_GOLDEN_DIR    goldens root               (default <repo>/testing-assets/emu/goldens)
  STOL_EMU_XROOT         xroot for the Lua interp   (default <repo>/xroot)
"""

import os
import re
import select
import shutil
import subprocess
import sys
import tempfile

# ─────────────────────────────────────────────────────────────────────────────
# INTEGRATION SEAM: the emulator's control replies share stdout with log noise.
# The sibling emu core marks reply lines with a sigil (see planning/headless-emu-
# plan.md §1). The runner treats every stdout line beginning with REPLY_SIGIL as a
# reply and everything else as log noise. If the core picks a different sigil, this
# ONE constant is the only place to change.
REPLY_SIGIL = "@"
# The unsolicited line the firmware emits once the Lua control-drain is live
# (plan §5). Scripts start only after it arrives.
READY_TOKEN = "ready"
# ─────────────────────────────────────────────────────────────────────────────

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _env_path(name, default):
    v = os.environ.get(name)
    return os.path.abspath(v) if v else default


class Config:
    def __init__(self):
        self.emu_bin = os.environ.get(
            "STOL_EMU_BIN", os.path.join(REPO_ROOT, "testing/linux-x86_64/emu/emu.elf")
        )
        self.tests_dir = _env_path("STOL_EMU_TESTS_DIR", os.path.join(REPO_ROOT, "tests/emu"))
        self.fixtures_dir = _env_path(
            "STOL_EMU_FIXTURES_DIR", os.path.join(REPO_ROOT, "testing-assets/emu/fixtures")
        )
        self.goldens_dir = _env_path(
            "STOL_EMU_GOLDEN_DIR", os.path.join(REPO_ROOT, "testing-assets/emu/goldens")
        )
        self.xroot = _env_path("STOL_EMU_XROOT", os.path.join(REPO_ROOT, "xroot"))
        self.timeout = float(os.environ.get("STOL_EMU_TEST_TIMEOUT", "60"))
        self.update_golden = os.environ.get("STOL_UPDATE_GOLDEN") == "1"
        self.keep_sandbox = os.environ.get("STOL_KEEP_SANDBOX") == "1"
        self.pkg_dir = os.environ.get("STOL_EMU_PKG_DIR")

    def pkg_search_dirs(self):
        """Ordered candidate dirs to source `!packages` .pkg archives from."""
        dirs = []
        if self.pkg_dir:
            dirs.append(self.pkg_dir)
        dirs.append(os.path.join(REPO_ROOT, "testing/linux-x86_64/mods"))
        dirs.append(os.path.expanduser("~/.od/front/ER-301/packages"))
        dirs.append(os.path.expanduser("~/.od/rear"))
        return dirs


# ── test-file model ──────────────────────────────────────────────────────────

class Directive:
    """A parsed line: kind is 'cmd' | 'golden' | 'assert' | 'expect' | 'packages'."""

    def __init__(self, kind, arg, lineno, raw):
        self.kind = kind
        self.arg = arg
        self.lineno = lineno
        self.raw = raw


def parse_test(path):
    """Parse a .test file into (packages, directives)."""
    packages = []
    directives = []
    with open(path, "r") as f:
        for i, raw in enumerate(f, start=1):
            line = raw.rstrip("\n")
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if stripped.startswith("!"):
                parts = stripped[1:].split(None, 1)
                name = parts[0]
                arg = parts[1] if len(parts) > 1 else ""
                if name == "packages":
                    packages.extend(arg.split())
                elif name in ("golden", "assert", "expect"):
                    directives.append(Directive(name, arg, i, stripped))
                else:
                    raise ValueError("%s:%d: unknown directive !%s" % (path, i, name))
            else:
                # A verbatim control-protocol command.
                directives.append(Directive("cmd", stripped, i, stripped))
    return packages, directives


# ── sandbox assembly (emu-hermetic-sandbox) ──────────────────────────────────

def find_package(name, search_dirs):
    """Find a `<name>-*.pkg` or `<name>.pkg` archive in the search dirs."""
    pat = re.compile(r"^" + re.escape(name) + r"(-.*)?\.pkg$")
    for d in search_dirs:
        if not d or not os.path.isdir(d):
            continue
        matches = sorted(fn for fn in os.listdir(d) if pat.match(fn))
        if matches:
            # Highest-sorting version wins (lexical; good enough for fixtures).
            return os.path.join(d, matches[-1])
    return None


def assemble_sandbox(cfg, packages):
    """Build a hermetic FRONT_ROOT/REAR_ROOT sandbox from committed fixtures.

    Returns (sandbox_dir, config_path) or raises on a fatal assembly error.
    """
    sandbox = tempfile.mkdtemp(prefix="emu-test-")
    front = os.path.join(sandbox, "front")
    rear = os.path.join(sandbox, "rear")

    fx_front = os.path.join(cfg.fixtures_dir, "front")
    fx_rear = os.path.join(cfg.fixtures_dir, "rear")
    if os.path.isdir(fx_front):
        shutil.copytree(fx_front, front)
    else:
        os.makedirs(front, exist_ok=True)
    if os.path.isdir(fx_rear):
        shutil.copytree(fx_rear, rear)
    else:
        os.makedirs(rear, exist_ok=True)

    # `!packages NAME` — copy core-*.pkg etc. into the front package repository
    # (0:/ER-301/packages, per xroot/Package/Manager.lua:51). NOTE: the plan draft
    # said "rear root"; the emu actually reads the package repo from the FRONT root
    # and installs into rear libs. See tests/emu/README.md.
    if packages:
        repo = os.path.join(front, "ER-301", "packages")
        os.makedirs(repo, exist_ok=True)
        search = cfg.pkg_search_dirs()
        missing = []
        for name in packages:
            src = find_package(name, search)
            if src is None:
                missing.append(name)
                continue
            shutil.copy2(src, os.path.join(repo, os.path.basename(src)))
        if missing:
            raise RuntimeError(
                "packages not found: %s (searched %s; set STOL_EMU_PKG_DIR)"
                % (", ".join(missing), os.pathsep.join(d for d in search if d))
            )

    config_path = os.path.join(sandbox, "emu.config")
    with open(config_path, "w") as f:
        f.write("# Generated by tools/emu_test.py — hermetic per-test sandbox.\n")
        f.write("XROOT %s\n" % cfg.xroot)
        f.write("FRONT_ROOT %s\n" % front)
        f.write("REAR_ROOT %s\n" % rear)
        f.write("FRONT_PRESENT true\n")
        f.write("REAR_PRESENT true\n")
    return sandbox, config_path


# ── the emulator process wrapper ─────────────────────────────────────────────

class EmuProcess:
    def __init__(self, cfg, config_path):
        argv = self._argv(cfg.emu_bin, config_path)
        env = dict(os.environ)
        env["SDL_AUDIODRIVER"] = "dummy"
        env["SDL_VIDEODRIVER"] = "dummy"
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
            text=True,
            bufsize=1,  # line-buffered
            cwd=REPO_ROOT,
        )
        self.log = []  # captured non-reply lines, for failure diagnostics

    @staticmethod
    def _argv(emu_bin, config_path):
        base = [emu_bin, "--headless", "--seed", "301", "-c", config_path]
        if emu_bin.endswith(".py"):
            return [sys.executable] + base
        return base

    def send(self, line):
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def read_reply(self, deadline):
        """Block until a REPLY_SIGIL line arrives or the deadline passes.

        Non-reply lines are captured as log noise. Returns the reply payload
        (sigil stripped) or None on timeout / EOF.
        """
        while True:
            remaining = deadline - _now()
            if remaining <= 0:
                return None
            r, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not r:
                return None
            line = self.proc.stdout.readline()
            if line == "":
                return None  # EOF: process exited
            line = line.rstrip("\n")
            if line.startswith(REPLY_SIGIL):
                return line[len(REPLY_SIGIL):].strip()
            self.log.append(line)

    def kill(self):
        try:
            self.proc.kill()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            pass


def _now():
    import time
    return time.monotonic()


# ── reply interpretation (integration seam) ─────────────────────────────────
# A reply payload is either an error ("err ...") or a success ("ok [detail]").
# For `lua`, the plan carries the pcall result tostring'd. The exact framing
# (whether it is "ok true" or bare "true") is still settling on the core side, so
# normalize both here in one place.

def reply_is_err(payload):
    return payload is not None and payload.startswith("err")


def reply_value(payload):
    """Extract the meaningful value from a reply, tolerating an 'ok ' prefix."""
    if payload is None:
        return None
    if payload == "ok":
        return ""
    if payload.startswith("ok "):
        return payload[3:].strip()
    return payload.strip()


# ── running a single test ────────────────────────────────────────────────────

class TestResult:
    def __init__(self, name):
        self.name = name
        self.ok = False
        self.reason = ""
        self.detail = ""      # e.g. "updated" for a regenerated golden
        self.sandbox = None
        self.log = []


def run_test(cfg, path):
    name = os.path.splitext(os.path.basename(path))[0]
    result = TestResult(name)
    try:
        packages, directives = parse_test(path)
    except Exception as e:
        result.reason = str(e)
        return result

    try:
        sandbox, config_path = assemble_sandbox(cfg, packages)
    except Exception as e:
        result.reason = "sandbox: %s" % e
        return result
    result.sandbox = sandbox

    emu = None
    deadline = _now() + cfg.timeout
    try:
        emu = EmuProcess(cfg, config_path)

        # Wait for the unsolicited ready line before the first command (plan §5).
        payload = emu.read_reply(deadline)
        if payload is None:
            result.reason = "watchdog: no '%s' before timeout/exit" % READY_TOKEN
            result.log = emu.log[:]
            return result
        if reply_value(payload) != READY_TOKEN and payload != READY_TOKEN:
            result.reason = "expected '%s', got %r" % (READY_TOKEN, payload)
            result.log = emu.log[:]
            return result

        last_reply = None
        for d in directives:
            if d.kind == "cmd":
                emu.send(d.arg)
                last_reply = emu.read_reply(deadline)
                if last_reply is None:
                    result.reason = "watchdog: %s:%d '%s' no reply" % (name, d.lineno, d.arg)
                    result.log = emu.log[:]
                    return result
                if reply_is_err(last_reply):
                    result.reason = "%s:%d '%s' -> %s" % (name, d.lineno, d.arg, last_reply)
                    result.log = emu.log[:]
                    return result

            elif d.kind == "assert":
                emu.send("lua %s" % d.arg)
                last_reply = emu.read_reply(deadline)
                if last_reply is None:
                    result.reason = "watchdog: %s:%d !assert no reply" % (name, d.lineno)
                    result.log = emu.log[:]
                    return result
                if reply_value(last_reply) != "true":
                    result.reason = "%s:%d !assert %s -> %r" % (name, d.lineno, d.arg, last_reply)
                    result.log = emu.log[:]
                    return result

            elif d.kind == "expect":
                if last_reply is None:
                    result.reason = "%s:%d !expect with no preceding reply" % (name, d.lineno)
                    return result
                if re.search(d.arg, last_reply) is None:
                    result.reason = "%s:%d !expect /%s/ vs %r" % (name, d.lineno, d.arg, last_reply)
                    result.log = emu.log[:]
                    return result

            elif d.kind == "golden":
                ok, reason, detail = _do_golden(cfg, emu, name, d, sandbox, deadline)
                if not ok:
                    result.reason = reason
                    result.log = emu.log[:]
                    return result
                if detail:
                    result.detail = detail
                last_reply = None

        # Best-effort clean shutdown if the script did not `quit` itself.
        try:
            emu.send("quit")
            emu.read_reply(_now() + 5)
        except Exception:
            pass

        result.ok = True
        result.log = emu.log[:]
        return result
    finally:
        if emu is not None:
            emu.kill()
        # Keep the sandbox on failure (or when asked) for debugging.
        if result.ok and not cfg.keep_sandbox:
            shutil.rmtree(sandbox, ignore_errors=True)


def _do_golden(cfg, emu, test_name, d, sandbox, deadline):
    """Handle `!golden NAME`. Returns (ok, reason, detail)."""
    shot_name = d.arg.strip()
    shot_path = os.path.join(sandbox, shot_name + ".png")
    emu.send("cap %s" % shot_path)
    payload = emu.read_reply(deadline)
    if payload is None:
        return False, "watchdog: %s:%d cap no reply" % (test_name, d.lineno), ""
    if reply_is_err(payload):
        return False, "%s:%d cap -> %s" % (test_name, d.lineno, payload), ""
    if not os.path.exists(shot_path):
        return False, "%s:%d cap produced no file %s" % (test_name, d.lineno, shot_path), ""

    golden = os.path.join(cfg.goldens_dir, test_name, shot_name + ".png")
    if cfg.update_golden:
        os.makedirs(os.path.dirname(golden), exist_ok=True)
        shutil.copyfile(shot_path, golden)
        return True, "", "updated"
    if not os.path.exists(golden):
        return (
            False,
            "%s:%d golden missing: %s (run with STOL_UPDATE_GOLDEN=1 to create)"
            % (test_name, d.lineno, golden),
            "",
        )
    with open(shot_path, "rb") as a, open(golden, "rb") as b:
        if a.read() != b.read():
            return (
                False,
                "%s:%d golden mismatch: %s (STOL_UPDATE_GOLDEN=1 to accept)"
                % (test_name, d.lineno, shot_name),
                "",
            )
    return True, "", ""


# ── discovery + suite ────────────────────────────────────────────────────────

def discover_tests(cfg, selectors=None):
    if not os.path.isdir(cfg.tests_dir):
        return []
    tests = sorted(
        os.path.join(cfg.tests_dir, fn)
        for fn in os.listdir(cfg.tests_dir)
        if fn.endswith(".test")
    )
    if selectors:
        wanted = set()
        for s in selectors:
            wanted.add(os.path.splitext(os.path.basename(s))[0])
        tests = [t for t in tests if os.path.splitext(os.path.basename(t))[0] in wanted]
    return tests


def run_suite(cfg, selectors=None, emit=print):
    """Run the suite, emitting TAP via `emit`. Returns True iff all passed."""
    tests = discover_tests(cfg, selectors)
    emit("TAP version 13")
    emit("1..%d" % len(tests))
    all_ok = True
    for i, path in enumerate(tests, start=1):
        result = run_test(cfg, path)
        if result.ok:
            suffix = (" # %s" % result.detail) if result.detail else ""
            emit("ok %d - %s%s" % (i, result.name, suffix))
        else:
            all_ok = False
            emit("not ok %d - %s # %s" % (i, result.name, result.reason))
            if result.sandbox and os.path.isdir(result.sandbox):
                emit("# sandbox kept: %s" % result.sandbox)
            for line in result.log[-20:]:
                emit("# emu: %s" % line)
    return all_ok


# ── self-test: validate the runner against a built-in fake emu ───────────────
#
# The fake emu speaks the control protocol (plan §2) well enough to exercise every
# runner path BEFORE the real core lands. It ignores --headless/--seed and reads
# REAR_ROOT/FRONT_ROOT from the -c config so hermeticity can be probed.

FAKE_EMU = r'''#!/usr/bin/env python3
import sys, os, time

def cfg_get(path, key):
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(None, 1)
                if len(parts) == 2 and parts[0] == key:
                    return parts[1]
    except OSError:
        pass
    return None

FIXED_PNG = b"\x89PNG-FAKE-DETERMINISTIC-BYTES\n"

def main():
    config_path = None
    args = sys.argv[1:]
    for i, a in enumerate(args):
        if a == "-c" and i + 1 < len(args):
            config_path = args[i + 1]
    rear = cfg_get(config_path, "REAR_ROOT") if config_path else None

    def reply(s):
        sys.stdout.write("@" + s + "\n")
        sys.stdout.flush()

    # unsolicited ready
    reply("ready")

    for raw in sys.stdin:
        line = raw.rstrip("\n").strip()
        if not line:
            continue
        parts = line.split(None, 1)
        cmd = parts[0]
        arg = parts[1] if len(parts) > 1 else ""
        if cmd == "quit":
            reply("ok")
            return
        elif cmd == "hang":
            # never replies -> exercises the watchdog
            while True:
                time.sleep(3600)
        elif cmd == "lua":
            # 'bleed' probe: count marker files in rear, then drop one.
            if arg.strip() == "bleed":
                n = 0
                if rear and os.path.isdir(rear):
                    n = len([x for x in os.listdir(rear) if x.startswith("marker-")])
                    open(os.path.join(rear, "marker-%d" % n), "w").close()
                reply("ok %d" % n)
            else:
                # echo the expression back as the tostring'd result
                reply("ok %s" % arg)
        elif cmd == "cap":
            try:
                with open(arg, "wb") as f:
                    f.write(FIXED_PNG)
                reply("ok")
            except OSError as e:
                reply("err %s" % e)
        else:
            reply("ok")

if __name__ == "__main__":
    main()
'''


def _selftest():
    import time

    tmp = tempfile.mkdtemp(prefix="emu-selftest-")
    failures = []

    def check(cond, msg):
        if not cond:
            failures.append(msg)
        marker = "PASS" if cond else "FAIL"
        print("  [%s] %s" % (marker, msg))

    # Materialize the fake emu.
    fake = os.path.join(tmp, "fake_emu.py")
    with open(fake, "w") as f:
        f.write(FAKE_EMU)

    # Minimal fixtures.
    fixtures = os.path.join(tmp, "fixtures")
    os.makedirs(os.path.join(fixtures, "front", "ER-301"))
    os.makedirs(os.path.join(fixtures, "rear"))
    with open(os.path.join(fixtures, "rear", "settings.lua"), "w") as f:
        f.write("return {}\n")

    tests_dir = os.path.join(tmp, "tests")
    goldens = os.path.join(tmp, "goldens")
    os.makedirs(tests_dir)
    os.makedirs(goldens)

    def write_test(name, body):
        with open(os.path.join(tests_dir, name + ".test"), "w") as f:
            f.write(body)

    def make_cfg(timeout=30):
        cfg = Config()
        cfg.emu_bin = fake
        cfg.tests_dir = tests_dir
        cfg.fixtures_dir = fixtures
        cfg.goldens_dir = goldens
        cfg.xroot = os.path.join(REPO_ROOT, "xroot")
        cfg.timeout = timeout
        cfg.update_golden = False
        cfg.keep_sandbox = False
        cfg.pkg_dir = None
        return cfg

    print("emu_test.py --selftest (fake emu: %s)" % fake)

    # 1. discovery
    write_test("00-alpha", "frames 2\n!assert true\nquit\n")
    write_test("10-beta", "frames 2\nquit\n")
    cfg = make_cfg()
    found = discover_tests(cfg)
    check(len(found) == 2, "discovery finds 2 *.test files")
    check(discover_tests(cfg, ["00-alpha"]) == [found[0]], "selector filters to one test")

    # 2. basic pass + TAP shape
    lines = []
    ok = run_suite(cfg, ["00-alpha"], emit=lines.append)
    check(ok is True, "passing test -> run_suite True")
    check("TAP version 13" in lines, "TAP header emitted")
    check("1..1" in lines, "TAP plan line emitted")
    check(any(l == "ok 1 - 00-alpha" for l in lines), "TAP 'ok 1 - 00-alpha'")

    # 3. !assert pass and fail
    write_test("assert-pass", "!assert true\nquit\n")
    write_test("assert-fail", "!assert false\nquit\n")
    lines = []
    ok = run_suite(make_cfg(), ["assert-pass"], emit=lines.append)
    check(ok, "!assert true passes")
    lines = []
    ok = run_suite(make_cfg(), ["assert-fail"], emit=lines.append)
    check(not ok, "!assert false fails")
    check(any(l.startswith("not ok") and "assert-fail" in l for l in lines), "!assert fail -> not ok line")

    # 4. golden: create (update mode), match, mismatch
    write_test("golden-t", "!golden shot\nquit\n")
    cfg = make_cfg()
    cfg.update_golden = True
    lines = []
    ok = run_suite(cfg, ["golden-t"], emit=lines.append)
    check(ok, "STOL_UPDATE_GOLDEN writes a golden and passes")
    check(any("# updated" in l for l in lines), "update reports '# updated'")
    check(os.path.exists(os.path.join(goldens, "golden-t", "shot.png")), "golden file written")
    # match
    lines = []
    ok = run_suite(make_cfg(), ["golden-t"], emit=lines.append)
    check(ok, "golden match passes on second run")
    # mismatch: corrupt the golden
    with open(os.path.join(goldens, "golden-t", "shot.png"), "wb") as f:
        f.write(b"different bytes")
    lines = []
    ok = run_suite(make_cfg(), ["golden-t"], emit=lines.append)
    check(not ok, "golden mismatch fails")
    check(any("mismatch" in l for l in lines), "mismatch reason surfaced")
    # missing golden
    write_test("golden-missing", "!golden nope\nquit\n")
    lines = []
    ok = run_suite(make_cfg(), ["golden-missing"], emit=lines.append)
    check(not ok, "missing golden fails")
    check(any("golden missing" in l and "STOL_UPDATE_GOLDEN" in l for l in lines),
          "missing golden names the update env var")

    # 5. watchdog
    write_test("watchdog-t", "hang\nquit\n")
    lines = []
    ok = run_suite(make_cfg(timeout=1.5), ["watchdog-t"], emit=lines.append)
    check(not ok, "watchdog fires on a hung command")
    check(any("watchdog" in l for l in lines), "watchdog reason surfaced")

    # 6. sandbox hermeticity: run a bleed-probe test twice; both see 0 markers.
    # The fake emu's `lua bleed` counts marker files in REAR_ROOT then drops one;
    # a fresh sandbox per run means both runs must report 0.
    write_test("bleed-t", "lua bleed\n!expect ^ok 0$\nquit\n")
    # first run
    lines1 = []
    ok1 = run_suite(make_cfg(), ["bleed-t"], emit=lines1.append)
    # second run — a fresh sandbox must NOT see run 1's marker
    lines2 = []
    ok2 = run_suite(make_cfg(), ["bleed-t"], emit=lines2.append)
    check(ok1 and ok2, "bleed probe: both runs see 0 markers (hermetic)")

    # 7. !expect
    write_test("expect-t", "lua hello\n!expect ^ok hello$\nquit\n")
    lines = []
    ok = run_suite(make_cfg(), ["expect-t"], emit=lines.append)
    check(ok, "!expect matches the preceding reply")
    write_test("expect-fail", "lua hello\n!expect ^ok goodbye$\nquit\n")
    lines = []
    ok = run_suite(make_cfg(), ["expect-fail"], emit=lines.append)
    check(not ok, "!expect mismatch fails")

    shutil.rmtree(tmp, ignore_errors=True)

    print()
    if failures:
        print("SELFTEST FAILED: %d check(s)" % len(failures))
        for m in failures:
            print("  - %s" % m)
        return 1
    print("SELFTEST OK")
    return 0


# ── main ─────────────────────────────────────────────────────────────────────

def main(argv):
    args = argv[1:]
    if "--selftest" in args:
        return _selftest()
    cfg = Config()
    selectors = [a for a in args if not a.startswith("-")]
    ok = run_suite(cfg, selectors or None)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
