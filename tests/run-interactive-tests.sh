#!/usr/bin/env bash
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# run-interactive-tests.sh — end-to-end coverage for the INTERACTIVE
# shim path of the dosemu2 images.
#
# Companion to run-tests.sh, which covers the headless (batch) path.
# Together the two scripts exercise all three shim branches:
#
#   run-tests.sh              : args given          → batch, exit on completion
#   run-interactive-tests.sh  : no args + TTY       → interactive terminal
#   run-interactive-tests.sh  : no args + no TTY    → exit 2 with usage
#
# For each image the interactive test:
#   1. Allocates a PTY (via python3) and spawns `podman run --rm -it IMAGE`.
#   2. Waits for the DOS prompt (env setup succeeded, shell started).
#   3. Types a compile command and waits for the next prompt.
#   4. Verifies the compiled .exe was produced on the host bind mount.
#   5. Types a command that runs the .exe and verifies its stdout.
#   6. Types `exit` and asserts the container exits with status 0.
#
# A per-image no-TTY usage check is also run to assert the shim bails out
# cleanly when invoked without a TTY and without a command.
#
# Usage:
#   tests/run-interactive-tests.sh                       # default matrix
#   tests/run-interactive-tests.sh watcom-11.0c-dosemu2  # specific image
#
# Exit status: 0 if every image passes, 1 otherwise.

set -u

IMAGES_DEFAULT=(
    watcom-9.5-dosemu2
    watcom-9.5a-dosemu2
    watcom-9.5b-dosemu2
    watcom-9.5c-dosemu2
    watcom-10.0a-dosemu2
    watcom-10.0b-dosemu2
    watcom-10.5-dosemu2
    watcom-10.6a-dosemu2
    watcom-11.0-dosemu2
    watcom-11.0b-dosemu2
    watcom-11.0c-dosemu2
)

if [ "$#" -gt 0 ]; then
    IMAGES=("$@")
else
    IMAGES=("${IMAGES_DEFAULT[@]}")
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HERE/hello.c" "$WORK/"

# -----------------------------------------------------------------------------
# PTY driver (Python).
# -----------------------------------------------------------------------------
interactive_case() {
    local img="$1"
    rm -f "$WORK"/hello.exe "$WORK"/hello.obj "$WORK"/_wcrun.bat \
          "$WORK"/HELLO.EXE "$WORK"/HELLO.OBJ

    python3 - "$img" "$WORK" <<'PY'
import os, pty, re, select, sys, time

image, work = sys.argv[1], sys.argv[2]

# Scripted dialog.
#   prompt_re  : regex for the DOS prompt after each command completes
#   compile_cmd: DOS command that produces an executable on the bind mount
#   run_cmd    : DOS command that runs the produced executable
#   run_expect : regex the executable's stdout must match
#   exe_name   : expected artefact filename on the host (case-sensitive)
# dosemu2 via FDPP + S-Lang terminal. CWD is F:\SRC (lowercase on disk).
prompt_re   = r"(?i)F:\\SRC>"
compile_cmd = b"wcl386 -l=dos4g hello.c\r\n"
run_cmd     = b"hello.exe\r\n"
run_expect  = r"hello from watcom C"
exe_name    = "hello.exe"

# Each step: (send_bytes_or_None, expect_regex_or_None, timeout_seconds).
# Send first, then wait for expect. Buffer resets after each send so
# expect matches only fresh output.
steps = [
    (None,         prompt_re, 25),
    (compile_cmd,  prompt_re, 45),
]
if run_cmd:
    steps.append((run_cmd, run_expect, 20))
steps.append((b"exit\r\n", None, 10))

pid, fd = pty.fork()
if pid == 0:
    os.execvp("podman", [
        "podman", "run", "--rm", "-it",
        "-v", f"{work}:/src",
        f"localhost/{image}",
    ])

ANSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b[=>]|\x0f|\x0e")
buf = b""

def send(data):
    """Write to the PTY. dosemu2's S-Lang terminal accepts burst writes."""
    os.write(fd, data)

def read_until(timeout, needle):
    global buf
    pat = re.compile(needle) if needle else None
    deadline = time.time() + timeout
    while time.time() < deadline:
        r,_,_ = select.select([fd], [], [], 0.2)
        if r:
            try:
                d = os.read(fd, 8192)
            except OSError:
                return pat is None
            if not d:
                return pat is None
            buf += ANSI.sub(b"", d)
        if pat and pat.search(buf.decode("utf-8", "replace")):
            return True
    return pat is None

ok = True
for data, expect, timeout in steps:
    if data:
        send(data)
        buf = b""
    if expect and not read_until(timeout, expect):
        ok = False
        break

# Drain + reap.
exit_code = None
end = time.time() + 15
while time.time() < end:
    r,_,_ = select.select([fd], [], [], 0.2)
    if r:
        try:
            d = os.read(fd, 8192)
            if d:
                buf += ANSI.sub(b"", d)
        except OSError:
            pass
    _pid, status = os.waitpid(pid, os.WNOHANG)
    if _pid == pid:
        exit_code = os.waitstatus_to_exitcode(status)
        break
if exit_code is None:
    try: os.kill(pid, 9)
    except ProcessLookupError: pass
    os.waitpid(pid, 0)
    exit_code = 124

try: os.close(fd)
except: pass

exe_path = os.path.join(work, exe_name)
exe_ok = os.path.exists(exe_path)

if ok and exe_ok and exit_code == 0:
    sz = os.path.getsize(exe_path)
    print(f"OK {sz}B")
    sys.exit(0)

sys.stderr.write(f"--- interactive failure for {image} (ok={ok} exe={exe_ok} exit={exit_code}) ---\n")
tail = buf[-1500:].decode("utf-8", "replace")
sys.stderr.write(tail + "\n")
sys.stderr.write(f"--- end {image} ---\n")
print("FAIL")
sys.exit(1)
PY
}

# -----------------------------------------------------------------------------
# No-TTY usage check. Both shim families exit non-zero with a "no DOS command"
# message on stderr. Run per-image so a future image shipping a divergent
# shim fails loudly.
# -----------------------------------------------------------------------------
no_tty_case() {
    local img="$1"
    local out rc
    out=$(podman run --rm "localhost/$img" </dev/null 2>&1)
    rc=$?
    if [ "$rc" != 0 ] && echo "$out" | grep -q "no DOS command given"; then
        echo "OK"
    else
        echo "FAIL rc=$rc"
        echo "--- no-tty stderr for $img ---" >&2
        echo "$out" >&2
    fi
}

fail=0
printf "%-26s %-22s %-10s\n" IMAGE INTERACTIVE NO-TTY
printf "%-26s %-22s %-10s\n" -------------------------- ---------------------- ----------
for img in "${IMAGES[@]}"; do
    i_r=$(interactive_case "$img") || fail=1
    n_r=$(no_tty_case   "$img") || fail=1
    printf "%-26s %-22s %-10s\n" "$img" "$i_r" "$n_r"
done

exit "$fail"
