#!/usr/bin/env python3
# haiku-vm.py - runs Haiku in QEMU and runs commands in it from the host.
#
# Usage: haiku-vm.py serve IMAGE [--files DIR] [--shots DIR] [--port N]
#        haiku-vm.py exec [--port N] COMMAND
#        haiku-vm.py shot [--port N] NAME
#        haiku-vm.py stop [--port N]
#        haiku-vm.py run IMAGE SCRIPT [--files DIR] [--shots DIR] [--timeout S]
#
# "serve" starts QEMU with a copy of IMAGE (a Haiku anyboot image), goes
# through the first-boot dialog, opens Terminal with the keyboard and
# starts a small agent in it. The agent asks the host for commands over
# HTTP (QEMU's user network gives the host the address 10.0.2.2).
#
# "exec" runs a shell command in Haiku and writes its output. The guest
# can get files from the --files directory at http://10.0.2.2:PORT/files/
# and can ask for a screenshot of the screen with
# "curl http://10.0.2.2:PORT/shot/NAME". The host writes NAME.png into the
# --shots directory with the QEMU monitor.
#
# "run" does "serve", runs SCRIPT (a file on the host) in Haiku, writes the
# output, stops QEMU and exits with the status of the script.
#
# QEMU must be on the PATH. KVM is used when /dev/kvm is there.
#
# Part of clang-retro unix-sdk.
# SPDX-License-Identifier: AGPL-3.0-only
import http.server
import os
import queue
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

DEFAULT_PORT = 8765

# Agent typed into Terminal. It gets jobs from the host and sends back the
# output. nohup keeps it alive when the Terminal window closes.
AGENT = r'''#!/bin/sh
H=http://10.0.2.2:%d
while :; do
  rm -f /tmp/job.sh
  if curl -sf -o /tmp/job.sh $H/next && [ -s /tmp/job.sh ]; then
    sh /tmp/job.sh > /tmp/job.out 2>&1 < /dev/null
    echo "@@exit=$?" >> /tmp/job.out
    curl -sf -T /tmp/job.out $H/result > /dev/null
  else
    sleep 1
  fi
done
'''

# QEMU's "sendkey" names for characters that are not letters or digits.
PLAIN_KEYS = {" ": "spc", "\n": "ret", "-": "minus", "=": "equal", "/": "slash", ".": "dot", ",": "comma",
              ";": "semicolon", "'": "apostrophe", "`": "grave_accent", "[": "bracket_left",
              "]": "bracket_right", "\\": "backslash", "\t": "tab"}
SHIFT_KEYS = {"_": "minus", "+": "equal", "?": "slash", ">": "dot", "<": "comma", ":": "semicolon",
              '"': "apostrophe", "~": "grave_accent", "{": "bracket_left", "}": "bracket_right",
              "|": "backslash", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
              "*": "8", "(": "9", ")": "0"}


class Monitor:
    """Talks to the QEMU human monitor through a Unix socket."""

    def __init__(self, path):
        """Connects to the monitor socket. Waits until QEMU makes it."""
        for _ in range(100):
            try:
                self.sock = socket.socket(socket.AF_UNIX)
                self.sock.connect(path)
                break
            except OSError:
                time.sleep(0.2)
        else:
            raise RuntimeError("cannot connect to the QEMU monitor")
        self.sock.settimeout(0.3)
        self.lock = threading.Lock()
        self.drain()

    def drain(self):
        """Reads and discards what the monitor wrote."""
        try:
            while self.sock.recv(65536):
                pass
        except OSError:
            pass

    def command(self, text):
        """Sends one monitor command."""
        with self.lock:
            self.sock.sendall((text + "\n").encode())
            time.sleep(0.05)
            self.drain()

    def key(self, name):
        """Presses and releases one key, named as "sendkey" names it."""
        self.command("sendkey " + name)
        time.sleep(0.04)

    def type(self, text):
        """Types text. Upper-case letters and symbols use Shift."""
        for c in text:
            if c in PLAIN_KEYS:
                self.key(PLAIN_KEYS[c])
            elif c in SHIFT_KEYS:
                self.key("shift-" + SHIFT_KEYS[c])
            elif c.isupper():
                self.key("shift-" + c.lower())
            else:
                self.key(c)

    def screendump(self, path):
        """Writes the screen to a PNG file and waits until the file is there."""
        if os.path.exists(path):
            os.remove(path)
        self.command("screendump %s -f png" % path)
        for _ in range(50):
            if os.path.exists(path) and os.path.getsize(path) > 0:
                time.sleep(0.2)
                return
            time.sleep(0.1)


class Server(http.server.ThreadingHTTPServer):
    """Holds the job queue, the results and the paths of the session."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, port, files, shots, monitor_holder):
        """Starts listening on all addresses at port."""
        super().__init__(("0.0.0.0", port), Handler)
        self.port = port
        self.files = files
        self.shots = shots
        self.monitor_holder = monitor_holder
        self.jobs = queue.Queue()
        self.results = queue.Queue()
        self.agent_seen = threading.Event()
        self.stop_requested = threading.Event()
        self.exec_lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    """Answers the agent in Haiku and the "exec" client on the host."""

    def log_message(self, fmt, *args):
        """Keeps the requests out of the output."""

    def reply(self, code, body=b"", kind="application/octet-stream"):
        """Sends a response with a body."""
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        """Reads the request body."""
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_GET(self):
        """Gives the agent, a job, a file or a screenshot."""
        s = self.server
        if self.path == "/agent.sh":
            self.reply(200, (AGENT % s.port).encode())
        elif self.path == "/next":
            s.agent_seen.set()
            try:
                job = s.jobs.get(timeout=15)
            except queue.Empty:
                # Not 204: "curl -f" takes any 2xx as a job.
                self.reply(404)
                return
            self.reply(200, job.encode())
        elif self.path.startswith("/files/") and s.files:
            rel = urllib.request.url2pathname(self.path[len("/files/"):])
            full = os.path.realpath(os.path.join(s.files, rel))
            if not full.startswith(os.path.realpath(s.files) + os.sep) or not os.path.isfile(full):
                self.reply(404)
                return
            with open(full, "rb") as f:
                self.reply(200, f.read())
        elif self.path.startswith("/shot/"):
            name = re.sub(r"[^A-Za-z0-9_.-]", "_", self.path[len("/shot/"):]) or "shot"
            os.makedirs(s.shots, exist_ok=True)
            out = os.path.join(s.shots, name + ".png")
            s.monitor_holder[0].screendump(out)
            self.reply(200, (out + "\n").encode())
        elif self.path == "/stop":
            s.stop_requested.set()
            self.reply(200)
        else:
            self.reply(404)

    def do_PUT(self):
        """Takes the output of a job, or a file to keep."""
        s = self.server
        data = self.body()
        if self.path == "/result":
            s.results.put(data)
            self.reply(200)
        elif self.path.startswith("/upload/"):
            name = re.sub(r"[^A-Za-z0-9_.-]", "_", self.path[len("/upload/"):])
            os.makedirs(s.shots, exist_ok=True)
            with open(os.path.join(s.shots, name), "wb") as f:
                f.write(data)
            self.reply(200)
        else:
            self.reply(404)

    def do_POST(self):
        """Runs a job for the "exec" client and gives back its output."""
        s = self.server
        if self.path != "/exec":
            self.reply(404)
            return
        script = self.body().decode()
        with s.exec_lock:
            s.jobs.put(script)
            out = s.results.get()
        self.reply(200, out)


def boot(image, port, files, shots, memory):
    """Starts QEMU and the agent. Returns the QEMU process and the server."""
    work = tempfile.mkdtemp(prefix="haiku-vm-")
    disk = os.path.join(work, "disk.img")
    shutil.copyfile(image, disk)
    mon_path = os.path.join(work, "monitor")
    serial = os.path.join(work, "serial.log")
    holder = [None]
    server = Server(port, files, shots, holder)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    accel = ["-accel", "kvm"] if os.access("/dev/kvm", os.W_OK) else ["-accel", "tcg,thread=multi"]
    cmd = ["qemu-system-x86_64", "-m", str(memory), "-smp", str(min(4, os.cpu_count() or 1))] + accel + [
        "-drive", "file=%s,format=raw,if=ide" % disk, "-display", "none", "-vga", "std",
        "-monitor", "unix:%s,server,nowait" % mon_path, "-serial", "file:%s" % serial,
        "-nic", "user,model=e1000"]
    qemu = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    mon = Monitor(mon_path)
    holder[0] = mon
    log("booting Haiku (%s)" % ("KVM" if "kvm" in accel[1] else "no KVM, this is slow"))
    # The first-boot dialog: Enter picks "Try Haiku". The serial log says
    # when the launch daemon has checked for it.
    wait_for(serial, rb"FirstBootPrompt", 1800, qemu)
    time.sleep(25)
    mon.key("ret")
    wait_for(serial, rb"first login script|default_deskbar_items", 900, qemu)
    time.sleep(30)
    # Terminal, through Tracker with the keyboard: the boot volume's icon
    # on the Desktop, then system/apps/Terminal.
    for name, pause in (("Haiku", 8), ("system", 8), ("apps", 8), ("Terminal", 15)):
        mon.type(name)
        time.sleep(1)
        mon.key("alt-down")
        time.sleep(pause)
    mon.type("curl -s http://10.0.2.2:%d/agent.sh > /tmp/agent.sh && nohup sh /tmp/agent.sh > /dev/null 2>&1 &\n" % port)
    time.sleep(3)
    mon.type("exit\n")
    # Closes the three Tracker windows that the way to Terminal opened.
    time.sleep(5)
    for _ in range(3):
        mon.key("alt-w")
        time.sleep(2)
    if not server.agent_seen.wait(300):
        raise RuntimeError("the agent in Haiku did not start")
    log("Haiku is ready")
    return qemu, server, work


def wait_for(path, pattern, timeout, proc):
    """Waits until the serial log at path matches pattern."""
    end = time.time() + timeout
    while time.time() < end:
        if proc.poll() is not None:
            raise RuntimeError("QEMU stopped")
        try:
            with open(path, "rb") as f:
                if re.search(pattern, f.read()):
                    return
        except OSError:
            pass
        time.sleep(2)
    raise RuntimeError("timed out waiting for %r" % pattern)


def log(text):
    """Writes a progress line to standard error."""
    sys.stderr.write("haiku-vm: %s\n" % text)
    sys.stderr.flush()


def run_job(server, script):
    """Queues a job and waits for its output. Returns (output, status)."""
    with server.exec_lock:
        server.jobs.put(script)
        out = server.results.get().decode("utf-8", "replace")
    m = re.search(r"@@exit=(\d+)\s*$", out)
    status = int(m.group(1)) if m else 1
    return out[:m.start()] if m else out, status


def options(argv):
    """Splits argv into positional arguments and --name value options."""
    pos, opt = [], {}
    i = 0
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv):
            opt[argv[i][2:]] = argv[i + 1]
            i += 2
        else:
            pos.append(argv[i])
            i += 1
    return pos, opt


def client(port, method, path, data=None):
    """Sends a request to a running "serve" and returns the body."""
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), data=data, method=method)
    with urllib.request.urlopen(req, timeout=3600) as r:
        return r.read()


def main(argv):
    """Runs one command of the tool."""
    if len(argv) < 2:
        sys.stderr.write(open(__file__).read().split("\n\n")[0] + "\n")
        return 2
    pos, opt = options(argv[2:])
    port = int(opt.get("port", DEFAULT_PORT))
    files = os.path.abspath(opt["files"]) if "files" in opt else None
    shots = os.path.abspath(opt.get("shots", "shots"))
    memory = int(opt.get("memory", 2048))
    cmd = argv[1]
    if cmd == "exec":
        out = client(port, "POST", "/exec", " ".join(pos).encode()).decode("utf-8", "replace")
        m = re.search(r"@@exit=(\d+)\s*$", out)
        sys.stdout.write(out[:m.start()] if m else out)
        return int(m.group(1)) if m else 1
    if cmd == "shot":
        sys.stdout.write(client(port, "GET", "/shot/" + pos[0]).decode())
        return 0
    if cmd == "stop":
        client(port, "GET", "/stop")
        return 0
    if cmd in ("serve", "run"):
        qemu, server, work = boot(pos[0], port, files, shots, memory)
        status = 0
        try:
            if cmd == "run":
                with open(pos[1]) as f:
                    out, status = run_job(server, f.read())
                sys.stdout.write(out)
            else:
                while not server.stop_requested.wait(1):
                    if qemu.poll() is not None:
                        break
        finally:
            if qemu.poll() is None:
                qemu.terminate()
                qemu.wait()
            server.shutdown()
            shutil.rmtree(work, ignore_errors=True)
        return status
    sys.stderr.write("unknown command %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
