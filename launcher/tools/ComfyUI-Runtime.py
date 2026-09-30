"""Launcher bootstrap: no changes to Windows services or installed packages."""
import os
import runpy
import sys
from pathlib import Path


def report(message):
    # English Windows may redirect stdout as cp1252. Diagnostics must not crash
    # the very failure path they describe. WPF normally provides UTF-8 already.
    try:
        print(message, flush=True)
    except UnicodeEncodeError:
        print(message.encode("ascii", errors="backslashreplace").decode("ascii"), flush=True)


def probe_null(path):
    # No O_CREAT: a failed device lookup must never create a pretend null file.
    fd = os.open(path, os.O_RDWR | getattr(os, "O_BINARY", 0))
    try:
        if os.name == "nt":
            import ctypes
            import msvcrt
            from ctypes import wintypes
            get_type = ctypes.WinDLL("kernel32", use_last_error=True).GetFileType
            get_type.argtypes = [wintypes.HANDLE]
            get_type.restype = wintypes.DWORD
            if get_type(msvcrt.get_osfhandle(fd)) != 2:
                raise OSError("Not a Windows character device")
        if os.read(fd, 1) != b"" or os.write(fd, b"launcher-null-probe") != 19:
            raise OSError("Null device read/write semantics failed")
    finally:
        os.close(fd)


def null_service_diagnostic():
    """Read-only evidence; never starts/stops a service or changes configuration."""
    if os.name != "nt":
        return
    import subprocess
    try:
        command = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/sc.exe"
        result = subprocess.run([str(command), "query", "Null"], capture_output=True,
                                timeout=5, creationflags=subprocess.CREATE_NO_WINDOW)
        import locale
        output = (result.stdout + result.stderr).decode(locale.getpreferredencoding(False), errors="replace")
        report(f"[LAUNCHER:NULL_SERVICE] query_exit={result.returncode}\n{output.strip()}")
    except (OSError, subprocess.TimeoutExpired) as error:
        report(f"[LAUNCHER:NULL_SERVICE] query_failed={error!r}")


def prepare_null(probe=probe_null):
    try:
        probe(os.devnull)
        return False
    except OSError as first:
        if os.name == "nt":
            try:
                probe(r"\\.\NUL")
            except OSError as second:
                report(f"[LAUNCHER:E_NULL_DEVICE] nul={first!r}; device={second!r}")
            else:
                # Local to this process; does not repair Windows or child interpreters.
                os.devnull = r"\\.\NUL"
                report("[LAUNCHER:W_NULL_ALIAS] 已验证系统 NUL 设备可用；本次 ComfyUI 进程改用设备完整路径。子进程不保证继承此兼容处理。")
                return True
        else:
            report(f"[LAUNCHER:E_NULL_DEVICE] {first!r}")
        null_service_diagnostic()
        report("Windows 空设备 NUL 无法读写，已在加载插件前停止。不能据此判定为缺少 pip、模型或显卡驱动。启动器未修改系统服务或安全设置。")
        raise SystemExit(73)


def self_check():
    import json
    import subprocess
    result = {"null": os.devnull, "python": sys.version.split()[0]}
    # Preserve the real pip error instead of using a possibly broken DEVNULL.
    try:
        pip = subprocess.run([sys.executable, "-s", "-m", "pip", "--version"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             timeout=20, encoding="utf-8", errors="replace",
                             env={**os.environ, "PYTHONIOENCODING": "utf-8"})
        result["pip_ok"] = pip.returncode == 0
        result["pip_output"] = (pip.stdout + pip.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        result["pip_ok"] = False
        result["pip_output"] = str(error)
    try:
        import dill
        import torch
        result.update(dill=dill.__version__, torch=torch.__version__, imports_ok=True)
    except Exception as error:
        result.update(imports_ok=False, import_error=repr(error))
    print(json.dumps(result, ensure_ascii=True), flush=True)
    return 0 if result["pip_ok"] and result["imports_ok"] else 74


def main():
    prepare_null()
    if sys.argv[1:] == ["--launcher-self-check"]:
        return self_check()
    root = Path(__file__).resolve().parent.parent
    entry = root / "main.py"
    if not entry.is_file():
        report("[LAUNCHER:E_PACKAGE] 缺少 main.py，请将补丁放在完整整合包内。")
        return 75
    # Some transfer/extraction tools omit empty directories. Only create missing
    # runtime folders; never replace a file, remove data, or touch model folders.
    try:
        for name in ("input", "output", "temp", "user"):
            (root / name).mkdir(exist_ok=True)
    except OSError as error:
        report(f"[LAUNCHER:E_PACKAGE] 无法准备运行目录，请检查解压位置和写入权限：{error}")
        return 75
    os.chdir(root)
    sys.path[0] = str(root)
    sys.argv[0] = str(entry)
    runpy.run_path(str(entry), run_name="__main__")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
