# Copyright (C) 2026 Simon Brakhane
# SPDX-License-Identifier: AGPL-3.0-or-later
"""
_dosemu.py — shared helpers for running DOS tools under dosemu2.

Consumed by the three Watcom installer-format interpreters
(install_scr.py, setup_inf_ini.py, setup_inf_manifest.py).  The leading
underscore marks the module as internal-to-scripts/lib — it is not a
stable CLI and has no `__main__` entry point.

Surface
-------
    dos_exec(work, cmd)             Run one DOS command with `work` as F:\\.
    wpack_unpack_one(wpk, dst, *, watcom_tools, final_name=None)
                                    Unpack one WPK via wpack.exe (slow).
    wpack_unpack_batch(jobs, *, watcom_tools)
                                    Unpack many WPKs per dosemu2 boot.
                                    `jobs` = [(wpk_bytes, dst_dir, name), ...]
    bpatch_apply(target, patch, *, watcom_tools)
                                    Run bpatch.exe -p -b PATCH -f TARGET.

Why the batch path exists
-------------------------
dosemu2 takes ~1-2 s to boot DOS regardless of how trivial the command
is.  For installers like 10.0 LA and 9.5 that unpack hundreds of WPK
files, that dominates the build time (~15 min serial vs ~21 s batched).
`wpack_unpack_batch` writes one BAT driver that runs every wpack.exe
invocation in sequence inside a single dosemu2 process, then harvests
the output from per-slot subdirectories.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


# ---------------------------------------------------------------------------
# Core dosemu2 invocation
# ---------------------------------------------------------------------------

def dos_exec(work: Path, cmd: str, *, quiet: bool = True) -> None:
    """Run `cmd` under dosemu2 with `work` as the DOS drive root (F:\\).

    When `quiet=True` (the default) both stdout and stderr are swallowed
    on success and only surfaced on failure.  Raises SystemExit on a
    non-zero dosemu2 exit code.
    """
    p = subprocess.run(
        ["dosemu", "-dumb", "-quiet", "-K", str(work), "-E", cmd],
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        sys.stderr.write(p.stdout)
        sys.stderr.write(p.stderr)
        raise SystemExit(f"dosemu2 failed (rc={p.returncode}) for: {cmd}")
    if not quiet:
        sys.stdout.write(p.stdout)
        sys.stderr.write(p.stderr)


# ---------------------------------------------------------------------------
# WPK unpacking
# ---------------------------------------------------------------------------

def wpack_unpack_one(
    wpk: Path,
    dst_dir: Path,
    *,
    watcom_tools: Path,
    final_name: str | None = None,
) -> list[Path]:
    """Unpack a single WPK file into `dst_dir`.

    This is the slow path — one dosemu2 boot per archive.  Prefer
    `wpack_unpack_batch` when unpacking more than a handful.

    The source WPK is staged inside a `_src\\` subdirectory so that
    wpack.exe's output filename cannot collide with the source archive
    name and trigger an interactive "Replace (y/n)?" prompt (which hangs
    under dumb-mode stdin).  See the commentary around the 9.01d
    WCCOPTS.DLL quirk for the concrete trigger case.

    Returns the list of produced destination paths (lower-cased).
    """
    if not wpk.is_file():
        raise SystemExit(f"wpack_unpack_one: missing archive: {wpk}")
    dst_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        shutil.copy(watcom_tools / "wpack.exe", work / "wpack.exe")
        src_dir = work / "_src"
        src_dir.mkdir()
        shutil.copy(wpk, src_dir / wpk.name)
        dos_exec(work, f"wpack.exe _src\\{wpk.name}")
        (work / "wpack.exe").unlink()
        shutil.rmtree(src_dir)

        produced = list(work.iterdir())
        if not produced:
            raise SystemExit(f"wpack produced no output for {wpk}")

        out_paths: list[Path] = []
        if len(produced) == 1 and final_name:
            target = dst_dir / final_name.lower()
            if target.exists():
                target.unlink()
            shutil.move(str(produced[0]), str(target))
            out_paths.append(target)
        else:
            for f in produced:
                target = dst_dir / f.name.lower()
                if target.exists():
                    target.unlink()
                shutil.move(str(f), str(target))
                out_paths.append(target)
        return out_paths


def wpack_unpack_batch(
    jobs: list[tuple[bytes, Path, str | None]],
    *,
    watcom_tools: Path,
) -> None:
    """Unpack many WPK archives in a single dosemu2 invocation.

    `jobs` is `[(wpk_bytes, dst_dir, final_name), ...]`.  Order is
    preserved: archives are unpacked in the order given.  `final_name`
    may be None to let wpack's embedded filename decide.

    Layout inside the dosemu2 work dir:

        wpack.exe
        _src\\aNNNN.wpk     renamed-to-unique source archives
        oNNNN\\...           wpack output, one subdir per slot
        run.bat              cd \\oNNNN then ..\\wpack.exe ..\\_src\\aNNNN.wpk

    Scratch names are kept DOS-8.3-compliant (<=8 char basenames): DOS's
    short-name aliasing for longer names made COMMAND.COM lose the
    argument to wpack.exe.  aNNNN gives headroom up to 9999 slots.
    """
    if not jobs:
        return
    assert len(jobs) <= 9999, "batch size exceeds 8.3-name scheme capacity"

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        shutil.copy(watcom_tools / "wpack.exe", work / "wpack.exe")
        src_dir = work / "_src"
        src_dir.mkdir()

        bat_lines = ["@echo off"]
        for i, (wpk_bytes, _dst, _name) in enumerate(jobs, start=1):
            tag = f"{i:04d}"
            arc_name = f"a{tag}.wpk"
            out_name = f"o{tag}"
            with open(src_dir / arc_name, "wb") as fh:
                fh.write(wpk_bytes)
            (work / out_name).mkdir()
            bat_lines.append(f"cd \\{out_name}")
            bat_lines.append(f"..\\wpack.exe ..\\_src\\{arc_name}")
            bat_lines.append("cd \\")
        bat_lines.append("")
        (work / "run.bat").write_text("\r\n".join(bat_lines))

        dos_exec(work, "run.bat")

        # Collect results in declaration order.
        for i, (_wpk, dst_dir, final_name) in enumerate(jobs, start=1):
            out_dir = work / f"o{i:04d}"
            produced = list(out_dir.iterdir())
            if not produced:
                raise SystemExit(
                    f"wpack produced no output for batch slot {i}"
                )
            dst_dir.mkdir(parents=True, exist_ok=True)
            if len(produced) == 1 and final_name:
                target = dst_dir / final_name.lower()
                if target.exists():
                    target.unlink()
                shutil.move(str(produced[0]), str(target))
            else:
                for f in produced:
                    target = dst_dir / f.name.lower()
                    if target.exists():
                        target.unlink()
                    shutil.move(str(f), str(target))


# ---------------------------------------------------------------------------
# bpatch
# ---------------------------------------------------------------------------

def bpatch_apply(target: Path, patch: Path, *, watcom_tools: Path) -> None:
    """Apply a Watcom binary patch (.bpatch-format) to `target` in place."""
    if not target.is_file():
        raise SystemExit(f"bpatch_apply: missing target: {target}")
    if not patch.is_file():
        raise SystemExit(f"bpatch_apply: missing patch: {patch}")

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        shutil.copy(watcom_tools / "bpatch.exe", work / "bpatch.exe")
        tcopy = work / target.name
        pcopy = work / patch.name
        shutil.copy(target, tcopy)
        shutil.copy(patch, pcopy)
        dos_exec(work, f"bpatch.exe -p -b {patch.name} -f {target.name}")
        shutil.copy(tcopy, target)
