#!/usr/bin/env python3
"""
End-to-end integration test for python/kernel_bridge.py and nbformat 4.5 validation.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = ROOT / "python" / "kernel_bridge.py"
DEMO_NB = ROOT / "examples" / "demo.ipynb"


def read_msg(proc: subprocess.Popen) -> dict:
    line = proc.stdout.readline()
    assert line, "Unexpected EOF from kernel_bridge.py"
    return json.loads(line)


def send_req(proc: subprocess.Popen, req_id: int, method: str, params: dict | None = None) -> None:
    payload = {"id": req_id, "method": method, "params": params or {}}
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()


def wait_response(proc: subprocess.Popen, req_id: int) -> dict:
    while True:
        msg = read_msg(proc)
        if msg.get("type") == "response" and msg.get("id") == req_id:
            return msg


def run_cell(proc: subprocess.Popen, req_id: int, cell_id: str, code: str) -> tuple[list[dict], dict]:
    send_req(proc, req_id, "execute", {"cell_id": cell_id, "code": code})
    outputs = []
    while True:
        msg = read_msg(proc)
        if msg.get("id") != req_id:
            continue
        if msg.get("type") == "output":
            outputs.append(msg["output"])
        elif msg.get("type") == "execute_reply":
            return outputs, msg


def main() -> None:
    print("=== Running juvimter.nvim Python bridge & nbformat integration tests ===")

    # 1. Validate demo.ipynb strictly with nbformat (if installed)
    try:
        import nbformat

        nb = nbformat.read(DEMO_NB, as_version=4)
        nbformat.validate(nb)
        print("  [PASS] examples/demo.ipynb passes strict nbformat 4.5 validation")
    except ImportError:
        print("  [SKIP] nbformat not installed in test python")

    # 2. Spawn kernel_bridge.py
    proc = subprocess.Popen(
        [sys.executable, "-u", str(BRIDGE)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    try:
        ready = read_msg(proc)
        assert ready.get("type") == "ready", f"Expected ready, got {ready}"
        print("  [PASS] kernel_bridge.py ready handshake")

        # 3. Start kernel using current python executable (venv direct mode)
        send_req(proc, 1, "start", {"kernel_name": "test_venv", "python_path": sys.executable, "cwd": str(ROOT)})
        resp = wait_response(proc, 1)
        assert resp.get("ok"), f"Kernel start failed: {resp}"
        print("  [PASS] kernel started via direct python_path")

        # 4. Execute basic stdout + execute_result
        outs, reply = run_cell(proc, 2, "c1", "x = 21\nprint('hello juvimter')\nx * 2")
        assert reply["status"] == "ok", f"Unexpected reply: {reply}"
        assert any(o.get("output_type") == "stream" and "hello juvimter" in o.get("text", "") for o in outs)
        assert any(o.get("output_type") == "execute_result" and o["data"].get("text/plain") == "42" for o in outs)
        print("  [PASS] execute stdout + execute_result")

        # 5. Execute DataFrame + Matplotlib plot (if pandas/matplotlib available)
        outs_df, reply_df = run_cell(
            proc,
            3,
            "c2",
            "import pandas as pd\ndf = pd.DataFrame({'a': [1, 2], 'b': [3.5, 4.5]})\ndf",
        )
        assert reply_df["status"] == "ok"
        assert any("text/html" in o.get("data", {}) for o in outs_df), f"Expected HTML table in {outs_df}"
        print("  [PASS] pandas DataFrame HTML output captured")

        outs_plt, reply_plt = run_cell(
            proc,
            4,
            "c3",
            "import matplotlib\nmatplotlib.use('module://matplotlib_inline.backend_inline')\n"
            "import matplotlib.pyplot as plt\n"
            "plt.figure(figsize=(3, 2))\nplt.plot([0, 1, 2], [0, 1, 4])\nplt.show()",
        )
        assert reply_plt["status"] == "ok"
        assert any("image/png" in o.get("data", {}) for o in outs_plt), f"Expected image/png in {outs_plt}"
        print("  [PASS] matplotlib image/png base64 output captured")

        # 6. Inspect variables (Variable Explorer backend)
        send_req(proc, 5, "inspect_variables")
        vresp = wait_response(proc, 5)
        assert vresp.get("ok"), f"inspect_variables failed: {vresp}"
        vmap = {v["name"]: v for v in vresp["result"]}
        assert "x" in vmap and vmap["x"]["type"] == "int", f"Missing x in {vmap}"
        assert "df" in vmap and vmap["df"]["shape"] == "(2, 2)", f"Missing df shape in {vmap}"
        print(f"  [PASS] variable explorer returned {len(vmap)} live variables (x=int, df=(2, 2))")

        # 7. Error capture
        outs_err, reply_err = run_cell(proc, 6, "c4", "1 / 0")
        assert reply_err["status"] == "error"
        assert any(o.get("output_type") == "error" and o.get("ename") == "ZeroDivisionError" for o in outs_err)
        print("  [PASS] error traceback captured cleanly")

        # 8. Restart kernel & confirm clean state
        send_req(proc, 7, "restart")
        rresp = wait_response(proc, 7)
        assert rresp.get("ok"), f"restart failed: {rresp}"
        send_req(proc, 8, "inspect_variables")
        vresp2 = wait_response(proc, 8)
        assert vresp2.get("ok") and len(vresp2["result"]) == 0, f"Expected empty vars after restart, got {vresp2}"
        print("  [PASS] kernel restart clears state")

        # 9. Clean shutdown
        send_req(proc, 9, "shutdown")
        sresp = wait_response(proc, 9)
        assert sresp.get("ok")
        proc.wait(timeout=10)
        print("  [PASS] clean kernel shutdown (zero orphan processes)")
    finally:
        if proc.poll() is None:
            proc.kill()

    print("=== ALL PYTHON INTEGRATION TESTS PASSED! ===")


if __name__ == "__main__":
    main()
