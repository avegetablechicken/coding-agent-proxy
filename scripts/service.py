#!/usr/bin/python3
"""Install a per-user launchd service and supervise its optional mihomo child."""

import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = Path.home() / "Library/Application Support/coding-agent-proxy"
LABEL = "local.coding-agent-proxy"
BREW_LABELS = ("sh.brew.mihomo", "homebrew.mxcl.mihomo")


def log(message):
    print(message, flush=True)


def mihomo_running(binary):
    # A loaded launchd job is not necessarily running. Check its actual state.
    for domain in (f"gui/{os.getuid()}", f"user/{os.getuid()}", "system"):
        for label in BREW_LABELS:
            result = subprocess.run(
                ["/bin/launchctl", "print", f"{domain}/{label}"],
                capture_output=True, text=True,
            )
            if result.returncode == 0 and re.search(
                r"^\s*state = running\s*$", result.stdout, re.MULTILINE
            ):
                return True
    # Also reuse a manually started Homebrew binary, including its Cellar path.
    # Fail on an unreadable process list rather than risk launching a duplicate.
    result = subprocess.run(
        ["/bin/ps", "-ww", "-axo", "command="], capture_output=True, text=True, check=True
    )
    return any(Path(line.split()[0]).resolve() == binary.resolve()
               for line in result.stdout.splitlines() if line.strip())


def brew_paths():
    for prefix in (Path("/opt/homebrew"), Path("/usr/local")):
        binary = prefix / "opt/mihomo/bin/mihomo"
        if binary.is_file():
            return binary, prefix / "etc/mihomo"
    raise RuntimeError("Homebrew mihomo is missing; install it before starting the service.")


def stop_child(child):
    if child is not None and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def port_in_use(port):
    with socket.socket() as probe:
        try:
            probe.bind(("127.0.0.1", port))
        except OSError as error:
            import errno
            if error.errno == errno.EADDRINUSE:
                return True
            raise
    return False


def run_service():
    os.umask(0o077)
    binary, config_dir = brew_paths()
    proxy = ROOT / ".build/release/coding-agent-proxy"
    if not proxy.is_file() or not (ROOT / "config.yaml").is_file():
        raise RuntimeError("Build the release executable and create config.yaml first.")
    children = []
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        port = int(subprocess.check_output(
            [str(proxy), "--config", str(ROOT / "config.yaml"), "--print-listen-port"],
            text=True,
        ).strip())
        if port_in_use(port):
            log(f"Waiting for existing listener on 127.0.0.1:{port}; leaving it untouched.")
            while not stopping and port_in_use(port):
                time.sleep(1)
        if stopping:
            return 0
        if mihomo_running(binary):
            log("Reusing running Homebrew mihomo; its lifecycle remains independent.")
        else:
            config = config_dir / "config.yaml"
            if not config.is_file():
                raise RuntimeError(f"Missing mihomo configuration: {config}")
            # Run the executable directly; never register/start a Homebrew service.
            log("Starting independent mihomo child.")
            child = subprocess.Popen([str(binary), "-d", str(config_dir)], cwd=config_dir)
            children.append(child)
            time.sleep(1)
            if child.poll() is not None:
                raise RuntimeError(f"mihomo exited during startup ({child.returncode}).")
        if stopping:
            return 0
        log("Starting coding-agent-proxy.")
        children.append(subprocess.Popen(
            [str(proxy), "--config", str(ROOT / "config.yaml")], cwd=ROOT
        ))
        while not stopping:
            for child in children:
                if child.poll() is not None:
                    raise RuntimeError(f"Managed process {child.pid} exited ({child.returncode}).")
            time.sleep(0.5)
        return 0
    finally:
        # Only terminate processes we created, never an existing Homebrew service.
        for child in reversed(children):
            stop_child(child)


def manage(action):
    domain = f"gui/{os.getuid()}"
    target = f"{domain}/{LABEL}"
    plist = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
    if action == "status":
        return subprocess.run(["/bin/launchctl", "print", target]).returncode
    if action == "restart":
        return subprocess.run(["/bin/launchctl", "kickstart", "-k", target]).returncode
    if action == "install" and plist.exists():
        raise RuntimeError("Service already installed; use update, then restart when convenient.")
    if action == "update" and not plist.exists():
        raise RuntimeError("Service is not installed; use install first.")
    if action in ("install", "update"):
        brew_paths()
        if not (ROOT / "config.yaml").is_file():
            raise RuntimeError("Create config.yaml first.")
        if not os.access(ROOT / ".build/release/coding-agent-proxy", os.X_OK):
            raise RuntimeError("Run swift build -c release first.")
        # launchd may be denied access to Documents/Desktop before Python starts.
        # Deploy real files to Application Support, not symlinks into the checkout.
        RUNTIME.mkdir(mode=0o700, parents=True, exist_ok=True)
        for relative in ("scripts/service.py", ".build/release/coding-agent-proxy"):
            destination = RUNTIME / relative
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            temporary = destination.with_name(destination.name + ".tmp")
            shutil.copy2(ROOT / relative, temporary)
            temporary.replace(destination)
        config = RUNTIME / "config.yaml"
        if not config.exists():
            shutil.copyfile(ROOT / "config.yaml", config)
            config.chmod(0o600)
        if action == "update":
            log("Updated executable and startup script. Running service unchanged; use restart to apply.")
            return 0
        logs = RUNTIME / "logs"
        logs.mkdir(mode=0o700, exist_ok=True)
        # Pre-create private launchd output files before it opens them.
        for name in ("service.stdout.log", "service.stderr.log"):
            fd = os.open(logs / name, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
            os.close(fd)
        payload = {
            "Label": LABEL,
            "ProgramArguments": ["/usr/bin/python3", str(RUNTIME / "scripts/service.py"), "run"],
            "WorkingDirectory": str(RUNTIME),
            "RunAtLoad": True,
            "KeepAlive": True,
            "ThrottleInterval": 10,
            "ExitTimeOut": 20,
            "Umask": 0o077,
            "StandardOutPath": str(logs / "service.stdout.log"),
            "StandardErrorPath": str(logs / "service.stderr.log"),
        }
        plist.parent.mkdir(parents=True, exist_ok=True)
        temporary = plist.with_suffix(".plist.tmp")
        temporary.write_bytes(plistlib.dumps(payload))
        temporary.chmod(0o600)
        temporary.replace(plist)
    if action == "uninstall":
        loaded = subprocess.run(["/bin/launchctl", "print", target], capture_output=True)
        if loaded.returncode == 0:
            subprocess.run(["/bin/launchctl", "bootout", target], check=True)
        plist.unlink(missing_ok=True)
        log("Service uninstalled.")
    else:
        subprocess.run(["/bin/launchctl", "enable", target], check=True)
        subprocess.run(["/bin/launchctl", "bootstrap", domain, str(plist)], check=True)
        log(f"Installed {plist}")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "update", "run", "status", "restart", "uninstall"))
    args = parser.parse_args()
    try:
        sys.exit(run_service() if args.action == "run" else manage(args.action))
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"Service error: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
