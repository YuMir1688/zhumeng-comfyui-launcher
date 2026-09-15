from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import zipfile
from pathlib import Path


ABSOLUTE_PYTHON_SHEBANG = re.compile(
    rb"#![A-Za-z]:[^\r\n]*\\pythonw?\.exe",
    re.IGNORECASE,
)
TEXT_PYTHON_SHEBANG = re.compile(
    rb"^#![A-Za-z]:[^\r\n]*\\pythonw?(?:\.exe)?(?:[ \t].*)?(?=\r?\n)",
    re.IGNORECASE,
)
DISPATCHER = b"""\
from __future__ import annotations

import runpy
import os
import sys

script_path = sys.argv[1]
entrypoint_path = sys.argv[2]
forwarded_arguments = sys.argv[3:]
portable_directory = os.path.normcase(os.path.abspath(os.path.dirname(__file__)))
sys.path = [
    path
    for path in sys.path
    if os.path.normcase(os.path.abspath(path or os.curdir)) != portable_directory
]
sys.argv = [entrypoint_path, *forwarded_arguments]
runpy.run_path(script_path, run_name="__main__")
"""


def _write_if_changed(path: Path, content: bytes) -> bool:
    if path.is_file() and path.read_bytes() == content:
        return False
    path.write_bytes(content)
    return True


def repair_entrypoints(root: Path, launcher: Path) -> dict[str, int | str]:
    scripts_directory = root / ".ext" / "Scripts"
    portable_directory = scripts_directory / ".portable"
    dispatcher_path = portable_directory / "portable_entrypoint_dispatcher.py"

    if not scripts_directory.is_dir():
        raise FileNotFoundError(f"Scripts directory is missing: {scripts_directory}")
    if not launcher.is_file():
        raise FileNotFoundError(f"Portable launcher is missing: {launcher}")

    portable_directory.mkdir(parents=True, exist_ok=True)
    dispatcher_updated = _write_if_changed(dispatcher_path, DISPATCHER)
    launcher_content = launcher.read_bytes()

    repaired_executables = 0
    synchronized_executables = 0
    for executable in sorted(scripts_directory.glob("*.exe")):
        content = executable.read_bytes()
        portable_script = portable_directory / f"{executable.stem}.py"
        has_absolute_shebang = bool(ABSOLUTE_PYTHON_SHEBANG.search(content))
        if not has_absolute_shebang:
            if portable_script.is_file() and content != launcher_content:
                shutil.copyfile(launcher, executable)
                synchronized_executables += 1
            continue

        try:
            with zipfile.ZipFile(executable) as archive:
                entrypoint_source = archive.read("__main__.py")
        except (KeyError, zipfile.BadZipFile) as exception:
            raise RuntimeError(
                f"Cannot preserve Python entrypoint: {executable.name}"
            ) from exception

        _write_if_changed(portable_script, entrypoint_source)
        if content != launcher_content:
            shutil.copyfile(launcher, executable)
        repaired_executables += 1

    repaired_text_scripts = 0
    for path in sorted(scripts_directory.iterdir()):
        if not path.is_file() or path.suffix.lower() == ".exe":
            continue
        if path.stat().st_size > 2 * 1024 * 1024:
            continue

        content = path.read_bytes()
        if not TEXT_PYTHON_SHEBANG.search(content):
            continue

        path.write_bytes(
            TEXT_PYTHON_SHEBANG.sub(
                b"#!/usr/bin/env python",
                content,
                count=1,
            )
        )
        repaired_text_scripts += 1

    remaining = []
    for path in sorted(scripts_directory.rglob("*")):
        if not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
            continue
        if ABSOLUTE_PYTHON_SHEBANG.search(path.read_bytes()):
            remaining.append(str(path.relative_to(root)))
    if remaining:
        raise RuntimeError(
            "Absolute Python entrypoints remain: " + ", ".join(remaining[:10])
        )

    return {
        "result": "OK",
        "root": str(root),
        "dispatcherUpdated": dispatcher_updated,
        "executablesRepaired": repaired_executables,
        "executablesSynchronized": synchronized_executables,
        "textScriptsRepaired": repaired_text_scripts,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--launcher", required=True)
    arguments = parser.parse_args()

    result = repair_entrypoints(
        Path(arguments.root).resolve(),
        Path(arguments.launcher).resolve(),
    )
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
