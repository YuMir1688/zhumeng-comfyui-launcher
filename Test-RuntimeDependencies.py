"""Optional integration test: run with the package's Python (torch/dill/pip required)."""
import os
from pathlib import Path
import subprocess
import sys

source = str(Path(__file__).parent / "launcher/tools/ComfyUI-Runtime.py")
code = r'''
import builtins, importlib.util, os, subprocess, sys
spec = importlib.util.spec_from_file_location("runtime", sys.argv[1])
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
old_open, old_os_open = builtins.open, os.open
def broken_open(path, *args, **kwargs):
    if isinstance(path, str) and path.lower() == "nul":
        raise FileNotFoundError(2, "injected alias failure", "nul")
    return old_open(path, *args, **kwargs)
def broken_os_open(path, *args, **kwargs):
    if isinstance(path, str) and path.lower() == "nul":
        raise FileNotFoundError(2, "injected alias failure", "nul")
    return old_os_open(path, *args, **kwargs)
builtins.open, os.open = broken_open, broken_os_open
if sys.argv[2] == "legacy":
    failures = 0
    try:
        subprocess.check_output([sys.executable, "-s", "-m", "pip", "--version"], stderr=subprocess.DEVNULL, timeout=20)
    except FileNotFoundError as error:
        assert error.filename == "nul"
        failures += 1
    try:
        import torch
    except FileNotFoundError as error:
        assert error.filename == "nul"
        failures += 1
    assert failures == 2, failures
    print("REPRODUCED: Manager pip probe and torch/dill both fail on nul")
else:
    assert runtime.prepare_null()
    print(subprocess.check_output([sys.executable, "-s", "-m", "pip", "--version"], stderr=subprocess.DEVNULL, timeout=20).decode("utf-8"))
    import torch, dill
    print("PASS: real pip probe, torch", torch.__version__, "dill", dill.__version__)
'''
for mode in ("legacy", "fixed"):
    result = subprocess.run([sys.executable, "-s", "-B", "-c", code, source, mode],
                            capture_output=True, encoding="utf-8", timeout=90,
                            env={**os.environ, "PYTHONIOENCODING": "utf-8", "PYTHONUTF8": "1"})
    print(result.stdout, end="")
    if result.returncode:
        raise RuntimeError(result.stderr)
