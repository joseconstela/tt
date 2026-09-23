#!/usr/bin/env python3
"""tt's Jupyter bridge: one kernel, spoken to over stdin/stdout.

tt starts this script with the interpreter of the notebook's environment
and talks to it in NDJSON — one JSON object per line, each way. The script
starts a Jupyter kernel through jupyter_client (the same library Jupyter
Lab and VS Code use), so any installed kernel works and the kernel does
everything Jupyter's would: magics, rich display, interrupts.

Requests, on stdin:
  {"op": "exec", "id": "<cell>", "code": "..."}   run a cell
  {"op": "interrupt"}                             SIGINT the kernel
  {"op": "restart"}                               restart it (state is lost)
  {"op": "shutdown"}                              stop it and exit
  {"op": "vars"}                                  list the user's variables
  {"op": "input", "text": "..."}                  answer an input() prompt

Events, on stdout (all carry "ev"):
  kernel      state: starting | ready | restarting | dead, with the spec, the
              interpreter and its version once ready
  status      busy | idle, with the cell it refers to when known
  stream      id, name (stdout | stderr), text
  display     id, data (a mime bundle), metadata
  result      id, count, data, metadata
  error       id, ename, evalue, traceback (a list of lines)
  clear       id, wait
  done        id, status (ok | error | aborted), count, ms
  vars        items: [{name, type, value}]
  input_request  id, prompt, password
  memory      rss_mb of the kernel process
  fatal       reason (no_jupyter_client | no_such_kernel | start_failed), detail
  log         text (diagnostics)

Exit codes: 0 done, 3 jupyter_client is not importable with this interpreter
(tt then tries the next one), 4 the kernel could not start.

A mime bundle that carries an HTML table (a DataFrame's repr) gets one more
entry, "application/vnd.tt.table+json": {"columns", "dtypes", "rows",
"truncated"}, so tt can draw the table natively.
"""
import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from html.parser import HTMLParser

MARK = "\x00tt-vars\x00"


def emit(ev, **fields):
    fields["ev"] = ev
    try:
        sys.stdout.write(json.dumps(fields, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, OSError):
        os._exit(0)


try:
    from jupyter_client.manager import KernelManager
    from jupyter_client.kernelspec import NoSuchKernel
except Exception as exc:  # ImportError, or a broken installation
    emit("fatal", reason="no_jupyter_client", detail=str(exc), python=sys.executable)
    sys.exit(3)


# ── HTML tables → native tables ──────────────────────────────────────────
class TableParser(HTMLParser):
    """Collects the first <table>'s rows: header rows (th cells) and body rows."""

    MAX_ROWS = 200
    MAX_COLS = 60

    def __init__(self):
        super().__init__()
        self.in_table = False
        self.done = False
        self.in_head = False
        self.row = None
        self.cell = None
        self.head_rows = []
        self.body_rows = []
        self.truncated = False

    def handle_starttag(self, tag, attrs):
        if self.done:
            return
        if tag == "table":
            if self.in_table:
                return  # nested tables: flatten their text into the cell
            self.in_table = True
        if not self.in_table:
            return
        if tag == "thead":
            self.in_head = True
        elif tag == "tr":
            self.row = []
            self.row_is_head = self.in_head
        elif tag in ("td", "th") and self.row is not None:
            self.cell = []
            if tag == "th" and not self.in_head and not self.row:
                self.row_is_head = self.row_is_head or False

    def handle_endtag(self, tag):
        if not self.in_table or self.done:
            return
        if tag == "thead":
            self.in_head = False
        elif tag in ("td", "th") and self.cell is not None and self.row is not None:
            text = " ".join("".join(self.cell).split())
            if len(self.row) < self.MAX_COLS:
                self.row.append(text)
            self.cell = None
        elif tag == "tr" and self.row is not None:
            target = self.head_rows if self.row_is_head else self.body_rows
            if len(target) < self.MAX_ROWS:
                target.append(self.row)
            elif not self.row_is_head:
                self.truncated = True
            self.row = None
        elif tag == "table":
            self.done = True
            self.in_table = False

    def handle_data(self, data):
        if self.cell is not None:
            self.cell.append(data)


def html_table(html):
    if "<table" not in html:
        return None
    try:
        p = TableParser()
        p.feed(html)
        p.close()
    except Exception:
        return None
    if not p.head_rows and not p.body_rows:
        return None
    columns = p.head_rows[0] if p.head_rows else []
    dtypes = p.head_rows[1] if len(p.head_rows) > 1 else None
    rows = p.body_rows
    width = max([len(columns)] + [len(r) for r in rows]) if (rows or columns) else 0
    if width == 0:
        return None
    columns = (columns + [""] * width)[:width]
    rows = [(r + [""] * width)[:width] for r in rows]
    if dtypes is not None:
        dtypes = (dtypes + [""] * width)[:width]
    return {"columns": columns, "dtypes": dtypes, "rows": rows, "truncated": p.truncated}


def enrich(data):
    """Adds the native-table entry to a mime bundle that has an HTML table."""
    if not isinstance(data, dict):
        return data
    html = data.get("text/html")
    if isinstance(html, list):
        html = "".join(html)
    if isinstance(html, str):
        table = html_table(html)
        if table:
            data = dict(data)
            data["application/vnd.tt.table+json"] = table
    return data


# ── the user's variables, for the inspector and the agent ────────────────
VARS_CODE = r'''
def __tt_vars():
    import json as _json, types as _types
    out = []
    for k, v in list(globals().items()):
        if k.startswith('_') or k in ('In', 'Out', 'get_ipython', 'exit', 'quit', 'open'):
            continue
        if isinstance(v, (_types.FunctionType, _types.BuiltinFunctionType, _types.MethodType, type)):
            continue
        t = type(v).__name__
        try:
            if isinstance(v, _types.ModuleType):
                s = getattr(v, '__name__', '')
            elif hasattr(v, 'shape') and isinstance(getattr(v, 'shape'), tuple) and len(v.shape) == 2:
                s = "{:,} × {:,}".format(v.shape[0], v.shape[1])
            elif hasattr(v, 'shape') and isinstance(getattr(v, 'shape'), tuple):
                s = 'shape ' + str(tuple(v.shape))
            elif isinstance(v, (list, tuple, set, frozenset, dict)):
                s = "{:,} items".format(len(v))
            elif isinstance(v, str):
                s = repr(v if len(v) <= 60 else v[:57] + '…')
            else:
                s = repr(v)
                s = s if len(s) <= 80 else s[:77] + '…'
        except Exception:
            s = '?'
        out.append({"name": k, "type": t, "value": s})
        if len(out) >= 300:
            break
    print(%r + _json.dumps(out))
__tt_vars()
del __tt_vars
''' % MARK


# ── the bridge ───────────────────────────────────────────────────────────
class Bridge:
    def __init__(self, kernel_name, cwd, want_vars):
        self.kernel_name = kernel_name
        self.cwd = cwd
        self.want_vars = want_vars
        self.km = None
        self.kc = None
        self.ops = queue.Queue()
        self.stop = False
        self.pending = {}  # msg_id → cell id
        self.started = {}  # cell id → time of the execute request
        self.vars_msg = None
        self.vars_text = []
        self.info_msg = None
        self.spec = {}
        self.last_alive_check = 0.0
        self.last_memory = 0.0
        self.alive = True

    # ── kernel lifecycle ────────────────────────────────────────────────
    def start(self):
        emit("kernel", state="starting", spec={"name": self.kernel_name})
        name = self.kernel_name
        try:
            self.km = KernelManager(kernel_name=name)
            self.km.kernel_spec  # resolves the spec now, raising if missing
        except NoSuchKernel:
            if name != "python3":
                emit("log", text="kernel %r is not installed; using python3" % name)
                name = "python3"
                try:
                    self.km = KernelManager(kernel_name=name)
                    self.km.kernel_spec
                except NoSuchKernel as exc:
                    emit("fatal", reason="no_such_kernel", detail=str(exc), python=sys.executable)
                    sys.exit(4)
            else:
                emit("fatal", reason="no_such_kernel", detail="the python3 kernel (ipykernel) is not installed", python=sys.executable)
                sys.exit(4)
        try:
            self.km.start_kernel(cwd=self.cwd or None)
            self.kc = self.km.client()
            self.kc.start_channels()
            self.kc.wait_for_ready(timeout=90)
        except Exception as exc:
            emit("fatal", reason="start_failed", detail=str(exc), python=sys.executable)
            sys.exit(4)
        spec = self.km.kernel_spec
        argv0 = spec.argv[0] if spec.argv else ""
        interpreter = argv0 if os.path.isabs(argv0) else sys.executable
        self.spec = {
            "name": name,
            "display_name": spec.display_name,
            "language": spec.language,
            "interpreter": interpreter,
            "pid": self.kernel_pid(),
        }
        self.alive = True
        # The version comes with the kernel_info reply; `ready` is sent then.
        self.info_msg = self.kc.kernel_info()

    def kernel_pid(self):
        try:
            return self.km.provisioner.pid
        except Exception:
            pass
        try:
            return self.km.kernel.pid
        except Exception:
            return None

    def restart(self):
        emit("kernel", state="restarting", spec=self.spec)
        self.pending.clear()
        self.started.clear()
        self.vars_msg = None
        try:
            self.kc.stop_channels()
        except Exception:
            pass
        try:
            self.km.restart_kernel(now=True)
            self.kc = self.km.client()
            self.kc.start_channels()
            self.kc.wait_for_ready(timeout=90)
        except Exception as exc:
            emit("fatal", reason="start_failed", detail=str(exc), python=sys.executable)
            self.alive = False
            return
        self.spec["pid"] = self.kernel_pid()
        self.alive = True
        self.info_msg = self.kc.kernel_info()

    def shutdown(self):
        try:
            if self.kc is not None:
                self.kc.stop_channels()
        except Exception:
            pass
        try:
            if self.km is not None and self.km.has_kernel:
                self.km.shutdown_kernel(now=True)
        except Exception:
            pass

    # ── stdin → ops ─────────────────────────────────────────────────────
    def reader(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                self.ops.put(json.loads(line))
            except ValueError:
                emit("log", text="bad request line: %r" % line[:200])
        self.ops.put({"op": "shutdown"})  # EOF: tt is gone

    def handle_op(self, op):
        kind = op.get("op")
        if kind == "exec":
            cell = str(op.get("id", ""))
            code = op.get("code", "")
            if not self.alive:
                emit("done", id=cell, status="aborted", count=None, ms=0)
                return
            msg_id = self.kc.execute(code, silent=False, store_history=True, allow_stdin=True, stop_on_error=True)
            self.pending[msg_id] = cell
            self.started[cell] = time.monotonic()
        elif kind == "interrupt":
            try:
                self.km.interrupt_kernel()
            except Exception as exc:
                emit("log", text="interrupt failed: %s" % exc)
        elif kind == "restart":
            self.restart()
        elif kind == "shutdown":
            self.stop = True
        elif kind == "vars":
            self.request_vars()
        elif kind == "input":
            try:
                self.kc.input(str(op.get("text", "")))
            except Exception as exc:
                emit("log", text="input failed: %s" % exc)
        else:
            emit("log", text="unknown op %r" % kind)

    def request_vars(self):
        if not self.alive or self.vars_msg is not None:
            return
        self.vars_text = []
        self.vars_msg = self.kc.execute(VARS_CODE, silent=True, store_history=False, allow_stdin=False)

    # ── kernel → events ─────────────────────────────────────────────────
    def cell_of(self, msg):
        return self.pending.get(msg.get("parent_header", {}).get("msg_id"))

    def on_iopub(self, msg):
        t = msg["msg_type"]
        c = msg["content"]
        parent = msg.get("parent_header", {}).get("msg_id")
        if parent == self.vars_msg:
            if t == "stream":
                self.vars_text.append(c.get("text", ""))
            elif t == "error":
                emit("log", text="vars failed: %s" % c.get("evalue", ""))
            return
        cell = self.pending.get(parent)
        if t == "status":
            emit("status", state=c.get("execution_state"), id=cell)
        elif cell is None:
            return  # comms, other clients, our own silent requests
        elif t == "stream":
            emit("stream", id=cell, name=c.get("name", "stdout"), text=c.get("text", ""))
        elif t in ("display_data", "update_display_data"):
            emit("display", id=cell, data=enrich(c.get("data", {})), metadata=c.get("metadata", {}))
        elif t == "execute_result":
            emit("result", id=cell, count=c.get("execution_count"), data=enrich(c.get("data", {})), metadata=c.get("metadata", {}))
        elif t == "error":
            emit("error", id=cell, ename=c.get("ename", ""), evalue=c.get("evalue", ""), traceback=c.get("traceback", []))
        elif t == "clear_output":
            emit("clear", id=cell, wait=bool(c.get("wait", False)))
        # execute_input, comm_*: nothing to show

    def on_shell(self, msg):
        t = msg["msg_type"]
        c = msg["content"]
        parent = msg.get("parent_header", {}).get("msg_id")
        if t == "kernel_info_reply" and parent == self.info_msg:
            self.info_msg = None
            info = c.get("language_info", {}) or {}
            emit("kernel", state="ready", spec=self.spec, version=info.get("version", ""),
                 implementation=c.get("implementation", ""), language=info.get("name", self.spec.get("language", "")))
            return
        if t == "execute_reply":
            if parent == self.vars_msg:
                self.vars_msg = None
                text = "".join(self.vars_text)
                at = text.rfind(MARK)
                if at >= 0:
                    try:
                        emit("vars", items=json.loads(text[at + len(MARK):].strip()))
                    except ValueError:
                        emit("log", text="vars: unreadable")
                return
            cell = self.pending.pop(parent, None)
            if cell is None:
                return
            t0 = self.started.pop(cell, None)
            ms = int((time.monotonic() - t0) * 1000) if t0 else 0
            emit("done", id=cell, status=c.get("status", "ok"), count=c.get("execution_count"), ms=ms)
            if self.want_vars and not self.pending:
                self.request_vars()

    def on_stdin(self, msg):
        if msg["msg_type"] == "input_request":
            c = msg["content"]
            emit("input_request", id=self.cell_of(msg), prompt=c.get("prompt", ""), password=bool(c.get("password", False)))

    def memory(self):
        pid = self.spec.get("pid")
        if not pid:
            return
        try:
            out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, timeout=2).stdout.strip()
            if out:
                emit("memory", rss_mb=int(out) // 1024)
        except Exception:
            pass

    # ── main loop ───────────────────────────────────────────────────────
    def run(self):
        self.start()
        threading.Thread(target=self.reader, daemon=True).start()
        while not self.stop:
            try:
                self.pump()
            except SystemExit:
                raise
            except Exception as exc:
                emit("log", text="bridge error: %r" % (exc,))
                time.sleep(0.05)

    def pump(self):
        got = False
        if self.alive:
            try:
                self.on_iopub(self.kc.get_iopub_msg(timeout=0.02))
                got = True
            except queue.Empty:
                pass
            try:
                while True:
                    self.on_shell(self.kc.get_shell_msg(timeout=0))
                    got = True
            except queue.Empty:
                pass
            try:
                while True:
                    self.on_stdin(self.kc.get_stdin_msg(timeout=0))
                    got = True
            except queue.Empty:
                pass
        else:
            time.sleep(0.05)
        try:
            while True:
                self.handle_op(self.ops.get_nowait())
                got = True
        except queue.Empty:
            pass
        now = time.monotonic()
        if now - self.last_alive_check > 1.0:
            self.last_alive_check = now
            if self.alive and not self.km.is_alive():
                self.alive = False
                for cell in list(self.pending.values()):
                    emit("done", id=cell, status="aborted", count=None, ms=0)
                self.pending.clear()
                self.started.clear()
                emit("kernel", state="dead", spec=self.spec)
        if self.alive and now - self.last_memory > 3.0:
            self.last_memory = now
            self.memory()
        if not got and self.alive:
            pass  # the iopub timeout above already paced this loop


def main():
    kernel = "python3"
    cwd = ""
    want_vars = False
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--kernel" and i + 1 < len(args):
            kernel = args[i + 1]
            i += 1
        elif a == "--cwd" and i + 1 < len(args):
            cwd = args[i + 1]
            i += 1
        elif a == "--vars":
            want_vars = True
        i += 1
    bridge = Bridge(kernel, cwd, want_vars)

    def on_term(signum, frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        bridge.run()
    finally:
        bridge.shutdown()


if __name__ == "__main__":
    main()
