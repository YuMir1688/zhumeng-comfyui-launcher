import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).parent / "launcher/tools/ComfyUI-Runtime.py"
spec = importlib.util.spec_from_file_location("launcher_runtime", SOURCE)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


@unittest.skipUnless(os.name == "nt", "Windows NUL tests")
class RuntimeTests(unittest.TestCase):
    def test_diagnostic_survives_english_windows_encoding(self):
        stream = io.TextIOWrapper(io.BytesIO(), encoding="cp1252", errors="strict")
        with contextlib.redirect_stdout(stream):
            runtime.report("[LAUNCHER:E_NULL_DEVICE] 中文诊断")
        self.assertIn(b"E_NULL_DEVICE", stream.buffer.getvalue())

    def test_normal_null(self):
        original = os.devnull
        self.assertFalse(runtime.prepare_null())
        self.assertEqual(os.devnull, original)
        runtime.probe_null(r"\\.\NUL")

    def test_regular_file_is_not_null(self):
        with tempfile.TemporaryDirectory() as folder:
            ordinary = Path(folder) / "not-a-device"
            ordinary.write_bytes(b"preserve me")
            with self.assertRaises(OSError):
                runtime.probe_null(str(ordinary))
            self.assertEqual(ordinary.read_bytes(), b"preserve me")
            missing = Path(folder) / "absent"
            with self.assertRaises(OSError):
                runtime.probe_null(str(missing))
            self.assertFalse(missing.exists())

    def test_alias_failure_uses_real_device(self):
        original_open = os.open
        original_null = os.devnull
        def fail_alias(path, *args, **kwargs):
            if path == original_null:
                raise FileNotFoundError(2, "injected NUL alias failure", path)
            return original_open(path, *args, **kwargs)
        try:
            with patch.object(os, "open", side_effect=fail_alias):
                self.assertTrue(runtime.prepare_null())
                # Same parent-side redirection used by ComfyUI-Manager.
                output = subprocess.check_output([sys.executable, "-c", "print('OK')"],
                                                 stderr=subprocess.DEVNULL, timeout=10)
                self.assertEqual(output.strip(), b"OK")
                with open(os.devnull, "rb", buffering=0) as stream:
                    self.assertEqual(stream.read(1), b"")
        finally:
            os.devnull = original_null

    def test_both_devices_fail_before_main(self):
        for error in (FileNotFoundError(2, "missing"), PermissionError(13, "denied")):
            with self.subTest(error=type(error).__name__), contextlib.redirect_stdout(io.StringIO()) as out:
                with patch.object(os, "open", side_effect=error), patch.object(runpy := runtime.runpy, "run_path") as run:
                    with self.assertRaises(SystemExit) as result:
                        runtime.main()
                    self.assertEqual(result.exception.code, 73)
                    run.assert_not_called()
                    self.assertIn("E_NULL_DEVICE", out.getvalue())

    def test_relocated_chinese_space_path_preserves_arguments(self):
        with tempfile.TemporaryDirectory(prefix="启动 中文 路径 ") as folder:
            root = Path(folder).resolve()
            (root / "tools").mkdir()
            shutil.copy2(SOURCE, root / "tools/ComfyUI-Runtime.py")
            (root / "user").mkdir()
            (root / "user/keep.txt").write_text("preserve")
            (root / "main.py").write_text(
                "import json,os,sys\nprint(json.dumps({'cwd':os.getcwd(),'argv':sys.argv,'path':sys.path[0]}))\n",
                encoding="utf-8")
            result = subprocess.run([sys.executable, "-s", str(root / "tools/ComfyUI-Runtime.py"),
                                     "--port", "1080", "--test", "中文 空格"], capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            record = json.loads(result.stdout)
            self.assertEqual(record["cwd"], str(root))
            self.assertEqual(record["path"], str(root))
            self.assertEqual(record["argv"], [str(root / "main.py"), "--port", "1080", "--test", "中文 空格"])
            self.assertTrue(all((root / name).is_dir() for name in ("input", "output", "temp", "user")))
            self.assertEqual((root / "user/keep.txt").read_text(), "preserve")
            self.assertFalse((root / "models").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
