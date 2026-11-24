#!/usr/bin/env python3
"""
juvimter.nvim - Lightweight Jupyter Kernel Bridge (JSON-RPC over stdio).

Communicates with Neovim via newline-delimited JSON messages on stdin/stdout.
All ZMQ/KernelClient operations run on a single dedicated worker thread for
strict thread safety, while interrupt() runs immediately from the stdin thread.
"""

from __future__ import annotations

import json
import os
import queue
import signal
import sys
import threading
import time
import traceback
from typing import Any, Dict, Optional

try:
    from jupyter_client import KernelManager
    from jupyter_client.kernelspec import KernelSpecManager
except ImportError as exc:
    sys.stdout.write(
        json.dumps(
            {
                "type": "fatal",
                "error": f"jupyter_client is not installed in {sys.executable}: {exc}",
            }
        )
        + "\n"
    )
    sys.stdout.flush()
    sys.exit(1)


_stdout_lock = threading.Lock()


def emit(payload: Dict[str, Any]) -> None:
    """Thread-safe JSON line writer to stdout."""
    line = json.dumps(payload, ensure_ascii=False, default=str)
    with _stdout_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


PYTHON_VARS_SNIPPET = r"""
import json as _jv_json
import types as _jv_types

def _jv_collect_vars():
    _skip = {
        "In", "Out", "get_ipython", "exit", "quit", "open",
        "_", "__", "___", "_i", "_ii", "_iii", "_oh", "_dh", "_sh",
        "_jv_json", "_jv_types", "_jv_collect_vars",
    }
    _g = globals()
    _res = []
    for _name, _val in sorted(_g.items()):
        if _name.startswith("_") or _name in _skip:
            continue
        if isinstance(_val, (_jv_types.ModuleType, _jv_types.FunctionType, _jv_types.BuiltinFunctionType, type)):
            continue
        _tname = type(_val).__name__
        _shape = ""
        try:
            if hasattr(_val, "shape"):
                _s = getattr(_val, "shape")
                if not callable(_s):
                    _shape = str(tuple(_s))
            elif hasattr(_val, "__len__"):
                _shape = f"len={len(_val)}"
        except Exception:
            _shape = ""
        try:
            _preview = repr(_val).replace("\n", " ")
            if len(_preview) > 120:
                _preview = _preview[:117] + "..."
        except Exception:
            _preview = "<unrepresentable>"
        _res.append({
            "name": _name,
            "type": _tname,
            "shape": _shape,
            "value": _preview,
        })
    print("__JUVIMTER_VARS__" + _jv_json.dumps(_res, ensure_ascii=False))

_jv_collect_vars()
del _jv_collect_vars, _jv_json, _jv_types
""".strip()


class VenvKernelManager(KernelManager):
    """KernelManager subclass that launches ipykernel directly from a Python binary."""

    def __init__(self, python_path: str, **kwargs: Any) -> None:
        self._python_path = python_path
        super().__init__(**kwargs)

    def format_kernel_cmd(self, extra_arguments: Optional[list[str]] = None) -> list[str]:
        cmd = [
            self._python_path,
            "-m",
            "ipykernel_launcher",
            "-f",
            self.connection_file,
        ]
        if extra_arguments:
            cmd.extend(extra_arguments)
        return cmd


class KernelBridge:
    def __init__(self) -> None:
        self.km: Optional[KernelManager] = None
        self.kc: Any = None
        self.kernel_info: Dict[str, Any] = {}
        self.kernel_name: str = ""
        self.python_path: Optional[str] = None
        self.cwd: Optional[str] = None
        self._cmd_queue: "queue.Queue[Dict[str, Any]]" = queue.Queue()
        self._running = True
        self._worker = threading.Thread(target=self._worker_loop, daemon=True)
        self._worker.start()

    def _drain_queue(self) -> None:
        while not self._cmd_queue.empty():
            try:
                self._cmd_queue.get_nowait()
            except queue.Empty:
                break

    def _shutdown_kernel(self) -> None:
        if self.kc is not None:
            try:
                self.kc.stop_channels()
            except Exception:
                pass
            self.kc = None
        if self.km is not None:
            try:
                if self.km.is_alive():
                    self.km.shutdown_kernel(now=False)
            except Exception:
                try:
                    self.km.shutdown_kernel(now=True)
                except Exception:
                    pass
            self.km = None

    def _worker_loop(self) -> None:
        while self._running:
            try:
                cmd = self._cmd_queue.get(timeout=0.2)
            except queue.Empty:
                continue

            method = cmd["method"]
            req_id = cmd["req_id"]
            params = cmd.get("params") or {}

            try:
                if method == "list_kernels":
                    self._handle_list_kernels(req_id)
                elif method == "start":
                    self._handle_start(req_id, params)
                elif method == "execute":
                    self._handle_execute(req_id, params)
                elif method == "inspect_variables":
                    self._handle_inspect_variables(req_id)
                elif method == "restart":
                    self._handle_restart(req_id)
                elif method == "shutdown":
                    self._shutdown_kernel()
                    self._running = False
                    if req_id is not None:
                        emit({"type": "response", "id": req_id, "ok": True})
                    return
                else:
                    emit({"type": "response", "id": req_id, "ok": False, "error": f"Unknown method: {method}"})
            except Exception as exc:
                emit(
                    {
                        "type": "response",
                        "id": req_id,
                        "ok": False,
                        "error": str(exc),
                        "traceback": traceback.format_exc(),
                    }
                )

    def _handle_list_kernels(self, req_id: Any) -> None:
        ksm = KernelSpecManager()
        specs = ksm.find_kernel_specs()
        result = []
        for name, path in sorted(specs.items()):
            try:
                spec = ksm.get_kernel_spec(name)
                result.append(
                    {
                        "name": name,
                        "display_name": spec.display_name,
                        "language": spec.language,
                        "argv": spec.argv,
                        "resource_dir": path,
                    }
                )
            except Exception as exc:
                result.append({"name": name, "display_name": name, "error": str(exc)})
        emit({"type": "response", "id": req_id, "ok": True, "result": result})

    def _handle_start(self, req_id: Any, params: Dict[str, Any]) -> None:
        kernel_name = params.get("kernel_name") or "python3"
        python_path = params.get("python_path")
        cwd = params.get("cwd") or os.getcwd()

        self._shutdown_kernel()
        try:
            if python_path:
                km: KernelManager = VenvKernelManager(python_path=python_path)
                self.python_path = python_path
            else:
                km = KernelManager(kernel_name=kernel_name)
                self.python_path = None

            km.start_kernel(cwd=cwd)
            kc = km.client()
            kc.start_channels()
            kc.wait_for_ready(timeout=30)

            info_msg = kc.kernel_info(reply=True, timeout=10)
            content = info_msg.get("content", {}) if isinstance(info_msg, dict) else {}

            self.km = km
            self.kc = kc
            self.kernel_name = kernel_name
            self.cwd = cwd
            self.kernel_info = {
                "kernel_name": kernel_name,
                "python_path": python_path,
                "language_info": content.get("language_info", {}),
                "implementation": content.get("implementation", ""),
                "implementation_version": content.get("implementation_version", ""),
                "banner": content.get("banner", ""),
            }
            emit({"type": "response", "id": req_id, "ok": True, "result": self.kernel_info})
        except Exception as exc:
            self._shutdown_kernel()
            emit(
                {
                    "type": "response",
                    "id": req_id,
                    "ok": False,
                    "error": f"Failed to start kernel '{kernel_name}': {exc}",
                    "traceback": traceback.format_exc(),
                }
            )

    def _handle_execute(self, req_id: Any, params: Dict[str, Any]) -> None:
        kc = self.kc
        cell_id = params.get("cell_id")
        code = params.get("code", "")
        silent = bool(params.get("silent", False))
        store_history = bool(params.get("store_history", not silent))

        if kc is None:
            emit(
                {
                    "type": "execute_reply",
                    "id": req_id,
                    "cell_id": cell_id,
                    "status": "error",
                    "error": "No active kernel",
                    "elapsed_ms": 0,
                }
            )
            return

        t0 = time.monotonic()
        msg_id = kc.execute(code, silent=silent, store_history=store_history, allow_stdin=False)

        idle_received = False
        reply_content: Optional[Dict[str, Any]] = None

        while not idle_received:
            try:
                msg = kc.get_iopub_msg(timeout=0.5)
            except queue.Empty:
                if self.km is None or not self.km.is_alive():
                    emit(
                        {
                            "type": "execute_reply",
                            "id": req_id,
                            "cell_id": cell_id,
                            "status": "error",
                            "error": "Kernel died during execution",
                            "elapsed_ms": int((time.monotonic() - t0) * 1000),
                        }
                    )
                    return
                continue

            if msg.get("parent_header", {}).get("msg_id") != msg_id:
                continue

            msg_type = msg.get("header", {}).get("msg_type") or msg.get("msg_type")
            content = msg.get("content", {})

            if msg_type == "status":
                state = content.get("execution_state")
                emit({"type": "status", "id": req_id, "cell_id": cell_id, "state": state})
                if state == "idle":
                    idle_received = True
            elif msg_type == "stream":
                emit(
                    {
                        "type": "output",
                        "id": req_id,
                        "cell_id": cell_id,
                        "output": {
                            "output_type": "stream",
                            "name": content.get("name", "stdout"),
                            "text": content.get("text", ""),
                        },
                    }
                )
            elif msg_type == "execute_result":
                emit(
                    {
                        "type": "output",
                        "id": req_id,
                        "cell_id": cell_id,
                        "output": {
                            "output_type": "execute_result",
                            "execution_count": content.get("execution_count"),
                            "data": content.get("data", {}),
                            "metadata": content.get("metadata", {}),
                        },
                    }
                )
            elif msg_type == "display_data":
                emit(
                    {
                        "type": "output",
                        "id": req_id,
                        "cell_id": cell_id,
                        "output": {
                            "output_type": "display_data",
                            "data": content.get("data", {}),
                            "metadata": content.get("metadata", {}),
                        },
                    }
                )
            elif msg_type == "update_display_data":
                emit(
                    {
                        "type": "output",
                        "id": req_id,
                        "cell_id": cell_id,
                        "update": True,
                        "output": {
                            "output_type": "display_data",
                            "data": content.get("data", {}),
                            "metadata": content.get("metadata", {}),
                        },
                    }
                )
            elif msg_type == "clear_output":
                emit(
                    {
                        "type": "clear_output",
                        "id": req_id,
                        "cell_id": cell_id,
                        "wait": bool(content.get("wait", False)),
                    }
                )
            elif msg_type == "error":
                emit(
                    {
                        "type": "output",
                        "id": req_id,
                        "cell_id": cell_id,
                        "output": {
                            "output_type": "error",
                            "ename": content.get("ename", "Error"),
                            "evalue": content.get("evalue", ""),
                            "traceback": content.get("traceback", []),
                        },
                    }
                )

        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            try:
                shell_msg = kc.get_shell_msg(timeout=0.5)
            except queue.Empty:
                break
            if shell_msg.get("parent_header", {}).get("msg_id") == msg_id:
                reply_content = shell_msg.get("content", {})
                break

        elapsed_ms = int((time.monotonic() - t0) * 1000)
        reply_content = reply_content or {}
        emit(
            {
                "type": "execute_reply",
                "id": req_id,
                "cell_id": cell_id,
                "status": reply_content.get("status", "ok"),
                "execution_count": reply_content.get("execution_count"),
                "elapsed_ms": elapsed_ms,
            }
        )

    def _handle_inspect_variables(self, req_id: Any) -> None:
        kc = self.kc
        if kc is None:
            emit({"type": "response", "id": req_id, "ok": False, "error": "No active kernel"})
            return

        lang = (self.kernel_info.get("language_info") or {}).get("name", "").lower()
        if lang and lang != "python":
            emit({"type": "response", "id": req_id, "ok": True, "result": []})
            return

        msg_id = kc.execute(PYTHON_VARS_SNIPPET, silent=False, store_history=False, allow_stdin=False)
        captured: list[str] = []
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            try:
                msg = kc.get_iopub_msg(timeout=0.5)
            except queue.Empty:
                continue
            if msg.get("parent_header", {}).get("msg_id") != msg_id:
                continue
            mtype = msg.get("header", {}).get("msg_type") or msg.get("msg_type")
            content = msg.get("content", {})
            if mtype == "stream" and content.get("name") == "stdout":
                captured.append(content.get("text", ""))
            elif mtype == "status" and content.get("execution_state") == "idle":
                break

        # Drain matching shell reply
        shell_deadline = time.monotonic() + 2.0
        while time.monotonic() < shell_deadline:
            try:
                smsg = kc.get_shell_msg(timeout=0.2)
                if smsg.get("parent_header", {}).get("msg_id") == msg_id:
                    break
            except queue.Empty:
                break

        joined = "".join(captured)
        marker = "__JUVIMTER_VARS__"
        idx = joined.find(marker)
        variables = json.loads(joined[idx + len(marker) :].strip()) if idx != -1 else []
        emit({"type": "response", "id": req_id, "ok": True, "result": variables})

    def _handle_restart(self, req_id: Any) -> None:
        if self.km is None or self.kc is None:
            emit({"type": "response", "id": req_id, "ok": False, "error": "No active kernel"})
            return
        self.km.restart_kernel(now=True)
        self.kc.wait_for_ready(timeout=30)
        emit({"type": "response", "id": req_id, "ok": True})

    def interrupt_now(self, req_id: Any) -> None:
        """Immediate OS signal interrupt safe to invoke while worker is executing."""
        self._drain_queue()
        km = self.km
        if km is not None:
            try:
                km.interrupt_kernel()
                emit({"type": "response", "id": req_id, "ok": True})
                return
            except Exception as exc:
                emit({"type": "response", "id": req_id, "ok": False, "error": str(exc)})
                return
        emit({"type": "response", "id": req_id, "ok": False, "error": "No active kernel"})

    def serve(self) -> None:
        emit({"type": "ready", "python": sys.executable})
        while True:
            raw_line = sys.stdin.readline()
            if not raw_line:
                break
            line = raw_line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except json.JSONDecodeError as exc:
                emit({"type": "error", "error": f"Invalid JSON: {exc}"})
                continue

            req_id = req.get("id")
            method = req.get("method")
            params = req.get("params") or {}

            if method == "interrupt":
                self.interrupt_now(req_id)
            elif method == "shutdown":
                self._drain_queue()
                self._cmd_queue.put({"method": "shutdown", "req_id": req_id, "params": {}})
                self._worker.join(timeout=10)
                return
            else:
                if method == "restart":
                    self._drain_queue()
                self._cmd_queue.put({"method": method, "req_id": req_id, "params": params})

        # EOF on stdin -> clean shutdown
        self._drain_queue()
        self._cmd_queue.put({"method": "shutdown", "req_id": None, "params": {}})
        self._worker.join(timeout=10)


def main() -> None:
    bridge = KernelBridge()

    def _handle_sig(_signum: int, _frame: Any) -> None:
        bridge._shutdown_kernel()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _handle_sig)
    signal.signal(signal.SIGINT, _handle_sig)
    bridge.serve()


if __name__ == "__main__":
    main()
