#!/usr/bin/env python3
# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
r"""
install_scr.py — interpreter for Watcom's INSTALL.SCR DSL.

Watcom shipped its C/C++ installers as a small tool (`INSTALL.EXE`,
a hybrid DOS/OS2 NE binary) plus a plain-text script (`INSTALL.SCR`)
written in a tiny installer DSL. On the 9.5 C/C++ distribution there
are two of these scripts — one per floppy set — and together they fully
describe how to lay out an installed Watcom tree from the packed files
on the floppies. Nothing outside of `INSTALL.SCR` is used.

Rather than drive the original `INSTALL.EXE` under dosemu2 with
synthesised keystrokes (which we'd need to do anyway because the DSL
prompts the user for yes/no answers on every package), this interpreter
executes the DSL directly against a pre-flattened source directory and
an arbitrary destination directory. Every `ask` prompt can be
pre-answered via an answers file or by the `--yes-all` flag.

DSL reference
=============

Whitespace-insensitive line-based language. Blank lines and lines
starting with `#` are comments. Commands:

    echo TEXT                   — print TEXT (informational only)
    ask VAR PROMPT              — set VAR to the user's y/n answer
    set VAR VALUE               — set VAR to VALUE
    if %VAR CMD                 — execute CMD if VAR == 'y'
    ifnot %VAR CMD              — execute CMD if VAR != 'y'
    goto LABEL                  — jump to LABEL:
    mkdir PATH                  — create directory (mkdir -p semantics)
    unpack DESTDIR ARCFILE      — unpack a .wpk archive into DESTDIR
    file PATH                   — start a heredoc; the following `> …`
                                  lines are its content. The heredoc
                                  ends at the next non-`>` line.
    > LINE                      — heredoc content line
    @copy SRC DST               — copy a single file
    @append SRC DST             — append SRC to DST
    @erase PATH                 — delete PATH if it exists
    @spawn CMD…                 — execute CMD. Dispatch is forked:
                                    * bpatch -p -b PATCH -f TARGET —
                                      recognised as the Watcom binary
                                      patcher call (9.5 uses this for
                                      COMMDLG.DLL localisation).
                                    * anything else — run as a DOS
                                      command under dosemu2 with the
                                      install destination as the
                                      current drive (9.01d uses this
                                      for `wlib` and `wimp`).
    enter FILE disk N, "LABEL"  — user prompt to insert disk N. Always
                                  a no-op here because the caller has
                                  already pre-flattened every floppy
                                  into a single staging directory.
    LABEL:                      — jump target

`if` commands nest: `if %doshost if %wpp unpack …` is legal and means
"unpack only if BOTH flags are set".

Variable expansion
==================

`%1`, `%2`, and `%NAME` (alphanumeric identifier) are expanded in every
command argument. `%1` is conventionally the source drive letter with
a trailing separator (`A:\` on DOS, mapped to e.g. `/staging/` here),
and `%2` is conventionally the install drive with a trailing separator
(`C:\WATCOM\` → `/dest/`). All backslashes in command arguments are
translated to forward slashes before any filesystem access.

The `%%` sequence inside heredocs is left alone — those are DOS batch
file escapes for literal `%` characters and have no meaning to this
interpreter.

Wpack and bpatch
================

`unpack` and bpatch `@spawn` forms both go through the shared helpers
in `scripts/lib/_dosemu.py`, which run the Watcom Install Archiver 1.3
(`wpack.exe`) or the Watcom binary patcher (`bpatch.exe`) under
dosemu2 in a scratch directory.  Output filenames are lower-cased so
the tree is consistently cased on a case-sensitive filesystem, matching
the layout Watcom's own Linux ports use.

Usage
=====

    install_scr.py \\
        --script  /path/to/INSTALL.SCR \\
        --source  /staging/           \\
        --dest    /out/watcom/        \\
        --watcom-tools /opt/watcom-tools \\
        [--yes-all | --answers FILE]  \\
        [--verbose]
"""

import argparse
import os
import re
import shutil
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
VERBOSE = False


def log(msg):
    print(f"[installer] {msg}", file=sys.stderr, flush=True)


def vlog(msg):
    if VERBOSE:
        log(msg)


def die(msg):
    print(f"[installer] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


# ---------------------------------------------------------------------------
# dosemu2 / wpack / bpatch helpers live in _dosemu.py (shared with the
# SETUP.INF interpreters).  Thin wrappers here keep the call sites in
# the DSL dispatch code readable and let `wpack_unpack` use the
# positional (dest, wpk, tools) argument order expected by the rest of
# this module.
# ---------------------------------------------------------------------------
from _dosemu import (
    dos_exec,
    wpack_unpack_one,
    bpatch_apply as _bpatch_apply,
)


def wpack_unpack(dest: Path, wpk: Path, watcom_tools: Path):
    """Unpack a .wpk archive into `dest`, lower-casing produced filenames."""
    wpack_unpack_one(wpk, dest, watcom_tools=watcom_tools)


def bpatch_apply(target: Path, patch: Path, watcom_tools: Path):
    """Apply a Watcom binary patch file to `target` in place."""
    _bpatch_apply(target, patch, watcom_tools=watcom_tools)


# ---------------------------------------------------------------------------
# SCR interpreter
# ---------------------------------------------------------------------------
VAR_RE = re.compile(r"%([0-9]|[A-Za-z_]\w*)")


class Interpreter:
    def __init__(
        self,
        script_path: Path,
        source_dir: Path,
        dest_dir: Path,
        watcom_tools: Path,
        answers: dict,
        yes_all: bool,
    ):
        self.script_path = script_path
        self.source_dir = source_dir
        self.dest_dir = dest_dir
        self.watcom_tools = watcom_tools
        self.answers = {k.lower(): v for k, v in answers.items()}
        self.yes_all = yes_all

        self.vars = {
            # %1 is the source drive with a trailing separator, so that
            # `%1foo.wpk` expands to `<source_dir>/foo.wpk`.
            "1": str(source_dir) + os.sep,
            "2": str(dest_dir) + os.sep,
        }
        self.labels: dict[str, int] = {}
        self.heredoc_path: Path | None = None
        self.heredoc_lines: list[str] = []

    # -- path / variable expansion --------------------------------------
    def expand(self, s: str) -> str:
        """Substitute %VAR references. Unknown variables become empty."""
        def sub(match):
            name = match.group(1).lower()
            return self.vars.get(name, "")
        return VAR_RE.sub(sub, s)

    def resolve_path(self, s: str) -> Path:
        """Expand vars, translate backslashes, return an absolute Path."""
        expanded = self.expand(s).replace("\\", "/")
        return Path(expanded)

    def resolve_source(self, s: str) -> Path:
        """Like resolve_path but also lower-case the final filename so
        that references to upper-case floppy names (FOO.WPK) match the
        lower-cased staged files."""
        p = self.resolve_path(s)
        return p.parent / p.name.lower()

    # -- heredoc handling -----------------------------------------------
    def flush_heredoc(self):
        if self.heredoc_path is None:
            return
        self.heredoc_path.parent.mkdir(parents=True, exist_ok=True)
        # Lines in the SCR use DOS line endings by convention; we write
        # the file with Unix newlines since nothing in the container
        # actually runs these DOS batch files. They're kept only so the
        # installed tree matches what Watcom's installer would produce.
        content = "\n".join(self.heredoc_lines) + "\n"
        self.heredoc_path.write_text(content)
        vlog(f"wrote heredoc {self.heredoc_path} ({len(self.heredoc_lines)} lines)")
        self.heredoc_path = None
        self.heredoc_lines = []

    # -- main loop ------------------------------------------------------
    def run(self):
        raw_text = self.script_path.read_text(
            encoding="ascii", errors="replace"
        )
        # DOS text files (e.g. the 8.5 / 6.5 INSTALL.SCR) may carry a
        # Ctrl-Z (0x1A) end-of-file marker; it and anything after it are
        # not part of the script.  Honour DOS EOF semantics by truncating
        # at the first SUB byte.
        eof = raw_text.find("\x1a")
        if eof != -1:
            raw_text = raw_text[:eof]
        raw_lines = raw_text.splitlines()

        # Strip trailing whitespace from every line. Don't strip leading
        # whitespace: the `> LINE` heredoc continuation needs the `>` as
        # the first non-space character but the content after it is
        # literal.
        lines = [ln.rstrip() for ln in raw_lines]

        # Pass 1: collect labels. A label is a line consisting of a
        # single identifier followed by a colon (possibly with trailing
        # whitespace already stripped).
        label_re = re.compile(r"^([A-Za-z_]\w*):$")
        for i, ln in enumerate(lines):
            stripped = ln.lstrip()
            m = label_re.match(stripped)
            if m:
                self.labels[m.group(1).lower()] = i

        # Pass 2: execute.
        pc = 0
        while pc < len(lines):
            ln = lines[pc]
            stripped = ln.lstrip()

            # Heredoc continuation.
            if self.heredoc_path is not None and stripped.startswith(">"):
                # Content starts after the `>` and an optional single
                # space. We expand %VAR here because the batch files
                # reference %1/%2.
                body = stripped[1:]
                if body.startswith(" "):
                    body = body[1:]
                self.heredoc_lines.append(self.expand(body))
                pc += 1
                continue

            # Any other line terminates an open heredoc.
            if self.heredoc_path is not None:
                self.flush_heredoc()

            # Blank / comment / label → skip.
            if not stripped or stripped.startswith("#") or label_re.match(stripped):
                pc += 1
                continue

            jump = self.execute(stripped)
            if jump is not None:
                if jump not in self.labels:
                    die(f"jump to undefined label: {jump}")
                pc = self.labels[jump]
            else:
                pc += 1

        # End of script: flush any trailing heredoc.
        self.flush_heredoc()

    # -- per-line dispatch ----------------------------------------------
    def execute(self, line: str) -> str | None:
        """Execute one command line. Returns a label name to jump to,
        or None to advance sequentially."""
        tokens = line.split()
        verb = tokens[0].lower()
        # `@` prefix on a verb (e.g. `@unpack`, `@file`, `@spawn`) has no
        # semantic difference from the bare verb in any installer script
        # we've seen — the original DOS installer used it as a hint to
        # suppress progress output. Both spellings appear in the same
        # 9.01d script for the same operation. Normalise to the bare
        # verb so the dispatch table stays small.
        if verb.startswith("@"):
            verb = verb[1:]

        if verb == "echo":
            vlog("echo " + " ".join(tokens[1:]))
            return None

        if verb == "ask":
            if len(tokens) < 2:
                die(f"malformed ask: {line}")
            var = tokens[1].lower()
            if self.yes_all:
                self.vars[var] = "y"
            else:
                self.vars[var] = self.answers.get(var, "n")
            vlog(f"ask {var} = {self.vars[var]}")
            return None

        if verb == "set":
            if len(tokens) < 3:
                die(f"malformed set: {line}")
            self.vars[tokens[1].lower()] = tokens[2]
            return None

        if verb == "if":
            # if %VAR CMD…
            return self._conditional(tokens, expect="y")

        if verb == "ifnot":
            return self._conditional(tokens, expect="n")

        if verb == "goto":
            return tokens[1].lower()

        if verb == "mkdir":
            path = self.resolve_path(tokens[1])
            path.mkdir(parents=True, exist_ok=True)
            return None

        if verb == "unpack":
            if len(tokens) != 3:
                die(f"malformed unpack: {line}")
            dest = self.resolve_path(tokens[1])
            src = self.resolve_source(tokens[2])
            vlog(f"unpack {dest} <- {src}")
            wpack_unpack(dest, src, self.watcom_tools)
            return None

        if verb == "file":
            # Start a heredoc: subsequent `> LINE` lines become content.
            self.heredoc_path = self.resolve_path(tokens[1])
            self.heredoc_lines = []
            return None

        if verb == "enter":
            # "enter FILE disk N, labelled ..." — user prompt for disk
            # swap. No-op here because all floppies are pre-flattened.
            return None

        if verb == "copy":
            src = self.resolve_path(tokens[1])
            dst = self.resolve_path(tokens[2])
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(src, dst)
            return None

        if verb == "append":
            src = self.resolve_path(tokens[1])
            dst = self.resolve_path(tokens[2])
            dst.parent.mkdir(parents=True, exist_ok=True)
            with open(dst, "ab") as out, open(src, "rb") as inp:
                shutil.copyfileobj(inp, out)
            return None

        if verb == "erase":
            path = self.resolve_path(tokens[1])
            if path.exists():
                path.unlink()
            return None

        if verb == "spawn":
            self._spawn(tokens[1:])
            return None

        die(f"unknown command at line: {line}")
        return None  # unreachable

    def _conditional(self, tokens: list[str], expect: str) -> str | None:
        """Handle `if %VAR ...` and `ifnot %VAR ...`."""
        if len(tokens) < 3:
            die(f"malformed conditional: {' '.join(tokens)}")
        if not tokens[1].startswith("%"):
            die(f"conditional missing %VAR: {' '.join(tokens)}")
        var = tokens[1][1:].lower()
        val = self.vars.get(var, "n")
        taken = (val == "y") if expect == "y" else (val != "y")
        if not taken:
            return None
        # Recurse on the rest of the line. This naturally handles
        # nested `if %A if %B unpack …`.
        return self.execute(" ".join(tokens[2:]))

    def _spawn(self, args: list[str]):
        """Handle `spawn CMD…` / `@spawn CMD…`.

        Two dispatch paths:

        1. bpatch       — pattern-matched and sent to bpatch_apply()
                          (the only spawn in 9.5's INSTALL.SCR).
        2. anything else — run as a DOS command under dosemu2, with
                          dest_dir mounted as the current drive.
                          Used by 9.01d's INSTALL.SCR for `wlib` (build
                          OS/2 runtime libraries from .lbc response
                          files) and `wimp` (generate OS/2 import
                          library).
        """
        if not args:
            die("spawn with no arguments")

        cmd = self.resolve_path(args[0])
        basename = cmd.name.lower()

        if basename in ("bpatch", "bpatch.exe"):
            # Expected form:  spawn BPATCH -p -b PATCH -f TARGET
            rest = [self.expand(a).replace("\\", "/") for a in args[1:]]
            patch = target = None
            i = 0
            while i < len(rest):
                tok = rest[i]
                if tok == "-b" and i + 1 < len(rest):
                    patch = Path(rest[i + 1])
                    i += 2
                elif tok == "-f" and i + 1 < len(rest):
                    target = Path(rest[i + 1])
                    i += 2
                elif tok in ("-p", "-q"):
                    i += 1
                else:
                    die(f"spawn bpatch: unrecognised arg {tok!r} in {rest}")
            if patch is None or target is None:
                die(f"spawn bpatch missing -b/-f: {rest}")
            vlog(f"bpatch {target} <- {patch}")
            bpatch_apply(target, patch, self.watcom_tools)
            return

        # General case: run as a DOS command under dosemu2.
        #
        # Every path in an INSTALL.SCR spawn (and in any @file-created
        # response file it references) is written as `%2SUBPATH`, which
        # after expansion is an absolute Unix path like
        # `/opt/watcom/lib386/os2/foo.lib`. dosemu2 sees dest_dir as
        # the current DOS drive root; the portion after dest_dir is
        # the DOS-relative path we actually want to hand to the tool.
        #
        # We rewrite three things:
        #   (a) each command-line token: strip dest_dir prefix, / -> \
        #   (b) each @RESPONSE_FILE referenced in the command line:
        #       rewrite its on-disk content line-by-line the same way.
        #   (c) the spawn executable token gets `.exe` appended when
        #       it lacks a suffix (DOS path conventions).
        dest_str = str(self.dest_dir) + os.sep

        def to_dos(tok: str) -> str:
            """Strip dest_dir prefix if present, switch slashes."""
            if tok.startswith(dest_str):
                tok = tok[len(dest_str):]
            return tok.replace("/", "\\")

        expanded = [self.expand(a) for a in args]
        # Executable (args[0]) — DOS needs the .exe on filename.
        exe_tok = expanded[0]
        if not Path(exe_tok).suffix:
            candidate = Path(exe_tok + ".exe")
            if candidate.is_file():
                exe_tok = str(candidate)
        dos_argv = [to_dos(exe_tok)]

        # Remaining tokens — same rewrite, plus rewrite any referenced
        # response files in place so their contents match.
        for tok in expanded[1:]:
            if tok.startswith("@"):
                ref = tok[1:]
                ref_path = Path(ref)
                # Response files are sometimes given without .lbc
                # suffix (`@%2_mkmtlib`). Resolve by probing.
                if not ref_path.is_file():
                    for ext in (".lbc", ".lnk"):
                        if ref_path.with_suffix(ext).is_file():
                            ref_path = ref_path.with_suffix(ext)
                            break
                if ref_path.is_file():
                    content = ref_path.read_text()
                    # Rewrite every line's paths the same way.
                    new_lines = []
                    for ln in content.splitlines():
                        # A leading operator char (+, -) is preserved.
                        op = ""
                        body = ln
                        if body[:1] in ("+", "-", "*"):
                            op, body = body[0], body[1:]
                        new_lines.append(op + to_dos(body))
                    ref_path.write_text("\n".join(new_lines) + "\n")
                    # And rewrite the @token to point at it DOS-style.
                    dos_argv.append("@" + to_dos(str(ref_path)))
                else:
                    # No file to rewrite — just rewrite the token.
                    dos_argv.append("@" + to_dos(ref))
            else:
                dos_argv.append(to_dos(tok))

        dos_cmd = " ".join(dos_argv)
        vlog(f"dos_exec in {self.dest_dir}: {dos_cmd}")
        dos_exec(self.dest_dir, dos_cmd)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Interpret a Watcom INSTALL.SCR installer script."
    )
    parser.add_argument("--script", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path,
                        help="Directory containing pre-flattened floppy files.")
    parser.add_argument("--dest", required=True, type=Path,
                        help="Installation destination directory.")
    parser.add_argument("--watcom-tools", type=Path,
                        default=Path(os.environ.get("WATCOM_TOOLS", "/opt/watcom-tools")))
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--yes-all", action="store_true",
                       help="Answer 'y' to every `ask` prompt.")
    group.add_argument("--answers", type=Path,
                       help="Answers file: lines of `var=y` or `var=n`.")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    global VERBOSE
    VERBOSE = args.verbose

    if not args.script.is_file():
        die(f"script not found: {args.script}")
    if not args.source.is_dir():
        die(f"source dir not found: {args.source}")
    if not (args.watcom_tools / "wpack.exe").is_file():
        die(f"wpack.exe not found under {args.watcom_tools}")

    answers: dict[str, str] = {}
    if args.answers:
        for ln in args.answers.read_text().splitlines():
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            if "=" not in ln:
                die(f"bad answers line: {ln}")
            k, v = ln.split("=", 1)
            answers[k.strip().lower()] = v.strip().lower()

    args.dest.mkdir(parents=True, exist_ok=True)

    log(f"script : {args.script}")
    log(f"source : {args.source}")
    log(f"dest   : {args.dest}")
    log(f"answers: {'all-yes' if args.yes_all else answers}")

    interp = Interpreter(
        script_path=args.script,
        source_dir=args.source.resolve(),
        dest_dir=args.dest.resolve(),
        watcom_tools=args.watcom_tools.resolve(),
        answers=answers,
        yes_all=args.yes_all,
    )
    interp.run()
    log("done")


if __name__ == "__main__":
    main()
