"""Model-free HTTP smoke test; use the isolated verification copy's Python."""
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

root = pathlib.Path(sys.argv[1]).resolve()
if not root.name.endswith("1.3.6_20260930"):
    raise SystemExit("Isolated verification copy required")
if "0.43.0" not in (root / "comfyui_version.py").read_text(encoding="utf-8"):
    raise SystemExit("Expected upgraded core 0.43.0")
stage = pathlib.Path(tempfile.mkdtemp(prefix="core043-http-"))
for name in ("input", "output", "temp", "user", "models"):
    (stage / name).mkdir()
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
base = f"http://127.0.0.1:{port}"
client = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(path, data=None):
    payload = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(base + path, data=payload,
                                 headers={"Content-Type": "application/json"})
    with client.open(req, timeout=5) as response:
        return json.load(response)


with (stage / "server.log").open("wb") as log:
    process = subprocess.Popen([
        sys.executable, "-s", str(root / "main.py"), "--cpu",
        "--disable-all-custom-nodes", "--disable-api-nodes", "--disable-auto-launch",
        "--base-directory", str(stage), "--listen", "127.0.0.1", "--port", str(port),
    ], cwd=root, stdout=log, stderr=subprocess.STDOUT,
        creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        deadline = time.monotonic() + 180
        while True:
            if process.poll() is not None:
                raise RuntimeError(f"Core exited: {stage / 'server.log'}")
            try:
                stats = request("/system_stats")
                break
            except (OSError, ValueError):
                if time.monotonic() > deadline:
                    raise TimeoutError(f"HTTP startup timeout: {stage / 'server.log'}")
                time.sleep(1)
        if stats["system"]["comfyui_version"] != "0.43.0":
            raise AssertionError(stats["system"]["comfyui_version"])
        prompt = {
            "1": {"class_type": "EmptyImage", "inputs": {
                "width": 64, "height": 64, "batch_size": 1, "color": 0}},
            "2": {"class_type": "SaveImage", "inputs": {
                "images": ["1", 0], "filename_prefix": "smoke"}},
        }
        submitted = request("/prompt", {"prompt": prompt})
        prompt_id = submitted["prompt_id"]
        deadline = time.monotonic() + 60
        while True:
            history = request("/history/" + prompt_id)
            if prompt_id in history:
                result = history[prompt_id]
                if not result["status"]["completed"]:
                    raise AssertionError(result["status"])
                break
            if time.monotonic() > deadline:
                raise TimeoutError("Model-free workflow timed out")
            time.sleep(0.5)
        images = list((stage / "output").glob("smoke*.png"))
        if len(images) != 1 or images[0].read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise AssertionError("Output image missing or invalid")
        print(json.dumps({"result": "OK", "core": "0.43.0", "http": "OK",
                          "modelFreeWorkflow": "OK", "evidence": str(stage)}))
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=15)
